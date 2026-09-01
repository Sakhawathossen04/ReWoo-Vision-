import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_gemma/pigeon.g.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../error_recovery_page.dart';
import '../settings_page.dart';
import 'config/system_prompts.dart';
import 'models/message_models.dart';
import 'services/bootstrap_manager.dart';
import 'services/chat_helpers.dart';
import 'services/chat_history_store.dart';
import 'services/live_camera_service.dart';
import 'services/speech_service.dart';
import 'services/streaming_tts_service.dart';
import 'services/text_recognition_service.dart';
import 'voice/voice_intent.dart';
import 'widgets/chat_ui_builder.dart';
import 'widgets/prompt_bar.dart';

/// Main Bengali, controller-free, voice-first chat page.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _msgs = <ChatMessage>[];
  bool _showMessages = false;

  late FlutterTts _tts = FlutterTts();
  late StreamingTtsService _streamingTts = StreamingTtsService(_tts);

  ChatHelpers? _chatHelpers;
  SpeechService? _speechService;
  TextRecognitionService? _textRecognition;

  String _systemCtx = SystemPrompts.blindUserNavigation;
  PreferredBackend _backend = PreferredBackend.cpu;

  final _promptBarKey = GlobalKey<PromptBarState>();
  bool _initialising = true;
  bool _redirectedOnError = false;
  bool _disposed = false;
  bool _resumeVoiceOnForeground = true;

  final ScrollController _scrollController = ScrollController();
  Timer? _autoScrollTimer;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 450),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (_disposed) return;

    try {
      // Priority 6: restore the previous conversation before services come
      // online, so returning users immediately see their chat history.
      final restored = await ChatHistoryStore.load();
      if (restored.isNotEmpty && mounted && !_disposed) {
        setState(() {
          _msgs
            ..clear()
            ..addAll(restored);
          _showMessages = true;
        });
      }

      final result = await BootstrapManager.bootstrap(
        context: context,
        systemContext: _systemCtx,
        backend: _backend,
        isMounted: () => mounted,
        isDisposed: () => _disposed,
        setState: (fn) {
          if (mounted && !_disposed) {
            setState(fn);
            if (_showMessages) _scheduleAutoScroll();
          }
        },
      );

      // The newly bootstrapped runtime is ready; release the previous/dummy
      // streaming wrapper before switching references.
      _streamingTts.dispose();
      await _tts.stop();

      _tts = result.tts;
      _streamingTts = result.streamingTts;
      _chatHelpers = result.chatHelpers;
      _speechService = result.speechService;
      _textRecognition = result.textRecognition;

      _speechService!.configureCommandHandler(
        onCommand: _handleVoiceIntent,
        canAcceptCommand: () {
          final helpers = _chatHelpers;
          if (helpers == null) return false;
          // While a video is being recorded the mic stays free (silent
          // recording) and "ভিডিও বন্ধ করো" MUST be heard — keep accepting.
          if (helpers.isRecording) return true;
          return !helpers.isBusy && !helpers.isSpeaking;
        },
      );

      if (mounted && !_disposed) {
        setState(() => _initialising = false);
        _fadeController.forward();
      }

      // Video-call mode: open the warm camera the moment the assistant is
      // ready, so the live view is on screen and every command captures
      // instantly. Also keep the screen awake while the call screen is open.
      // Camera errors never block the voice assistant.
      unawaited(
        LiveCameraManager.instance.start().catchError((e) {
          debugPrint('[ChatPage] live camera start failed: $e');
        }),
      );
      // Video-call behaviour: the screen stays awake for as long as the
      // assistant is open, and is released the moment the screen closes.
      try {
        await WakelockPlus.enable();
      } catch (_) {}

      if (!_speechService!.hasBengaliSpeechLocale && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'এই ফোনে বাংলা স্পিচ-রিকগনিশন লোকেল পাওয়া যায়নি। Google Speech Services-এ বাংলা ভাষা চালু করুন।',
            ),
          ),
        );
      }

      await _speechService!.speak(
        'সহায়ক প্রস্তুত। আপনি বলতে পারেন, সামনে কী আছে দেখো, এটা কী, লেখাটা পড়ে শোনাও, ছবি তোলো অথবা ভিডিও রেকর্ড করো।',
      );
      await _speechService!.startCommandListening();
    } catch (e) {
      debugPrint('[ChatPage] initialization failed: $e');
      if (mounted && !_disposed && !_redirectedOnError) {
        _redirectedOnError = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ErrorRecoveryPage()),
        );
      }
    }
  }

  Future<void> _disposeCurrentVoiceRuntime({bool disposeOcr = false}) async {
    try {
      await _speechService?.stopCommandListening();
    } catch (_) {}
    _speechService?.dispose();
    _chatHelpers?.dispose();
    try {
      _streamingTts.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
    if (disposeOcr) {
      try {
        await _textRecognition?.dispose();
      } catch (_) {}
    }
    _speechService = null;
    _chatHelpers = null;
  }

  Future<void> _handleVoiceIntent(VoiceIntent intent, String heardText) async {
    if (_disposed || _chatHelpers == null) return;
    try {
      await _chatHelpers!.handleVoiceIntent(
        intent,
        _msgs,
        _promptBarKey,
        commandText: heardText,
      );
    } finally {
      // Priority 3: the microphone MUST come back after every finished
      // command — generation, camera work and spoken answers included.
      _speechService?.scheduleRestartSoon();
    }
  }

  void _scheduleAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _newChat() => _chatHelpers!.newChat(_msgs, _promptBarKey);

  Future<void> _captureAndSend(String prompt) =>
      _chatHelpers!.captureAndSend(prompt, _msgs);

  Future<void> _sendTextOnly(String prompt) =>
      _chatHelpers!.sendTextOnly(prompt, _msgs);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_disposed || _speechService == null) return;

    if (state == AppLifecycleState.resumed) {
      // Video-call mode: the warm camera comes back with the app, and the
      // microphone loop resumes alongside it. Recording keeps the mic free
      // (enableAudio: false), so the command loop must ALWAYS resume on
      // foreground.
      unawaited(
        LiveCameraManager.instance.start().catchError((e) {
          debugPrint('[ChatPage] live camera resume failed: $e');
        }),
      );
      if (_resumeVoiceOnForeground) {
        unawaited(_speechService!.startCommandListening());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // Leaving the app = hanging up: release the camera fully unless a
      // video recording is running (the OS owns the camera during a take).
      _resumeVoiceOnForeground =
          _speechService!.commandModeEnabled || _chatHelpers!.isRecording;
      if (!_chatHelpers!.isRecording) {
        LiveCameraManager.instance.dispose();
        unawaited(_speechService!.pauseLoop());
      } else {
        unawaited(_speechService!.stopCommandListening());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _autoScrollTimer?.cancel();
    _scrollController.dispose();
    _fadeController.dispose();
    // Persist the conversation before the runtime goes away.
    unawaited(ChatHistoryStore.save(_msgs));
    // dispose() cannot await; detach listeners before disposing their notifiers.
    _chatHelpers?.dispose();
    _speechService?.dispose();
    _streamingTts.dispose();
    _tts.stop();
    _textRecognition?.dispose();
    // Hanging up: the video-call camera and the screen wakelock are fully
    // released with the screen.
    LiveCameraManager.instance.dispose();
    try {
      WakelockPlus.disable();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initialising) return ChatUIBuilder.buildLoadingScreen();

    final helpers = _chatHelpers!;
    final speech = _speechService!;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: ChatUIBuilder.buildCleanAppBar(
        onNewChat: _newChat,
        onToggleSettings: _navigateToSettings,
        isResetting: helpers.resetting,
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: Column(
          children: [
            // Video-call hero: always-on live camera + mic status overlay.
            ChatUIBuilder.buildVideoCallView(
              camera: LiveCameraManager.instance,
              listening: speech.commandListening,
              isRecording: helpers.isRecording,
              speechEnabled: speech.speechEnabled,
              isGenerating: helpers.isGenerating,
              isSpeaking: helpers.isSpeaking,
              lastHeard: speech.lastHeard,
              onToggleListening: speech.toggleDictation,
              onStopRecording: () => _handleVoiceIntent(
                VoiceIntent.stopVideo,
                VoiceIntent.stopVideo.banglaLabel,
              ),
              onRetryCamera: () {
                unawaited(
                  LiveCameraManager.instance.restart().catchError((e) {
                    debugPrint('[ChatPage] camera retry failed: $e');
                  }),
                );
              },
            ),
            ChatUIBuilder.buildQuickActions(
              disabled: helpers.isBusy || helpers.isRecording,
              onDescribeFront: () => _handleVoiceIntent(
                VoiceIntent.describeFront,
                VoiceIntent.describeFront.banglaLabel,
              ),
              onIdentifyObject: () => _handleVoiceIntent(
                VoiceIntent.identifyObject,
                VoiceIntent.identifyObject.banglaLabel,
              ),
              onReadText: () => _handleVoiceIntent(
                VoiceIntent.readText,
                VoiceIntent.readText.banglaLabel,
              ),
            ),
            ChatUIBuilder.buildViewToggleButtons(
              showMessages: _showMessages,
              onToggleMessages: () {
                setState(() => _showMessages = !_showMessages);
                if (_showMessages) _scheduleAutoScroll();
              },
              onNewChat: _newChat,
              isResetting: helpers.resetting,
            ),
            if (_showMessages)
              ChatUIBuilder.buildMessagesContainer(_msgs, _scrollController)
            else
              ChatUIBuilder.buildLastAnswer(_msgs),
            ChatUIBuilder.buildPromptBarContainer(
              promptBarKey: _promptBarKey,
              onPromptWithPhoto: _captureAndSend,
              onPromptTextOnly: _sendTextOnly,
              disabled: helpers.resetting || helpers.isGenerating,
              // Continuous command listening is automatic; the prompt bar is a
              // touch/text fallback, so it does not expose a second dictation
              // recognizer that could conflict with the command loop.
              speechEnabled: false,
              listening: speech.commandListening,
              onToggleListening: speech.toggleDictation,
              isGenerating: helpers.isGenerating,
              isSpeaking: helpers.isSpeaking,
              onStopTts: helpers.stopSpeaking,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _navigateToSettings() async {
    if (_disposed || !mounted) return;

    final wasListening = _speechService?.commandModeEnabled ?? false;
    await _speechService?.stopCommandListening();

    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          systemContext: _systemCtx,
          backend: _backend,
          wakeWordMode: _speechService?.wakeWordMode ?? false,
        ),
      ),
    );

    if (result != null && mounted && !_disposed) {
      final newSystemContext = result['systemContext'] as String?;
      final newBackend = result['backend'] as PreferredBackend?;
      final wakeWordMode = result['wakeWordMode'] as bool?;

      if (wakeWordMode != null) {
        await _speechService?.setWakeWordMode(wakeWordMode);
      }

      if (newSystemContext != null && newBackend != null) {
        final backendChanged = _backend != newBackend;
        setState(() {
          _systemCtx = newSystemContext;
          _chatHelpers?.updateSystemContext(_systemCtx);
          _backend = newBackend;
        });

        if (backendChanged) {
          _msgs.clear();
          setState(() => _initialising = true);
          await _disposeCurrentVoiceRuntime();
          BootstrapManager.reset();
          _redirectedOnError = false;
          await _bootstrap();
          return;
        }
      }
    }

    if (wasListening && mounted && !_disposed) {
      await _speechService?.startCommandListening();
    }
  }
}
