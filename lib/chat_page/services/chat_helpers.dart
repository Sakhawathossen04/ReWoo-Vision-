import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/system_prompts.dart';
import '../models/message_models.dart';
import '../voice/bengali_voice_commands.dart';
import '../voice/voice_intent.dart';
import '../widgets/prompt_bar.dart';
import 'chat_history_store.dart';
import 'gemma_service.dart';
import 'media_service.dart';
import 'speech_service.dart';
import 'streaming_tts_service.dart';
import 'text_recognition_service.dart';

/// Core vision-assistant operations.
///
/// Camera activation is event driven: the camera is initialized only after a
/// valid command, one image is captured, and the controller is disposed before
/// Gemma inference starts. This preserves the performance advantage of the
/// original project while removing the external controller dependency.
///
/// User messages show the actual Bengali command the user spoke ([displayText])
/// while the model receives the specialised English task prompt.
///
/// Voice-only operations:
///   * [takePhoto] — capture a photo, save it, show it in chat.
///   * [startVideoRecording] / [stopVideoRecording] — hands-free video.
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

  CameraController? _videoController;
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
  })  : _service = service,
        _streamingTts = streamingTts,
        _speechService = speechService,
        _textRecognition = textRecognition,
        _onStateChanged = onStateChanged,
        _showSnackBar = showSnackBar,
        _systemCtx = systemContext {
    _streamingTts.isSpeaking.addListener(
      _onStateChanged,
    );
  }

  void dispose() {
    _streamingTts.isSpeaking.removeListener(
      _onStateChanged,
    );

    _recordingSafetyTimer?.cancel();

    _videoController?.dispose();
    _videoController = null;
  }

  bool get resetting => _resetting;

  bool get isGenerating => _isGenerating;

  bool get isSpeaking =>
      _streamingTts.isSpeaking.value;

  bool get isRecording => _isRecording;

  bool get isBusy =>
      _resetting || _isGenerating;

  String get systemContext => _systemCtx;

  void updateSystemContext(
    String newContext,
  ) {
    _systemCtx = newContext;
  }

  // ===========================================================================
  // ANNOUNCEMENTS
  // ===========================================================================

  Future<void> _announceError(
    String error,
  ) async {
    final cleanError = error
        .replaceAll(
          'Exception:',
          '',
        )
        .replaceAll(
          'Error:',
          '',
        )
        .replaceAll(
          '_',
          ' ',
        )
        .trim();

    await _speechService.speak(
      'একটি সমস্যা হয়েছে। $cleanError',
    );
  }

  Future<void> _announceStateChange(
    String message,
  ) {
    return _speechService.speak(
      message,
    );
  }

  // ===========================================================================
  // NEW CHAT
  // ===========================================================================

  Future<void> newChat(
    List<ChatMessage> messages,
    GlobalKey<PromptBarState>? promptBarKey,
  ) async {
    if (_resetting) {
      return;
    }

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

      await _announceStateChange(
        'নতুন আলাপ প্রস্তুত।',
      );
    } catch (e) {
      _resetting = false;
      _onStateChanged();

      const errorMsg =
          'নতুন আলাপ শুরু করা যায়নি';

      _showSnackBar(
        errorMsg,
      );

      await _announceError(
        errorMsg,
      );
    }
  }

  Future<void> showMessages(
    List<ChatMessage> messages,
    bool show,
  ) async {
    await _announceStateChange(
      show
          ? '${messages.length}টি বার্তা দেখানো হচ্ছে'
          : 'বার্তা লুকানো হয়েছে',
    );
  }

  // ===========================================================================
  // DISPLAY COMMAND
  // ===========================================================================

  /// Prefer the actual STT text. Fall back to the canonical intent label.
  String displayCommandText(
    String? heardText,
    VoiceIntent? intent,
  ) {
    final heard =
        (heardText ?? '').trim();

    if (heard.isNotEmpty) {
      return heard;
    }

    if (intent != null) {
      return intent.banglaLabel;
    }

    return 'কমান্ড';
  }

  // ===========================================================================
  // CAMERA
  // ===========================================================================

  Future<CameraController> _openCamera({
    bool forVideo = false,
  }) async {
    if (kIsWeb) {
      throw Exception(
        'ওয়েবে ক্যামেরা সমর্থিত নয়',
      );
    }

    final cameraStatus =
        await Permission.camera.request();

    if (!cameraStatus.isGranted &&
        await Permission.camera.isPermanentlyDenied) {
      throw Exception(
        'ক্যামেরার অনুমতি দেওয়া হয়নি',
      );
    }

    final cameras =
        await availableCameras();

    if (cameras.isEmpty) {
      throw Exception(
        'কোনো ক্যামেরা পাওয়া যায়নি',
      );
    }

    final description =
        cameras.firstWhere(
      (camera) =>
          camera.lensDirection ==
          CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final presets = forVideo
        ? [
            ResolutionPreset.medium,
            ResolutionPreset.low,
            ResolutionPreset.high,
          ]
        : [
            ResolutionPreset.high,
            ResolutionPreset.medium,
            ResolutionPreset.low,
          ];

    Object? lastError;

    for (final preset in presets) {
      CameraController? controller;

      try {
        controller = CameraController(
          description,
          preset,
          enableAudio: false,
          imageFormatGroup:
              ImageFormatGroup.jpeg,
        );

        await controller.initialize();

        return controller;
      } catch (e) {
        lastError = e;

        try {
          await controller?.dispose();
        } catch (_) {}

        controller = null;
      }
    }

    throw Exception(
      'ক্যামেরা চালু করা যায়নি: $lastError',
    );
  }

  Future<File>
      _captureWithEfficientCamera() async {
    final controller =
        await _openCamera();

    try {
      await Future.delayed(
        const Duration(
          milliseconds: 180,
        ),
      );

      try {
        final image =
            await controller.takePicture();

        return File(
          image.path,
        );
      } catch (e) {
        debugPrint(
          '[ChatHelpers] first takePicture failed, retrying: $e',
        );

        await Future.delayed(
          const Duration(
            milliseconds: 400,
          ),
        );

        final image =
            await controller.takePicture();

        return File(
          image.path,
        );
      }
    } finally {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  // ===========================================================================
  // CAPTURE + GEMMA
  // ===========================================================================

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

    if (_isGenerating ||
        _resetting) {
      return;
    }

    _isGenerating = true;
    _muteCurrentResponse = false;
    _onStateChanged();

    File? imageFile;

    try {
      if (spokenAcknowledgement != null &&
          spokenAcknowledgement.isNotEmpty) {
        await _announceStateChange(
          spokenAcknowledgement,
        );
      }

      imageFile =
          await _captureWithEfficientCamera();

      final userMsg =
          ChatMessage.withImageFile(
        displayText ?? prompt,
        isUser: true,
        imageFile: imageFile,
      );

      messages.add(
        userMsg,
      );

      _onStateChanged();

      unawaited(
        ChatHistoryStore.save(
          messages,
        ),
      );

      final aiMsg =
          ChatMessage.text(
        '',
        isUser: false,
        isStreaming: true,
      );

      messages.add(
        aiMsg,
      );

      _onStateChanged();

      await _speechService.playWooshSound();

      await _streamingTts.startLoading();

      String extractedText = '';

      if (useOcr) {
        try {
          extractedText =
              await _textRecognition
                  .extractTextFromImage(
            imageFile,
          );
        } catch (e) {
          debugPrint(
            '[ChatHelpers] OCR failed: $e',
          );
        }
      }

      String enhancedPrompt =
          prompt;

      if (extractedText.trim().isNotEmpty) {
        enhancedPrompt = '''$prompt

A Latin-script OCR engine produced this optional hint. It may be incomplete or wrong, so verify it against the image before using it:
[OCR HINT: $extractedText]''';
      }

      final responseBuffer =
          StringBuffer();

      int tokenCounter = 0;

      await _service.sendWithStreaming(
        text:
            '$_systemCtx\nTask: $enhancedPrompt',
        image:
            imageFile,
        onToken:
            (token) {
          responseBuffer.write(
            token,
          );

          tokenCounter++;

          final currentText =
              responseBuffer.toString();

          if (!_muteCurrentResponse) {
            _streamingTts.addText(
              token,
              currentText,
            );
          }

          if (tokenCounter % 3 == 0) {
            aiMsg.text =
                currentText;

            _onStateChanged();
          }
        },
        onComplete:
            (stats) async {
          final finalText =
              responseBuffer
                  .toString()
                  .trim();

          aiMsg
            ..text = finalText
            ..isStreaming = false
            ..stats = stats;

          _isGenerating = false;

          _onStateChanged();

          if (_muteCurrentResponse) {
            await _streamingTts
                .stopLoading();
          } else {
            await _streamingTts
                .onMessageComplete();
          }

          unawaited(
            ChatHistoryStore.save(
              messages,
            ),
          );
        },
      );
    } catch (e) {
      await _streamingTts.stopLoading();

      _isGenerating = false;

      _onStateChanged();

      final errorMsg =
          e.toString().contains(
                'Camera',
              )
              ? 'ক্যামেরা ব্যবহার করা যায়নি। ক্যামেরার অনুমতি পরীক্ষা করুন।'
              : 'ছবিটি বিশ্লেষণ করা যায়নি। আবার চেষ্টা করুন।';

      if (messages.isEmpty ||
          messages.last.isUser) {
        messages.add(
          ChatMessage.text(
            errorMsg,
            isUser: false,
          ),
        );
      } else if (messages.last.isStreaming) {
        messages.last
          ..text = errorMsg
          ..isStreaming = false;
      }

      _onStateChanged();

      unawaited(
        ChatHistoryStore.save(
          messages,
        ),
      );

      _showSnackBar(
        errorMsg,
      );

      await _announceError(
        errorMsg,
      );

      debugPrint(
        '[ChatHelpers] captureAndSend error: $e',
      );
    }
  }

  // ===========================================================================
  // TEXT ONLY
  // ===========================================================================

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

    if (_isGenerating ||
        _resetting) {
      return;
    }

    _isGenerating = true;
    _muteCurrentResponse = false;

    _onStateChanged();

    try {
      messages.add(
        ChatMessage.text(
          displayText ?? prompt,
          isUser: true,
        ),
      );

      final aiMsg =
          ChatMessage.text(
        '',
        isUser: false,
        isStreaming: true,
      );

      messages.add(
        aiMsg,
      );

      _onStateChanged();

      unawaited(
        ChatHistoryStore.save(
          messages,
        ),
      );

      await _speechService.playWooshSound();

      await _streamingTts.startLoading();

      final responseBuffer =
          StringBuffer();

      int tokenCounter = 0;

      await _service.sendWithStreaming(
        text:
            '$_systemCtx\nUser question: $prompt',
        onToken:
            (token) {
          responseBuffer.write(
            token,
          );

          tokenCounter++;

          final currentText =
              responseBuffer.toString();

          if (!_muteCurrentResponse) {
            _streamingTts.addText(
              token,
              currentText,
            );
          }

          if (tokenCounter % 3 == 0) {
            aiMsg.text =
                currentText;

            _onStateChanged();
          }
        },
        onComplete:
            (stats) async {
          aiMsg
            ..text = responseBuffer
                .toString()
                .trim()
            ..isStreaming = false
            ..stats = stats;

          _isGenerating = false;

          _onStateChanged();

          if (_muteCurrentResponse) {
            await _streamingTts
                .stopLoading();
          } else {
            await _streamingTts
                .onMessageComplete();
          }

          unawaited(
            ChatHistoryStore.save(
              messages,
            ),
          );
        },
      );
    } catch (e) {
      await _streamingTts.stopLoading();

      _isGenerating = false;

      _onStateChanged();

      const errorMsg =
          'প্রশ্নের উত্তর তৈরি করা যায়নি। আবার চেষ্টা করুন।';

      messages.add(
        ChatMessage.text(
          errorMsg,
          isUser: false,
        ),
      );

      _onStateChanged();

      unawaited(
        ChatHistoryStore.save(
          messages,
        ),
      );

      _showSnackBar(
        errorMsg,
      );

      await _announceError(
        errorMsg,
      );

      debugPrint(
        '[ChatHelpers] sendTextOnly error: $e',
      );
    }
  }

  // ===========================================================================
  // PHOTO
  // ===========================================================================

  Future<void> takePhoto(
    List<ChatMessage> messages, {
    String? commandText,
  }) async {
    if (_isRecording) {
      await _announceStateChange(
        'ভিডিও রেকর্ড হচ্ছে। আগে ভিডিও বন্ধ করুন।',
      );

      return;
    }

    if (_isGenerating ||
        _resetting) {
      return;
    }

    _isGenerating = true;

    _onStateChanged();

    try {
      await _announceStateChange(
        'ছবি তুলছি।',
      );

      final raw =
          await _captureWithEfficientCamera();

      final saved =
          await MediaService.savePhoto(
        raw,
      );

      messages.add(
        ChatMessage.text(
          displayCommandText(
            commandText,
            VoiceIntent.takePhoto,
          ),
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

      unawaited(
        ChatHistoryStore.save(
          messages,
        ),
      );

      await _speechService.playWooshSound();

      await _announceStateChange(
        'ছবি তোলা হয়েছে। বিশ্লেষণ চাইলে বলুন: সামনে কী আছে দেখো।',
      );
    } catch (e) {
      _showSnackBar(
        'ছবি তোলা যায়নি',
      );

      await _announceError(
        'ছবি তোলা যায়নি। আবার চেষ্টা করুন।',
      );

      debugPrint(
        '[ChatHelpers] takePhoto error: $e',
      );
    } finally {
      _isGenerating = false;

      _onStateChanged();
    }
  }

  // ===========================================================================
  // VIDEO START
  // ===========================================================================

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

    if (_isGenerating ||
        _resetting) {
      await _announceStateChange(
        'একটু পরে আবার বলুন।',
      );

      return;
    }

    _isGenerating = true;

    _onStateChanged();

    try {
      await _announceStateChange(
        'ভিডিও রেকর্ডিং শুরু করছি। বন্ধ করতে বলুন: ভিডিও বন্ধ করো।',
      );

      final controller =
          await _openCamera(
        forVideo: true,
      );

      _videoController =
          controller;

      await controller
          .prepareForVideoRecording();

      await controller
          .startVideoRecording();

      _isRecording = true;

      _onStateChanged();

      try {
        await WakelockPlus.enable();
      } catch (_) {}

      messages.add(
        ChatMessage.text(
          displayCommandText(
            commandText,
            VoiceIntent.startVideo,
          ),
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

      unawaited(
        ChatHistoryStore.save(
          messages,
        ),
      );

      _recordingSafetyTimer?.cancel();

      _recordingSafetyTimer =
          Timer(
        const Duration(
          minutes: 5,
        ),
        () {
          unawaited(
            _finishRecording(
              messages,
              autoStopped: true,
            ),
          );
        },
      );
    } catch (e) {
      _isRecording = false;

      try {
        await _videoController?.dispose();
      } catch (_) {}

      _videoController =
          null;

      _showSnackBar(
        'ভিডিও রেকর্ডিং শুরু করা যায়নি',
      );

      await _announceError(
        'ভিডিও রেকর্ডিং শুরু করা যায়নি। আবার চেষ্টা করুন।',
      );

      debugPrint(
        '[ChatHelpers] startVideoRecording error: $e',
      );
    } finally {
      _isGenerating = false;

      _onStateChanged();
    }
  }

  // ===========================================================================
  // VIDEO STOP
  // ===========================================================================

  Future<void> stopVideoRecording(
    List<ChatMessage> messages,
  ) async {
    if (!_isRecording) {
      await _announceStateChange(
        'কোনো ভিডিও রেকর্ড হচ্ছে না।',
      );

      return;
    }

    await _finishRecording(
      messages,
      autoStopped: false,
    );
  }

  Future<void> _finishRecording(
    List<ChatMessage> messages, {
    required bool autoStopped,
  }) async {
    _recordingSafetyTimer?.cancel();

    _recordingSafetyTimer =
        null;

    final controller =
        _videoController;

    if (controller == null) {
      _isRecording = false;

      _onStateChanged();

      return;
    }

    XFile? file;

    try {
      file =
          await controller
              .stopVideoRecording();
    } catch (e) {
      debugPrint(
        '[ChatHelpers] stopVideoRecording error: $e',
      );
    } finally {
      _isRecording = false;

      _onStateChanged();

      try {
        await WakelockPlus.disable();
      } catch (_) {}

      try {
        await controller.dispose();
      } catch (_) {}

      _videoController =
          null;
    }

    if (file == null) {
      await _announceError(
        'ভিডিও সংরক্ষণ করা যায়নি।',
      );

      return;
    }

    try {
      final saved =
          await MediaService.saveVideo(
        File(
          file.path,
        ),
      );

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

      unawaited(
        ChatHistoryStore.save(
          messages,
        ),
      );

      await _announceStateChange(
        'ভিডিও সংরক্ষিত হয়েছে।',
      );
    } catch (e) {
      await _announceError(
        'ভিডিও সংরক্ষণ করা যায়নি।',
      );

      debugPrint(
        '[ChatHelpers] video save error: $e',
      );
    }
  }

  // ===========================================================================
  // INTENT ROUTING
  // ===========================================================================

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
          spokenAcknowledgement:
              'সামনে দেখছি।',
          displayText:
              displayCommandText(
            commandText,
            intent,
          ),
        );

        return;

      case VoiceIntent.describeCurrent:
        await captureAndSend(
          SystemPrompts.describeCurrent,
          messages,
          isQuickAction: true,
          spokenAcknowledgement:
              'দেখছি।',
          displayText:
              displayCommandText(
            commandText,
            intent,
          ),
        );

        return;

      case VoiceIntent.describeRight:
        await captureAndSend(
          SystemPrompts.describeRight,
          messages,
          isQuickAction: true,
          spokenAcknowledgement:
              'ক্যামেরার ডান পাশ দেখছি।',
          displayText:
              displayCommandText(
            commandText,
            intent,
          ),
        );

        return;

      case VoiceIntent.describeLeft:
        await captureAndSend(
          SystemPrompts.describeLeft,
          messages,
          isQuickAction: true,
          spokenAcknowledgement:
              'ক্যামেরার বাম পাশ দেখছি।',
          displayText:
              displayCommandText(
            commandText,
            intent,
          ),
        );

        return;

      case VoiceIntent.identifyObject:
        await captureAndSend(
          SystemPrompts.whatIsThis,
          messages,
          isQuickAction: true,
          spokenAcknowledgement:
              'জিনিসটি দেখছি।',
          displayText:
              displayCommandText(
            commandText,
            intent,
          ),
        );

        return;

      case VoiceIntent.readText:
        await captureAndSend(
          SystemPrompts.readText,
          messages,
          isQuickAction: true,
          useOcr: true,
          spokenAcknowledgement:
              'লেখা পড়ার চেষ্টা করছি।',
          displayText:
              displayCommandText(
            commandText,
            intent,
          ),
        );

        return;

      case VoiceIntent.takePhoto:
        await takePhoto(
          messages,
          commandText: commandText,
        );

        return;

      case VoiceIntent.startVideo:
        await startVideoRecording(
          messages,
          commandText: commandText,
        );

        return;

      case VoiceIntent.stopVideo:
        await stopVideoRecording(
          messages,
        );

        return;

      case VoiceIntent.repeatLast:
        await repeatLastResponse(
          messages,
        );

        return;

      case VoiceIntent.stopSpeaking:
        await stopSpeaking();

        return;

      case VoiceIntent.help:
        await speakCommandHelp();

        return;

      case VoiceIntent.newChat:
        await newChat(
          messages,
          promptBarKey,
        );

        return;
    }
  }

  // ===========================================================================
  // REPEAT
  // ===========================================================================

  Future<void> repeatLastResponse(
    List<ChatMessage> messages,
  ) async {
    ChatMessage? lastAi;

    for (final message
        in messages.reversed) {
      if (!message.isUser &&
          message.text.trim().isNotEmpty) {
        lastAi = message;

        break;
      }
    }

    if (lastAi == null) {
      await _announceStateChange(
        'এখনও কোনো উত্তর নেই।',
      );

      return;
    }

    await _speechService.speak(
      lastAi.text,
    );
  }

  // ===========================================================================
  // STOP SPEAKING
  // ===========================================================================

  Future<void> stopSpeaking() async {
    _muteCurrentResponse = true;

    _streamingTts.stop();

    await _speechService.stopTts();

    _onStateChanged();
  }

  // ===========================================================================
  // HELP
  // ===========================================================================

  /// Announces ONLY the five direct commands accepted by trigger mode.
  Future<void> speakCommandHelp() async {
    final commands =
        BengaliVoiceCommands
            .triggerHelpCommands
            .join(', ');

    await _announceStateChange(
      'আপনি বলতে পারেন: $commands।',
    );
  }

  // ===========================================================================
  // QUICK ACTIONS
  // ===========================================================================

  Future<void> quickAction1(
    List<ChatMessage> messages,
  ) {
    return captureAndSend(
      SystemPrompts.describeCurrent,
      messages,
      isQuickAction: true,
      spokenAcknowledgement:
          'চারপাশ দেখছি।',
    );
  }

  Future<void> quickAction2(
    List<ChatMessage> messages,
  ) {
    return captureAndSend(
      SystemPrompts.describeFront,
      messages,
      isQuickAction: true,
      spokenAcknowledgement:
          'সামনে দেখছি।',
    );
  }

  Future<void> quickAction3(
    List<ChatMessage> messages,
  ) {
    return captureAndSend(
      SystemPrompts.whatIsThis,
      messages,
      isQuickAction: true,
      spokenAcknowledgement:
          'জিনিসটি দেখছি।',
    );
  }

  Future<void> quickAction4(
    List<ChatMessage> messages,
  ) {
    return captureAndSend(
      SystemPrompts.readText,
      messages,
      isQuickAction: true,
      useOcr: true,
      spokenAcknowledgement:
          'লেখা পড়ার চেষ্টা করছি।',
    );
  }

  // ===========================================================================
  // CLEAR MESSAGES
  // ===========================================================================

  Future<void> clearMessages(
    List<ChatMessage> messages,
  ) async {
    final messageCount =
        messages.length;

    messages.clear();

    _onStateChanged();

    unawaited(
      ChatHistoryStore.save(
        messages,
      ),
    );

    await _announceStateChange(
      '$messageCountটি বার্তা মুছে দেওয়া হয়েছে।',
    );
  }
}
