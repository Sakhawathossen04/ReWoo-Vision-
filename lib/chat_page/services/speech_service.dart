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
/// Priority 3 — continuous listening: the command loop must survive every
/// command. The loop is restarted:
///   * after every recognised command,
///   * after every TTS announcement finishes,
///   * whenever the platform reports notListening/done,
///   * by a watchdog timer that catches silent engine death.
/// A dead TTS engine can no longer freeze the loop because every speak call
/// is wrapped in a timeout (see TtsEngineService.speakWithTimeout).
///
/// Priority 4 — wake word: optional "রিউ / সহায়ক / hey assistant" gating.
/// In wake mode only utterances containing a wake word trigger commands;
/// hearing only the wake word primes the assistant for ~12 seconds.
class SpeechService {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts;
  final VoidCallback _onStateChanged;

  bool _speechEnabled = false;
  bool _commandModeEnabled = false;
  bool _commandListening = false;
  bool _disposed = false;
  bool _startingSession = false;
  bool _pausedForMedia = false;

  Timer? _restartTimer;
  Timer? _watchdogTimer;

  String _bengaliLocaleId = 'bn-BD';
  bool _bengaliLocaleAvailable = true;
  String _lastHeard = '';
  String _lastError = '';

  bool _wakeWordMode = false;
  DateTime _wakePrimedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> Function(VoiceIntent intent, String heardText)? _onCommand;
  bool Function()? _canAcceptCommand;

  VoiceIntent? _lastIntent;
  DateTime _lastIntentAt = DateTime.fromMillisecondsSinceEpoch(0);

  SpeechService({
    required FlutterTts tts,
    required VoidCallback onStateChanged,
  }) : _tts = tts,
       _onStateChanged = onStateChanged;

  bool get speechEnabled => _speechEnabled;
  bool get commandModeEnabled => _commandModeEnabled;
  bool get commandListening => _commandListening;
  bool get listening => _commandListening;
  String get lastHeard => _lastHeard;
  String get lastError => _lastError;
  String get bengaliLocaleId => _bengaliLocaleId;
  bool get hasBengaliSpeechLocale => _bengaliLocaleAvailable;
  bool get wakeWordMode => _wakeWordMode;
  bool get pausedForMedia => _pausedForMedia;

  Future<void> initialize() async {
    try {
      // Priority 3/TTS: robust engine + language selection with fallbacks.
      // This is what fixes "no sound" on phones without a bn-BD voice or
      // with a broken default TTS engine.
      await TtsEngineService.configure(_tts);

      // Ensure the microphone permission is granted before starting the
      // recogniser. On some devices speech_to_text fails permanently when
      // the first listen happens without an explicit permission grant.
      final micStatus = await Permission.microphone.request();
      debugPrint('[SpeechService] microphone permission: $micStatus');

      _speechEnabled = await _speech.initialize(
        onStatus: _handleSpeechStatus,
        onError: (error) {
          _commandListening = false;

          final errorCode = error.errorMsg.toLowerCase();
          final isLanguageError =
              errorCode.contains('language_not_supported') ||
              errorCode.contains('language_unavailable');

          if (isLanguageError) {
            _bengaliLocaleAvailable = false;
            _lastError =
                'বাংলা ভয়েস ইনপুট পাওয়া যায়নি। '
                'ফোনের Google Speech Services বা ভয়েস ইনপুটে '
                'বাংলা (বাংলাদেশ) চালু করুন।';

            _commandModeEnabled = false;
            _restartTimer?.cancel();
            _watchdogTimer?.cancel();
          } else {
            _lastError = error.errorMsg;

            // Permanent errors (for example denied microphone permission)
            // cannot be fixed by a tight restart loop.
            if (error.permanent) {
              _commandModeEnabled = false;
              _restartTimer?.cancel();
              _watchdogTimer?.cancel();
            } else if (_commandModeEnabled && !_disposed && !_pausedForMedia) {
              _scheduleRestart(const Duration(milliseconds: 900));
            }
          }

          debugPrint('[SpeechService] speech error: $error');
          _onStateChanged();
        },
      );

      if (_speechEnabled) {
        await _resolveBengaliLocale();
      }
    } catch (e) {
      _speechEnabled = false;
      _lastError = e.toString();
      debugPrint('[SpeechService] initialization error: $e');
    } finally {
      await _loadWakeWordMode();
      _onStateChanged();
    }
  }

  Future<void> _loadWakeWordMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _wakeWordMode = prefs.getBool(wakeWordModeKey) ?? false;
    } catch (_) {
      _wakeWordMode = false;
    }
  }

  /// Switch between direct command mode and wake-word mode (Priority 4).
  Future<void> setWakeWordMode(bool enabled) async {
    _wakeWordMode = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(wakeWordModeKey, enabled);
    } catch (_) {}
    _onStateChanged();
    // Restart the session so the new mode applies immediately.
    if (_commandModeEnabled && !_disposed) {
      await _startCommandSession();
    }
  }

  @visibleForTesting
  static String? selectBengaliLocaleId(List<LocaleName> locales) {
    String normalize(String id) =>
        id.toLowerCase().replaceAll('-', '_').trim();

    // First preference: Bangla (Bangladesh).
    for (final locale in locales) {
      if (normalize(locale.localeId) == 'bn_bd') {
        return locale.localeId;
      }
    }

    // Second preference: any Bengali locale, including Bangla (India).
    for (final locale in locales) {
      final id = normalize(locale.localeId);
      if (id == 'bn_in' || id == 'bn' || id.startsWith('bn_')) {
        return locale.localeId;
      }
    }

    return null;
  }

  Future<void> _resolveBengaliLocale() async {
    // Never leave this nullable. Passing null to speech_to_text makes it use
    // the device default recognition language, which is often English.
    _bengaliLocaleId = 'bn-BD';
    _bengaliLocaleAvailable = true;

    try {
      final locales = await _speech.locales().timeout(
        const Duration(seconds: 5),
      );

      final selected = selectBengaliLocaleId(locales);

      if (selected != null) {
        _bengaliLocaleId = selected;
        debugPrint(
          '[SpeechService] using Bengali speech locale: $_bengaliLocaleId',
        );
        return;
      }

      // Some Android recognizers do not advertise every supported locale.
      // Still try Bengali explicitly instead of silently falling back to
      // English. If the recognizer truly does not support Bengali, onError
      // will stop the loop and show a clear Bengali message.
      debugPrint(
        '[SpeechService] Bengali locale not advertised; forcing bn-BD.',
      );
    } on TimeoutException {
      debugPrint(
        '[SpeechService] locale lookup timed out; forcing bn-BD.',
      );
    } catch (e) {
      debugPrint(
        '[SpeechService] locale lookup failed: $e; forcing bn-BD.',
      );
    }
  }

  void configureCommandHandler({
    required Future<void> Function(VoiceIntent intent, String heardText) onCommand,
    required bool Function() canAcceptCommand,
  }) {
    _onCommand = onCommand;
    _canAcceptCommand = canAcceptCommand;
  }

  Future<void> startCommandListening() async {
    if (_disposed || !_speechEnabled) return;
    if (_pausedForMedia) return; // e.g. video recording in progress

    // Re-check the Bengali locale if a previous session reported that the
    // language was unavailable. This lets the user enable Bengali in Android
    // settings and retry without reinstalling the app.
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
    } catch (_) {}
  }

  /// Temporarily suspends recognition while the camera records video or the
  /// app needs the microphone for something else. Mode flag is preserved.
  Future<void> pauseLoop() async {
    _pausedForMedia = true;
    _restartTimer?.cancel();
    _watchdogTimer?.cancel();
    _commandListening = false;
    _onStateChanged();
    try {
      await _speech.stop();
    } catch (_) {}
  }

  /// Resumes the command loop after pauseLoop() once the media is done.
  Future<void> resumeLoop() async {
    _pausedForMedia = false;
    _onStateChanged();
    if (_commandModeEnabled && !_disposed) {
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

  /// Priority 3: public hook so the chat layer can bring the microphone
  /// back as soon as a command finishes (generation + speech complete).
  void scheduleRestartSoon([Duration delay = const Duration(milliseconds: 400)]) {
    if (_disposed || !_commandModeEnabled || _pausedForMedia) return;
    _scheduleRestart(delay);
  }

  Future<void> _startCommandSession() async {
    if (_disposed ||
        !_commandModeEnabled ||
        !_speechEnabled ||
        _pausedForMedia ||
        _startingSession ||
        _commandListening) {
      return;
    }

    _startingSession = true;
    try {
      // Make sure a stale platform session is closed before restarting.
      if (_speech.isListening) {
        await _speech.stop();
        await Future.delayed(const Duration(milliseconds: 120));
      }

      _commandListening = true;
      _onStateChanged();

      await _speech.listen(
        onResult: (result) {
          if (_disposed || !_commandModeEnabled || _pausedForMedia) return;

          final heard = result.recognizedWords.trim();
          if (heard.isNotEmpty) {
            _lastHeard = heard;
            _onStateChanged();
          }

          final intent = _extractIntent(heard);
          if (intent == null) return;
          _handleDetectedIntent(intent, heard);
        },
        localeId: _bengaliLocaleId,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        cancelOnError: false,
        onDevice: false,
        listenMode: ListenMode.confirmation,
      );
    } catch (e) {
      _commandListening = false;

      final errorText = e.toString().toLowerCase();
      final isLanguageError =
          errorText.contains('language_not_supported') ||
          errorText.contains('language_unavailable');

      if (isLanguageError) {
        _bengaliLocaleAvailable = false;
        _commandModeEnabled = false;
        _restartTimer?.cancel();
        _watchdogTimer?.cancel();
        _lastError =
            'বাংলা ভয়েস ইনপুট পাওয়া যায়নি। '
            'ফোনের Google Speech Services বা ভয়েস ইনপুটে '
            'বাংলা (বাংলাদেশ) চালু করুন।';
      } else {
        _lastError = e.toString();
        _scheduleRestart(const Duration(milliseconds: 900));
      }

      debugPrint('[SpeechService] command listen start failed: $e');
      _onStateChanged();
    } finally {
      _startingSession = false;
    }
  }

  /// Maps a recognised utterance to an intent, honouring wake-word mode.
  VoiceIntent? _extractIntent(String heard) {
    if (!_wakeWordMode) {
      return BengaliVoiceCommands.match(heard);
    }

    final now = DateTime.now();
    final primed = now.isBefore(_wakePrimedUntil);
    final stripped = BengaliVoiceCommands.stripWakeWord(heard);

    if (stripped != null) {
      if (stripped.isNotEmpty) {
        // Wake word + command in one breath.
        _wakePrimedUntil = now.add(const Duration(seconds: 12));
        return BengaliVoiceCommands.match(stripped);
      }
      // Only the wake word: confirm with a sound and open the prime window.
      _wakePrimedUntil = now.add(const Duration(seconds: 12));
      unawaited(SoundManager.instance.playDictationStart());
      _onStateChanged();
      return null;
    }

    if (primed) {
      return BengaliVoiceCommands.match(heard);
    }
    return null;
  }

  void _handleDetectedIntent(VoiceIntent intent, String heardText) {
    final now = DateTime.now();
    if (_lastIntent == intent &&
        now.difference(_lastIntentAt) < const Duration(seconds: 2)) {
      return;
    }

    final canAccept = _canAcceptCommand?.call() ?? true;
    // The stop command is intentionally allowed while the AI is generating or
    // speaking. Other vision commands are ignored while busy to prevent two
    // concurrent camera/model jobs.
    if (!canAccept && intent != VoiceIntent.stopSpeaking) return;

    _lastIntent = intent;
    _lastIntentAt = now;

    // A short sound confirms that a valid command was recognized without
    // adding spoken noise that could itself be re-recognized.
    unawaited(SoundManager.instance.playDictationStart());

    final handler = _onCommand;
    if (handler != null) {
      unawaited(_runCommand(handler, intent, heardText));
    }

    // Speech recognizers frequently end a session after a confirmed phrase.
    // Proactively restart so the hands-free loop remains available.
    _scheduleRestart(const Duration(milliseconds: 650));
  }

  Future<void> _runCommand(
    Future<void> Function(VoiceIntent intent, String heardText) handler,
    VoiceIntent intent,
    String heardText,
  ) async {
    try {
      await handler(intent, heardText);
    } catch (e, st) {
      debugPrint('[SpeechService] command handler failed: $e');
      debugPrint('$st');
    }
  }

  void _handleSpeechStatus(String status) {
    debugPrint('[SpeechService] status: $status');
    if (_disposed) return;

    if (status == 'listening') {
      _commandListening = true;
      _bengaliLocaleAvailable = true;
      _lastError = '';
      _onStateChanged();
      return;
    }

    if (status == 'notListening' || status == 'done') {
      _commandListening = false;
      _onStateChanged();
      if (_commandModeEnabled && !_pausedForMedia) {
        _scheduleRestart(const Duration(milliseconds: 500));
      }
    }
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_disposed ||
          !_commandModeEnabled ||
          !_speechEnabled ||
          _pausedForMedia) {
        return;
      }
      if (!_commandListening && !_startingSession && !_speech.isListening) {
        unawaited(_startCommandSession());
      }
    });
  }

  void _scheduleRestart(Duration delay) {
    if (_disposed ||
        !_commandModeEnabled ||
        !_speechEnabled ||
        _pausedForMedia) {
      return;
    }
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      if (!_disposed && _commandModeEnabled && !_pausedForMedia) {
        unawaited(_startCommandSession());
      }
    });
  }

  Future<void> announceMessageType(bool hasPhoto) async {
    await speak(hasPhoto ? 'ছবিসহ প্রশ্ন পাঠানো হচ্ছে' : 'প্রশ্ন পাঠানো হচ্ছে');
  }

  /// Speak a short accessibility message in Bengali.
  /// Command recognition is briefly paused so the application does not hear
  /// its own announcement as a user command.
  Future<void> speak(String message) async {
    final clean = message.trim();
    if (clean.isEmpty || _disposed) return;

    final resumeAfter = _commandModeEnabled;
    if (resumeAfter) {
      _restartTimer?.cancel();
      try {
        await _speech.stop();
      } catch (_) {}
      _commandListening = false;
      _onStateChanged();
    }

    // TtsEngineService.speakWithTimeout guarantees this await returns even
    // when the TTS engine is dead — previously a hang here permanently
    // killed the microphone loop ("mic off after first command").
    await TtsEngineService.speakWithTimeout(_tts, clean);

    if (resumeAfter && !_disposed) {
      _scheduleRestart(const Duration(milliseconds: 350));
    }
  }

  Future<void> playWooshSound() => SoundManager.instance.playWoosh();

  Future<void> stopTts() async {
    try {
      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 40));
    } catch (e) {
      debugPrint('[SpeechService] stop TTS error: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _commandModeEnabled = false;
    _restartTimer?.cancel();
    _watchdogTimer?.cancel();
    _speech.stop();
    _speech.cancel();
  }
}
