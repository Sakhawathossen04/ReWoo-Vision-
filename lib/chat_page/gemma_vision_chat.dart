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
///
/// Voice ownership rule:
///
/// - ChatPage decides whether voice mode SHOULD be armed.
/// - SpeechService exclusively owns STT session start/restart while armed.
/// - ChatPage never restarts STT after an individual voice command.
/// - Lifecycle pause is temporary and must never permanently disable voice.
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

  // ===========================================================================
  // VOICE INTENT / LIFECYCLE STATE
  // ===========================================================================

  /// Stable desired state.
  ///
  /// This is intentionally NOT derived from speech.commandModeEnabled during
  /// lifecycle callbacks. A temporary recognizer error, app inactivity, TTS,
  /// camera work, or Android callback must not permanently turn voice off.
  ///
  /// Initial value is true because ReWoo Vision is voice-first.
  bool _voiceShouldBeArmed = true;

  /// Whether the app is currently in the foreground.
  bool _appInForeground = true;

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

    final lifecycleState =
        WidgetsBinding.instance.lifecycleState;

    _appInForeground =
        lifecycleState == null ||
        lifecycleState == AppLifecycleState.resumed;

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 450),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    unawaited(
      _bootstrap(),
    );
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

      if (_disposed || !mounted) {
        return;
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

      if (_disposed || !mounted) {
        return;
      }

      // -----------------------------------------------------------------------
      // Release previous/dummy TTS wrapper
      // -----------------------------------------------------------------------

      _streamingTts.dispose();

      try {
        await _tts.stop();
      } catch (_) {}

      if (_disposed || !mounted) {
        return;
      }

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
          // or assistant speech is still active.
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

      // =======================================================================
      // ARM VOICE BEFORE STARTUP TTS
      // =======================================================================
      //
      // Old flow:
      //
      //   speak startup message
      //   -> later startCommandListening()
      //
      // New flow:
      //
      //   desired voice state = ON
      //   -> arm SpeechService first
      //   -> SpeechService.speak() temporarily pauses STT using its TTS lock
      //   -> TTS ends
      //   -> SpeechService can re-arm automatically
      //
      // This removes the startup gap where lifecycle changes could leave
      // commandModeEnabled false and require a manual mic tap.
      // =======================================================================

      if (_voiceShouldBeArmed &&
          _appInForeground &&
          speech.microphonePermissionGranted &&
          !_disposed) {
        await speech.startCommandListening();
      }

      if (_disposed || !mounted) {
        return;
      }

      // -----------------------------------------------------------------------
      // STARTUP VOICE MESSAGE
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

      if (_disposed || !mounted) {
        return;
      }

      // -----------------------------------------------------------------------
      // FINAL STARTUP SELF-HEAL
      // -----------------------------------------------------------------------
      //
      // If TTS/lifecycle/native recognizer callbacks ended the first session,
      // restore the desired always-on command listener.
      // -----------------------------------------------------------------------

      await _restoreVoiceListening(
        reason: 'bootstrap complete',
      );
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
  // CENTRAL VOICE RESTORE
  // ===========================================================================

  /// Restores the microphone only when the user/app still wants voice mode.
  ///
  /// IMPORTANT:
  ///
  /// This method is used for:
  ///
  /// - bootstrap completion
  /// - foreground resume
  /// - settings return
  ///
  /// It is NOT called after an individual voice command. SpeechService owns
  /// command completion and restart.
  Future<void> _restoreVoiceListening({
    required String reason,
  }) async {
    if (_disposed ||
        !mounted ||
        !_voiceShouldBeArmed ||
        !_appInForeground) {
      return;
    }

    final speech = _speechService;
    final helpers = _chatHelpers;

    if (speech == null ||
        helpers == null) {
      return;
    }

    // Video recording intentionally owns microphone/media resources.
    if (helpers.isRecording) {
      debugPrint(
        '[ChatPage] voice restore deferred during recording: $reason',
      );

      return;
    }

    try {
      // Lifecycle pauseLoop() sets pausedForMedia=true while preserving the
      // desired command mode. resumeLoop() MUST clear that temporary blocker.
      if (speech.pausedForMedia) {
        debugPrint(
          '[ChatPage] resuming paused voice loop: $reason',
        );

        await speech.resumeLoop();

        return;
      }

      // If command mode was genuinely disabled by Android/service state,
      // startCommandListening() self-heals permission/recognizer readiness.
      if (!speech.commandModeEnabled) {
        debugPrint(
          '[ChatPage] re-arming command mode: $reason',
        );

        await speech.startCommandListening();

        return;
      }

      // Command mode is armed but no recognizer session is currently active.
      //
      // Do NOT interfere with an in-progress voice command. Its finally block
      // inside SpeechService owns restart.
      if (!speech.commandListening &&
          !speech.commandInProgress) {
        debugPrint(
          '[ChatPage] command mode armed but idle; restoring session: $reason',
        );

        await speech.resumeLoop();
      }
    } catch (e) {
      // Do not disable desired voice state because of one temporary failure.
      // SpeechService watchdog/error recovery remains active when possible.
      debugPrint(
        '[ChatPage] voice restore warning ($reason): $e',
      );
    }
  }

  // ===========================================================================
  // MANUAL VOICE TOGGLE
  // ===========================================================================

  /// Manual UI control changes the stable desired voice state.
  ///
  /// Temporary lifecycle/TTS/media pauses do NOT change this value.
  Future<void> _toggleVoiceListening() async {
    if (_disposed) {
      return;
    }

    final speech = _speechService;

    if (speech == null) {
      return;
    }

    if (speech.commandModeEnabled) {
      _voiceShouldBeArmed = false;

      await speech.stopCommandListening();

      return;
    }

    _voiceShouldBeArmed = true;

    if (!_appInForeground) {
      return;
    }

    if (speech.pausedForMedia) {
      await speech.resumeLoop();

      // resumeLoop() requires command mode to have been armed previously.
      // If the mode was fully stopped, start it explicitly.
      if (!speech.commandModeEnabled &&
          !_disposed) {
        await speech.startCommandListening();
      }

      return;
    }

    await speech.startCommandListening();
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
  /// There is deliberately NO scheduleRestartSoon() here.
  ///
  /// SpeechService is the single owner of microphone restart for a detected
  /// voice command:
  ///
  /// trigger
  ///   -> commandInProgress=true
  ///   -> STT stop
  ///   -> camera/OCR/Gemma/TTS
  ///   -> handler Future returns
  ///   -> commandInProgress=false
  ///   -> SpeechService re-arms STT
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

    if (_disposed) {
      return;
    }

    // -------------------------------------------------------------------------
    // APP RETURNED TO FOREGROUND
    // -------------------------------------------------------------------------

    if (state ==
        AppLifecycleState.resumed) {
      _appInForeground = true;

      // Stable desired state wins.
      //
      // We do NOT ask whether commandModeEnabled happened to be true during
      // the previous inactive callback. That value may be temporarily false
      // because of TTS, startup, Android recognizer recovery, or media work.
      if (_voiceShouldBeArmed) {
        unawaited(
          _restoreVoiceListening(
            reason: 'app resumed',
          ),
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
      _appInForeground = false;

      final speech = _speechService;
      final helpers = _chatHelpers;

      if (speech == null ||
          helpers == null) {
        return;
      }

      // CRITICAL:
      //
      // NEVER overwrite _voiceShouldBeArmed here.
      //
      // Lifecycle is temporary. The user's desired always-on voice setting
      // must survive inactive -> paused -> resumed sequences.

      if (!helpers.isRecording) {
        // pauseLoop() preserves commandModeEnabled and only adds a temporary
        // media/lifecycle blocker.
        //
        // Only call it when command mode is actually armed. Calling pauseLoop()
        // on an already-disabled mode would leave pausedForMedia=true and could
        // make a later manual start unnecessarily complicated.
        if (speech.commandModeEnabled &&
            !speech.pausedForMedia) {
          unawaited(
            speech.pauseLoop(),
          );
        }
      } else {
        // Recording owns media resources. Stop the recognizer session.
        //
        // _voiceShouldBeArmed remains unchanged so voice can be restored later.
        if (speech.commandModeEnabled) {
          unawaited(
            speech.stopCommandListening(),
          );
        }
      }
    }
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  @override
  void dispose() {
    _disposed = true;
    _voiceShouldBeArmed = false;
    _appInForeground = false;

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
                  _toggleVoiceListening,
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
                onStop: () async {
                  await _handleVoiceIntent(
                    VoiceIntent.stopVideo,
                    VoiceIntent
                        .stopVideo
                        .banglaLabel,
                  );

                  // If recording was stopped from the UI (not through the
                  // SpeechService command lifecycle), restore desired voice.
                  await _restoreVoiceListening(
                    reason: 'recording stopped',
                  );
                },
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
                  _toggleVoiceListening,

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

    // IMPORTANT:
    //
    // Use the stable desired state, NOT commandModeEnabled.
    //
    // commandModeEnabled can be temporarily false because Android or media
    // work. Settings navigation must not accidentally make that temporary
    // state permanent.
    final shouldRestoreVoice =
        _voiceShouldBeArmed;

    // -------------------------------------------------------------------------
    // Temporarily stop trigger listener while Settings is open.
    //
    // Do NOT change _voiceShouldBeArmed.
    // -------------------------------------------------------------------------

    await speech
        ?.stopCommandListening();

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

    if (_disposed ||
        !mounted) {
      return;
    }

    if (result != null) {
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
        // Backend changed -> completely rebuild runtime.
        //
        // _voiceShouldBeArmed survives the rebuild.
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
    // Restore trigger listener after Settings closes.
    // -------------------------------------------------------------------------

    if (shouldRestoreVoice &&
        _voiceShouldBeArmed &&
        mounted &&
        !_disposed) {
      await _restoreVoiceListening(
        reason: 'settings closed',
      );
    }
  }
}
