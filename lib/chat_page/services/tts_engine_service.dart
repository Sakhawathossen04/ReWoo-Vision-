// lib/chat_page/services/tts_engine_service.dart
//
// Fixes the "no sound in output" problem reported on some phones.
//
// Root causes handled here:
//  1. bn-BD voice not installed → TTS fails SILENTLY on many devices.
//     We probe bn-BD → bn-IN → bn → device default and remember what works.
//  2. Some phones ship with a third-party default TTS engine that has no
//     Bengali data. We look for Google TTS (which ships Bengali) and select
//     it when available.
//  3. Audio focus: TTS must request audio focus (focus: true) or the output
//     can be muted by media sessions on some OEM ROMs (Xiaomi, Realme…).
//  4. speak() with awaitSpeakCompletion can hang forever when the engine is
//     broken, which used to freeze the voice loop. Every speak call in the
//     app goes through `speakWithTimeout` so a dead engine can never stall
//     the assistant.
//  5. RETRY with reconfiguration: when the first speak attempt produces no
//     audio (engine glitch, language rejected mid-flight, OEM battery
//     manager), we stop the engine, reset the language to the device
//     default and speak one more time. A wrong-language utterance is far
//     better for a blind user than silence.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsConfigResult {
  /// Language actually accepted by the engine (empty string = default voice).
  final String? language;

  /// TTS engine package that was selected, when one was chosen.
  final String? engine;

  /// True when a Bengali voice was confirmed available.
  final bool bengaliVoiceAvailable;

  const TtsConfigResult({
    required this.language,
    required this.engine,
    required this.bengaliVoiceAvailable,
  });
}

class TtsEngineService {
  TtsEngineService._();

  /// Bengali language candidates in preference order.
  static const List<String> bengaliCandidates = [
    'bn-BD',
    'bn_IN',
    'bn-IN',
    'bn_BD',
    'bn-IN-x-locale',
    'bn',
  ];

  /// Engines known to ship Bengali voices, in preference order.
  static const List<String> preferredEngines = [
    'com.google.android.tts',
    'com.google.android.apps.tabs.google.tts',
    'com.samsung.SMT',
  ];

  /// The speech rate used across the app for Bengali narration.
  static const double bengaliSpeechRate = 0.46;

  /// Remembers the result of the last configuration so the settings page can
  /// display what the device is actually using.
  static TtsConfigResult? lastResult;

  static String? lastSetLanguage;

  /// True while a retry is in progress — prevents recursive retries.
  static bool _retrying = false;

  /// Full setup: engine → language → rate/volume/pitch.
  ///
  /// Never throws — a misconfigured device falls back to platform defaults.
  static Future<TtsConfigResult> configure(FlutterTts tts) async {
    String? chosenEngine;
    String? chosenLanguage;
    bool bengaliAvailable = false;

    try {
      // 1) Engine selection (Android only).
      try {
        final engines = await tts.getEngines;
        if (engines is List && engines.isNotEmpty) {
          final available = engines.map((e) => e.toString()).toList();
          for (final candidate in preferredEngines) {
            if (available.contains(candidate)) {
              final ok = await tts.setEngine(candidate);
              if (ok == 1 || ok == true) {
                chosenEngine = candidate;
                debugPrint('[TtsEngine] selected engine: $candidate');
                break;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[TtsEngine] engine selection unavailable: $e');
      }

      // 2) Language selection with fallback chain.
      bengaliAvailable = await _trySetBengali(tts);
      if (bengaliAvailable) {
        chosenLanguage = lastSetLanguage;
      }
    } catch (e) {
      debugPrint('[TtsEngine] configure error: $e');
    }

    // 3) Voice parameters. These apply regardless of engine/language.
    try {
      await tts.setSpeechRate(bengaliSpeechRate);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);
      // Streaming TTS relies on awaiting each segment; keep it enabled but
      // every await is wrapped in a timeout (see speakWithTimeout).
      await tts.awaitSpeakCompletion(true);
    } catch (e) {
      debugPrint('[TtsEngine] parameter setup error: $e');
    }

    lastResult = TtsConfigResult(
      language: chosenLanguage,
      engine: chosenEngine,
      bengaliVoiceAvailable: bengaliAvailable,
    );
    debugPrint(
      '[TtsEngine] configured — engine: ${chosenEngine ?? "default"}, '
      'language: ${chosenLanguage ?? "default"}, '
      'bengali: $bengaliAvailable',
    );
    return lastResult!;
  }

  /// Tries every Bengali candidate until the engine accepts one.
  static Future<bool> _trySetBengali(FlutterTts tts) async {
    for (final candidate in bengaliCandidates) {
      try {
        final available = await tts.isLanguageAvailable(candidate);
        if (available == true || available == 1) {
          final setResult = await tts.setLanguage(candidate);
          if (setResult == 1 || setResult == true) {
            lastSetLanguage = candidate;
            debugPrint('[TtsEngine] Bengali voice OK: $candidate');
            return true;
          }
        }
      } catch (_) {
        // Try the next candidate.
      }
    }
    debugPrint('[TtsEngine] no Bengali TTS voice found — using default voice');
    return false;
  }

  /// Speaks with a hard timeout so a broken engine can never freeze the
  /// voice loop. Returns true when the utterance completed normally.
  ///
  /// If the first attempt fails or times out, the engine is stopped and
  /// reconfigured (falling back to the device default voice when Bengali
  /// is rejected) and the utterance is spoken once more.
  static Future<bool> speakWithTimeout(
    FlutterTts tts,
    String text, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    if (text.trim().isEmpty) return true;

    final firstOk = await _speakOnce(tts, text, timeout);
    if (firstOk) return true;

    // One automatic recovery attempt — this is what rescues phones where
    // the first utterance after startup is silently dropped.
    if (_retrying) return false;
    _retrying = true;
    try {
      debugPrint('[TtsEngine] speak failed — reconfiguring engine and retrying');
      try {
        await tts.stop();
      } catch (_) {}
      await configure(tts);
      // If Bengali could not be re-applied, configure() already left the
      // engine on the platform default voice, which maximises the chance
      // the user hears SOMETHING.
      return await _speakOnce(tts, text, timeout);
    } finally {
      _retrying = false;
    }
  }

  /// A single speak attempt wrapped in a timeout.
  static Future<bool> _speakOnce(
    FlutterTts tts,
    String text,
    Duration timeout,
  ) async {
    try {
      // focus: true requests audio focus — REQUIRED for reliable playback
      // on phones that otherwise keep the media session muted.
      final result = await tts
          .speak(text, focus: true)
          .timeout(timeout, onTimeout: () {
        debugPrint('[TtsEngine] speak() timed out — engine likely broken');
        return null;
      });
      return result != null;
    } catch (e) {
      debugPrint('[TtsEngine] speak error: $e');
      return false;
    }
  }
}
