import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../voice/bengali_voice_commands.dart';
import '../voice/voice_intent.dart';
import 'sound_manager.dart';

/// Bengali-first voice control service.
///
/// The existing application used speech recognition as manually toggled
/// dictation. This version keeps a command-recognition loop active while the
/// chat page is open and only forwards a small, deterministic command set.
///
/// Important platform limitation: speech_to_text is backed by the device speech
/// recognizer. Some Android devices stop listening after a pause. We therefore
/// restart recognition whenever the platform reports `notListening` or `done`.
class SpeechService {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts;
  final VoidCallback _onStateChanged;

  bool _speechEnabled = false;
  bool _commandModeEnabled = false;
  bool _commandListening = false;
  bool _disposed = false;
  bool _startingSession = false;
  Timer? _restartTimer;
  Timer? _watchdogTimer;

  String _bengaliLocaleId = 'bn-BD';
  bool _bengaliLocaleAvailable = true;
  String _lastHeard = '';
  String _lastError = '';

  Future<void> Function(VoiceIntent intent)? _onCommand;
  bool Function()? _canAcceptCommand;

  VoiceIntent? _lastIntent;
  DateTime _lastIntentAt = DateTime.fromMillisecondsSinceEpoch(0);

  SpeechService({
    required FlutterTts tts,
    required VoidCallback onStateChanged,
  }) : _tts = tts, _onStateChanged = onStateChanged;

  bool get speechEnabled => _speechEnabled;
  bool get commandModeEnabled => _commandModeEnabled;
  bool get commandListening => _commandListening;
  bool get listening => _commandListening;
  String get lastHeard => _lastHeard;
  String get lastError => _lastError;
  String get bengaliLocaleId => _bengaliLocaleId;
  bool get hasBengaliSpeechLocale => _bengaliLocaleAvailable;

  Future<void> initialize() async {
    try {
      await _configureBanglaTts();

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
                'বাংলা ভয়েস ইনপুট পাওয়া যায়নি। '
                'ফোনের Google Speech Services বা ভয়েস ইনপুটে '
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
            } else if (_commandModeEnabled && !_disposed) {
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
      _onStateChanged();
    }
  }

  Future<void> _configureBanglaTts() async {
    try {
      // Android language tags normally use a hyphen while speech recognizer
      // locale ids are commonly returned with an underscore.
      await _tts.setLanguage('bn-BD');
    } catch (e) {
      debugPrint('[SpeechService] bn-BD TTS locale unavailable: $e');
      // Keep the platform default voice as a graceful fallback.
    }
    await _tts.setSpeechRate(0.46);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
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
    required Future<void> Function(VoiceIntent intent) onCommand,
    required bool Function() canAcceptCommand,
  }) {
    _onCommand = onCommand;
    _canAcceptCommand = canAcceptCommand;
  }

  Future<void> startCommandListening() async {
    if (_disposed || !_speechEnabled) return;

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

  Future<void> toggleDictation() async {
    if (_commandModeEnabled) {
      await stopCommandListening();
    } else {
      await startCommandListening();
    }
  }

  Future<void> _startCommandSession() async {
    if (_disposed ||
        !_commandModeEnabled ||
        !_speechEnabled ||
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
          if (_disposed || !_commandModeEnabled) return;

          final heard = result.recognizedWords.trim();
          if (heard.isNotEmpty) {
            _lastHeard = heard;
            _onStateChanged();
          }

          final intent = BengaliVoiceCommands.match(heard);
          if (intent == null) return;
          _handleDetectedIntent(intent);
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
            'বাংলা ভয়েস ইনপুট পাওয়া যায়নি। '
            'ফোনের Google Speech Services বা ভয়েস ইনপুটে '
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

  void _handleDetectedIntent(VoiceIntent intent) {
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
      unawaited(_runCommand(handler, intent));
    }

    // Speech recognizers frequently end a session after a confirmed phrase.
    // Proactively restart so the hands-free loop remains available.
    _scheduleRestart(const Duration(milliseconds: 650));
  }


  Future<void> _runCommand(
    Future<void> Function(VoiceIntent intent) handler,
    VoiceIntent intent,
  ) async {
    try {
      await handler(intent);
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
      if (_commandModeEnabled) {
        _scheduleRestart(const Duration(milliseconds: 500));
      }
    }
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_disposed || !_commandModeEnabled || !_speechEnabled) return;
      if (!_commandListening && !_startingSession && !_speech.isListening) {
        unawaited(_startCommandSession());
      }
    });
  }

  void _scheduleRestart(Duration delay) {
    if (_disposed || !_commandModeEnabled || !_speechEnabled) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      if (!_disposed && _commandModeEnabled) {
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

    try {
      await _tts.speak(clean, focus: false);
    } catch (e) {
      debugPrint('[SpeechService] TTS error: $e');
    } finally {
      if (resumeAfter && !_disposed) {
        _scheduleRestart(const Duration(milliseconds: 350));
      }
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
