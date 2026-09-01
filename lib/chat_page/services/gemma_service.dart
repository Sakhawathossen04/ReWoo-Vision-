import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/pigeon.g.dart';
import 'package:path_provider/path_provider.dart';

import '../../download_page/config/constants.dart';
import '../models/message_models.dart';

/// Reasons why the local Gemma runtime can fail.
///
/// UI / BootstrapManager can inspect these values and show an exact
/// user-facing message instead of a generic "AI failed" error.
enum GemmaFailureReason {
  unsupportedGpu,
  outOfMemory,
  modelFileMissing,
  modelFileCorrupt,
  modelInitializationFailed,
  cpuFallbackFailed,
  unsupportedDevice,
}

/// Typed Gemma error.
///
/// [reason] is machine-readable.
/// [userMessage] is ready to show to the user.
class GemmaServiceException implements Exception {
  final GemmaFailureReason reason;

  final String userMessage;

  /// Original exception that triggered this failure.
  final Object? originalError;

  /// Backend that was being attempted when the final failure occurred.
  final PreferredBackend? backend;

  /// When GPU -> CPU fallback fails, this keeps the original GPU reason.
  final GemmaFailureReason? gpuFailureReason;

  const GemmaServiceException({
    required this.reason,
    required this.userMessage,
    this.originalError,
    this.backend,
    this.gpuFailureReason,
  });

  @override
  String toString() {
    return 'GemmaServiceException('
        'reason: $reason, '
        'backend: $backend, '
        'message: $userMessage'
        ')';
  }
}

/// Singleton service for the local Gemma vision model.
///
/// Initialization strategy:
///
/// Requested GPU
///      ↓
/// validate local model
///      ↓
/// create GPU model
///      ↓
/// create GPU chat
///      ↓
/// SUCCESS
///
/// If GPU runtime fails:
///
/// GPU failure
///      ↓
/// close partial GPU runtime
///      ↓
/// CPU createModel
///      ↓
/// CPU createChat
///      ↓
/// SUCCESS
///
/// If CPU also fails:
///
/// GemmaServiceException(
///   reason: cpuFallbackFailed,
/// )
///
///
/// Requested CPU:
///
/// validate model
///      ↓
/// CPU model + chat
///      ↓
/// success / classified failure
class GemmaService {
  GemmaService._internal();

  static final GemmaService instance =
      GemmaService._internal();

  final FlutterGemmaPlugin _gemma =
      FlutterGemmaPlugin.instance;

  InferenceModel? _model;

  InferenceChat? _chat;

  bool _initialised = false;

  /// Actual backend used by this service.
  PreferredBackend? _currentBackend;

  /// Backend requested by Settings/Bootstrap.
  ///
  /// Example:
  ///
  /// requested = GPU
  /// actual    = CPU
  ///
  /// means GPU failed and CPU fallback succeeded.
  PreferredBackend? _requestedBackend;

  bool _usedCpuFallback = false;

  GemmaServiceException? _lastFailure;

  // ===========================================================================
  // PUBLIC STATE
  // ===========================================================================

  bool get isInitialised =>
      _initialised;

  PreferredBackend? get currentBackend =>
      _currentBackend;

  PreferredBackend? get requestedBackend =>
      _requestedBackend;

  bool get usedCpuFallback =>
      _usedCpuFallback;

  GemmaServiceException? get lastFailure =>
      _lastFailure;

  String get lastFailureMessage =>
      _lastFailure?.userMessage ?? '';

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  Future<void> init(
    PreferredBackend backend,
  ) async {
    // -------------------------------------------------------------------------
    // Idempotent.
    //
    // Important:
    //
    // If GPU was requested but CPU fallback succeeded:
    //
    // requestedBackend = GPU
    // currentBackend   = CPU
    //
    // Calling init(GPU) again in the same runtime should NOT endlessly retry
    // the broken GPU.
    // -------------------------------------------------------------------------

    if (_initialised &&
        _requestedBackend ==
            backend) {
      return;
    }

    // Backend/settings changed.
    if (_initialised ||
        _model != null ||
        _chat != null) {
      await _releaseRuntime();
    }

    _requestedBackend =
        backend;

    _currentBackend =
        null;

    _usedCpuFallback =
        false;

    _lastFailure =
        null;

    // =======================================================================
    // PHASE 1
    // MODEL FILE VALIDATION
    // =======================================================================

    final modelFile =
        await _getValidatedModelFile();

    // =======================================================================
    // PHASE 2
    // POINT FLUTTER GEMMA TO LOCAL MODEL
    // =======================================================================

    try {
      final installed =
          await _gemma
              .modelManager
              .isModelInstalled;

      if (!installed) {
        await _gemma
            .modelManager
            .setModelPath(
          modelFile.path,
        );
      }
    } catch (e, st) {
      debugPrint(
        '[GemmaService] '
        'Model path registration failed: $e',
      );

      debugPrint('$st');

      final failure =
          _classifyInitializationError(
        e,
        backend:
            backend,
      );

      _lastFailure =
          failure;

      throw failure;
    }

    // =======================================================================
    // PHASE 3
    // GPU REQUEST
    // =======================================================================

    if (backend ==
        PreferredBackend.gpu) {
      try {
        debugPrint(
          '[GemmaService] '
          'Attempting GPU Gemma runtime...',
        );

        await _createRuntime(
          PreferredBackend.gpu,
        );

        _initialised =
            true;

        _currentBackend =
            PreferredBackend.gpu;

        _usedCpuFallback =
            false;

        _lastFailure =
            null;

        debugPrint(
          '[GemmaService] '
          'GPU runtime initialized successfully.',
        );

        return;
      } catch (gpuError, gpuStack) {
        debugPrint(
          '[GemmaService] '
          'GPU runtime failed: $gpuError',
        );

        debugPrint(
          '$gpuStack',
        );

        final gpuFailure =
            _classifyInitializationError(
          gpuError,
          backend:
              PreferredBackend.gpu,
        );

        // -------------------------------------------------------------------
        // GPU failure does NOT immediately fail the application.
        //
        // Try CPU.
        // -------------------------------------------------------------------

        debugPrint(
          '[GemmaService] '
          'GPU failure classified as '
          '${gpuFailure.reason}. '
          'Trying CPU fallback...',
        );

        // _createRuntime() already closes its partially created model on
        // failure, but reset our service state defensively as well.
        await _releaseRuntime(
          preserveRequestedBackend:
              true,
        );

        try {
          await _createRuntime(
            PreferredBackend.cpu,
          );

          _initialised =
              true;

          _currentBackend =
              PreferredBackend.cpu;

          _requestedBackend =
              PreferredBackend.gpu;

          _usedCpuFallback =
              true;

          _lastFailure =
              null;

          debugPrint(
            '[GemmaService] '
            'GPU failed but CPU fallback succeeded.',
          );

          return;
        } catch (cpuError, cpuStack) {
          debugPrint(
            '[GemmaService] '
            'CPU fallback failed: $cpuError',
          );

          debugPrint(
            '$cpuStack',
          );

          await _releaseRuntime(
            preserveRequestedBackend:
                true,
          );

          final cpuFailure =
              _classifyInitializationError(
            cpuError,
            backend:
                PreferredBackend.cpu,
          );

          final finalFailure =
              GemmaServiceException(
            reason:
                GemmaFailureReason
                    .cpuFallbackFailed,

            backend:
                PreferredBackend.cpu,

            gpuFailureReason:
                gpuFailure.reason,

            originalError:
                cpuError,

            userMessage:
                _cpuFallbackFailureMessage(
              gpuFailure:
                  gpuFailure,
              cpuFailure:
                  cpuFailure,
            ),
          );

          _lastFailure =
              finalFailure;

          throw finalFailure;
        }
      }
    }

    // =======================================================================
    // PHASE 4
    // CPU REQUEST
    // =======================================================================

    try {
      debugPrint(
        '[GemmaService] '
        'Attempting CPU Gemma runtime...',
      );

      await _createRuntime(
        PreferredBackend.cpu,
      );

      _initialised =
          true;

      _currentBackend =
          PreferredBackend.cpu;

      _requestedBackend =
          PreferredBackend.cpu;

      _usedCpuFallback =
          false;

      _lastFailure =
          null;

      debugPrint(
        '[GemmaService] '
        'CPU runtime initialized successfully.',
      );
    } catch (e, st) {
      debugPrint(
        '[GemmaService] '
        'CPU runtime initialization failed: $e',
      );

      debugPrint(
        '$st',
      );

      await _releaseRuntime(
        preserveRequestedBackend:
            true,
      );

      final failure =
          _classifyInitializationError(
        e,
        backend:
            PreferredBackend.cpu,
      );

      _lastFailure =
          failure;

      throw failure;
    }
  }

  // ===========================================================================
  // CREATE COMPLETE RUNTIME
  // ===========================================================================

  /// Creates BOTH:
  ///
  /// model + chat
  ///
  /// for one backend.
  ///
  /// This is important because GPU createModel() can succeed while
  /// createChat() later fails due to driver/memory problems.
  ///
  /// We consider the backend successful only when both objects exist.
  Future<void> _createRuntime(
    PreferredBackend backend,
  ) async {
    InferenceModel?
        candidateModel;

    try {
      // -----------------------------------------------------------------------
      // MODEL
      // -----------------------------------------------------------------------

      candidateModel =
          await _gemma
              .createModel(
        preferredBackend:
            backend,

        // Gemma 3 / Gemma 3n instruction-tuned family.
        modelType:
            ModelType.gemmaIt,

        // Vision assistant.
        supportImage:
            true,

        // Total model context / KV-cache budget.
        maxTokens:
            8192,

        // ReWoo currently processes one camera image per user query.
        maxNumImages:
            1,
      );

      // -----------------------------------------------------------------------
      // CHAT
      // -----------------------------------------------------------------------

      final candidateChat =
          await candidateModel
              .createChat(
        randomSeed:
            1,

        temperature:
            1,

        topK:
            64,

        topP:
            0.95,

        supportImage:
            true,

        tokenBuffer:
            512,
      );

      // -----------------------------------------------------------------------
      // Publish runtime only AFTER complete success.
      // -----------------------------------------------------------------------

      _model =
          candidateModel;

      _chat =
          candidateChat;
    } catch (e) {
      // -----------------------------------------------------------------------
      // Never leave a half-created GPU/CPU model alive.
      // -----------------------------------------------------------------------

      if (candidateModel !=
          null) {
        try {
          await candidateModel
              .close();
        } catch (closeError) {
          debugPrint(
            '[GemmaService] '
            'Could not close failed candidate runtime: '
            '$closeError',
          );
        }
      }

      _model =
          null;

      _chat =
          null;

      rethrow;
    }
  }

  // ===========================================================================
  // LOCAL MODEL FILE VALIDATION
  // ===========================================================================

  Future<File>
      _getValidatedModelFile() async {
    final dir =
        await getApplicationDocumentsDirectory();

    final path =
        '${dir.path}/$modelName';

    final file =
        File(path);

    // -------------------------------------------------------------------------
    // MISSING
    // -------------------------------------------------------------------------

    if (!await file.exists()) {
      final failure =
          GemmaServiceException(
        reason:
            GemmaFailureReason
                .modelFileMissing,

        userMessage:
            'Local AI model file ফোনে পাওয়া যায়নি। '
            'Model download page থেকে model আবার download বা recovery করুন.',

        originalError:
            FileSystemException(
          'Model file missing',
          path,
        ),
      );

      _lastFailure =
          failure;

      throw failure;
    }

    // -------------------------------------------------------------------------
    // SIZE VALIDATION
    // -------------------------------------------------------------------------

    int size;

    try {
      size =
          await file.length();
    } catch (e) {
      final failure =
          GemmaServiceException(
        reason:
            GemmaFailureReason
                .modelFileCorrupt,

        userMessage:
            'Local AI model file পড়া যাচ্ছে না। '
            'File corrupt অথবা storage error হতে পারে.',

        originalError:
            e,
      );

      _lastFailure =
          failure;

      throw failure;
    }

    final minimumValidSize =
        (expectedModelFileSize *
                modelSizeTolerance)
            .round();

    if (size <
        minimumValidSize) {
      final failure =
          GemmaServiceException(
        reason:
            GemmaFailureReason
                .modelFileCorrupt,

        userMessage:
            'Local AI model file অসম্পূর্ণ বা corrupt। '
            'Expected model-এর তুলনায় file size কম। '
            'Download recovery/verification আবার চালান.',

        originalError:
            StateError(
          'Model file too small: '
          '$size bytes, '
          'minimum=$minimumValidSize',
        ),
      );

      _lastFailure =
          failure;

      throw failure;
    }

    debugPrint(
      '[GemmaService] '
      'Model file validation passed: '
      '$size bytes',
    );

    return file;
  }

  // ===========================================================================
  // FAILURE CLASSIFICATION
  // ===========================================================================

  GemmaServiceException
      _classifyInitializationError(
    Object error, {
    required PreferredBackend backend,
  }) {
    // Preserve an already-classified error.
    if (error
        is GemmaServiceException) {
      return error;
    }

    final text =
        _fullErrorText(
      error,
    );

    // -------------------------------------------------------------------------
    // MODEL FILE MISSING
    // -------------------------------------------------------------------------

    if (_containsAny(
      text,
      const [
        'no such file',
        'file not found',
        'model file missing',
        'does not exist',
        'path not found',
      ],
    )) {
      return GemmaServiceException(
        reason:
            GemmaFailureReason
                .modelFileMissing,

        backend:
            backend,

        originalError:
            error,

        userMessage:
            'Local AI model file পাওয়া যায়নি। '
            'Model download সম্পূর্ণ হয়েছে কিনা পরীক্ষা করুন.',
      );
    }

    // -------------------------------------------------------------------------
    // MODEL CORRUPT
    // -------------------------------------------------------------------------

    if (_containsAny(
      text,
      const [
        'corrupt',
        'truncated',
        'unexpected eof',
        'checksum',
        'invalid model',
        'invalid flatbuffer',
        'flatbuffer verification',
        'failed to parse model',
        'model verification failed',
      ],
    )) {
      return GemmaServiceException(
        reason:
            GemmaFailureReason
                .modelFileCorrupt,

        backend:
            backend,

        originalError:
            error,

        userMessage:
            'Downloaded Local AI model file corrupt অথবা অসম্পূর্ণ। '
            'Model verification/download recovery আবার চালাতে হবে.',
      );
    }

    // -------------------------------------------------------------------------
    // OUT OF MEMORY
    // -------------------------------------------------------------------------

    if (_containsAny(
      text,
      const [
        'out of memory',
        'out_of_memory',
        'std::bad_alloc',
        'bad_alloc',
        'cannot allocate memory',
        'failed to allocate',
        'memory allocation failed',
        'memory exhausted',
        'resource exhausted',
        'oom',
      ],
    )) {
      return GemmaServiceException(
        reason:
            GemmaFailureReason
                .outOfMemory,

        backend:
            backend,

        originalError:
            error,

        userMessage:
            'Local AI model চালু করার সময় ফোনের memory শেষ হয়ে গেছে। '
            'এই model চালানোর জন্য device-এ পর্যাপ্ত available RAM নেই.',
      );
    }

    // -------------------------------------------------------------------------
    // GPU / OPENCL / DRIVER FAILURE
    // -------------------------------------------------------------------------

    if (backend ==
            PreferredBackend.gpu &&
        _containsAny(
          text,
          const [
            'gpu',
            'opencl',
            'open cl',
            'cl_device',
            'cl_context',
            'cl_command',
            'delegate',
            'accelerator',
            'egl',
            'graphics driver',
            'gpu delegate',
          ],
        )) {
      return GemmaServiceException(
        reason:
            GemmaFailureReason
                .unsupportedGpu,

        backend:
            backend,

        originalError:
            error,

        userMessage:
            'এই ফোনের GPU/OpenCL driver দিয়ে Local AI model চালু করা যায়নি। '
            'ReWoo Vision CPU fallback চেষ্টা করবে.',
      );
    }

    // -------------------------------------------------------------------------
    // UNSUPPORTED DEVICE / ABI / CPU
    // -------------------------------------------------------------------------

    if (_containsAny(
      text,
      const [
        'unsupported architecture',
        'unsupported device',
        'unsupported abi',
        'abi not supported',
        'wrong elf class',
        'dlopen failed',
        'library not found',
        'cannot locate symbol',
        'illegal instruction',
        'instruction set',
        'arm64',
        'neon unsupported',
      ],
    )) {
      return GemmaServiceException(
        reason:
            GemmaFailureReason
                .unsupportedDevice,

        backend:
            backend,

        originalError:
            error,

        userMessage:
            'এই ফোনের CPU/ABI/runtime বর্তমান Local AI model-এর সাথে compatible নয়.',
      );
    }

    // -------------------------------------------------------------------------
    // GPU backend failed for an unknown reason.
    //
    // Still classify as GPU failure so CPU fallback is meaningful.
    // -------------------------------------------------------------------------

    if (backend ==
        PreferredBackend.gpu) {
      return GemmaServiceException(
        reason:
            GemmaFailureReason
                .unsupportedGpu,

        backend:
            backend,

        originalError:
            error,

        userMessage:
            'GPU backend দিয়ে Local AI চালু করা যায়নি। '
            'ReWoo Vision CPU fallback চেষ্টা করবে.',
      );
    }

    // -------------------------------------------------------------------------
    // GENERIC CPU / MODEL INITIALIZATION
    // -------------------------------------------------------------------------

    return GemmaServiceException(
      reason:
          GemmaFailureReason
              .modelInitializationFailed,

      backend:
          backend,

      originalError:
          error,

      userMessage:
          'Local AI model runtime initialize করা যায়নি। '
          'Model file, RAM এবং device compatibility পরীক্ষা করুন.',
    );
  }

  // ===========================================================================
  // CPU FALLBACK FINAL MESSAGE
  // ===========================================================================

  String _cpuFallbackFailureMessage({
    required GemmaServiceException gpuFailure,
    required GemmaServiceException cpuFailure,
  }) {
    // -------------------------------------------------------------------------
    // CPU specifically failed because of RAM.
    // -------------------------------------------------------------------------

    if (cpuFailure.reason ==
        GemmaFailureReason.outOfMemory) {
      return 'GPU backend চালু হয়নি এবং CPU fallback-এর সময়ও '
          'ফোনের memory শেষ হয়ে গেছে। '
          'এই device-এ Local AI model চালানোর জন্য পর্যাপ্ত RAM নেই.';
    }

    // -------------------------------------------------------------------------
    // Corruption detected while CPU tried to read the model.
    // -------------------------------------------------------------------------

    if (cpuFailure.reason ==
            GemmaFailureReason
                .modelFileCorrupt ||
        gpuFailure.reason ==
            GemmaFailureReason
                .modelFileCorrupt) {
      return 'GPU এবং CPU কোনোটিতেই model চালু করা যায়নি কারণ '
          'local model file corrupt অথবা অসম্পূর্ণ মনে হচ্ছে। '
          'Model আবার verify/download করুন.';
    }

    // -------------------------------------------------------------------------
    // Device ABI/runtime unsupported.
    // -------------------------------------------------------------------------

    if (cpuFailure.reason ==
        GemmaFailureReason
            .unsupportedDevice) {
      return 'GPU backend ব্যর্থ হয়েছে এবং CPU fallback-ও এই phone-এর '
          'CPU/ABI/runtime support করছে না। '
          'এই device Local Gemma mode-এর সাথে compatible নয়.';
    }

    // -------------------------------------------------------------------------
    // Generic double failure.
    // -------------------------------------------------------------------------

    return 'GPU backend দিয়ে Local AI চালু করা যায়নি এবং '
        'CPU fallback-ও সফল হয়নি। '
        'এই phone-এর hardware/runtime modelটির সাথে compatible নাও হতে পারে.';
  }

  // ===========================================================================
  // ERROR TEXT NORMALIZATION
  // ===========================================================================

  String _fullErrorText(
    Object error,
  ) {
    if (error is PlatformException) {
      return '${error.code} '
              '${error.message ?? ''} '
              '${error.details ?? ''}'
          .toLowerCase();
    }

    return error
        .toString()
        .toLowerCase();
  }

  bool _containsAny(
    String source,
    List<String> patterns,
  ) {
    for (final pattern
        in patterns) {
      if (source.contains(
        pattern,
      )) {
        return true;
      }
    }

    return false;
  }

  // ===========================================================================
  // RUNTIME RELEASE
  // ===========================================================================

  /// Releases only the inference runtime.
  ///
  /// Downloaded multi-GB model remains on disk.
  Future<void> _releaseRuntime({
    bool preserveRequestedBackend = false,
  }) async {
    final model =
        _model;

    // Detach service references first so no new request can access a model
    // that is currently closing.
    _chat =
        null;

    _model =
        null;

    _initialised =
        false;

    _currentBackend =
        null;

    _usedCpuFallback =
        false;

    if (!preserveRequestedBackend) {
      _requestedBackend =
          null;
    }

    if (model != null) {
      try {
        await model.close();
      } catch (e) {
        debugPrint(
          '[GemmaService] '
          'Runtime close warning: $e',
        );
      }
    }
  }

  // ===========================================================================
  // STREAMING INFERENCE
  // ===========================================================================

  Future<void> sendWithStreaming({
    required String text,
    File? image,
    required Function(String) onToken,
    required FutureOr<void> Function(
      MessageStats,
    ) onComplete,
  }) async {
    if (!_initialised ||
        _model == null) {
      throw const GemmaServiceException(
        reason:
            GemmaFailureReason
                .modelInitializationFailed,

        userMessage:
            'Local AI model এখনো initialize হয়নি.',
      );
    }

    final chat =
        _chat;

    if (chat == null) {
      throw const GemmaServiceException(
        reason:
            GemmaFailureReason
                .modelInitializationFailed,

        userMessage:
            'Local AI chat session পাওয়া যাচ্ছে না.',
      );
    }

    // -------------------------------------------------------------------------
    // PERFORMANCE TRACKING
    // -------------------------------------------------------------------------

    final startTime =
        DateTime.now();

    DateTime?
        firstTokenTime;

    int tokenCount =
        0;

    // -------------------------------------------------------------------------
    // QUERY
    // -------------------------------------------------------------------------

    if (image != null) {
      final bytes =
          await image
              .readAsBytes();

      await chat.addQuery(
        Message.withImage(
          text:
              text,
          imageBytes:
              bytes,
          isUser:
              true,
        ),
      );
    } else {
      await chat.addQuery(
        Message.text(
          text:
              text,
          isUser:
              true,
        ),
      );
    }

    final completer =
        Completer<void>();

    // -------------------------------------------------------------------------
    // STREAM RESPONSE
    // -------------------------------------------------------------------------

    chat
        .generateChatResponseAsync()
        .listen(
      (
        ModelResponse response,
      ) {
        if (response
            is! TextResponse) {
          return;
        }

        firstTokenTime ??=
            DateTime.now();

        tokenCount++;

        try {
          onToken(
            response.token,
          );
        } catch (e) {
          // UI callback errors must not terminate model generation.
          debugPrint(
            '[GemmaService] '
            'onToken callback warning: $e',
          );
        }
      },

      // -----------------------------------------------------------------------
      // COMPLETE
      // -----------------------------------------------------------------------

      onDone: () async {
        final endTime =
            DateTime.now();

        final firstTokenMilliseconds =
            firstTokenTime !=
                    null
                ? firstTokenTime!
                    .difference(
                      startTime,
                    )
                    .inMilliseconds
                : 0;

        final decodeMilliseconds =
            firstTokenTime !=
                    null
                ? endTime
                    .difference(
                      firstTokenTime!,
                    )
                    .inMilliseconds
                : 0;

        final stats =
            MessageStats(
          timeToFirstToken:
              firstTokenTime !=
                      null
                  ? firstTokenMilliseconds /
                      1000.0
                  : null,

          totalLatency:
              endTime
                      .difference(
                        startTime,
                      )
                      .inMilliseconds /
                  1000.0,

          tokenCount:
              tokenCount,

          prefillSpeed:
              firstTokenMilliseconds >
                          0 &&
                      tokenCount >
                          0
                  ? 1000.0 /
                      firstTokenMilliseconds
                  : null,

          decodeSpeed:
              decodeMilliseconds >
                          0 &&
                      tokenCount >
                          1
                  ? (tokenCount -
                              1) *
                      1000.0 /
                      decodeMilliseconds
                  : null,
        );

        try {
          await onComplete(
            stats,
          );

          if (!completer
              .isCompleted) {
            completer.complete();
          }
        } catch (e, st) {
          if (!completer
              .isCompleted) {
            completer
                .completeError(
              e,
              st,
            );
          }
        }
      },

      // -----------------------------------------------------------------------
      // GENERATION ERROR
      // -----------------------------------------------------------------------

      onError: (
        Object error,
        StackTrace stackTrace,
      ) {
        if (!completer
            .isCompleted) {
          completer
              .completeError(
            error,
            stackTrace,
          );
        }
      },

      cancelOnError:
          true,
    );

    await completer.future;
  }

  // ===========================================================================
  // CHAT RESET
  // ===========================================================================

  /// Clears chat history while keeping the multi-GB model loaded.
  Future<void>
      resetChatSession() async {
    if (!_initialised) {
      return;
    }

    try {
      await _chat
          ?.clearHistory();
    } catch (e) {
      debugPrint(
        '[GemmaService] '
        'Chat reset failed: $e',
      );

      rethrow;
    }
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  /// Releases RAM/GPU/CPU inference resources.
  ///
  /// The downloaded model file is intentionally preserved.
  Future<void> dispose() async {
    await _releaseRuntime();

    _lastFailure =
        null;
  }
}
