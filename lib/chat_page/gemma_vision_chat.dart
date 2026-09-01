import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_gemma/pigeon.g.dart';

import '../error_recovery_page.dart';
import '../settings_page.dart';
import 'config/system_prompts.dart';
import 'models/message_models.dart';
import 'services/bootstrap_manager.dart';
import 'services/chat_helpers.dart';
import 'services/chat_history_store.dart';
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

  late StreamingTtsService _streamingTts =
      StreamingTtsService(_tts);

  ChatHelpers? _chatHelpers;
  SpeechService? _speechService;
  TextRecognitionService? _textRecognition;

  String _systemCtx = SystemPrompts.blindUserNavigation;

  PreferredBackend _backend = PreferredBackend.cpu;

  final _promptBarKey = GlobalKey<PromptBarState>();

  bool _initialising = true;
  bool _redirectedOnError = false;
  bool _disposed = false;

  /// True when voice listening should return after the application comes
  /// back to the foreground.
  bool _resumeVoiceOnForeground = true;

  /// True when app lifecycle used SpeechService.pauseLoop().
  ///
  /// This distinction matters because:
  ///
  /// pauseLoop()
  ///   -> preserves commandModeEnabled
  ///   -> sets pausedForMedia = true
  ///   -> must be resumed using resumeLoop()
  ///
  /// stopCommandListening()
  ///   -> disables commandModeEnabled
  ///   -> must be resumed using startCommandListening()
  bool _voicePausedByLifecycle = false;

  final ScrollController _scrollController =
      ScrollController();

  Timer? _autoScrollTimer;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // ===========================================================================
  // INIT
  // ===========================================================================

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

  // ===========================================================================
  // BOOTSTRAP
  // ===========================================================================

  Future<void> _bootstrap() async {
    if (_disposed) {
      return;
    }

    try {
      // -----------------------------------------------------------------------
      // Restore previous conversation
      // -----------------------------------------------------------------------

      final restored =
          await ChatHistoryStore.load();

      if (restored.isNotEmpty &&
          mounted &&
          !_disposed) {
        setState(() {
          _msgs
            ..clear()
            ..addAll(restored);

          _showMessages = true;
        });
      }

      // -----------------------------------------------------------------------
      // Bootstrap application services
      // -----------------------------------------------------------------------

      final result =
          await BootstrapManager.bootstrap(
        context: context,
        systemContext: _systemCtx,
        backend: _backend,
        isMounted: () => mounted,
        isDisposed: () => _disposed,
        setState: (fn) {
          if (mounted && !_disposed) {
            setState(fn);

            if (_showMessages) {
              _scheduleAutoScroll();
            }
          }
        },
      );

      // -----------------------------------------------------------------------
      // Release previous/dummy TTS wrapper
      // -----------------------------------------------------------------------

      _streamingTts.dispose();

      try {
        await _tts.stop();
      } catch (_) {}

      // -----------------------------------------------------------------------
      // Store bootstrapped services
      // -----------------------------------------------------------------------

      _tts = result.tts;
      _streamingTts = result.streamingTts;
      _chatHelpers = result.chatHelpers;
      _speechService = result.speechService;
      _textRecognition = result.textRecognition;

      final speech = _speechService!;

      // -----------------------------------------------------------------------
      // Configure command handler
      // -----------------------------------------------------------------------

      speech.configureCommandHandler(
        onCommand: _handleVoiceIntent,
        canAcceptCommand: () {
          final helpers = _chatHelpers;

          if (helpers == null) {
            return false;
          }

          // A second camera/model task must never begin while another task
          // or TTS response is still active.
          return !helpers.isBusy &&
              !helpers.isSpeaking;
        },
      );

      // -----------------------------------------------------------------------
      // UI ready
      // -----------------------------------------------------------------------

      if (mounted && !_disposed) {
        setState(() {
          _initialising = false;
        });

        _fadeController.forward();
      }

      // -----------------------------------------------------------------------
      // Voice compatibility warning
      // -----------------------------------------------------------------------

      if (mounted && !_disposed) {
        String? warning;

        if (!speech.microphonePermissionGranted) {
          warning = speech.lastError.isNotEmpty
              ? speech.lastError
              : 'মাইক্রোফোন অনুমতি চালু করুন।';
        } else if (!speech.speechRecognizerAvailable) {
          warning = speech.lastError.isNotEmpty
              ? speech.lastError
              : 'এই ফোনে Speech Recognition service পাওয়া যাচ্ছে না।';
        } else if (!speech.hasBengaliSpeechLocale ||
            speech.bengaliLanguageUnsupported) {
          warning =
              'এই ফোনে বাংলা স্পিচ-রিকগনিশন পাওয়া যাচ্ছে না। '
              'Google Speech Services-এ বাংলা ভাষা চালু করুন।';
        }

        if (warning != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(warning),
            ),
          );
        }
      }

      // -----------------------------------------------------------------------
      // STARTUP VOICE MESSAGE
      //
      // IMPORTANT:
      // This exactly describes the five direct trigger commands.
      // -----------------------------------------------------------------------

      await speech.speak(
        'সহায়ক প্রস্তুত। '
        'আপনি বলতে পারেন, '
        'সামনে কী আছে দেখো, '
        'এটা কী, '
        'লেখাটা পড়ে শোনাও, '
        'ডান পাশে কী আছে, '
        'অথবা বাম পাশে কী আছে।',
      );

      // -----------------------------------------------------------------------
      // START FIVE-COMMAND TRIGGER LISTENER
      // -----------------------------------------------------------------------
      //
      // From this point SpeechService owns the lifecycle:
      //
      // waiting
      //      ↓
      // final STT result
      //      ↓
      // exact five-command match
      //      ↓
      // commandInProgress = true
      //      ↓
      // recognizer stop
      //      ↓
      // camera / OCR / Gemma
      //      ↓
      // TTS
      //      ↓
      // command complete
      //      ↓
      // trigger listener re-arm
      //
      // ChatPage MUST NOT manually restart recognition after a command.
      // -----------------------------------------------------------------------

      if (!_disposed) {
        await speech.startCommandListening();
      }
    } catch (e, st) {
      debugPrint(
        '[ChatPage] initialization failed: $e',
      );

      debugPrint('$st');

      if (mounted &&
          !_disposed &&
          !_redirectedOnError) {
        _redirectedOnError = true;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) =>
                const ErrorRecoveryPage(),
          ),
        );
      }
    }
  }

  // ===========================================================================
  // VOICE RUNTIME DISPOSAL
  // ===========================================================================

  Future<void> _disposeCurrentVoiceRuntime({
    bool disposeOcr = false,
  }) async {
    try {
      await _speechService
          ?.stopCommandListening();
    } catch (_) {}

    try {
      _speechService?.dispose();
    } catch (_) {}

    try {
      _chatHelpers?.dispose();
    } catch (_) {}

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

  // ===========================================================================
  // VOICE COMMAND HANDLER
  // ===========================================================================

  /// Executes one voice intent.
  ///
  /// IMPORTANT:
  ///
  /// There is deliberately NO:
  ///
  /// scheduleRestartSoon()
  ///
  /// here.
  ///
  /// SpeechService is the single owner of microphone restart.
  ///
  /// Correct flow:
  ///
  /// SpeechService
  ///    ↓
  /// trigger detected
  ///    ↓
  /// recognizer stopped
  ///    ↓
  /// this method awaited
  ///    ↓
  /// camera / OCR / AI
  ///    ↓
  /// TTS finishes
  ///    ↓
  /// this Future returns
  ///    ↓
  /// SpeechService unlocks
  ///    ↓
  /// trigger listener restarts
  Future<void> _handleVoiceIntent(
    VoiceIntent intent,
    String heardText,
  ) async {
    if (_disposed) {
      return;
    }

    final helpers = _chatHelpers;

    if (helpers == null) {
      return;
    }

    await helpers.handleVoiceIntent(
      intent,
      _msgs,
      _promptBarKey,
      commandText: heardText,
    );

    // =======================================================================
    // DO NOT ADD THIS:
    //
    // _speechService?.scheduleRestartSoon();
    //
    // SpeechService exclusively owns restart.
    // =======================================================================
  }

  // ===========================================================================
  // AUTO SCROLL
  // ===========================================================================

  void _scheduleAutoScroll() {
    _autoScrollTimer?.cancel();

    _autoScrollTimer = Timer(
      const Duration(milliseconds: 100),
      () {
        if (_disposed) {
          return;
        }

        if (!_scrollController.hasClients) {
          return;
        }

        _scrollController.animateTo(
          _scrollController
              .position
              .maxScrollExtent,
          duration:
              const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      },
    );
  }

  // ===========================================================================
  // MANUAL UI ACTIONS
  // ===========================================================================

  Future<void> _newChat() async {
    final helpers = _chatHelpers;

    if (helpers == null ||
        _disposed) {
      return;
    }

    await helpers.newChat(
      _msgs,
      _promptBarKey,
    );
  }

  Future<void> _captureAndSend(
    String prompt,
  ) async {
    final helpers = _chatHelpers;

    if (helpers == null ||
        _disposed) {
      return;
    }

    await helpers.captureAndSend(
      prompt,
      _msgs,
    );
  }

  Future<void> _sendTextOnly(
    String prompt,
  ) async {
    final helpers = _chatHelpers;

    if (helpers == null ||
        _disposed) {
      return;
    }

    await helpers.sendTextOnly(
      prompt,
      _msgs,
    );
  }

  // ===========================================================================
  // APP LIFECYCLE
  // ===========================================================================

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    super.didChangeAppLifecycleState(state);

    if (_disposed ||
        _speechService == null) {
      return;
    }

    final speech = _speechService!;
    final helpers = _chatHelpers;

    if (helpers == null) {
      return;
    }

    // -------------------------------------------------------------------------
    // APP RETURNED TO FOREGROUND
    // -------------------------------------------------------------------------

    if (state ==
        AppLifecycleState.resumed) {
      if (!_resumeVoiceOnForeground) {
        return;
      }

      // ---------------------------------------------------------------------
      // IMPORTANT FIX
      //
      // If background handling used pauseLoop(), we MUST call resumeLoop().
      //
      // startCommandListening() alone is not enough because pauseLoop()
      // leaves SpeechService.pausedForMedia = true.
      // ---------------------------------------------------------------------

      if (_voicePausedByLifecycle) {
        _voicePausedByLifecycle = false;

        unawaited(
          speech.resumeLoop(),
        );
      } else {
        unawaited(
          speech.startCommandListening(),
        );
      }

      return;
    }

    // -------------------------------------------------------------------------
    // APP LEAVING FOREGROUND
    // -------------------------------------------------------------------------

    if (state ==
            AppLifecycleState.paused ||
        state ==
            AppLifecycleState.inactive ||
        state ==
            AppLifecycleState.detached) {
      // Remember whether voice should come back.
      _resumeVoiceOnForeground =
          speech.commandModeEnabled ||
              helpers.isRecording;

      // ---------------------------------------------------------------------
      // Normal command-listening mode
      //
      // Preserve commandModeEnabled and temporarily pause recognition.
      // ---------------------------------------------------------------------

      if (!helpers.isRecording) {
        _voicePausedByLifecycle =
            speech.commandModeEnabled;

        unawaited(
          speech.pauseLoop(),
        );
      }

      // ---------------------------------------------------------------------
      // Recording case
      //
      // Existing behavior intentionally stops command listening completely.
      // startCommandListening() will recreate it after foreground resume.
      // ---------------------------------------------------------------------

      else {
        _voicePausedByLifecycle = false;

        unawaited(
          speech.stopCommandListening(),
        );
      }
    }
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  @override
  void dispose() {
    _disposed = true;

    WidgetsBinding.instance
        .removeObserver(this);

    _autoScrollTimer?.cancel();

    _scrollController.dispose();

    _fadeController.dispose();

    unawaited(
      ChatHistoryStore.save(_msgs),
    );

    try {
      _chatHelpers?.dispose();
    } catch (_) {}

    try {
      _speechService?.dispose();
    } catch (_) {}

    try {
      _streamingTts.dispose();
    } catch (_) {}

    try {
      _tts.stop();
    } catch (_) {}

    try {
      _textRecognition?.dispose();
    } catch (_) {}

    super.dispose();
  }

  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    if (_initialising) {
      return ChatUIBuilder
          .buildLoadingScreen();
    }

    final helpers =
        _chatHelpers;

    final speech =
        _speechService;

    if (helpers == null ||
        speech == null) {
      return ChatUIBuilder
          .buildLoadingScreen();
    }

    return Scaffold(
      backgroundColor:
          const Color(0xFFF7F8FA),

      appBar:
          ChatUIBuilder.buildCleanAppBar(
        onNewChat: _newChat,
        onToggleSettings:
            _navigateToSettings,
        isResetting:
            helpers.resetting,
      ),

      body: FadeTransition(
        opacity: _fadeAnimation,

        child: Column(
          children: [
            // ---------------------------------------------------------------
            // Voice status
            // ---------------------------------------------------------------

            ChatUIBuilder
                .buildVoiceControlCard(
              speechEnabled:
                  speech.speechEnabled,

              listening:
                  speech.commandListening,

              bengaliLocaleAvailable:
                  speech
                      .hasBengaliSpeechLocale,

              lastHeard:
                  speech.lastHeard,

              onToggleListening:
                  speech.toggleDictation,
            ),

            // ---------------------------------------------------------------
            // Quick actions
            // ---------------------------------------------------------------

            ChatUIBuilder
                .buildQuickActions(
              disabled:
                  helpers.isBusy ||
                      helpers.isRecording,

              onDescribeFront: () =>
                  _handleVoiceIntent(
                VoiceIntent.describeFront,
                VoiceIntent
                    .describeFront
                    .banglaLabel,
              ),

              onIdentifyObject: () =>
                  _handleVoiceIntent(
                VoiceIntent.identifyObject,
                VoiceIntent
                    .identifyObject
                    .banglaLabel,
              ),

              onReadText: () =>
                  _handleVoiceIntent(
                VoiceIntent.readText,
                VoiceIntent
                    .readText
                    .banglaLabel,
              ),
            ),

            // ---------------------------------------------------------------
            // Chat controls
            // ---------------------------------------------------------------

            ChatUIBuilder
                .buildViewToggleButtons(
              showMessages:
                  _showMessages,

              onToggleMessages: () {
                if (_disposed) {
                  return;
                }

                setState(() {
                  _showMessages =
                      !_showMessages;
                });

                if (_showMessages) {
                  _scheduleAutoScroll();
                }
              },

              onNewChat:
                  _newChat,

              isResetting:
                  helpers.resetting,
            ),

            // ---------------------------------------------------------------
            // Recording banner
            // ---------------------------------------------------------------

            if (helpers.isRecording)
              ChatUIBuilder
                  .buildRecordingBanner(
                onStop: () =>
                    _handleVoiceIntent(
                  VoiceIntent.stopVideo,
                  VoiceIntent
                      .stopVideo
                      .banglaLabel,
                ),
              ),

            // ---------------------------------------------------------------
            // Messages / last answer
            // ---------------------------------------------------------------

            if (_showMessages)
              ChatUIBuilder
                  .buildMessagesContainer(
                _msgs,
                _scrollController,
              )
            else
              ChatUIBuilder
                  .buildLastAnswer(
                _msgs,
              ),

            // ---------------------------------------------------------------
            // Prompt bar
            // ---------------------------------------------------------------

            ChatUIBuilder
                .buildPromptBarContainer(
              promptBarKey:
                  _promptBarKey,

              onPromptWithPhoto:
                  _captureAndSend,

              onPromptTextOnly:
                  _sendTextOnly,

              disabled:
                  helpers.resetting ||
                      helpers.isGenerating,

              // PromptBar MUST NOT create a second recognizer.
              speechEnabled: false,

              listening:
                  speech.commandListening,

              onToggleListening:
                  speech.toggleDictation,

              isGenerating:
                  helpers.isGenerating,

              isSpeaking:
                  helpers.isSpeaking,

              onStopTts:
                  helpers.stopSpeaking,
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // SETTINGS
  // ===========================================================================

  Future<void> _navigateToSettings() async {
    if (_disposed ||
        !mounted) {
      return;
    }

    final speech =
        _speechService;

    final wasListening =
        speech?.commandModeEnabled ??
            false;

    // -------------------------------------------------------------------------
    // Stop trigger listener while Settings is open
    // -------------------------------------------------------------------------

    await speech?.stopCommandListening();

    final result =
        await Navigator.of(context)
            .push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) =>
            SettingsPage(
          systemContext:
              _systemCtx,

          backend:
              _backend,

          // Legacy compatibility.
          wakeWordMode:
              speech?.wakeWordMode ??
                  false,
        ),
      ),
    );

    if (result != null &&
        mounted &&
        !_disposed) {
      final newSystemContext =
          result['systemContext']
              as String?;

      final newBackend =
          result['backend']
              as PreferredBackend?;

      final wakeWordMode =
          result['wakeWordMode']
              as bool?;

      // ---------------------------------------------------------------------
      // Legacy wake-word preference
      // ---------------------------------------------------------------------

      if (wakeWordMode != null) {
        await _speechService
            ?.setWakeWordMode(
          wakeWordMode,
        );
      }

      // ---------------------------------------------------------------------
      // System prompt / backend
      // ---------------------------------------------------------------------

      if (newSystemContext != null &&
          newBackend != null) {
        final backendChanged =
            _backend !=
                newBackend;

        setState(() {
          _systemCtx =
              newSystemContext;

          _chatHelpers
              ?.updateSystemContext(
            _systemCtx,
          );

          _backend =
              newBackend;
        });

        // -------------------------------------------------------------------
        // Backend changed -> completely rebuild runtime
        // -------------------------------------------------------------------

        if (backendChanged) {
          _msgs.clear();

          setState(() {
            _initialising =
                true;
          });

          await _disposeCurrentVoiceRuntime();

          BootstrapManager.reset();

          _redirectedOnError =
              false;

          await _bootstrap();

          return;
        }
      }
    }

    // -------------------------------------------------------------------------
    // Restore trigger listener after Settings closes
    // -------------------------------------------------------------------------

    if (wasListening &&
        mounted &&
        !_disposed) {
      await _speechService
          ?.startCommandListening();
    }
  }
}
