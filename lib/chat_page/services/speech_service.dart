import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../download_page/config/constants.dart';
import '../voice/bengali_voice_commands.dart';
import '../voice/voice_intent.dart';
import 'sound_manager.dart';
import 'tts_engine_service.dart';

/// Bengali-first, always-armed voice command service.
///
/// Intended lifecycle:
///
/// app ready
///   -> microphone permission
///   -> SpeechToText ready
///   -> command mode armed
///   -> Bengali listening session
///   -> exact FINAL trigger result
///   -> command lock
///   -> stop STT
///   -> camera/OCR/Gemma/TTS
///   -> command unlock
///   -> automatically re-arm STT
///
/// Important:
///
/// - Partial STT results never trigger a command.
/// - Camera / AI / TTS can never restart STT while they are active.
/// - Normal recognizer errors such as no-match, timeout, busy, network/client
///   errors do not permanently disable command mode.
/// - Only real hard failures such as permission denial, unsupported Bengali,
///   or unavailable recognizer disable automatic command listening.
class SpeechService {
  final SpeechToText _speech = SpeechToText();

  final FlutterTts _tts;
  final VoidCallback _onStateChanged;

  // ===========================================================================
  // CORE STATE
  // ===========================================================================

  bool _speechEnabled = false;

  /// Desired always-on command mode.
  ///
  /// This is set BEFORE starting an actual recognition session so a temporary
  /// pause, lifecycle transition, recognizer timeout, or TTS cannot lose the
  /// user's intended listening state.
  bool _commandModeEnabled = false;

  /// True only while Android currently has an active recognition session.
  bool _commandListening = false;

  bool _disposed = false;
  bool _startingSession = false;
  bool _pausedForMedia = false;

  /// True from trigger detection until camera/OCR/Gemma/TTS is completely done.
  bool _commandInProgress = false;

  /// Blocks status/error/watchdog restart while SpeechService-owned TTS is
  /// speaking.
  bool _ttsInProgress = false;

  Future<void>? _initializationFuture;

  // ===========================================================================
  // DEVICE / PERMISSION STATE
  // ===========================================================================

  bool _microphonePermissionGranted = false;
  bool _microphonePermissionPermanentlyDenied = false;

  bool _speechRecognizerAvailable = false;

  bool _bengaliLanguageUnsupported = false;

  // ===========================================================================
  // TIMERS
  // ===========================================================================

  Timer? _restartTimer;
  Timer? _watchdogTimer;

  // ===========================================================================
  // LANGUAGE / DISPLAY STATE
  // ===========================================================================

  String _bengaliLocaleId = 'bn-BD';
  bool _bengaliLocaleAvailable = true;

  String _lastHeard = '';
  String _lastError = '';

  // ===========================================================================
  // LEGACY WAKE-WORD SETTING
  // ===========================================================================

  /// Kept only for Settings/SharedPreferences compatibility.
  ///
  /// The five direct Bengali trigger phrases do not require a wake word.
  bool _wakeWordMode = false;

  // ===========================================================================
  // COMMAND HANDLERS
  // ===========================================================================

  Future<void> Function(
    VoiceIntent intent,
    String heardText,
  )? _onCommand;

  bool Function()? _canAcceptCommand;

  // ===========================================================================
  // DUPLICATE FINAL-RESULT PROTECTION
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

  bool get commandModeEnabled => _commandModeEnabled;

  bool get commandListening => _commandListening;

  bool get listening => _commandListening;

  bool get commandInProgress => _commandInProgress;

  bool get microphonePermissionGranted =>
      _microphonePermissionGranted;

  bool get microphonePermissionPermanentlyDenied =>
      _microphonePermissionPermanentlyDenied;

  bool get speechRecognizerAvailable =>
      _speechRecognizerAvailable;

  bool get bengaliLanguageUnsupported =>
      _bengaliLanguageUnsupported;

  String get lastHeard => _lastHeard;

  String get lastError => _lastError;

  String get bengaliLocaleId => _bengaliLocaleId;

  bool get hasBengaliSpeechLocale =>
      _bengaliLocaleAvailable;

  bool get wakeWordMode => _wakeWordMode;

  bool get pausedForMedia => _pausedForMedia;

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  /// Idempotent and single-flight.
  ///
  /// Calling this twice cannot create two concurrent recognizer initializations.
  Future<void> initialize() async {
    if (_disposed) {
      return;
    }

    final running = _initializationFuture;

    if (running != null) {
      await running;
      return;
    }

    if (_microphonePermissionGranted &&
        _speechEnabled &&
        _speechRecognizerAvailable) {
      await _loadWakeWordMode();
      _onStateChanged();
      return;
    }

    final future = _initializeInternal();

    _initializationFuture = future;

    try {
      await future;
    } finally {
      if (identical(
        _initializationFuture,
        future,
      )) {
        _initializationFuture = null;
      }
    }
  }

  Future<void> _initializeInternal() async {
    if (_disposed) {
      return;
    }

    try {
      // -----------------------------------------------------------------------
      // 1. TTS
      // -----------------------------------------------------------------------

      try {
        await TtsEngineService.configure(
          _tts,
        );
      } catch (e) {
        debugPrint(
          '[SpeechService] TTS configuration warning: $e',
        );
      }

      if (_disposed) {
        return;
      }

      // -----------------------------------------------------------------------
      // 2. MICROPHONE PERMISSION
      // -----------------------------------------------------------------------

      final micStatus =
          await Permission.microphone.request();

      if (_disposed) {
        return;
      }

      debugPrint(
        '[SpeechService] microphone permission: $micStatus',
      );

      _microphonePermissionGranted =
          micStatus.isGranted;

      _microphonePermissionPermanentlyDenied =
          micStatus.isPermanentlyDenied;

      if (!micStatus.isGranted) {
        _speechEnabled = false;
        _speechRecognizerAvailable = false;
        _commandListening = false;

        // Permission failure is a real hard blocker.
        _commandModeEnabled = false;

        _restartTimer?.cancel();
        _watchdogTimer?.cancel();

        if (micStatus.isPermanentlyDenied) {
          _lastError =
              'মাইক্রোফোন অনুমতি স্থায়ীভাবে বন্ধ আছে। '
              'ফোনের Settings > Apps > ReWoo Vision > Permissions থেকে '
              'Microphone permission চালু করুন।';
        } else if (micStatus.isRestricted) {
          _lastError =
              'এই ফোনে মাইক্রোফোন ব্যবহার সীমাবদ্ধ করা আছে। '
              'ফোনের Settings থেকে Microphone access চালু করুন।';
        } else {
          _lastError =
              'ভয়েস কমান্ড ব্যবহার করতে Microphone permission প্রয়োজন। '
              'অনুগ্রহ করে Microphone permission Allow করুন।';
        }

        debugPrint(
          '[SpeechService] microphone permission unavailable: $_lastError',
        );

        return;
      }

      _microphonePermissionGranted = true;
      _microphonePermissionPermanentlyDenied = false;

      // -----------------------------------------------------------------------
      // 3. SPEECH RECOGNIZER
      // -----------------------------------------------------------------------

      final recognizerInitialized =
          await _speech.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
      );

      if (_disposed) {
        return;
      }

      if (!recognizerInitialized) {
        _speechEnabled = false;
        _speechRecognizerAvailable = false;
        _commandListening = false;

        // No recognizer is a hard blocker.
        _commandModeEnabled = false;

        _restartTimer?.cancel();
        _watchdogTimer?.cancel();

        _lastError =
            'এই ফোনে ব্যবহারযোগ্য Speech Recognition service পাওয়া যায়নি। '
            'Google app / Speech Services by Google ইনস্টল বা চালু করুন, '
            'তারপর অ্যাপটি আবার খুলুন।';

        debugPrint(
          '[SpeechService] SpeechToText.initialize() returned false.',
        );

        return;
      }

      _speechEnabled = true;
      _speechRecognizerAvailable = true;

      // A successful fresh initialization gets a new Bengali attempt.
      _bengaliLanguageUnsupported = false;
      _bengaliLocaleAvailable = true;

      // -----------------------------------------------------------------------
      // 4. BENGALI LOCALE
      // -----------------------------------------------------------------------

      await _resolveBengaliLocale();

      if (_lastError.isEmpty) {
        debugPrint(
          '[SpeechService] initialization successful.',
        );
      }
    } catch (e, st) {
      _speechEnabled = false;
      _speechRecognizerAvailable = false;
      _commandListening = false;
      _commandModeEnabled = false;

      _restartTimer?.cancel();
      _watchdogTimer?.cancel();

      _lastError =
          'ভয়েস সিস্টেম চালু করা যায়নি। ${e.toString()}';

      debugPrint(
        '[SpeechService] initialization error: $e',
      );

      debugPrint(
        '$st',
      );
    } finally {
      await _loadWakeWordMode();

      if (!_disposed) {
        _onStateChanged();
      }
    }
  }

  // ===========================================================================
  // SPEECH ERROR HANDLER
  // ===========================================================================

  void _handleSpeechError(
    dynamic error,
  ) {
    if (_disposed) {
      return;
    }

    _commandListening = false;

    final rawError =
        error.errorMsg.toString();

    final errorCode =
        rawError.toLowerCase();

    debugPrint(
      '[SpeechService] speech error: $error',
    );

    // -------------------------------------------------------------------------
    // HARD FAILURE: BENGALI UNSUPPORTED
    // -------------------------------------------------------------------------

    if (_isLanguageError(
      errorCode,
    )) {
      _disableForUnsupportedBengali();
      return;
    }

    // -------------------------------------------------------------------------
    // HARD FAILURE: PERMISSION
    // -------------------------------------------------------------------------

    if (_isPermissionError(
      errorCode,
    )) {
      _speechEnabled = false;
      _commandModeEnabled = false;
      _commandListening = false;

      _restartTimer?.cancel();
      _watchdogTimer?.cancel();

      _lastError =
          'মাইক্রোফোন অনুমতি পাওয়া যায়নি। '
          'ফোনের Settings > Apps > ReWoo Vision > Permissions থেকে '
          'Microphone permission চালু করুন।';

      _onStateChanged();

      return;
    }

    // -------------------------------------------------------------------------
    // HARD FAILURE: RECOGNIZER/SERVICE REALLY UNAVAILABLE
    // -------------------------------------------------------------------------

    if (_isRecognizerUnavailableError(
      errorCode,
    )) {
      _speechRecognizerAvailable = false;
      _speechEnabled = false;

      _commandModeEnabled = false;
      _commandListening = false;

      _restartTimer?.cancel();
      _watchdogTimer?.cancel();

      _lastError =
          'ফোনের Speech Recognition service এখন ব্যবহার করা যাচ্ছে না। '
          'Google app / Speech Services by Google চালু আছে কিনা পরীক্ষা করুন।';

      _onStateChanged();

      return;
    }

    // -------------------------------------------------------------------------
    // RECOVERABLE / IDLE ERRORS
    // -------------------------------------------------------------------------
    //
    // speech_to_text / Android may mark errors such as:
    //
    // error_no_match
    // error_speech_timeout
    // error_busy
    // error_network
    // error_client
    //
    // as permanent=true for a single recognition session.
    //
    // That does NOT mean the app's always-on command mode should be disabled.
    //
    // Old behavior disabled _commandModeEnabled for every permanent error.
    // That is exactly the failure mode where auto-listening silently dies and
    // tapping the microphone manually makes it work again.
    // -------------------------------------------------------------------------

    final permanent =
        error.permanent == true;

    _lastError =
        _friendlyTransientError(
      errorCode,
      rawError,
    );

    debugPrint(
      '[SpeechService] recoverable recognition error '
      '(permanent=$permanent): $rawError',
    );

    _onStateChanged();

    if (_canRestartRecognition) {
      _scheduleRestart(
        _restartDelayForError(
          errorCode,
        ),
      );
    }
  }

  static bool _isLanguageError(
    String error,
  ) {
    return error.contains(
          'language_not_supported',
        ) ||
        error.contains(
          'language_unavailable',
        ) ||
        (error.contains('language') &&
            error.contains('unsupported'));
  }

  static bool _isPermissionError(
    String error,
  ) {
    return error.contains(
          'error_permission',
        ) ||
        error.contains(
          'permission',
        ) ||
        error.contains(
          'not_allowed',
        ) ||
        error.contains(
          'not allowed',
        );
  }

  static bool _isRecognizerUnavailableError(
    String error,
  ) {
    return error.contains(
          'recognizer_not_available',
        ) ||
        error.contains(
          'recognizer unavailable',
        ) ||
        error.contains(
          'service_not_available',
        ) ||
        error.contains(
          'service unavailable',
        );
  }

  static String _friendlyTransientError(
    String errorCode,
    String rawError,
  ) {
    if (errorCode.contains(
          'no_match',
        ) ||
        errorCode.contains(
          'speech_timeout',
        )) {
      return '';
    }

    if (errorCode.contains(
      'busy',
    )) {
      return 'Speech recognizer ব্যস্ত ছিল। আবার শোনা হচ্ছে।';
    }

    if (errorCode.contains(
          'network',
        ) ||
        errorCode.contains(
          'server',
        )) {
      return 'Speech recognition network সাময়িকভাবে unavailable। আবার চেষ্টা করা হচ্ছে।';
    }

    if (errorCode.contains(
      'client',
    )) {
      return 'Speech recognition session পুনরায় চালু করা হচ্ছে।';
    }

    return rawError;
  }

  static Duration _restartDelayForError(
    String errorCode,
  ) {
    if (errorCode.contains(
          'no_match',
        ) ||
        errorCode.contains(
          'speech_timeout',
        )) {
      return const Duration(
        milliseconds: 350,
      );
    }

    if (errorCode.contains(
          'busy',
        ) ||
        errorCode.contains(
          'client',
        )) {
      return const Duration(
        milliseconds: 1200,
      );
    }

    if (errorCode.contains(
          'network',
        ) ||
        errorCode.contains(
          'server',
        )) {
      return const Duration(
        milliseconds: 1800,
      );
    }

    return const Duration(
      milliseconds: 900,
    );
  }

  void _disableForUnsupportedBengali() {
    _bengaliLanguageUnsupported = true;
    _bengaliLocaleAvailable = false;

    _commandListening = false;
    _commandModeEnabled = false;

    _restartTimer?.cancel();
    _watchdogTimer?.cancel();

    _lastError =
        'এই ফোনের Speech Recognition service বাংলা ভাষা গ্রহণ করছে না। '
        'Google Speech Services / Google app-এ বাংলা (বাংলাদেশ) '
        'ভাষা চালু করুন, তারপর অ্যাপটি পুনরায় চালু করুন।';

    debugPrint(
      '[SpeechService] Bengali recognition disabled after language error.',
    );

    _onStateChanged();
  }

  // ===========================================================================
  // OPEN ANDROID APP SETTINGS
  // ===========================================================================

  Future<bool> openSystemAppSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      debugPrint(
        '[SpeechService] openAppSettings failed: $e',
      );

      return false;
    }
  }

  // ===========================================================================
  // LEGACY WAKE-WORD SETTING
  // ===========================================================================

  Future<void> _loadWakeWordMode() async {
    try {
      final prefs =
          await SharedPreferences.getInstance();

      _wakeWordMode =
          prefs.getBool(
                wakeWordModeKey,
              ) ??
              false;
    } catch (_) {
      _wakeWordMode = false;
    }
  }

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

    if (!_disposed) {
      _onStateChanged();
    }
  }

  // ===========================================================================
  // BENGALI LOCALE
  // ===========================================================================

  @visibleForTesting
  static String? selectBengaliLocaleId(
    List<LocaleName> locales,
  ) {
    String normalize(
      String id,
    ) {
      return id
          .toLowerCase()
          .replaceAll('-', '_')
          .trim();
    }

    // First choice: Bengali — Bangladesh.
    for (final locale in locales) {
      if (normalize(
            locale.localeId,
          ) ==
          'bn_bd') {
        return locale.localeId;
      }
    }

    // Second choice: any Bengali locale.
    for (final locale in locales) {
      final id =
          normalize(
        locale.localeId,
      );

      if (id == 'bn_in' ||
          id == 'bn' ||
          id.startsWith('bn_')) {
        return locale.localeId;
      }
    }

    return null;
  }

  Future<void> _resolveBengaliLocale() async {
    if (_disposed ||
        !_speechEnabled ||
        !_speechRecognizerAvailable ||
        _bengaliLanguageUnsupported) {
      return;
    }

    // Some OEM recognizers do not advertise every supported locale.
    _bengaliLocaleId = 'bn-BD';

    try {
      final locales =
          await _speech
              .locales()
              .timeout(
        const Duration(
          seconds: 5,
        ),
      );

      final selected =
          selectBengaliLocaleId(
        locales,
      );

      if (selected != null) {
        _bengaliLocaleId =
            selected;

        _bengaliLocaleAvailable = true;

        debugPrint(
          '[SpeechService] Bengali locale selected: '
          '$_bengaliLocaleId',
        );

        return;
      }

      debugPrint(
        '[SpeechService] Bengali locale was not advertised; '
        'trying bn-BD.',
      );
    } on TimeoutException {
      debugPrint(
        '[SpeechService] locale lookup timed out; trying bn-BD.',
      );
    } catch (e) {
      debugPrint(
        '[SpeechService] locale lookup failed: $e; trying bn-BD.',
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
  // START COMMAND MODE
  // ===========================================================================

  /// Arms command mode and starts the microphone when possible.
  ///
  /// Critical difference from the old version:
  ///
  /// `_commandModeEnabled = true` is recorded BEFORE checking temporary pause
  /// or command/TTS state. Therefore a lifecycle/media pause cannot cause the
  /// desired always-on mode to be silently lost.
  Future<void> startCommandListening() async {
    if (_disposed) {
      return;
    }

    // Record user/app intent FIRST.
    _commandModeEnabled = true;

    _restartTimer?.cancel();

    _onStateChanged();

    // -------------------------------------------------------------------------
    // Self-heal if the page asks us to start before initialization is ready.
    // -------------------------------------------------------------------------

    if (!_microphonePermissionGranted ||
        !_speechEnabled ||
        !_speechRecognizerAvailable) {
      await initialize();

      if (_disposed) {
        return;
      }
    }

    // -------------------------------------------------------------------------
    // HARD BLOCKERS
    // -------------------------------------------------------------------------

    if (!_microphonePermissionGranted) {
      _commandModeEnabled = false;

      if (_microphonePermissionPermanentlyDenied) {
        _lastError =
            'Microphone permission বন্ধ আছে। '
            'Settings থেকে permission চালু করুন।';
      } else {
        _lastError =
            'ভয়েস কমান্ড চালু করতে Microphone permission প্রয়োজন।';
      }

      _onStateChanged();

      return;
    }

    if (!_speechEnabled ||
        !_speechRecognizerAvailable) {
      _commandModeEnabled = false;

      if (_lastError.isEmpty) {
        _lastError =
            'এই ফোনে Speech Recognition service পাওয়া যাচ্ছে না।';
      }

      _onStateChanged();

      return;
    }

    if (_bengaliLanguageUnsupported) {
      _commandModeEnabled = false;

      _lastError =
          'বাংলা Speech Recognition পাওয়া যাচ্ছে না। '
          'Google Speech Services-এ বাংলা চালু করে অ্যাপটি পুনরায় খুলুন।';

      _onStateChanged();

      return;
    }

    // Successful readiness check. Keep desired mode armed.
    _commandModeEnabled = true;

    // Watchdog belongs to command mode, not to one recognition session.
    _startWatchdog();

    // Temporary blockers do NOT disable command mode.
    //
    // resumeLoop() / command finally / TTS finally will start the session.
    if (_pausedForMedia ||
        _commandInProgress ||
        _ttsInProgress) {
      debugPrint(
        '[SpeechService] command mode armed; '
        'waiting for temporary blocker to clear '
        '(paused=$_pausedForMedia, '
        'command=$_commandInProgress, '
        'tts=$_ttsInProgress).',
      );

      return;
    }

    await _startCommandSession();
  }

  // ===========================================================================
  // STOP COMMAND MODE
  // ===========================================================================

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

  // ===========================================================================
  // MEDIA / LIFECYCLE PAUSE
  // ===========================================================================

  /// Temporarily pauses the microphone WITHOUT disabling desired command mode.
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
        '[SpeechService] pauseLoop error: $e',
      );
    }
  }

  /// Clears the temporary pause and restores listening if command mode was
  /// previously armed.
  Future<void> resumeLoop() async {
    _pausedForMedia = false;

    _onStateChanged();

    if (_disposed ||
        !_commandModeEnabled) {
      return;
    }

    // Foreground resume can happen after Android reclaimed/restarted speech
    // services. Re-check readiness instead of requiring a manual tap.
    if (!_microphonePermissionGranted ||
        !_speechEnabled ||
        !_speechRecognizerAvailable) {
      await initialize();

      if (_disposed ||
          !_commandModeEnabled) {
        return;
      }
    }

    if (!_microphonePermissionGranted ||
        !_speechEnabled ||
        !_speechRecognizerAvailable ||
        _bengaliLanguageUnsupported ||
        _commandInProgress ||
        _ttsInProgress) {
      return;
    }

    _startWatchdog();

    await _startCommandSession();
  }

  // ===========================================================================
  // TOGGLE
  // ===========================================================================

  Future<void> toggleDictation() async {
    if (_commandModeEnabled) {
      await stopCommandListening();
    } else {
      await startCommandListening();
    }
  }

  // ===========================================================================
  // COMPATIBILITY RESTART HOOK
  // ===========================================================================

  void scheduleRestartSoon([
    Duration delay =
        const Duration(
          milliseconds: 400,
        ),
  ]) {
    if (!_canRestartRecognition) {
      return;
    }

    _scheduleRestart(
      delay,
    );
  }

  // ===========================================================================
  // CENTRAL RESTART ELIGIBILITY
  // ===========================================================================

  bool get _canRestartRecognition {
    return !_disposed &&
        _microphonePermissionGranted &&
        _speechEnabled &&
        _speechRecognizerAvailable &&
        _commandModeEnabled &&
        !_pausedForMedia &&
        !_commandInProgress &&
        !_ttsInProgress &&
        !_bengaliLanguageUnsupported;
  }

  // ===========================================================================
  // START ONE RECOGNIZER SESSION
  // ===========================================================================

  Future<void> _startCommandSession() async {
    if (!_canRestartRecognition ||
        _startingSession ||
        _commandListening) {
      return;
    }

    _startingSession = true;

    _restartTimer?.cancel();

    try {
      // -----------------------------------------------------------------------
      // Stop any stale native session before opening a new one.
      // -----------------------------------------------------------------------

      if (_speech.isListening) {
        try {
          await _speech.stop();
        } catch (_) {}

        await Future.delayed(
          const Duration(
            milliseconds: 140,
          ),
        );
      }

      if (!_canRestartRecognition) {
        return;
      }

      _commandListening = true;

      _onStateChanged();

      await _speech.listen(
        onResult: (
          result,
        ) {
          if (_disposed ||
              !_commandModeEnabled ||
              _pausedForMedia ||
              _commandInProgress ||
              _ttsInProgress ||
              _bengaliLanguageUnsupported) {
            return;
          }

          final heard =
              result.recognizedWords.trim();

          if (heard.isNotEmpty) {
            _lastHeard =
                heard;

            _onStateChanged();
          }

          // ===============================================================
          // FINAL-ONLY COMMAND GATE
          // ===============================================================

          if (!result.finalResult) {
            return;
          }

          if (heard.isEmpty) {
            return;
          }

          final intent =
              _extractIntent(
            heard,
          );

          if (intent ==
              null) {
            return;
          }

          _handleDetectedIntent(
            intent,
            heard,
          );
        },

        localeId:
            _bengaliLocaleId,

        listenFor:
            const Duration(
          minutes: 5,
        ),

        pauseFor:
            const Duration(
          seconds: 5,
        ),

        listenOptions:
            SpeechListenOptions(
          partialResults:
              true,

          cancelOnError:
              false,

          onDevice:
              false,

          // Keep confirmation mode for short command phrases.
          // Session continuity is handled by restart/watchdog logic.
          listenMode:
              ListenMode.confirmation,
        ),
      );
    } catch (e) {
      _commandListening = false;

      final errorText =
          e
              .toString()
              .toLowerCase();

      debugPrint(
        '[SpeechService] command listen start failed: $e',
      );

      if (_isLanguageError(
        errorText,
      )) {
        _disableForUnsupportedBengali();
      } else if (_isPermissionError(
        errorText,
      )) {
        _speechEnabled = false;
        _commandModeEnabled = false;

        _lastError =
            'মাইক্রোফোন অনুমতি পাওয়া যায়নি।';

        _onStateChanged();
      } else {
        _lastError =
            e.toString();

        _onStateChanged();

        if (_canRestartRecognition) {
          _scheduleRestart(
            _restartDelayForError(
              errorText,
            ),
          );
        }
      }
    } finally {
      _startingSession = false;
    }
  }

  // ===========================================================================
  // STRICT FIVE-COMMAND MATCHING
  // ===========================================================================

  VoiceIntent? _extractIntent(
    String heard,
  ) {
    return BengaliVoiceCommands
        .matchTriggerCommand(
      heard,
    );
  }

  // ===========================================================================
  // COMMAND DETECTED
  // ===========================================================================

  void _handleDetectedIntent(
    VoiceIntent intent,
    String heardText,
  ) {
    if (_commandInProgress ||
        _ttsInProgress ||
        _pausedForMedia ||
        !_commandModeEnabled) {
      return;
    }

    final now =
        DateTime.now();

    if (_lastIntent ==
            intent &&
        now.difference(
              _lastIntentAt,
            ) <
            const Duration(
              seconds: 2,
            )) {
      return;
    }

    final canAccept =
        _canAcceptCommand?.call() ??
            true;

    if (!canAccept) {
      return;
    }

    _lastIntent =
        intent;

    _lastIntentAt =
        now;

    // -------------------------------------------------------------------------
    // CRITICAL LOCK BEFORE stop().
    // -------------------------------------------------------------------------

    _commandInProgress = true;

    _restartTimer?.cancel();

    final handler =
        _onCommand;

    if (handler == null) {
      _commandInProgress = false;

      if (_canRestartRecognition) {
        _scheduleRestart(
          const Duration(
            milliseconds: 450,
          ),
        );
      }

      return;
    }

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
      _restartTimer?.cancel();

      // -----------------------------------------------------------------------
      // STOP STT WHILE COMMAND EXECUTES
      // -----------------------------------------------------------------------

      try {
        await _speech.stop();
      } catch (e) {
        debugPrint(
          '[SpeechService] stop after trigger error: $e',
        );
      }

      _commandListening = false;

      _onStateChanged();

      await Future.delayed(
        const Duration(
          milliseconds: 80,
        ),
      );

      // -----------------------------------------------------------------------
      // COMMAND CONFIRMATION SOUND
      // -----------------------------------------------------------------------

      try {
        await SoundManager.instance
            .playDictationStart();
      } catch (e) {
        debugPrint(
          '[SpeechService] trigger confirmation sound failed: $e',
        );
      }

      // -----------------------------------------------------------------------
      // CAMERA / OCR / GEMMA / TTS
      // -----------------------------------------------------------------------

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
      _commandInProgress = false;
      _commandListening = false;

      _onStateChanged();

      // SpeechService is the single restart owner.
      if (_canRestartRecognition) {
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

    if (status ==
        'listening') {
      // A stale listening callback must never leave STT open while command,
      // TTS, media pause, or manual command-mode disable is active.
      if (!_commandModeEnabled ||
          _pausedForMedia ||
          _commandInProgress ||
          _ttsInProgress ||
          _bengaliLanguageUnsupported) {
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

      // Clear harmless no-match/timeout text as soon as listening recovers.
      _lastError = '';

      _onStateChanged();

      return;
    }

    if (status ==
            'notListening' ||
        status ==
            'done') {
      _commandListening = false;

      _onStateChanged();

      if (_canRestartRecognition) {
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

  void _startWatchdog() {
    _watchdogTimer?.cancel();

    if (!_commandModeEnabled ||
        _disposed) {
      return;
    }

    _watchdogTimer =
        Timer.periodic(
      const Duration(
        seconds: 8,
      ),
      (_) {
        if (!_canRestartRecognition) {
          return;
        }

        if (!_commandListening &&
            !_startingSession &&
            !_speech.isListening) {
          debugPrint(
            '[SpeechService] watchdog re-arming recognizer.',
          );

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

  void _scheduleRestart(
    Duration delay,
  ) {
    if (!_canRestartRecognition) {
      return;
    }

    _restartTimer?.cancel();

    _restartTimer =
        Timer(
      delay,
      () {
        if (!_canRestartRecognition) {
          return;
        }

        unawaited(
          _startCommandSession(),
        );
      },
    );
  }

  // ===========================================================================
  // ACCESSIBILITY ANNOUNCEMENT
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

  Future<void> speak(
    String message,
  ) async {
    final clean =
        message.trim();

    if (clean.isEmpty ||
        _disposed) {
      return;
    }

    final shouldPauseRecognizer =
        _commandModeEnabled &&
        !_commandInProgress &&
        !_pausedForMedia &&
        _speechEnabled &&
        _speechRecognizerAvailable &&
        !_bengaliLanguageUnsupported;

    // -------------------------------------------------------------------------
    // CRITICAL TTS LOCK
    //
    // Set this BEFORE stopping STT.
    //
    // stop() can synchronously/asynchronously emit done/notListening. Those
    // callbacks now see _ttsInProgress=true and cannot reopen the microphone
    // while TTS is speaking.
    // -------------------------------------------------------------------------

    _ttsInProgress = true;

    _restartTimer?.cancel();

    if (shouldPauseRecognizer) {
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
      _ttsInProgress = false;

      if (!_disposed) {
        _onStateChanged();
      }

      // During triggered commands, _commandInProgress is still true here, so
      // _canRestartRecognition is false. The command-finally block owns restart.
      //
      // For standalone TTS, restart happens here.
      if (_canRestartRecognition) {
        _scheduleRestart(
          const Duration(
            milliseconds: 350,
          ),
        );
      }
    }
  }

  // ===========================================================================
  // SOUND
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
    } finally {
      _ttsInProgress = false;

      if (!_disposed &&
          _canRestartRecognition) {
        _scheduleRestart(
          const Duration(
            milliseconds: 250,
          ),
        );
      }
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
    _pausedForMedia = false;
    _ttsInProgress = false;

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
