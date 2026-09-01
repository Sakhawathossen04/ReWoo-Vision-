import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../voice/bengali_voice_commands.dart';
import '../voice/voice_intent.dart';
import '../../download_page/config/constants.dart';
import 'sound_manager.dart';
import 'tts_engine_service.dart';

/// Bengali-first voice control service.
///
/// New direct-trigger lifecycle:
///
///   Trigger listener waiting
///        ↓
///   One of the five configured commands is detected
///        ↓
///   _commandInProgress = true
///        ↓
///   Speech recognizer stops
///        ↓
///   Camera / OCR / AI task runs
///        ↓
///   TTS finishes
///        ↓
///   _commandInProgress = false
///        ↓
///   Trigger listener starts again
///
/// IMPORTANT:
///
/// While [_commandInProgress] is true, every possible automatic microphone
/// restart path is blocked:
///
/// - speech status callback
/// - speech error callback
/// - watchdog
/// - restart timer
/// - public scheduleRestartSoon()
/// - speak()
///
/// This prevents the recognizer from reopening while camera, AI or TTS is
/// still running.
class SpeechService {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts;
  final VoidCallback _onStateChanged;

  // ===========================================================================
  // CORE STATE
  // ===========================================================================

  bool _speechEnabled = false;
  bool _commandModeEnabled = false;
  bool _commandListening = false;
  bool _disposed = false;
  bool _startingSession = false;
  bool _pausedForMedia = false;

  /// True from the moment a valid direct trigger command is detected until
  /// the complete task Future has finished.
  ///
  /// That includes:
  ///
  /// camera
  /// -> OCR / image processing
  /// -> AI generation
  /// -> TTS
  ///
  /// No recognition session is allowed to restart while this is true.
  bool _commandInProgress = false;

  Timer? _restartTimer;
  Timer? _watchdogTimer;

  // ===========================================================================
  // SPEECH LOCALE / STATUS
  // ===========================================================================

  String _bengaliLocaleId = 'bn-BD';
  bool _bengaliLocaleAvailable = true;

  String _lastHeard = '';
  String _lastError = '';

  // ===========================================================================
  // LEGACY WAKE-WORD SETTING
  // ===========================================================================

  /// Kept because SettingsPage / SharedPreferences may still reference this
  /// property.
  ///
  /// Direct five-command trigger mode does NOT use the old wake-word gating.
  /// The five task phrases themselves are the trigger phrases.
  bool _wakeWordMode = false;

  // ===========================================================================
  // COMMAND CALLBACK
  // ===========================================================================

  Future<void> Function(
    VoiceIntent intent,
    String heardText,
  )? _onCommand;

  bool Function()? _canAcceptCommand;

  // ===========================================================================
  // DUPLICATE COMMAND PROTECTION
  // ===========================================================================

  VoiceIntent? _lastIntent;

  DateTime _lastIntentAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  // ===========================================================================
  // CONSTRUCTOR
  // ===========================================================================

  SpeechService({
    required FlutterTts tts,
    required VoidCallback onStateChanged,
  })  : _tts = tts,
        _onStateChanged = onStateChanged;

  // ===========================================================================
  // GETTERS
  // ===========================================================================

  bool get speechEnabled => _speechEnabled;

  bool get commandModeEnabled =>
      _commandModeEnabled;

  bool get commandListening =>
      _commandListening;

  bool get listening =>
      _commandListening;

  bool get commandInProgress =>
      _commandInProgress;

  String get lastHeard =>
      _lastHeard;

  String get lastError =>
      _lastError;

  String get bengaliLocaleId =>
      _bengaliLocaleId;

  bool get hasBengaliSpeechLocale =>
      _bengaliLocaleAvailable;

  bool get wakeWordMode =>
      _wakeWordMode;

  bool get pausedForMedia =>
      _pausedForMedia;

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  Future<void> initialize() async {
    try {
      // -----------------------------------------------------------------------
      // Configure Bengali TTS
      // -----------------------------------------------------------------------

      await TtsEngineService.configure(
        _tts,
      );

      // -----------------------------------------------------------------------
      // Microphone permission
      // -----------------------------------------------------------------------

      final micStatus =
          await Permission.microphone.request();

      debugPrint(
        '[SpeechService] microphone permission: $micStatus',
      );

      // -----------------------------------------------------------------------
      // Initialize SpeechToText
      // -----------------------------------------------------------------------

      _speechEnabled =
          await _speech.initialize(
        onStatus: _handleSpeechStatus,

        onError: (error) {
          if (_disposed) {
            return;
          }

          _commandListening = false;

          final errorCode =
              error.errorMsg.toLowerCase();

          final isLanguageError =
              errorCode.contains(
                'language_not_supported',
              ) ||
              errorCode.contains(
                'language_unavailable',
              );

          // ---------------------------------------------------------------
          // Bengali language unavailable
          // ---------------------------------------------------------------

          if (isLanguageError) {
            _bengaliLocaleAvailable = false;

            _lastError =
                'বাংলা ভয়েস ইনপুট পাওয়া যায়নি। '
                'ফোনের Google Speech Services বা ভয়েস ইনপুটে '
                'বাংলা (বাংলাদেশ) চালু করুন।';

            _commandModeEnabled = false;

            _restartTimer?.cancel();
            _watchdogTimer?.cancel();
          }

          // ---------------------------------------------------------------
          // Other speech recognizer errors
          // ---------------------------------------------------------------

          else {
            _lastError =
                error.errorMsg;

            // Permanent errors cannot be fixed by repeatedly restarting.
            if (error.permanent) {
              _commandModeEnabled = false;

              _restartTimer?.cancel();
              _watchdogTimer?.cancel();
            }

            // Transient error:
            //
            // Restart ONLY when a command is not currently being processed.
            else if (_commandModeEnabled &&
                !_disposed &&
                !_pausedForMedia &&
                !_commandInProgress) {
              _scheduleRestart(
                const Duration(
                  milliseconds: 900,
                ),
              );
            }
          }

          debugPrint(
            '[SpeechService] speech error: $error',
          );

          _onStateChanged();
        },
      );

      // -----------------------------------------------------------------------
      // Resolve Bengali speech locale
      // -----------------------------------------------------------------------

      if (_speechEnabled) {
        await _resolveBengaliLocale();
      }
    } catch (e) {
      _speechEnabled = false;

      _lastError =
          e.toString();

      debugPrint(
        '[SpeechService] initialization error: $e',
      );
    } finally {
      // Legacy settings compatibility.
      await _loadWakeWordMode();

      _onStateChanged();
    }
  }

  // ===========================================================================
  // LEGACY WAKE WORD SETTING
  // ===========================================================================

  Future<void> _loadWakeWordMode() async {
    try {
      final prefs =
          await SharedPreferences.getInstance();

      _wakeWordMode =
          prefs.getBool(wakeWordModeKey) ??
              false;
    } catch (_) {
      _wakeWordMode = false;
    }
  }

  /// Kept for SettingsPage compatibility.
  ///
  /// Direct trigger matching no longer depends on this setting.
  Future<void> setWakeWordMode(
    bool enabled,
  ) async {
    _wakeWordMode = enabled;

    try {
      final prefs =
          await SharedPreferences.getInstance();

      await prefs.setBool(
        wakeWordModeKey,
        enabled,
      );
    } catch (_) {}

    _onStateChanged();
  }

  // ===========================================================================
  // BENGALI LOCALE
  // ===========================================================================

  @visibleForTesting
  static String? selectBengaliLocaleId(
    List<LocaleName> locales,
  ) {
    String normalize(String id) {
      return id
          .toLowerCase()
          .replaceAll('-', '_')
          .trim();
    }

    // -------------------------------------------------------------------------
    // First preference: Bangla (Bangladesh)
    // -------------------------------------------------------------------------

    for (final locale in locales) {
      if (normalize(locale.localeId) ==
          'bn_bd') {
        return locale.localeId;
      }
    }

    // -------------------------------------------------------------------------
    // Second preference: any Bengali locale
    // -------------------------------------------------------------------------

    for (final locale in locales) {
      final id =
          normalize(locale.localeId);

      if (id == 'bn_in' ||
          id == 'bn' ||
          id.startsWith('bn_')) {
        return locale.localeId;
      }
    }

    return null;
  }

  Future<void> _resolveBengaliLocale() async {
    // Always explicitly prefer Bengali.
    //
    // Passing null to speech_to_text may cause the device default language
    // (often English) to be used.
    _bengaliLocaleId = 'bn-BD';

    _bengaliLocaleAvailable = true;

    try {
      final locales =
          await _speech.locales().timeout(
        const Duration(seconds: 5),
      );

      final selected =
          selectBengaliLocaleId(
        locales,
      );

      if (selected != null) {
        _bengaliLocaleId =
            selected;

        debugPrint(
          '[SpeechService] using Bengali speech locale: '
          '$_bengaliLocaleId',
        );

        return;
      }

      // Some Android recognizers do not advertise all supported languages.
      // Explicitly try bn-BD anyway.
      debugPrint(
        '[SpeechService] Bengali locale not advertised; forcing bn-BD.',
      );
    } on TimeoutException {
      debugPrint(
        '[SpeechService] locale lookup timed out; forcing bn-BD.',
      );
    } catch (e) {
      debugPrint(
        '[SpeechService] locale lookup failed: '
        '$e; forcing bn-BD.',
      );
    }
  }

  // ===========================================================================
  // COMMAND HANDLER CONFIGURATION
  // ===========================================================================

  void configureCommandHandler({
    required Future<void> Function(
      VoiceIntent intent,
      String heardText,
    ) onCommand,
    required bool Function() canAcceptCommand,
  }) {
    _onCommand = onCommand;

    _canAcceptCommand =
        canAcceptCommand;
  }

  // ===========================================================================
  // COMMAND LISTENING PUBLIC API
  // ===========================================================================

  Future<void> startCommandListening() async {
    if (_disposed ||
        !_speechEnabled) {
      return;
    }

    if (_pausedForMedia) {
      return;
    }

    // -------------------------------------------------------------------------
    // Recheck Bengali after previous locale failure
    // -------------------------------------------------------------------------

    if (!_bengaliLocaleAvailable) {
      await _resolveBengaliLocale();
    }

    _commandModeEnabled = true;

    _startWatchdog();

    await _startCommandSession();
  }

  Future<void> stopCommandListening() async {
    _commandModeEnabled = false;

    _restartTimer?.cancel();
    _watchdogTimer?.cancel();

    _commandListening = false;

    _onStateChanged();

    try {
      await _speech.stop();
    } catch (e) {
      debugPrint(
        '[SpeechService] stop command listening error: $e',
      );
    }
  }

  /// Temporarily stops trigger recognition while another media operation
  /// requires recognition to remain suspended.
  ///
  /// The main command mode flag is preserved.
  Future<void> pauseLoop() async {
    _pausedForMedia = true;

    _restartTimer?.cancel();
    _watchdogTimer?.cancel();

    _commandListening = false;

    _onStateChanged();

    try {
      await _speech.stop();
    } catch (e) {
      debugPrint(
        '[SpeechService] pause loop error: $e',
      );
    }
  }

  /// Re-enables trigger recognition after [pauseLoop].
  Future<void> resumeLoop() async {
    _pausedForMedia = false;

    _onStateChanged();

    if (_commandModeEnabled &&
        !_disposed &&
        !_commandInProgress) {
      _startWatchdog();

      await _startCommandSession();
    }
  }

  Future<void> toggleDictation() async {
    if (_commandModeEnabled) {
      await stopCommandListening();
    } else {
      await startCommandListening();
    }
  }

  // ===========================================================================
  // LEGACY / COMPATIBILITY RESTART HOOK
  // ===========================================================================

  /// Kept so older code that still calls scheduleRestartSoon() does not break.
  ///
  /// IMPORTANT:
  /// During an active command this intentionally does nothing.
  ///
  /// SpeechService itself now owns command completion + restart.
  void scheduleRestartSoon([
    Duration delay =
        const Duration(milliseconds: 400),
  ]) {
    if (_disposed ||
        !_commandModeEnabled ||
        !_speechEnabled ||
        _pausedForMedia ||
        _commandInProgress) {
      return;
    }

    _scheduleRestart(
      delay,
    );
  }

  // ===========================================================================
  // START ONE RECOGNITION SESSION
  // ===========================================================================

  Future<void> _startCommandSession() async {
    if (_disposed ||
        !_commandModeEnabled ||
        !_speechEnabled ||
        _pausedForMedia ||
        _startingSession ||
        _commandListening ||
        _commandInProgress) {
      return;
    }

    _startingSession = true;

    _restartTimer?.cancel();

    try {
      // -----------------------------------------------------------------------
      // Close any stale platform recognizer
      // -----------------------------------------------------------------------

      if (_speech.isListening) {
        try {
          await _speech.stop();
        } catch (_) {}

        await Future.delayed(
          const Duration(
            milliseconds: 120,
          ),
        );
      }

      // A command may have started while the stale recognizer was stopping.
      if (_disposed ||
          !_commandModeEnabled ||
          _pausedForMedia ||
          _commandInProgress) {
        return;
      }

      _commandListening = true;

      _onStateChanged();

      // -----------------------------------------------------------------------
      // Start Bengali speech recognition
      // -----------------------------------------------------------------------

      await _speech.listen(
        onResult: (result) {
          if (_disposed ||
              !_commandModeEnabled ||
              _pausedForMedia ||
              _commandInProgress) {
            return;
          }

          final heard =
              result.recognizedWords.trim();

          if (heard.isNotEmpty) {
            _lastHeard = heard;

            _onStateChanged();
          }

          // ---------------------------------------------------------------
          // STRICT DIRECT TRIGGER MATCHER
          //
          // Only the five trigger commands are accepted here.
          // ---------------------------------------------------------------

          final intent =
              _extractIntent(
            heard,
          );

          if (intent == null) {
            return;
          }

          _handleDetectedIntent(
            intent,
            heard,
          );
        },

        localeId:
            _bengaliLocaleId,

        // speech_to_text can end earlier depending on platform behaviour.
        // The status callback / watchdog will re-arm waiting mode.
        listenFor:
            const Duration(minutes: 5),

        pauseFor:
            const Duration(seconds: 5),

        listenOptions:
            SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          onDevice: false,
          listenMode:
              ListenMode.confirmation,
        ),
      );
    } catch (e) {
      _commandListening = false;

      final errorText =
          e.toString().toLowerCase();

      final isLanguageError =
          errorText.contains(
            'language_not_supported',
          ) ||
          errorText.contains(
            'language_unavailable',
          );

      // -----------------------------------------------------------------------
      // Bengali unavailable
      // -----------------------------------------------------------------------

      if (isLanguageError) {
        _bengaliLocaleAvailable = false;

        _commandModeEnabled = false;

        _restartTimer?.cancel();
        _watchdogTimer?.cancel();

        _lastError =
            'বাংলা ভয়েস ইনপুট পাওয়া যায়নি। '
            'ফোনের Google Speech Services বা ভয়েস ইনপুটে '
            'বাংলা (বাংলাদেশ) চালু করুন।';
      }

      // -----------------------------------------------------------------------
      // Transient start failure
      // -----------------------------------------------------------------------

      else {
        _lastError =
            e.toString();

        if (!_commandInProgress) {
          _scheduleRestart(
            const Duration(
              milliseconds: 900,
            ),
          );
        }
      }

      debugPrint(
        '[SpeechService] command listen start failed: $e',
      );

      _onStateChanged();
    } finally {
      _startingSession = false;
    }
  }

  // ===========================================================================
  // FIVE-COMMAND TRIGGER MATCHING
  // ===========================================================================

  /// The five task phrases themselves are the wake/activation phrases.
  ///
  /// There is no separate:
  ///
  /// "Hey ReWoo"
  ///     ↓
  /// command
  ///
  /// Instead:
  ///
  /// "সামনে কী আছে দেখো"
  ///     ↓
  /// assistant activates immediately
  VoiceIntent? _extractIntent(
    String heard,
  ) {
    return BengaliVoiceCommands
        .matchTriggerCommand(
      heard,
    );
  }

  // ===========================================================================
  // TRIGGER DETECTED
  // ===========================================================================

  void _handleDetectedIntent(
    VoiceIntent intent,
    String heardText,
  ) {
    // -------------------------------------------------------------------------
    // Never accept a second trigger while a task is already running.
    // -------------------------------------------------------------------------

    if (_commandInProgress) {
      return;
    }

    // -------------------------------------------------------------------------
    // Duplicate partial/final recognition protection
    // -------------------------------------------------------------------------

    final now =
        DateTime.now();

    if (_lastIntent == intent &&
        now.difference(_lastIntentAt) <
            const Duration(seconds: 2)) {
      return;
    }

    // -------------------------------------------------------------------------
    // Check whether ChatPage is ready for a command
    // -------------------------------------------------------------------------

    final canAccept =
        _canAcceptCommand?.call() ??
            true;

    if (!canAccept) {
      return;
    }

    _lastIntent = intent;
    _lastIntentAt = now;

    // -------------------------------------------------------------------------
    // CRITICAL LOCK
    //
    // Set this BEFORE calling _speech.stop().
    //
    // _speech.stop() can immediately generate:
    //
    // notListening
    // done
    // transient error
    //
    // All those callbacks must see commandInProgress == true so they cannot
    // restart the recognizer.
    // -------------------------------------------------------------------------

    _commandInProgress = true;

    _restartTimer?.cancel();

    final handler =
        _onCommand;

    // -------------------------------------------------------------------------
    // No handler configured
    // -------------------------------------------------------------------------

    if (handler == null) {
      _commandInProgress = false;

      _scheduleRestart(
        const Duration(
          milliseconds: 450,
        ),
      );

      return;
    }

    // -------------------------------------------------------------------------
    // Execute the complete trigger -> task -> TTS lifecycle.
    // -------------------------------------------------------------------------

    unawaited(
      _runTriggeredCommand(
        handler,
        intent,
        heardText,
      ),
    );
  }

  // ===========================================================================
  // COMPLETE COMMAND LIFECYCLE
  // ===========================================================================

  Future<void> _runTriggeredCommand(
    Future<void> Function(
      VoiceIntent intent,
      String heardText,
    ) handler,
    VoiceIntent intent,
    String heardText,
  ) async {
    try {
      // =======================================================================
      // PHASE 1
      // TRIGGER DETECTED -> STOP RECOGNIZER
      // =======================================================================

      _restartTimer?.cancel();

      try {
        await _speech.stop();
      } catch (e) {
        debugPrint(
          '[SpeechService] stop after trigger error: $e',
        );
      }

      _commandListening = false;

      _onStateChanged();

      // Give the platform a very small amount of time to release the active
      // recognition session.
      await Future.delayed(
        const Duration(
          milliseconds: 80,
        ),
      );

      // =======================================================================
      // CONFIRMATION SOUND
      // =======================================================================

      try {
        await SoundManager.instance
            .playDictationStart();
      } catch (e) {
        // Confirmation sound failure must never prevent the actual command.
        debugPrint(
          '[SpeechService] trigger confirmation sound failed: $e',
        );
      }

      // =======================================================================
      // PHASE 2
      // EXECUTE COMPLETE TASK
      //
      // This Future should include:
      //
      // camera
      // -> OCR / vision
      // -> Gemma
      // -> final TTS
      //
      // The listener remains locked for the complete await.
      // =======================================================================

      await handler(
        intent,
        heardText,
      );
    } catch (e, st) {
      debugPrint(
        '[SpeechService] triggered command failed: $e',
      );

      debugPrint(
        '$st',
      );
    } finally {
      // =======================================================================
      // PHASE 3
      // TASK + TTS FINISHED
      // =======================================================================

      _commandInProgress = false;

      _commandListening = false;

      _onStateChanged();

      // =======================================================================
      // PHASE 4
      // RE-ARM THE FIVE COMMAND TRIGGERS
      // =======================================================================

      if (!_disposed &&
          _commandModeEnabled &&
          _speechEnabled &&
          !_pausedForMedia) {
        _scheduleRestart(
          const Duration(
            milliseconds: 450,
          ),
        );
      }
    }
  }

  // ===========================================================================
  // SPEECH STATUS CALLBACK
  // ===========================================================================

  void _handleSpeechStatus(
    String status,
  ) {
    debugPrint(
      '[SpeechService] status: $status',
    );

    if (_disposed) {
      return;
    }

    // -------------------------------------------------------------------------
    // LISTENING
    // -------------------------------------------------------------------------

    if (status == 'listening') {
      // A stale Android speech callback may arrive just after a trigger was
      // detected and stop() was requested.
      //
      // Never allow UI/state to consider that listener active during a task.
      if (_commandInProgress) {
        _commandListening = false;

        _onStateChanged();

        if (_speech.isListening) {
          unawaited(
            _speech.stop(),
          );
        }

        return;
      }

      _commandListening = true;

      _bengaliLocaleAvailable = true;

      _lastError = '';

      _onStateChanged();

      return;
    }

    // -------------------------------------------------------------------------
    // NOT LISTENING / DONE
    // -------------------------------------------------------------------------

    if (status == 'notListening' ||
        status == 'done') {
      _commandListening = false;

      _onStateChanged();

      // CRITICAL:
      //
      // During camera / AI / TTS the recognizer MUST stay stopped.
      if (_commandModeEnabled &&
          !_pausedForMedia &&
          !_commandInProgress) {
        _scheduleRestart(
          const Duration(
            milliseconds: 500,
          ),
        );
      }
    }
  }

  // ===========================================================================
  // WATCHDOG
  // ===========================================================================

  /// Android speech recognizers sometimes silently stop without producing a
  /// useful callback.
  ///
  /// The watchdog restores trigger waiting mode, but NEVER while a command is
  /// being executed.
  void _startWatchdog() {
    _watchdogTimer?.cancel();

    _watchdogTimer =
        Timer.periodic(
      const Duration(seconds: 8),
      (_) {
        if (_disposed ||
            !_commandModeEnabled ||
            !_speechEnabled ||
            _pausedForMedia ||
            _commandInProgress) {
          return;
        }

        if (!_commandListening &&
            !_startingSession &&
            !_speech.isListening) {
          unawaited(
            _startCommandSession(),
          );
        }
      },
    );
  }

  // ===========================================================================
  // CENTRAL RESTART METHOD
  // ===========================================================================

  /// Every automatic microphone restart eventually comes through this method.
  ///
  /// That gives us one final safety gate before opening recognition.
  void _scheduleRestart(
    Duration delay,
  ) {
    if (_disposed ||
        !_commandModeEnabled ||
        !_speechEnabled ||
        _pausedForMedia ||
        _commandInProgress) {
      return;
    }

    _restartTimer?.cancel();

    _restartTimer =
        Timer(
      delay,
      () {
        if (_disposed ||
            !_commandModeEnabled ||
            !_speechEnabled ||
            _pausedForMedia ||
            _commandInProgress) {
          return;
        }

        unawaited(
          _startCommandSession(),
        );
      },
    );
  }

  // ===========================================================================
  // ACCESSIBILITY ANNOUNCEMENTS
  // ===========================================================================

  Future<void> announceMessageType(
    bool hasPhoto,
  ) async {
    await speak(
      hasPhoto
          ? 'ছবিসহ প্রশ্ন পাঠানো হচ্ছে'
          : 'প্রশ্ন পাঠানো হচ্ছে',
    );
  }

  // ===========================================================================
  // SHORT TTS
  // ===========================================================================

  /// Speaks a short accessibility message.
  ///
  /// There are two cases:
  ///
  /// CASE A:
  /// speak() is called outside a triggered command.
  ///
  /// -> temporarily stop recognition
  /// -> speak
  /// -> restart recognition
  ///
  /// CASE B:
  /// speak() is called while _commandInProgress == true.
  ///
  /// -> recognizer is already locked/stopped
  /// -> speak
  /// -> DO NOT restart here
  /// -> _runTriggeredCommand() finally restarts after the whole command
  Future<void> speak(
    String message,
  ) async {
    final clean =
        message.trim();

    if (clean.isEmpty ||
        _disposed) {
      return;
    }

    // Only this standalone speak() call owns recognizer pause/resume when no
    // triggered command currently owns the lifecycle.
    final shouldPauseRecognizer =
        _commandModeEnabled &&
        !_commandInProgress &&
        !_pausedForMedia;

    if (shouldPauseRecognizer) {
      _restartTimer?.cancel();

      try {
        await _speech.stop();
      } catch (e) {
        debugPrint(
          '[SpeechService] stop before TTS error: $e',
        );
      }

      _commandListening = false;

      _onStateChanged();
    }

    try {
      // Timeout protection prevents a broken TTS engine from freezing the
      // microphone lifecycle forever.
      await TtsEngineService
          .speakWithTimeout(
        _tts,
        clean,
      );
    } catch (e) {
      debugPrint(
        '[SpeechService] TTS error: $e',
      );
    } finally {
      // Only restart if this speak() call itself paused recognition.
      //
      // During a triggered command, _runTriggeredCommand() is the sole owner
      // of restart.
      if (shouldPauseRecognizer &&
          !_disposed &&
          _commandModeEnabled &&
          !_pausedForMedia &&
          !_commandInProgress) {
        _scheduleRestart(
          const Duration(
            milliseconds: 350,
          ),
        );
      }
    }
  }

  // ===========================================================================
  // SOUNDS
  // ===========================================================================

  Future<void> playWooshSound() {
    return SoundManager.instance
        .playWoosh();
  }

  // ===========================================================================
  // STOP TTS
  // ===========================================================================

  Future<void> stopTts() async {
    try {
      await _tts.stop();

      await Future.delayed(
        const Duration(
          milliseconds: 40,
        ),
      );
    } catch (e) {
      debugPrint(
        '[SpeechService] stop TTS error: $e',
      );
    }
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;

    _commandModeEnabled = false;
    _commandListening = false;
    _commandInProgress = false;
    _startingSession = false;

    _restartTimer?.cancel();
    _watchdogTimer?.cancel();

    _restartTimer = null;
    _watchdogTimer = null;

    unawaited(
      _speech.stop(),
    );

    unawaited(
      _speech.cancel(),
    );
  }
}
