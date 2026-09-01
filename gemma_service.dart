// services/gemma_service.dart - Further Optimized Version
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/pigeon.g.dart';
import 'package:path_provider/path_provider.dart';

import '../models/message_models.dart';

/// Singleton service for Google's Gemma AI model - optimized for performance and memory efficiency
/// Handles model loading, chat sessions, and streaming responses with minimal overhead
class GemmaService {
  GemmaService._internal();
  static final GemmaService instance = GemmaService._internal();

  final _gemma = FlutterGemmaPlugin.instance;
  InferenceModel? _model;
  InferenceChat? _chat;
  bool _initialised = false;
  PreferredBackend? _currentBackend;

  /// Initialize model with selected backend (CPU/GPU) - idempotent operation
  /// Uses local model file if available to avoid redundant downloads
  ///
  /// Device compatibility: some phones ship GPU drivers that cannot run the
  /// model (white screens / instant crashes / load timeouts). When the
  /// requested backend fails to load, we automatically fall back to CPU —
  /// slower but working on every device.
  Future<void> init(PreferredBackend backend) async {
    if (_initialised && _currentBackend == backend) return;

    // Switching CPU/GPU requires recreating the runtime, but must not delete
    // the downloaded multi-gigabyte model from storage.
    if (_initialised && _currentBackend != backend) {
      await _releaseRuntime();
    }

    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/gemma-3n-E2B-it-int4.task';

    if (!File(path).existsSync()) {
      throw Exception(
        'মডেল ফাইল পাওয়া যায়নি। ইন্টারনেট সংযোগ রেখে অ্যাপটি আবার খুলুন — '
        'মডেল স্বয়ংক্রিয়ভাবে ডাউনলোড হবে।',
      );
    }

    // Point plugin to local model file if it exists and plugin hasn't loaded one yet
    if (!await _gemma.modelManager.isModelInstalled) {
      await _gemma.modelManager.setModelPath(path);
    }

    // Create model instance with vision support and performance settings.
    // GPU failures (unsupported Adreno/Mali drivers, OEM battery killers)
    // transparently fall back to CPU so the assistant keeps working.
    try {
      _model ??= await _gemma.createModel(
        preferredBackend: backend,
        modelType: ModelType.gemmaIt, // Instruction-tuned variant
        supportImage: true, // Enable vision capabilities
        maxTokens: 8192, // Context window size
        maxNumImages: 1, // Single image per message
      );
    } catch (e) {
      if (backend == PreferredBackend.gpu) {
        debugPrint('[GemmaService] GPU load failed ($e) — retrying with CPU');
        _model = null;
        _model = await _gemma.createModel(
          preferredBackend: PreferredBackend.cpu,
          modelType: ModelType.gemmaIt,
          supportImage: true,
          maxTokens: 8192,
          maxNumImages: 1,
        );
        backend = PreferredBackend.cpu;
      } else {
        rethrow;
      }
    }

    // Create persistent chat session with consistency-first parameters.
    // For a safety-critical visual assistant, "same scene → same answer"
    // matters more than creative variety. Near-deterministic sampling is the
    // single biggest in-app fix for "sometimes the answer is good, sometimes
    // it isn't" — the model stops gambling on low-probability tokens.
    _chat ??= await _model!.createChat(
      randomSeed: 1, // Deterministic for testing
      temperature: 0.3, // Low — factual, repeatable answers
      topK: 40, // Focused candidate pool
      topP: 0.9, // Tighter nucleus
      supportImage: true,
      tokenBuffer: 512, // Reserve tokens for system prompts
    );

    _initialised = true;
    _currentBackend = backend;
  }

  Future<void> _releaseRuntime() async {
    try {
      await _model?.close();
    } finally {
      _model = null;
      _chat = null;
      _initialised = false;
      _currentBackend = null;
    }
  }

  /// Provides detailed performance statistics and error handling.
  ///
  /// Reliability guard: when a generation dies with a stream error or
  /// produces no usable tokens at all (a known "sometimes bad" failure of
  /// on-device inference under memory pressure), the chat session is
  /// recreated once and the request retried transparently. The caller only
  /// sees an error when the retry also fails.
  Future<void> sendWithStreaming({
    required String text,
    File? image,
    required Function(String) onToken,
    required FutureOr<void> Function(MessageStats) onComplete,
  }) async {
    try {
      await _sendOnce(
        text: text,
        image: image,
        onToken: onToken,
        onComplete: onComplete,
      );
    } catch (e) {
      debugPrint('[GemmaService] generation failed ($e) — retrying once with a fresh chat session');
      await _recreateChat();
      await _sendOnce(
        text: text,
        image: image,
        onToken: onToken,
        onComplete: onComplete,
      );
    }
  }

  /// Recreates the chat session while keeping the model itself loaded.
  /// A wedged session (dead stream, corrupted history) is a common source
  /// of intermittent generation failures; this is the cheap cure.
  Future<void> _recreateChat() async {
    if (!_initialised || _model == null) return;
    try {
      await _chat?.clearHistory();
    } catch (_) {}
    _chat = null;
    _chat = await _model!.createChat(
      randomSeed: 1,
      temperature: 0.3,
      topK: 40,
      topP: 0.9,
      supportImage: true,
      tokenBuffer: 512,
    );
  }

  Future<void> _sendOnce({
    required String text,
    File? image,
    required Function(String) onToken,
    required FutureOr<void> Function(MessageStats) onComplete,
  }) async {
    if (!_initialised) {
      throw Exception('GemmaService not initialized');
    }
    if (_chat == null) {
      throw Exception('Chat not available');
    }

    // Performance tracking variables
    final startTime = DateTime.now();
    DateTime? firstTokenTime;
    int tokenCount = 0;
    final responseBuffer = StringBuffer();

    // Add user message with optional image to chat history
    if (image != null) {
      final bytes = await image.readAsBytes();
      await _chat!.addQuery(
        Message.withImage(text: text, imageBytes: bytes, isUser: true),
      );
    } else {
      await _chat!.addQuery(Message.text(text: text, isUser: true));
    }

    final completer = Completer<void>();
    bool streamStarted = false;

    // Process streaming response with performance metrics
    _chat!.generateChatResponseAsync().listen(
      (ModelResponse res) {
        if (!streamStarted) {
          streamStarted = true;
        }

        if (res is TextResponse) {
          // Record timing for first token (important latency metric)
          firstTokenTime ??= DateTime.now();
          tokenCount++;
          responseBuffer.write(res.token);

          // Forward token to caller (swallow any callback errors)
          try {
            onToken(res.token);
          } catch (_) {
            // Ignore callback errors - caller's responsibility
          }
        }
        // Note: Non-text responses (metadata, etc.) are ignored
      },
      onDone: () async {
        final endTime = DateTime.now();

        // Calculate comprehensive performance statistics
        final stats = MessageStats(
          timeToFirstToken: firstTokenTime != null
              ? firstTokenTime!.difference(startTime).inMilliseconds / 1000.0
              : null,
          totalLatency: endTime.difference(startTime).inMilliseconds / 1000.0,
          tokenCount: tokenCount,
          // Tokens per second during initial processing
          prefillSpeed: firstTokenTime != null && tokenCount > 0
              ? 1000.0 / firstTokenTime!.difference(startTime).inMilliseconds
              : null,
          // Tokens per second during generation (excluding first token)
          decodeSpeed: firstTokenTime != null && tokenCount > 1
              ? (tokenCount - 1) *
                    1000.0 /
                    endTime.difference(firstTokenTime!).inMilliseconds
              : null,
        );

        // Deliver final statistics (ignore callback errors)
        try {
          await onComplete(stats);
          if (!completer.isCompleted) completer.complete();
        } catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );

    await completer.future;

    // Empty-generation guard: treat "no tokens at all" as a failure so the
    // outer retry logic can rebuild the session instead of silently
    // answering nothing.
    if (responseBuffer.toString().trim().isEmpty) {
      throw StateError('empty_generation');
    }
  }

  /// Fast chat reset - clears conversation history but keeps model loaded in memory
  /// Much faster than full reinitialization for "new chat" functionality
  Future<void> resetChatSession() async {
    if (!_initialised) return;
    await _chat?.clearHistory();
  }

  /// Release only the in-memory inference runtime. The downloaded model is
  /// intentionally preserved so restarting the app or changing backend does
  /// not force another ~3 GB download.
  Future<void> dispose() => _releaseRuntime();
}
