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

  /// Whether trigger listening should resume when the app returns
  /// to the foreground.
  bool _resumeVoiceOnForeground = true;

  final ScrollController _scrollController =
      ScrollController();

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
      // Bootstrap app services
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
      // Release old/dummy TTS wrapper before switching runtime
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

      // -----------------------------------------------------------------------
      // Configure voice command handler
      // -----------------------------------------------------------------------

      _speechService!.configureCommandHandler(
        onCommand: _handleVoiceIntent,
        canAcceptCommand: () {
          final helpers = _chatHelpers;

          if (helpers == null) {
            return false;
          }

          // Video recording is silent (enableAudio: false), therefore
          // recognition can remain available when necessary.
          if (helpers.isRecording) {
            return true;
          }

          // Do not accept another task while AI/camera/TTS is active.
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
      // Bengali speech locale warning
      // -----------------------------------------------------------------------

      if (!_speechService!
              .hasBengaliSpeechLocale &&
          mounted &&
          !_disposed) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'এই ফোনে বাংলা স্পিচ-রিকগনিশন লোকেল পাওয়া যায়নি। '
              'Google Speech Services-এ বাংলা ভাষা চালু করুন।',
            ),
          ),
        );
      }

      // -----------------------------------------------------------------------
      // Startup announcement
      //
      // IMPORTANT:
      // These are the SAME five direct trigger commands configured inside
      // BengaliVoiceCommands.triggerCommands.
      // -----------------------------------------------------------------------

      await _speechService!.speak(
        'সহায়ক প্রস্তুত। '
        'আপনি বলতে পারেন, '
        'সামনে কী আছে দেখো, '
        'এটা কী, '
        'লেখাটা পড়ে শোনাও, '
        'ডান পাশে কী আছে, '
        'অথবা বাম পাশে কী আছে।',
      );

      // -----------------------------------------------------------------------
      // Start waiting for the five trigger commands.
      //
      // SpeechService owns the trigger lifecycle from this point:
      //
      // wait
      // -> trigger detected
      // -> stop recognizer
      // -> run task
      // -> AI processing
      // -> TTS
      // -> task completes
      // -> restart trigger listener
      // -----------------------------------------------------------------------

      if (!_disposed) {
        await _speechService!
            .startCommandListening();
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

        Navigator.of(context)
            .pushReplacement(
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
    // Stop command recognition first.
    try {
      await _speechService
          ?.stopCommandListening();
    } catch (_) {}

    // Dispose speech service.
    try {
      _speechService?.dispose();
    } catch (_) {}

    // Dispose chat helper runtime.
    try {
      _chatHelpers?.dispose();
    } catch (_) {}

    // Stop streaming TTS.
    try {
      _streamingTts.stop();
    } catch (_) {}

    // Stop Flutter TTS.
    try {
      await _tts.stop();
    } catch (_) {}

    // OCR can optionally survive a runtime/backend restart.
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

  /// Executes a voice intent.
  ///
  /// IMPORTANT:
  ///
  /// ChatPage does NOT restart the microphone here.
  ///
  /// SpeechService is the single owner of the complete voice lifecycle:
  ///
  /// trigger detected
  ///     ↓
  /// recognizer stopped
  ///     ↓
  /// command handler called
  ///     ↓
  /// camera / OCR / AI task
  ///     ↓
  /// TTS response
  ///     ↓
  /// handler Future completes
  ///     ↓
  /// SpeechService re-arms trigger listening
  ///
  /// Keeping restart logic in one place prevents duplicate recognizer
  /// sessions and prevents the mic from reopening while TTS is speaking.
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

    // DO NOT call:
    //
    // _speechService?.scheduleRestartSoon();
    //
    // SpeechService will restart the trigger listener only after this
    // complete Future returns.
  }

  // ===========================================================================
  // AUTO SCROLL
  // ===========================================================================

  void _scheduleAutoScroll() {
    _autoScrollTimer?.cancel();

    _autoScrollTimer =
        Timer(
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

    if (helpers == null || _disposed) {
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

    if (helpers == null || _disposed) {
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

    if (helpers == null || _disposed) {
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
    super.didChangeAppLifecycleState(
      state,
    );

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
      if (_resumeVoiceOnForeground) {
        unawaited(
          speech.startCommandListening(),
        );
      }

      return;
    }

    // -------------------------------------------------------------------------
    // APP MOVED AWAY FROM FOREGROUND
    // -------------------------------------------------------------------------

    if (state ==
            AppLifecycleState.paused ||
        state ==
            AppLifecycleState.inactive ||
        state ==
            AppLifecycleState.detached) {
      // Remember whether voice listening must come back when the app resumes.
      _resumeVoiceOnForeground =
          speech.commandModeEnabled ||
              helpers.isRecording;

      // Keep video recording alive when necessary.
      //
      // Otherwise pause recognition while the app is not active.
      if (!helpers.isRecording) {
        unawaited(
          speech.pauseLoop(),
        );
      } else {
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

    // Persist conversation before runtime goes away.
    unawaited(
      ChatHistoryStore.save(_msgs),
    );

    // dispose() cannot await.
    //
    // Detach and dispose services synchronously where possible.
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
  Widget build(BuildContext context) {
    if (_initialising) {
      return ChatUIBuilder
          .buildLoadingScreen();
    }

    final helpers = _chatHelpers;
    final speech = _speechService;

    // Runtime should normally always exist after initialization.
    //
    // This guard prevents a crash during runtime replacement/backend
    // transitions.
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
        isResetting: helpers.resetting,
      ),

      body: FadeTransition(
        opacity: _fadeAnimation,

        child: Column(
          children: [
            // ---------------------------------------------------------------
            // Voice status/control
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
            //
            // These are manual UI alternatives to voice triggers.
            // ---------------------------------------------------------------

            ChatUIBuilder
                .buildQuickActions(
              disabled:
                  helpers.isBusy ||
                      helpers.isRecording,

              onDescribeFront: () =>
                  _handleVoiceIntent(
                VoiceIntent
                    .describeFront,
                VoiceIntent
                    .describeFront
                    .banglaLabel,
              ),

              onIdentifyObject: () =>
                  _handleVoiceIntent(
                VoiceIntent
                    .identifyObject,
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
            // Chat view controls
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

              onNewChat: _newChat,

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
            // Messages / last response
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

              // Voice trigger listening is managed globally by SpeechService.
              //
              // PromptBar therefore does not create another speech recognizer.
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

  Future<void>
      _navigateToSettings() async {
    if (_disposed || !mounted) {
      return;
    }

    final speech = _speechService;

    final wasListening =
        speech?.commandModeEnabled ??
            false;

    // Stop trigger recognition while Settings is open.
    await speech?.stopCommandListening();

    final result =
        await Navigator.of(context)
            .push<
                Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          systemContext: _systemCtx,
          backend: _backend,

          // Legacy setting retained for compatibility.
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
      // Legacy wake-word setting
      // ---------------------------------------------------------------------

      if (wakeWordMode != null) {
        await _speechService
            ?.setWakeWordMode(
          wakeWordMode,
        );
      }

      // ---------------------------------------------------------------------
      // System context / backend
      // ---------------------------------------------------------------------

      if (newSystemContext != null &&
          newBackend != null) {
        final backendChanged =
            _backend != newBackend;

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

        // Backend change requires complete runtime rebuild.
        if (backendChanged) {
          _msgs.clear();

          setState(() {
            _initialising = true;
          });

          await _disposeCurrentVoiceRuntime();

          BootstrapManager.reset();

          _redirectedOnError = false;

          await _bootstrap();

          return;
        }
      }
    }

    // -----------------------------------------------------------------------
    // Resume trigger listener after Settings closes.
    // -----------------------------------------------------------------------

    if (wasListening &&
        mounted &&
        !_disposed) {
      await _speechService
          ?.startCommandListening();
    }
  }
}
