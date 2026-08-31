import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_gemma/pigeon.g.dart';

import 'gemma_service.dart';
import 'streaming_tts_service.dart';
import 'chat_helpers.dart';
import 'speech_service.dart';
import 'text_recognition_service.dart';

/// Initializes the services required by the Bengali voice-first assistant.
class BootstrapManager {
  static bool _globalBootstrapping = false;
  static Completer<void>? _globalBootstrapCompleter;

  static Future<BootstrapResult> bootstrap({
    required BuildContext context,
    required String systemContext,
    required PreferredBackend backend,
    required bool Function() isMounted,
    required bool Function() isDisposed,
    required void Function(VoidCallback) setState,
  }) async {
    if (_globalBootstrapping) {
      try {
        await _globalBootstrapCompleter?.future.timeout(
          const Duration(seconds: 30),
        );
      } catch (_) {
        _globalBootstrapping = false;
        _globalBootstrapCompleter = null;
      }
    }

    if (isDisposed()) {
      throw BootstrapException('Widget disposed');
    }

    _globalBootstrapping = true;
    _globalBootstrapCompleter = Completer<void>();

    try {
      final tts = FlutterTts();
      final streamingTts = StreamingTtsService(tts);

      final textRecognition = TextRecognitionService.instance;
      await textRecognition.initialize();

      if (!isMounted() || isDisposed()) {
        throw BootstrapException('Widget not mounted');
      }

      final speechService = SpeechService(
        tts: tts,
        onStateChanged: () {
          if (isMounted() && !isDisposed()) setState(() {});
        },
      );
      await speechService.initialize();

      if (!isMounted() || isDisposed()) {
        throw BootstrapException('Widget not mounted');
      }

      final chatHelpers = ChatHelpers(
        service: GemmaService.instance,
        streamingTts: streamingTts,
        speechService: speechService,
        textRecognition: textRecognition,
        onStateChanged: () {
          if (isMounted() && !isDisposed()) setState(() {});
        },
        showSnackBar: (msg) {
          if (isMounted() && !isDisposed()) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg)),
            );
          }
        },
        systemContext: systemContext,
      );

      await GemmaService.instance.init(backend);

      if (!isMounted() || isDisposed()) {
        throw BootstrapException('Widget not mounted');
      }

      if (!_globalBootstrapCompleter!.isCompleted) {
        _globalBootstrapCompleter!.complete();
      }

      return BootstrapResult(
        tts: tts,
        streamingTts: streamingTts,
        chatHelpers: chatHelpers,
        speechService: speechService,
        textRecognition: textRecognition,
      );
    } catch (e, st) {
      debugPrint('[BootstrapManager] bootstrap error: $e');
      debugPrint('$st');
      if (e is PlatformException) {
        debugPrint('[BootstrapManager] platform code: ${e.code}');
        debugPrint('[BootstrapManager] platform message: ${e.message}');
      }
      if (_globalBootstrapCompleter != null &&
          !_globalBootstrapCompleter!.isCompleted) {
        _globalBootstrapCompleter!.completeError(e, st);
      }
      rethrow;
    } finally {
      _globalBootstrapping = false;
      _globalBootstrapCompleter = null;
    }
  }

  static void reset() {
    _globalBootstrapping = false;
    _globalBootstrapCompleter = null;
  }
}

class BootstrapResult {
  final FlutterTts tts;
  final StreamingTtsService streamingTts;
  final ChatHelpers chatHelpers;
  final SpeechService speechService;
  final TextRecognitionService textRecognition;

  BootstrapResult({
    required this.tts,
    required this.streamingTts,
    required this.chatHelpers,
    required this.speechService,
    required this.textRecognition,
  });
}

class BootstrapException implements Exception {
  final String message;
  BootstrapException(this.message);

  @override
  String toString() => 'BootstrapException: $message';
}
