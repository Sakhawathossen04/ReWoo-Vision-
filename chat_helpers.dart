import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/system_prompts.dart';
import '../models/message_models.dart';
import '../voice/bengali_voice_commands.dart';
import '../voice/voice_intent.dart';
import '../widgets/prompt_bar.dart';
import 'chat_history_store.dart';
import 'gemma_service.dart';
import 'live_camera_service.dart';
import 'media_service.dart';
import 'speech_service.dart';
import 'streaming_tts_service.dart';
import 'text_recognition_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Core vision-assistant operations.
///
/// Video-call camera model: the camera is a persistent warm service
/// ([LiveCameraService]) that opens once when the assistant screen appears
/// and stays alive while the screen is visible. Commands capture instantly
/// from the warm preview — no open/dispose cycle per question, which removes
/// the 1–3 s dead time and the OEM camera-stack flakiness that made some
/// commands fail at random.
///
/// Priority 6: user messages now show the actual Bengali command the user
/// spoke ([displayText]) while the model still receives the specialised
/// English task prompt — previously the raw English prompt was displayed in
/// the chat, which broke the conversation feel.
///
/// New voice-only operations:
///   * [takePhoto]  — capture a photo, save it, show it in chat.
///   * [startVideoRecording] / [stopVideoRecording] — full hands-free video.
///     Recording is done without the audio track so the continuous command
///     listener stays alive and "ভিডিও বন্ধ করো" can be heard.
class ChatHelpers {
  final GemmaService _service;
  final StreamingTtsService _streamingTts;
  final SpeechService _speechService;
  final TextRecognitionService _textRecognition;
  final VoidCallback _onStateChanged;
  final Function(String) _showSnackBar;

  String _systemCtx;
  bool _resetting = false;
  bool _isGenerating = false;
  bool _muteCurrentResponse = false;

  // Video recording state (voice controlled start/stop).
  bool _isRecording = false;
  Timer? _recordingSafetyTimer;

  ChatHelpers({
    required GemmaService service,
    required StreamingTtsService streamingTts,
    required SpeechService speechService,
    required TextRecognitionService textRecognition,
    required VoidCallback onStateChanged,
    required Function(String) showSnackBar,
    required String systemContext,
  }) : _service = service,
       _streamingTts = streamingTts,
       _speechService = speechService,
       _textRecognition = textRecognition,
       _onStateChanged = onStateChanged,
       _showSnackBar = showSnackBar,
       _systemCtx = systemContext {
    _streamingTts.isSpeaking.addListener(_onStateChanged);
  }

  void dispose() {
    _streamingTts.isSpeaking.removeListener(_onStateChanged);
    _recordingSafetyTimer?.cancel();
  }

  bool get resetting => _resetting;
  bool get isGenerating => _isGenerating;
  bool get isSpeaking => _streamingTts.isSpeaking.value;
  bool get isRecording => _isRecording;
  bool get isBusy => _resetting || _isGenerating;
  String get systemContext => _systemCtx;

  /// The video-call camera shared by every command on this screen.
  LiveCameraService get camera => LiveCameraManager.instance;

  void updateSystemContext(String newContext) => _systemCtx = newContext;

  Future<void> _announceError(String error) async {
    final cleanError = error
        .replaceAll('Exception:', '')
        .replaceAll('Error:', '')
        .replaceAll('_', ' ')
        .trim();
    await _speechService.speak('একটি সমস্যা হয়েছে। $cleanError');
  }

  Future<void> _announceStateChange(String message) =>
      _speechService.speak(message);

  Future<void> newChat(
    List<ChatMessage> messages,
    GlobalKey<PromptBarState>? promptBarKey,
  ) async {
    if (_resetting) return;

    try {
      _streamingTts.reset();
      _resetting = true;
      _onStateChanged();

      messages.clear();
      promptBarKey?.currentState?.clear();
      await ChatHistoryStore.clear();
      await _service.resetChatSession();

      _resetting = false;
      _onStateChanged();
      await _announceStateChange('নতুন আলাপ প্রস্তুত।');
    } catch (e) {
      _resetting = false;
      _onStateChanged();
      final errorMsg = 'নতুন আলাপ শুরু করা যায়নি';
      _showSnackBar(errorMsg);
      await _announceError(errorMsg);
    }
  }

  Future<void> showMessages(List<ChatMessage> messages, bool show) async {
    await _announceStateChange(
      show ? '${messages.length}টি বার্তা দেখানো হচ্ছে' : 'বার্তা লুকানো হয়েছে',
    );
  }

  /// Resolves what the chat should display for a user command: prefer the
  /// text the recognizer actually heard, fall back to the canonical label.
  String displayCommandText(String? heardText, VoiceIntent? intent) {
    final heard = (heardText ?? '').trim();
    if (heard.isNotEmpty) return heard;
    if (intent != null) return intent.banglaLabel;
    return 'কমান্ড';
  }

  /// Captures one frame from the warm video-call camera.
  Future<File> _captureWithWarmCamera() async {
    if (kIsWeb) {
      throw Exception('ওয়েবে ক্যামেরা সমর্থিত নয়');
    }
    final cam = LiveCameraManager.instance;
    if (!cam.isReady) {
      await cam.start();
    }
    return cam.capturePhoto();
  }

  Future<void> captureAndSend(
    String prompt,
    List<ChatMessage> messages, {
    bool isQuickAction = false,
    bool useOcr = false,
    String? spokenAcknowledgement,
    String? displayText,
  }) async {
    if (_isRecording) {
      await _announceStateChange(
        'ভিডিও রেকর্ড হচ্ছে। আগে বলুন: ভিডিও বন্ধ করো।',
      );
      return;
    }
    if (_isGenerating || _resetting) return;

    _isGenerating = true;
    _muteCurrentResponse = false;
    _onStateChanged();

    File? imageFile;
    try {
      if (spokenAcknowledgement != null && spokenAcknowledgement.isNotEmpty) {
        await _announceStateChange(spokenAcknowledgement);
      }

      imageFile = await _captureWithWarmCamera();

      final userMsg = ChatMessage.withImageFile(
        displayText ?? prompt,
        isUser: true,
        imageFile: imageFile,
      );
      messages.add(userMsg);
      _onStateChanged();
      unawaited(ChatHistoryStore.save(messages));

      final aiMsg = ChatMessage.text('', isUser: false, isStreaming: true);
      messages.add(aiMsg);
      _onStateChanged();

      await _speechService.playWooshSound();
      await _streamingTts.startLoading();

      String extractedText = '';
      if (useOcr) {
        try {
          extractedText = await _textRecognition.extractTextFromImage(imageFile);
        } catch (e) {
          debugPrint('[ChatHelpers] OCR failed: $e');
        }
      }

      String enhancedPrompt = prompt;
      if (extractedText.trim().isNotEmpty) {
        enhancedPrompt = '''$prompt

A Latin-script OCR engine produced this optional hint. It may be incomplete or wrong, so verify it against the image before using it:
[OCR HINT: $extractedText]''';
      }

      final responseBuffer = StringBuffer();
      int tokenCounter = 0;

      await _service.sendWithStreaming(
        text: '$_systemCtx\nTask: $enhancedPrompt',
        image: imageFile,
        onToken: (tok) {
          responseBuffer.write(tok);
          tokenCounter++;

          final currentText = responseBuffer.toString();
          if (!_muteCurrentResponse) {
            _streamingTts.addText(tok, currentText);
          }

          if (tokenCounter % 3 == 0) {
            aiMsg.text = currentText;
            _onStateChanged();
          }
        },
        onComplete: (stats) async {
          final finalText = responseBuffer.toString().trim();
          aiMsg
            ..text = finalText
            ..isStreaming = false
            ..stats = stats;
          _isGenerating = false;
          _onStateChanged();
          if (_muteCurrentResponse) {
            await _streamingTts.stopLoading();
          } else {
            await _streamingTts.onMessageComplete();
          }
          unawaited(ChatHistoryStore.save(messages));
        },
      );
    } catch (e) {
      await _streamingTts.stopLoading();
      _isGenerating = false;
      _onStateChanged();

      final errorMsg = e.toString().contains('Camera')
          ? 'ক্যামেরা ব্যবহার করা যায়নি। ক্যামেরার অনুমতি পরীক্ষা করুন।'
          : 'ছবিটি বিশ্লেষণ করা যায়নি। আবার চেষ্টা করুন।';

      if (messages.isEmpty || messages.last.isUser) {
        messages.add(ChatMessage.text(errorMsg, isUser: false));
      } else if (messages.last.isStreaming) {
        messages.last
          ..text = errorMsg
          ..isStreaming = false;
      }
      _onStateChanged();
      unawaited(ChatHistoryStore.save(messages));
      _showSnackBar(errorMsg);
      await _announceError(errorMsg);
      debugPrint('[ChatHelpers] captureAndSend error: $e');
    }
  }

  Future<void> sendTextOnly(
    String prompt,
    List<ChatMessage> messages, {
    String? displayText,
  }) async {
    if (_isRecording) {
      await _announceStateChange(
        'ভিডিও রেকর্ড হচ্ছে। আগে বলুন: ভিডিও বন্ধ করো।',
      );
      return;
    }
    if (_isGenerating || _resetting) return;
    _isGenerating = true;
    _muteCurrentResponse = false;
    _onStateChanged();
    try {
      messages.add(ChatMessage.text(displayText ?? prompt, isUser: true));
      final aiMsg = ChatMessage.text('', isUser: false, isStreaming: true);
      messages.add(aiMsg);
      _onStateChanged();
      unawaited(ChatHistoryStore.save(messages));

      await _speechService.playWooshSound();
      await _streamingTts.startLoading();

      final responseBuffer = StringBuffer();
      int tokenCounter = 0;

      await _service.sendWithStreaming(
        text: '$_systemCtx\nUser question: $prompt',
        onToken: (tok) {
          responseBuffer.write(tok);
          tokenCounter++;
          final currentText = responseBuffer.toString();
          if (!_muteCurrentResponse) {
            _streamingTts.addText(tok, currentText);
          }
          if (tokenCounter % 3 == 0) {
            aiMsg.text = currentText;
            _onStateChanged();
          }
        },
        onComplete: (stats) async {
          aiMsg
            ..text = responseBuffer.toString().trim()
            ..isStreaming = false
            ..stats = stats;
          _isGenerating = false;
          _onStateChanged();
          if (_muteCurrentResponse) {
            await _streamingTts.stopLoading();
          } else {
            await _streamingTts.onMessageComplete();
          }
          unawaited(ChatHistoryStore.save(messages));
        },
      );
    } catch (e) {
      await _streamingTts.stopLoading();
      _isGenerating = false;
      _onStateChanged();
      const errorMsg = 'প্রশ্নের উত্তর তৈরি করা যায়নি। আবার চেষ্টা করুন।';
      messages.add(ChatMessage.text(errorMsg, isUser: false));
      _onStateChanged();
      unawaited(ChatHistoryStore.save(messages));
      _showSnackBar(errorMsg);
      await _announceError(errorMsg);
      debugPrint('[ChatHelpers] sendTextOnly error: $e');
    }
  }



  // ────────────────────────────────────────────────────────────
  // Voice-controlled photo capture ("ছবি তোলো")
  // ────────────────────────────────────────────────────────────

  Future<void> takePhoto(
    List<ChatMessage> messages, {
    String? commandText,
  }) async {
    if (_isRecording) {
      await _announceStateChange('ভিডিও রেকর্ড হচ্ছে। আগে ভিডিও বন্ধ করুন।');
      return;
    }
    if (_isGenerating || _resetting) return;

    _isGenerating = true;
    _onStateChanged();
    try {
      await _announceStateChange('ছবি তুলছি।');
      final raw = await _captureWithWarmCamera();
      final saved = await MediaService.savePhoto(raw);

      messages.add(
        ChatMessage.text(
          displayCommandText(commandText, VoiceIntent.takePhoto),
          isUser: true,
        ),
      );
      messages.add(
        ChatMessage.withImageFile(
          'ছবি তোলা হয়েছে এবং সংরক্ষিত হয়েছে।',
          isUser: false,
          imageFile: saved,
        ),
      );
      _onStateChanged();
      unawaited(ChatHistoryStore.save(messages));
      await _speechService.playWooshSound();
      await _announceStateChange(
        'ছবি তোলা হয়েছে। বিশ্লেষণ চাইলে বলুন: সামনে কী আছে দেখো।',
      );
    } catch (e) {
      _showSnackBar('ছবি তোলা যায়নি');
      await _announceError('ছবি তোলা যায়নি। আবার চেষ্টা করুন।');
      debugPrint('[ChatHelpers] takePhoto error: $e');
    } finally {
      _isGenerating = false;
      _onStateChanged();
    }
  }

  // ────────────────────────────────────────────────────────────
  // Voice-controlled video recording ("ভিডিও রেকর্ড করো" / "বন্ধ করো")
  // ────────────────────────────────────────────────────────────

  Future<void> startVideoRecording(
    List<ChatMessage> messages, {
    String? commandText,
  }) async {
    if (_isRecording) {
      await _announceStateChange(
        'ভিডিও আগেই চালু আছে। বন্ধ করতে বলুন: ভিডিও বন্ধ করো।',
      );
      return;
    }
    if (_isGenerating || _resetting) {
      await _announceStateChange('একটু পরে আবার বলুন।');
      return;
    }

    _isGenerating = true;
    _onStateChanged();
    try {
      await _announceStateChange(
        'ভিডিও রেকর্ডিং শুরু করছি। বন্ধ করতে বলুন: ভিডিও বন্ধ করো।',
      );

      final cam = LiveCameraManager.instance;
      if (!cam.isReady) {
        await cam.start();
      }
      await cam.startVideo();

      _isRecording = true;
      _onStateChanged();

      // Keep the screen awake for the whole recording so the OS cannot
      // interrupt the camera mid-take.
      try {
        await WakelockPlus.enable();
      } catch (_) {}

      messages.add(
        ChatMessage.text(
          displayCommandText(commandText, VoiceIntent.startVideo),
          isUser: true,
        ),
      );
      messages.add(
        ChatMessage.text(
          'ভিডিও রেকর্ড হচ্ছে… বন্ধ করতে বলুন: "ভিডিও বন্ধ করো"।',
          isUser: false,
        ),
      );
      _onStateChanged();
      unawaited(ChatHistoryStore.save(messages));

      // Safety: hard-stop after 5 minutes so storage cannot fill up
      // unnoticed on a phone left in a pocket.
      _recordingSafetyTimer?.cancel();
      _recordingSafetyTimer = Timer(const Duration(minutes: 5), () {
        unawaited(_finishRecording(messages, autoStopped: true));
      });
    } catch (e) {
      _isRecording = false;
      // The video-call camera heals itself — no controller cleanup here.
      _showSnackBar('ভিডিও রেকর্ডিং শুরু করা যায়নি');
      await _announceError('ভিডিও রেকর্ডিং শুরু করা যায়নি। আবার চেষ্টা করুন।');
      debugPrint('[ChatHelpers] startVideoRecording error: $e');
    } finally {
      _isGenerating = false;
      _onStateChanged();
    }
  }

  Future<void> stopVideoRecording(List<ChatMessage> messages) async {
    if (!_isRecording) {
      await _announceStateChange('কোনো ভিডিও রেকর্ড হচ্ছে না।');
      return;
    }
    await _finishRecording(messages, autoStopped: false);
  }

  Future<void> _finishRecording(
    List<ChatMessage> messages, {
    required bool autoStopped,
  }) async {
    _recordingSafetyTimer?.cancel();
    _recordingSafetyTimer = null;

    File? file;
    try {
      file = await LiveCameraManager.instance.stopVideo();
    } catch (e) {
      debugPrint('[ChatHelpers] stopVideoRecording error: $e');
    } finally {
      _isRecording = false;
      _onStateChanged();
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }

    if (file == null) {
      await _announceError('ভিডিও সংরক্ষণ করা যায়নি।');
      return;
    }

    try {
      final saved = await MediaService.saveVideo(File(file.path));
      messages.add(
        ChatMessage.withVideoFile(
          autoStopped
              ? 'ভিডিও স্বয়ংক্রিয়ভাবে বন্ধ হয়ে সংরক্ষিত হয়েছে।'
              : 'ভিডিও রেকর্ড সম্পন্ন হয়ে সংরক্ষিত হয়েছে।',
          isUser: false,
          videoFile: saved,
        ),
      );
      _onStateChanged();
      unawaited(ChatHistoryStore.save(messages));
      await _announceStateChange('ভিডিও সংরক্ষিত হয়েছে।');
    } catch (e) {
      await _announceError('ভিডিও সংরক্ষণ করা যায়নি।');
      debugPrint('[ChatHelpers] video save error: $e');
    }
  }

  // ────────────────────────────────────────────────────────────
  // Intent routing
  // ────────────────────────────────────────────────────────────

  Future<void> handleVoiceIntent(
    VoiceIntent intent,
    List<ChatMessage> messages,
    GlobalKey<PromptBarState>? promptBarKey, {
    String? commandText,
  }) async {
    switch (intent) {
      case VoiceIntent.describeFront:
        await captureAndSend(
          SystemPrompts.describeFront,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'সামনে দেখছি।',
          displayText: displayCommandText(commandText, intent),
        );
        return;
      case VoiceIntent.describeCurrent:
        await captureAndSend(
          SystemPrompts.describeCurrent,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'দেখছি।',
          displayText: displayCommandText(commandText, intent),
        );
        return;
      case VoiceIntent.describeRight:
        await captureAndSend(
          SystemPrompts.describeRight,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'ক্যামেরার ডান পাশ দেখছি।',
          displayText: displayCommandText(commandText, intent),
        );
        return;
      case VoiceIntent.describeLeft:
        await captureAndSend(
          SystemPrompts.describeLeft,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'ক্যামেরার বাম পাশ দেখছি।',
          displayText: displayCommandText(commandText, intent),
        );
        return;
      case VoiceIntent.identifyObject:
        await captureAndSend(
          SystemPrompts.whatIsThis,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'জিনিসটি দেখছি।',
          displayText: displayCommandText(commandText, intent),
        );
        return;
      case VoiceIntent.readText:
        await captureAndSend(
          SystemPrompts.readText,
          messages,
          isQuickAction: true,
          useOcr: true,
          spokenAcknowledgement: 'লেখা পড়ার চেষ্টা করছি।',
          displayText: displayCommandText(commandText, intent),
        );
        return;
      case VoiceIntent.takePhoto:
        await takePhoto(messages, commandText: commandText);
        return;
      case VoiceIntent.startVideo:
        await startVideoRecording(messages, commandText: commandText);
        return;
      case VoiceIntent.stopVideo:
        await stopVideoRecording(messages);
        return;
      case VoiceIntent.repeatLast:
        await repeatLastResponse(messages);
        return;
      case VoiceIntent.stopSpeaking:
        await stopSpeaking();
        return;
      case VoiceIntent.help:
        await speakCommandHelp();
        return;
      case VoiceIntent.newChat:
        await newChat(messages, promptBarKey);
        return;
    }
  }

  Future<void> repeatLastResponse(List<ChatMessage> messages) async {
    ChatMessage? lastAi;
    for (final message in messages.reversed) {
      if (!message.isUser && message.text.trim().isNotEmpty) {
        lastAi = message;
        break;
      }
    }
    if (lastAi == null) {
      await _announceStateChange('এখনও কোনো উত্তর নেই।');
      return;
    }
    await _speechService.speak(lastAi.text);
  }

  Future<void> stopSpeaking() async {
    _muteCurrentResponse = true;
    _streamingTts.stop();
    await _speechService.stopTts();
    _onStateChanged();
  }

  Future<void> speakCommandHelp() async {
    final commands = BengaliVoiceCommands.primaryHelpCommands.join(', ');
    await _announceStateChange('আপনি বলতে পারেন: $commands।');
  }

  // Compatibility methods retained for existing UI/manual actions.
  Future<void> quickAction1(List<ChatMessage> messages) => captureAndSend(
    SystemPrompts.describeCurrent,
    messages,
    isQuickAction: true,
    spokenAcknowledgement: 'চারপাশ দেখছি।',
  );

  Future<void> quickAction2(List<ChatMessage> messages) => captureAndSend(
    SystemPrompts.describeFront,
    messages,
    isQuickAction: true,
    spokenAcknowledgement: 'সামনে দেখছি।',
  );

  Future<void> quickAction3(List<ChatMessage> messages) => captureAndSend(
    SystemPrompts.whatIsThis,
    messages,
    isQuickAction: true,
    spokenAcknowledgement: 'জিনিসটি দেখছি।',
  );

  Future<void> quickAction4(List<ChatMessage> messages) => captureAndSend(
    SystemPrompts.readText,
    messages,
    isQuickAction: true,
    useOcr: true,
    spokenAcknowledgement: 'লেখা পড়ার চেষ্টা করছি।',
  );

  Future<void> clearMessages(List<ChatMessage> messages) async {
    final messageCount = messages.length;
    messages.clear();
    _onStateChanged();
    unawaited(ChatHistoryStore.save(messages));
    await _announceStateChange('$messageCountটি বার্তা মুছে দেওয়া হয়েছে।');
  }
}
