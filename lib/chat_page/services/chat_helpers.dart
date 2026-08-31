import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/system_prompts.dart';
import '../models/message_models.dart';
import '../voice/bengali_voice_commands.dart';
import '../voice/voice_intent.dart';
import '../widgets/prompt_bar.dart';
import 'gemma_service.dart';
import 'speech_service.dart';
import 'streaming_tts_service.dart';
import 'text_recognition_service.dart';

/// Core vision-assistant operations.
///
/// Camera activation is event driven: the camera is initialized only after a
/// valid command, one image is captured, and the controller is disposed before
/// Gemma inference starts. This preserves the performance advantage of the
/// original project while removing the external controller dependency.
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
  }

  bool get resetting => _resetting;
  bool get isGenerating => _isGenerating;
  bool get isSpeaking => _streamingTts.isSpeaking.value;
  bool get isBusy => _resetting || _isGenerating;
  String get systemContext => _systemCtx;

  void updateSystemContext(String newContext) => _systemCtx = newContext;

  Future<void> _announceError(String error) async {
    final cleanError = error
        .replaceAll('Exception:', '')
        .replaceAll('Error:', '')
        .replaceAll('_', ' ')
        .trim();
    await _speechService.speak('একটি সমস্যা হয়েছে। $cleanError');
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
      await _service.resetChatSession();

      _resetting = false;
      _onStateChanged();
      await _announceStateChange('নতুন আলাপ প্রস্তুত।');
    } catch (e) {
      _resetting = false;
      _onStateChanged();
      final errorMsg = 'নতুন আলাপ শুরু করা যায়নি';
      _showSnackBar(errorMsg);
      await _announceError(errorMsg);
    }
  }

  Future<void> showMessages(List<ChatMessage> messages, bool show) async {
    await _announceStateChange(
      show ? '${messages.length}টি বার্তা দেখানো হচ্ছে' : 'বার্তা লুকানো হয়েছে',
    );
  }

  Future<File> _captureWithEfficientCamera() async {
    if (kIsWeb) {
      throw Exception('ওয়েবে ক্যামেরা সমর্থিত নয়');
    }

    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('কোনো ক্যামেরা পাওয়া যায়নি');
      }

      final description = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      controller = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await controller.initialize();
      // Give auto-exposure/focus a brief moment after initialization. This is a
      // small latency tradeoff for noticeably more reliable text/object images.
      await Future.delayed(const Duration(milliseconds: 180));
      final image = await controller.takePicture();
      return File(image.path);
    } finally {
      await controller?.dispose();
    }
  }

  Future<void> captureAndSend(
    String prompt,
    List<ChatMessage> messages, {
    bool isQuickAction = false,
    bool useOcr = false,
    String? spokenAcknowledgement,
  }) async {
    if (_isGenerating || _resetting) return;

    _isGenerating = true;
    _muteCurrentResponse = false;
    _onStateChanged();

    File? imageFile;
    try {
      if (spokenAcknowledgement != null && spokenAcknowledgement.isNotEmpty) {
        await _announceStateChange(spokenAcknowledgement);
      }

      imageFile = await _captureWithEfficientCamera();

      final userMsg = ChatMessage.withImageFile(
        prompt,
        isUser: true,
        imageFile: imageFile,
      );
      messages.add(userMsg);
      _onStateChanged();

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
        },
      );
    } catch (e) {
      await _streamingTts.stopLoading();
      _isGenerating = false;
      _onStateChanged();

      final errorMsg = e.toString().contains('Camera')
          ? 'ক্যামেরা ব্যবহার করা যায়নি। ক্যামেরার অনুমতি পরীক্ষা করুন।'
          : 'ছবিটি বিশ্লেষণ করা যায়নি। আবার চেষ্টা করুন।';

      if (messages.isEmpty || messages.last.isUser) {
        messages.add(ChatMessage.text(errorMsg, isUser: false));
      } else if (messages.last.isStreaming) {
        messages.last
          ..text = errorMsg
          ..isStreaming = false;
      }
      _onStateChanged();
      _showSnackBar(errorMsg);
      await _announceError(errorMsg);
      debugPrint('[ChatHelpers] captureAndSend error: $e');
    }
  }

  Future<void> sendTextOnly(String prompt, List<ChatMessage> messages) async {
    if (_isGenerating || _resetting) return;
    _isGenerating = true;
    _muteCurrentResponse = false;
    _onStateChanged();
    try {
      messages.add(ChatMessage.text(prompt, isUser: true));
      final aiMsg = ChatMessage.text('', isUser: false, isStreaming: true);
      messages.add(aiMsg);
      _onStateChanged();

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
        },
      );
    } catch (e) {
      await _streamingTts.stopLoading();
      _isGenerating = false;
      _onStateChanged();
      const errorMsg = 'প্রশ্নের উত্তর তৈরি করা যায়নি। আবার চেষ্টা করুন।';
      messages.add(ChatMessage.text(errorMsg, isUser: false));
      _showSnackBar(errorMsg);
      await _announceError(errorMsg);
      debugPrint('[ChatHelpers] sendTextOnly error: $e');
    }
  }

  Future<void> handleVoiceIntent(
    VoiceIntent intent,
    List<ChatMessage> messages,
    GlobalKey<PromptBarState>? promptBarKey,
  ) async {
    switch (intent) {
      case VoiceIntent.describeFront:
        await captureAndSend(
          SystemPrompts.describeFront,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'সামনে দেখছি।',
        );
        return;
      case VoiceIntent.describeCurrent:
        await captureAndSend(
          SystemPrompts.describeCurrent,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'দেখছি।',
        );
        return;
      case VoiceIntent.describeRight:
        await captureAndSend(
          SystemPrompts.describeRight,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'ক্যামেরার ডান পাশ দেখছি।',
        );
        return;
      case VoiceIntent.describeLeft:
        await captureAndSend(
          SystemPrompts.describeLeft,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'ক্যামেরার বাম পাশ দেখছি।',
        );
        return;
      case VoiceIntent.identifyObject:
        await captureAndSend(
          SystemPrompts.whatIsThis,
          messages,
          isQuickAction: true,
          spokenAcknowledgement: 'জিনিসটি দেখছি।',
        );
        return;
      case VoiceIntent.readText:
        await captureAndSend(
          SystemPrompts.readText,
          messages,
          isQuickAction: true,
          useOcr: true,
          spokenAcknowledgement: 'লেখা পড়ার চেষ্টা করছি।',
        );
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
    spokenAcknowledgement: 'লেখা পড়ার চেষ্টা করছি।',
  );

  Future<void> clearMessages(List<ChatMessage> messages) async {
    final messageCount = messages.length;
    messages.clear();
    _onStateChanged();
    await _announceStateChange('$messageCountটি বার্তা মুছে দেওয়া হয়েছে।');
  }
}
