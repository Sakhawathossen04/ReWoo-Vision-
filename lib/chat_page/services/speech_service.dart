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
/// Voice lifecycle:
///
/// Waiting for one of the 5 trigger commands
///        ↓
/// Final speech result arrives
///        ↓
/// Exact 5-command matcher
///        ↓
/// Trigger detected
///        ↓
/// _commandInProgress = true
///        ↓
/// Speech recognizer STOP
///        ↓
/// Camera / OCR / AI
///        ↓
/// TTS
///        ↓
/// Task completely finished
///        ↓
/// _commandInProgress = false
///        ↓
/// Trigger listener starts again
///
/// Important safety rules:
///
/// 1. Microphone permission must be granted before SpeechToText initializes.
///
/// 2. If no Android speech recognizer is available, automatic restart is
///    disabled.
///
/// 3. If Bengali recognition is confirmed unsupported, automatic restart is
///    disabled instead of creating an infinite error/restart loop.
///
/// 4. While a command is running, no callback/timer/watchdog is allowed to
///    reopen the recognizer.
///
/// 5. Partial speech-recognition results NEVER trigger commands.
///    Only final recognition results are checked against the five trigger
///    phrases.
///
/// Example:
///
/// User actually says:
/// "এটা কী সুন্দর জিনিস"
///
/// Android may produce:
///
/// partial -> "এটা"
/// partial -> "এটা কী"
/// final   -> "এটা কী সুন্দর জিনিস"
///
/// The partial "এটা কী" MUST NOT trigger identifyObject.
///
/// But:
///
/// final -> "এটা কী"
///
/// WILL trigger identifyObject.
class SpeechService {
  final SpeechToText _speech = SpeechToText();

  final FlutterTts _tts;
  final VoidCallback _onStateChanged;

  // ===========================================================================
  // CORE SPEECH STATE
  // ===========================================================================

  /// True only after SpeechToText.initialize() succeeds.
  bool _speechEnabled = false;

  /// True while automatic trigger-listening mode is enabled.
  bool _commandModeEnabled = false;

  /// True while the Android recognizer currently has an active session.
  bool _commandListening = false;

  bool _disposed = false;
  bool _startingSession = false;
  bool _pausedForMedia = false;

  /// True from trigger detection until the complete command + TTS Future ends.
  ///
  /// No microphone restart is allowed while this is true.
  bool _commandInProgress = false;

  // ===========================================================================
  // DEVICE / PERMISSION STATE
  // ===========================================================================

  bool _microphonePermissionGranted = false;
  bool _microphonePermissionPermanentlyDenied = false;

  /// True when Android exposes a speech recognition service.
  bool _speechRecognizerAvailable = false;

  /// Becomes true only after Android explicitly reports that the requested
  /// Bengali recognition language is unsupported/unavailable.
  ///
  /// Once this becomes true, automatic retries STOP.
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

  /// Bengali recognition availability.
  bool _bengaliLocaleAvailable = true;

  String _lastHeard = '';
  String _lastError = '';

  // ===========================================================================
  // LEGACY WAKE WORD SETTING
  // ===========================================================================

  /// Retained because SettingsPage / SharedPreferences may still use it.
  ///
  /// Direct trigger mode does not depend on this property.
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

  Future<void> initialize() async {
    if (_disposed) {
      return;
    }

    try {
      // -----------------------------------------------------------------------
      // 1. Configure TTS
      // -----------------------------------------------------------------------

      try {
        await TtsEngineService.configure(_tts);
      } catch (e) {
        // TTS failure must not prevent microphone/speech initialization.
        debugPrint(
          '[SpeechService] TTS configuration warning: $e',
        );
      }

      // -----------------------------------------------------------------------
      // 2. MICROPHONE PERMISSION
      //
      // Do NOT initialize SpeechToText if permission is denied.
      // -----------------------------------------------------------------------

      final micStatus =
          await Permission.microphone.request();

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

        _commandModeEnabled = false;
        _commandListening = false;

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
      // 3. INITIALIZE ANDROID SPEECH RECOGNIZER
      //
      // initialize() returning false means there is no usable recognizer.
      // -----------------------------------------------------------------------

      final recognizerInitialized =
          await _speech.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
      );

      if (!recognizerInitialized) {
        _speechEnabled = false;
        _speechRecognizerAvailable = false;

        _commandModeEnabled = false;
        _commandListening = false;

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

      // New initialization gets one fresh Bengali-language attempt.
      _bengaliLanguageUnsupported = false;

      // -----------------------------------------------------------------------
      // 4. FIND BENGALI LOCALE
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

      _commandModeEnabled = false;
      _commandListening = false;

      _restartTimer?.cancel();
      _watchdogTimer?.cancel();

      _lastError =
          'ভয়েস সিস্টেম চালু করা যায়নি। ${e.toString()}';

      debugPrint(
        '[SpeechService] initialization error: $e',
      );

      debugPrint('$st');
    } finally {
      await _loadWakeWordMode();

      _onStateChanged();
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
    // BENGALI LANGUAGE UNSUPPORTED
    // -------------------------------------------------------------------------

    if (_isLanguageError(errorCode)) {
      _disableForUnsupportedBengali();
      return;
    }

    // -------------------------------------------------------------------------
    // PERMISSION ERROR
    // -------------------------------------------------------------------------

    if (_isPermissionError(errorCode)) {
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
    // RECOGNIZER / SERVICE UNAVAILABLE
    // -------------------------------------------------------------------------

    if (_isRecognizerUnavailableError(errorCode)) {
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
    // OTHER PERMANENT ERROR
    // -------------------------------------------------------------------------

    final bool permanent =
        error.permanent == true;

    if (permanent) {
      _commandModeEnabled = false;

      _restartTimer?.cancel();
      _watchdogTimer?.cancel();

      _lastError =
          'Speech recognition বন্ধ হয়েছে: $rawError';

      _onStateChanged();

      return;
    }

    // -------------------------------------------------------------------------
    // TRANSIENT ERROR
    // -------------------------------------------------------------------------

    _lastError = rawError;

    _onStateChanged();

    // Never restart during Camera / AI / TTS.
    if (_canRestartRecognition) {
      _scheduleRestart(
        const Duration(milliseconds: 900),
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
    String normalize(
      String id,
    ) {
      return id
          .toLowerCase()
          .replaceAll('-', '_')
          .trim();
    }

    // -------------------------------------------------------------------------
    // First choice: Bangla — Bangladesh
    // -------------------------------------------------------------------------

    for (final locale in locales) {
      if (normalize(
            locale.localeId,
          ) ==
          'bn_bd') {
        return locale.localeId;
      }
    }

    // -------------------------------------------------------------------------
    // Second choice: any Bengali locale
    // -------------------------------------------------------------------------

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

    // Some Android recognizers do not advertise all supported languages.
    // Use bn-BD as the explicit fallback.
    _bengaliLocaleId = 'bn-BD';

    try {
      final locales =
          await _speech
              .locales()
              .timeout(
        const Duration(seconds: 5),
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

      // Do not immediately mark Bengali as unsupported.
      //
      // Some OEM recognizers do not correctly advertise available locales.
      // We try bn-BD once. If Android rejects it, _handleSpeechError()
      // disables automatic retries.
      debugPrint(
        '[SpeechService] Bengali locale was not advertised; '
        'trying bn-BD once.',
      );
    } on TimeoutException {
      debugPrint(
        '[SpeechService] locale lookup timed out; '
        'trying bn-BD once.',
      );
    } catch (e) {
      debugPrint(
        '[SpeechService] locale lookup failed: $e; '
        'trying bn-BD once.',
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

  Future<void> startCommandListening() async {
    if (_disposed) {
      return;
    }

    // -------------------------------------------------------------------------
    // Permission safety
    // -------------------------------------------------------------------------

    if (!_microphonePermissionGranted) {
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

    // -------------------------------------------------------------------------
    // Recognizer safety
    // -------------------------------------------------------------------------

    if (!_speechEnabled ||
        !_speechRecognizerAvailable) {
      if (_lastError.isEmpty) {
        _lastError =
            'এই ফোনে Speech Recognition service পাওয়া যাচ্ছে না।';
      }

      _onStateChanged();

      return;
    }

    // -------------------------------------------------------------------------
    // Bengali-language safety
    // -------------------------------------------------------------------------

    if (_bengaliLanguageUnsupported) {
      _lastError =
          'বাংলা Speech Recognition পাওয়া যাচ্ছে না। '
          'Google Speech Services-এ বাংলা চালু করে অ্যাপটি পুনরায় খুলুন।';

      _onStateChanged();

      return;
    }

    if (_pausedForMedia ||
        _commandInProgress) {
      return;
    }

    _commandModeEnabled = true;

    _startWatchdog();

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
  // MEDIA PAUSE / RESUME
  // ===========================================================================

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

  Future<void> resumeLoop() async {
    _pausedForMedia = false;

    _onStateChanged();

    if (_commandModeEnabled &&
        !_disposed &&
        !_commandInProgress &&
        _speechEnabled &&
        _speechRecognizerAvailable &&
        !_bengaliLanguageUnsupported) {
      _startWatchdog();

      await _startCommandSession();
    }
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
        const Duration(milliseconds: 400),
  ]) {
    if (!_canRestartRecognition) {
      return;
    }

    _scheduleRestart(delay);
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
      // Stop stale Android recognizer session
      // -----------------------------------------------------------------------

      if (_speech.isListening) {
        try {
          await _speech.stop();
        } catch (_) {}

        await Future.delayed(
          const Duration(milliseconds: 120),
        );
      }

      // Re-check all guards after await.
      if (!_canRestartRecognition) {
        return;
      }

      _commandListening = true;

      _onStateChanged();

      // -----------------------------------------------------------------------
      // Start Bengali listener
      // -----------------------------------------------------------------------

      await _speech.listen(
        onResult: (result) {
          if (_disposed ||
              !_commandModeEnabled ||
              _pausedForMedia ||
              _commandInProgress ||
              _bengaliLanguageUnsupported) {
            return;
          }

          final heard =
              result.recognizedWords.trim();

          if (heard.isNotEmpty) {
            _lastHeard = heard;

            _onStateChanged();
          }

          // ===================================================================
          // CRITICAL FALSE-TRIGGER PROTECTION
          // ===================================================================
          //
          // speech_to_text sends partial results while the user is speaking.
          //
          // Example:
          //
          // User says:
          //
          //   "এটা কী সুন্দর জিনিস"
          //
          // Android may send:
          //
          //   partial -> "এটা"
          //   partial -> "এটা কী"
          //   final   -> "এটা কী সুন্দর জিনিস"
          //
          // If we matched partial results, "এটা কী" would incorrectly trigger
          // identifyObject before the user finished speaking.
          //
          // Therefore:
          //
          // ONLY FINAL RESULTS ARE ALLOWED TO TRIGGER COMMANDS.
          // ===================================================================

          if (!result.finalResult) {
            return;
          }

          if (heard.isEmpty) {
            return;
          }

          // ===================================================================
          // STRICT FIVE-COMMAND MATCH
          // ===================================================================

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

        listenFor:
            const Duration(minutes: 5),

        pauseFor:
            const Duration(seconds: 5),

        listenOptions:
            SpeechListenOptions(
          // Keep partial results enabled so the UI can display what the device
          // is hearing.
          //
          // They are NEVER used for triggering commands.
          partialResults: true,

          cancelOnError: false,

          // Uses the Android/system recognizer.
          //
          // This avoids requiring the device to have offline Bengali speech
          // recognition installed.
          onDevice: false,

          listenMode:
              ListenMode.confirmation,
        ),
      );
    } catch (e) {
      _commandListening = false;

      final errorText =
          e.toString().toLowerCase();

      debugPrint(
        '[SpeechService] command listen start failed: $e',
      );

      if (_isLanguageError(errorText)) {
        _disableForUnsupportedBengali();
      } else {
        _lastError =
            e.toString();

        _onStateChanged();

        // Never retry during Camera / AI / TTS.
        if (_canRestartRecognition) {
          _scheduleRestart(
            const Duration(milliseconds: 900),
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
    // Never accept another command during Camera / AI / TTS.
    if (_commandInProgress) {
      return;
    }

    final now =
        DateTime.now();

    // -------------------------------------------------------------------------
    // Duplicate final result protection
    // -------------------------------------------------------------------------

    if (_lastIntent == intent &&
        now.difference(
              _lastIntentAt,
            ) <
            const Duration(seconds: 2)) {
      return;
    }

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
    // Lock BEFORE calling _speech.stop().
    //
    // stop() may generate notListening/done callbacks immediately.
    // -------------------------------------------------------------------------

    _commandInProgress = true;

    _restartTimer?.cancel();

    final handler =
        _onCommand;

    if (handler == null) {
      _commandInProgress = false;

      if (_canRestartRecognition) {
        _scheduleRestart(
          const Duration(milliseconds: 450),
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
      // =======================================================================
      // PHASE 1
      // STOP SPEECH RECOGNITION
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

      await Future.delayed(
        const Duration(milliseconds: 80),
      );

      // =======================================================================
      // COMMAND CONFIRMATION SOUND
      // =======================================================================

      try {
        await SoundManager.instance
            .playDictationStart();
      } catch (e) {
        debugPrint(
          '[SpeechService] trigger confirmation sound failed: $e',
        );
      }

      // =======================================================================
      // PHASE 2
      //
      // Camera
      // -> OCR / Vision
      // -> Gemma
      // -> TTS
      //
      // The microphone stays locked throughout this Future.
      // =======================================================================

      await handler(
        intent,
        heardText,
      );
    } catch (e, st) {
      debugPrint(
        '[SpeechService] triggered command failed: $e',
      );

      debugPrint('$st');
    } finally {
      // =======================================================================
      // PHASE 3
      // TASK + TTS COMPLETE
      // =======================================================================

      _commandInProgress = false;
      _commandListening = false;

      _onStateChanged();

      // =======================================================================
      // PHASE 4
      // RE-ARM FIVE-COMMAND TRIGGER LISTENER
      // =======================================================================

      if (_canRestartRecognition) {
        _scheduleRestart(
          const Duration(milliseconds: 450),
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
      // Android may send a stale listening callback just after stop().
      //
      // Never allow that session to remain active during Camera / AI / TTS.
      if (_commandInProgress ||
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

      _lastError = '';

      _onStateChanged();

      return;
    }

    // -------------------------------------------------------------------------
    // SESSION ENDED
    // -------------------------------------------------------------------------

    if (status == 'notListening' ||
        status == 'done') {
      _commandListening = false;

      _onStateChanged();

      // Never restart during Camera / AI / TTS.
      //
      // Never restart if Bengali is unsupported.
      if (_canRestartRecognition) {
        _scheduleRestart(
          const Duration(milliseconds: 500),
        );
      }
    }
  }

  // ===========================================================================
  // WATCHDOG
  // ===========================================================================

  void _startWatchdog() {
    _watchdogTimer?.cancel();

    _watchdogTimer =
        Timer.periodic(
      const Duration(seconds: 8),
      (_) {
        // _canRestartRecognition includes:
        //
        // permission
        // recognizer availability
        // command mode
        // media pause
        // command-in-progress lock
        // Bengali support
        if (!_canRestartRecognition) {
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
        // Re-check everything when the timer actually fires.
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

    // -------------------------------------------------------------------------
    // Standalone TTS:
    //
    // recognizer stop
    // -> TTS
    // -> recognizer restart
    //
    //
    // Trigger-command TTS:
    //
    // _commandInProgress == true
    // -> recognizer already stopped
    // -> TTS
    // -> NO restart here
    // -> _runTriggeredCommand finally block owns restart
    // -------------------------------------------------------------------------

    final shouldPauseRecognizer =
        _commandModeEnabled &&
        !_commandInProgress &&
        !_pausedForMedia &&
        _speechEnabled &&
        _speechRecognizerAvailable &&
        !_bengaliLanguageUnsupported;

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
      // Trigger-command TTS cannot restart from here.
      if (shouldPauseRecognizer &&
          _canRestartRecognition) {
        _scheduleRestart(
          const Duration(milliseconds: 350),
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
        const Duration(milliseconds: 40),
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
