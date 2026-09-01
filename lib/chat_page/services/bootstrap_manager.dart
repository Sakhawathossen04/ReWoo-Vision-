import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_gemma/pigeon.g.dart';

import '../../services/device_capability_service.dart';
import 'gemma_service.dart';
import 'streaming_tts_service.dart';
import 'chat_helpers.dart';
import 'speech_service.dart';
import 'text_recognition_service.dart';

/// Initializes the services required by the Bengali voice-first assistant.
///
/// Bootstrap flow:
///
/// Device capability check
///        ↓
/// Local Gemma runtime supported?
///        ↓
/// YES
///        ↓
/// TTS / OCR / Speech initialization
///        ↓
/// Gemma initialization
///        ↓
/// ChatHelpers
///        ↓
/// ChatPage ready
///
///
/// Unsupported / weak device:
///
/// capability check
///        ↓
/// DO NOT load 3+ GB Gemma
///        ↓
/// show clear compatibility error
///        ↓
/// throw [DeviceCompatibilityException]
///
/// This prevents weak/incompatible phones from attempting an expensive
/// local-model initialization that may otherwise crash, OOM, or hang.
class BootstrapManager {
  static bool _globalBootstrapping = false;

  static Completer<void>?
      _globalBootstrapCompleter;

  // ===========================================================================
  // BOOTSTRAP
  // ===========================================================================

  static Future<BootstrapResult> bootstrap({
    required BuildContext context,
    required String systemContext,
    required PreferredBackend backend,
    required bool Function() isMounted,
    required bool Function() isDisposed,
    required void Function(VoidCallback) setState,
  }) async {
    // -------------------------------------------------------------------------
    // Prevent overlapping bootstrap runs.
    // -------------------------------------------------------------------------

    if (_globalBootstrapping) {
      try {
        await _globalBootstrapCompleter
            ?.future
            .timeout(
          const Duration(
            seconds: 45,
          ),
        );
      } catch (_) {
        // Previous bootstrap either failed or became stuck.
        _globalBootstrapping = false;
        _globalBootstrapCompleter = null;
      }
    }

    if (isDisposed()) {
      throw BootstrapException(
        'Widget disposed before bootstrap.',
      );
    }

    _globalBootstrapping = true;

    _globalBootstrapCompleter =
        Completer<void>();

    // -------------------------------------------------------------------------
    // Runtime references for cleanup when bootstrap fails midway.
    // -------------------------------------------------------------------------

    FlutterTts? tts;

    StreamingTtsService?
        streamingTts;

    SpeechService?
        speechService;

    ChatHelpers?
        chatHelpers;

    TextRecognitionService?
        textRecognition;

    DeviceCapabilityResult?
        baseCapability;

    try {
      // =======================================================================
      // PHASE 1
      // DEVICE CAPABILITY CHECK
      // =======================================================================

      debugPrint(
        '[BootstrapManager] '
        'Checking device capability before Gemma load...',
      );

      baseCapability =
          await DeviceCapabilityService
              .check();

      if (!isMounted() ||
          isDisposed()) {
        throw BootstrapException(
          'Widget not mounted after capability check.',
        );
      }

      debugPrint(
        '[BootstrapManager] '
        'Base capability: $baseCapability',
      );

      // -----------------------------------------------------------------------
      // IMPORTANT:
      //
      // Do NOT blindly use:
      //
      // capability.localGemmaSupported
      //
      // here.
      //
      // DeviceCapabilityService also includes the 6 GB DOWNLOAD-storage
      // requirement in that value.
      //
      // Bootstrap is loading an ALREADY DOWNLOADED model, therefore low free
      // storage alone must not incorrectly block a valid installed model.
      //
      // Runtime compatibility is evaluated separately below.
      // -----------------------------------------------------------------------

      final runtimeCheck =
          _evaluateLocalGemmaRuntime(
        baseCapability,
      );

      // =======================================================================
      // UNSUPPORTED DEVICE
      // =======================================================================

      if (!runtimeCheck.supported) {
        final message =
            runtimeCheck
                .userMessage;

        debugPrint(
          '[BootstrapManager] '
          'Local Gemma blocked: $message',
        );

        // Show an accessible, explicit compatibility dialog instead of
        // attempting model initialization and crashing later.
        if (isMounted() &&
            !isDisposed()) {
          await _showCompatibilityDialog(
            context,
            title:
                'এই ফোনে Local AI চালানো যাবে না',
            message:
                message,
          );
        }

        throw DeviceCompatibilityException(
          message,
          capability:
              baseCapability,
          reasons:
              runtimeCheck.reasons,
        );
      }

      // =======================================================================
      // SUPPORTED WITH WARNING
      // =======================================================================

      if (runtimeCheck
              .warnings
              .isNotEmpty &&
          isMounted() &&
          !isDisposed()) {
        final warning =
            runtimeCheck
                .warnings
                .first;

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content:
                Text(
              warning,
            ),
            duration:
                const Duration(
              seconds: 5,
            ),
          ),
        );
      }

      // =======================================================================
      // PHASE 2
      // TTS
      // =======================================================================

      tts =
          FlutterTts();

      streamingTts =
          StreamingTtsService(
        tts,
      );

      // =======================================================================
      // PHASE 3
      // OCR
      // =======================================================================

      textRecognition =
          TextRecognitionService
              .instance;

      await textRecognition
          .initialize();

      if (!isMounted() ||
          isDisposed()) {
        throw BootstrapException(
          'Widget not mounted after OCR initialization.',
        );
      }

      // =======================================================================
      // PHASE 4
      // SPEECH
      // =======================================================================

      speechService =
          SpeechService(
        tts: tts,
        onStateChanged: () {
          if (isMounted() &&
              !isDisposed()) {
            setState(
              () {},
            );
          }
        },
      );

      await speechService
          .initialize();

      if (!isMounted() ||
          isDisposed()) {
        throw BootstrapException(
          'Widget not mounted after speech initialization.',
        );
      }

      // =======================================================================
      // PHASE 5
      // ENRICH CAPABILITY WITH REAL SPEECH STATE
      //
      // DeviceCapabilityService deliberately does not create another
      // SpeechToText instance.
      //
      // SpeechService owns SpeechToText.initialize().
      // =======================================================================

      DeviceCapabilityResult
          finalCapability =
          baseCapability;

      try {
        finalCapability =
            await DeviceCapabilityService
                .checkAfterSpeechInit(
          speechRecognizerAvailable:
              speechService
                  .speechRecognizerAvailable,

          bengaliSpeechAvailable:
              speechService
                      .hasBengaliSpeechLocale &&
                  !speechService
                      .bengaliLanguageUnsupported,
        );

        debugPrint(
          '[BootstrapManager] '
          'Capability after speech init: '
          '$finalCapability',
        );
      } catch (e) {
        // This second capability pass contains useful diagnostics, but it
        // should never prevent Gemma startup after the base runtime gate
        // already passed.
        debugPrint(
          '[BootstrapManager] '
          'Speech-enriched capability check warning: $e',
        );
      }

      if (!isMounted() ||
          isDisposed()) {
        throw BootstrapException(
          'Widget not mounted before Gemma initialization.',
        );
      }

      // =======================================================================
      // PHASE 6
      // LOCAL GEMMA INITIALIZATION
      //
      // This expensive step happens ONLY AFTER the device gate passed.
      // =======================================================================

      debugPrint(
        '[BootstrapManager] '
        'Device passed local-model gate. '
        'Initializing Gemma using $backend...',
      );

      try {
        await GemmaService
            .instance
            .init(
          backend,
        );
      } on PlatformException catch (e, st) {
        debugPrint(
          '[BootstrapManager] '
          'Gemma platform initialization failed.',
        );

        debugPrint(
          '[BootstrapManager] '
          'code=${e.code}',
        );

        debugPrint(
          '[BootstrapManager] '
          'message=${e.message}',
        );

        debugPrint(
          '$st',
        );

        final friendlyMessage =
            _classifyGemmaInitFailure(
          e,
        );

        if (isMounted() &&
            !isDisposed()) {
          await _showCompatibilityDialog(
            context,
            title:
                'Local AI চালু করা যায়নি',
            message:
                friendlyMessage,
          );
        }

        throw LocalModelInitializationException(
          friendlyMessage,
          originalError:
              e,
        );
      } catch (e, st) {
        debugPrint(
          '[BootstrapManager] '
          'Gemma initialization failed: $e',
        );

        debugPrint(
          '$st',
        );

        final friendlyMessage =
            _classifyGenericGemmaFailure(
          e,
        );

        if (isMounted() &&
            !isDisposed()) {
          await _showCompatibilityDialog(
            context,
            title:
                'Local AI চালু করা যায়নি',
            message:
                friendlyMessage,
          );
        }

        throw LocalModelInitializationException(
          friendlyMessage,
          originalError:
              e,
        );
      }

      if (!isMounted() ||
          isDisposed()) {
        throw BootstrapException(
          'Widget not mounted after Gemma initialization.',
        );
      }

      // =======================================================================
      // PHASE 7
      // CHAT HELPERS
      //
      // Create ChatHelpers only after the local model initialized successfully.
      // =======================================================================

      chatHelpers =
          ChatHelpers(
        service:
            GemmaService.instance,

        streamingTts:
            streamingTts,

        speechService:
            speechService,

        textRecognition:
            textRecognition,

        onStateChanged: () {
          if (isMounted() &&
              !isDisposed()) {
            setState(
              () {},
            );
          }
        },

        showSnackBar:
            (message) {
          if (isMounted() &&
              !isDisposed()) {
            ScaffoldMessenger
                    .of(
                      context,
                    )
                .showSnackBar(
              SnackBar(
                content:
                    Text(
                  message,
                ),
              ),
            );
          }
        },

        systemContext:
            systemContext,
      );

      // =======================================================================
      // SUCCESS
      // =======================================================================

      if (_globalBootstrapCompleter !=
              null &&
          !_globalBootstrapCompleter!
              .isCompleted) {
        _globalBootstrapCompleter!
            .complete();
      }

      debugPrint(
        '[BootstrapManager] '
        'Bootstrap completed successfully.',
      );

      return BootstrapResult(
        tts:
            tts,

        streamingTts:
            streamingTts,

        chatHelpers:
            chatHelpers,

        speechService:
            speechService,

        textRecognition:
            textRecognition,

        capability:
            finalCapability,

        mode:
            BootstrapMode.localGemma,
      );
    } catch (e, st) {
      debugPrint(
        '[BootstrapManager] bootstrap error: $e',
      );

      debugPrint(
        '$st',
      );

      if (e is PlatformException) {
        debugPrint(
          '[BootstrapManager] '
          'platform code: ${e.code}',
        );

        debugPrint(
          '[BootstrapManager] '
          'platform message: ${e.message}',
        );
      }

      // =======================================================================
      // CLEAN UP PARTIALLY INITIALIZED RUNTIME
      // =======================================================================

      try {
        chatHelpers
            ?.dispose();
      } catch (_) {}

      try {
        speechService
            ?.dispose();
      } catch (_) {}

      try {
        streamingTts
            ?.dispose();
      } catch (_) {}

      try {
        await tts
            ?.stop();
      } catch (_) {}

      // TextRecognitionService is a singleton.
      //
      // Do not dispose it here automatically because bootstrap may be retried
      // by ErrorRecoveryPage / backend reset.
      //
      // ChatPage performs the final application-level disposal.

      if (_globalBootstrapCompleter !=
              null &&
          !_globalBootstrapCompleter!
              .isCompleted) {
        _globalBootstrapCompleter!
            .completeError(
          e,
          st,
        );
      }

      rethrow;
    } finally {
      _globalBootstrapping =
          false;

      _globalBootstrapCompleter =
          null;
    }
  }

  // ===========================================================================
  // LOCAL GEMMA RUNTIME CAPABILITY
  // ===========================================================================

  /// Evaluates only properties required for RUNNING the already-downloaded
  /// local model.
  ///
  /// Free-storage download requirements are deliberately excluded.
  static _LocalRuntimeCheck
      _evaluateLocalGemmaRuntime(
    DeviceCapabilityResult capability,
  ) {
    final reasons =
        <String>[];

    final warnings =
        <String>[];

    // -------------------------------------------------------------------------
    // Android version
    // -------------------------------------------------------------------------

    if (!capability
        .android9OrLater) {
      reasons.add(
        'Android 9 বা তার পরের version প্রয়োজন।',
      );
    }

    // -------------------------------------------------------------------------
    // CPU / ABI
    // -------------------------------------------------------------------------

    if (!capability
        .is64BitCapable) {
      reasons.add(
        'এই ফোনে 64-bit Android runtime পাওয়া যায়নি।',
      );
    }

    if (!capability
        .hasArm64) {
      reasons.add(
        'এই ফোনে ARM64 architecture পাওয়া যায়নি। '
        'বর্তমান local Gemma runtime-এর জন্য ARM64 প্রয়োজন।',
      );
    }

    // -------------------------------------------------------------------------
    // RAM
    // -------------------------------------------------------------------------

    if (capability
            .physicalRamMb <=
        0) {
      // Safe default:
      //
      // If RAM cannot be verified we do not attempt a multi-GB local model.
      reasons.add(
        'ফোনের RAM capacity নির্ভরযোগ্যভাবে যাচাই করা যায়নি। '
        'নিরাপত্তার জন্য local AI model load করা হচ্ছে না।',
      );
    } else if (capability
            .physicalRamMb <
        DeviceCapabilityService
            .minimumLocalGemmaRamMb) {
      reasons.add(
        'এই ফোনে প্রায় '
        '${capability.physicalRamGb.toStringAsFixed(1)} GB RAM আছে। '
        'এই local AI model চালাতে অন্তত 6 GB RAM প্রয়োজন।',
      );
    } else if (capability
            .physicalRamMb <
        DeviceCapabilityService
            .recommendedLocalGemmaRamMb) {
      warnings.add(
        'এই ফোনে প্রায় '
        '${capability.physicalRamGb.toStringAsFixed(1)} GB RAM আছে। '
        'Local AI চলতে পারে, তবে 8 GB বা বেশি RAM recommended।',
      );
    }

    if (capability
        .isLowRamDevice) {
      reasons.add(
        'Android এই ফোনটিকে low-RAM device হিসেবে চিহ্নিত করেছে। '
        '3 GB-এর বেশি local AI model load করা নিরাপদ নয়।',
      );
    }

    // -------------------------------------------------------------------------
    // Camera
    //
    // ReWoo Vision is a visual assistant, therefore absence of a usable camera
    // means the primary application workflow is unavailable.
    // -------------------------------------------------------------------------

    if (!capability
        .cameraAvailable) {
      reasons.add(
        'এই ফোনে ব্যবহারযোগ্য camera পাওয়া যায়নি। '
        'ReWoo Vision-এর visual assistant mode চালানো যাবে না।',
      );
    }

    // -------------------------------------------------------------------------
    // Permission / speech / TTS are NOT local-model hardware blockers.
    //
    // They are handled gracefully by SpeechService and the UI.
    //
    // Example:
    //
    // microphone permission denied
    //
    // must NOT cause Gemma to be classified as hardware-incompatible.
    // -------------------------------------------------------------------------

    final supported =
        reasons.isEmpty;

    if (supported) {
      return _LocalRuntimeCheck(
        supported: true,
        reasons:
            const [],
        warnings:
            warnings,
        userMessage:
            warnings.isNotEmpty
                ? warnings.first
                : 'এই ফোনটি Local AI চালানোর জন্য উপযুক্ত।',
      );
    }

    final message =
        _buildUnsupportedMessage(
      reasons,
    );

    return _LocalRuntimeCheck(
      supported: false,
      reasons:
          reasons,
      warnings:
          warnings,
      userMessage:
          message,
    );
  }

  static String _buildUnsupportedMessage(
    List<String> reasons,
  ) {
    if (reasons.isEmpty) {
      return 'এই ফোনে local AI model চালানো যাবে না।';
    }

    if (reasons.length ==
        1) {
      return '${reasons.first} '
          'এই কারণে ReWoo Vision local Gemma load করবে না।';
    }

    final buffer =
        StringBuffer(
      'এই ফোনে local AI model চালানোর জন্য প্রয়োজনীয় capability নেই।\n\n',
    );

    for (final reason
        in reasons) {
      buffer.write(
        '• $reason\n',
      );
    }

    buffer.write(
      '\nModel load বন্ধ রাখা হয়েছে যাতে app crash বা out-of-memory না হয়।',
    );

    return buffer
        .toString()
        .trim();
  }

  // ===========================================================================
  // GEMMA ERROR CLASSIFICATION
  // ===========================================================================

  static String
      _classifyGemmaInitFailure(
    PlatformException error,
  ) {
    final combined =
        '${error.code} '
        '${error.message ?? ''} '
        '${error.details ?? ''}'
            .toLowerCase();

    if (_containsAny(
      combined,
      const [
        'out of memory',
        'out_of_memory',
        'oom',
        'allocation',
        'memory exhausted',
      ],
    )) {
      return 'Local AI model load করার সময় ফোনের memory শেষ হয়ে গেছে। '
          'এই device-এ model চালানোর জন্য পর্যাপ্ত RAM নেই।';
    }

    if (_containsAny(
      combined,
      const [
        'opencl',
        'gpu',
        'delegate',
        'accelerator',
        'graphics',
      ],
    )) {
      return 'এই ফোনের GPU/AI accelerator দিয়ে model চালু করা যায়নি। '
          'CPU fallback-ও সফল না হলে এই device local AI mode support করে না।';
    }

    if (_containsAny(
      combined,
      const [
        'corrupt',
        'invalid model',
        'model file',
        'unexpected eof',
        'truncated',
      ],
    )) {
      return 'Downloaded AI model file corrupt অথবা অসম্পূর্ণ মনে হচ্ছে। '
          'Model verification করে প্রয়োজনে পুনরায় download করতে হবে।';
    }

    if (_containsAny(
      combined,
      const [
        'not found',
        'no such file',
        'file does not exist',
      ],
    )) {
      return 'Local AI model file ফোনে পাওয়া যায়নি। '
          'Model download আবার যাচাই করুন।';
    }

    if (_containsAny(
      combined,
      const [
        'unsupported',
        'not supported',
        'architecture',
        'abi',
      ],
    )) {
      return 'এই ফোনের CPU/GPU architecture বর্তমান local AI runtime support করে না।';
    }

    return 'Local AI model চালু করা যায়নি। '
        'Device compatibility, RAM এবং downloaded model file পরীক্ষা করুন.';
  }

  static String
      _classifyGenericGemmaFailure(
    Object error,
  ) {
    final text =
        error
            .toString()
            .toLowerCase();

    if (_containsAny(
      text,
      const [
        'out of memory',
        'out_of_memory',
        'oom',
        'memory',
      ],
    )) {
      return 'Local AI model load করার জন্য ফোনে পর্যাপ্ত RAM নেই।';
    }

    if (_containsAny(
      text,
      const [
        'corrupt',
        'truncated',
        'invalid model',
      ],
    )) {
      return 'Local AI model file corrupt অথবা অসম্পূর্ণ। '
          'Model download verification প্রয়োজন।';
    }

    if (_containsAny(
      text,
      const [
        'gpu',
        'opencl',
        'delegate',
      ],
    )) {
      return 'ফোনের GPU দিয়ে AI model চালু করা যায়নি। '
          'CPU fallback support পরীক্ষা করতে হবে।';
    }

    return 'Local AI model চালু করা যায়নি। '
        'এই phone-এর hardware/runtime modelটির সাথে compatible নাও হতে পারে।';
  }

  static bool _containsAny(
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
  // COMPATIBILITY DIALOG
  // ===========================================================================

  static Future<void>
      _showCompatibilityDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) async {
    try {
      await showDialog<void>(
        context:
            context,

        barrierDismissible:
            false,

        builder:
            (dialogContext) {
          return AlertDialog(
            title:
                Text(
              title,
            ),

            content:
                SingleChildScrollView(
              child:
                  Text(
                message,
              ),
            ),

            actions: [
              TextButton(
                onPressed:
                    () {
                  Navigator.of(
                    dialogContext,
                  ).pop();
                },
                child:
                    const Text(
                  'ঠিক আছে',
                ),
              ),
            ],
          );
        },
      );
    } catch (e) {
      // Dialog failure must not make an unsupported device proceed to Gemma.
      debugPrint(
        '[BootstrapManager] '
        'Could not show compatibility dialog: $e',
      );
    }
  }

  // ===========================================================================
  // RESET
  // ===========================================================================

  static void reset() {
    _globalBootstrapping =
        false;

    _globalBootstrapCompleter =
        null;
  }
}

// =============================================================================
// BOOTSTRAP RESULT
// =============================================================================

enum BootstrapMode {
  /// Full local on-device Gemma mode.
  localGemma,
}

class BootstrapResult {
  final FlutterTts tts;

  final StreamingTtsService
      streamingTts;

  final ChatHelpers
      chatHelpers;

  final SpeechService
      speechService;

  final TextRecognitionService
      textRecognition;

  /// Full capability snapshot for diagnostics/UI.
  final DeviceCapabilityResult
      capability;

  final BootstrapMode
      mode;

  BootstrapResult({
    required this.tts,
    required this.streamingTts,
    required this.chatHelpers,
    required this.speechService,
    required this.textRecognition,
    required this.capability,
    required this.mode,
  });
}

// =============================================================================
// INTERNAL RUNTIME CHECK
// =============================================================================

class _LocalRuntimeCheck {
  final bool supported;

  final List<String>
      reasons;

  final List<String>
      warnings;

  final String
      userMessage;

  const _LocalRuntimeCheck({
    required this.supported,
    required this.reasons,
    required this.warnings,
    required this.userMessage,
  });
}

// =============================================================================
// EXCEPTIONS
// =============================================================================

class BootstrapException
    implements Exception {
  final String message;

  BootstrapException(
    this.message,
  );

  @override
  String toString() =>
      'BootstrapException: $message';
}

/// Device capability was checked BEFORE Gemma initialization and the local
/// model was deliberately blocked.
class DeviceCompatibilityException
    extends BootstrapException {
  final DeviceCapabilityResult
      capability;

  final List<String>
      reasons;

  DeviceCompatibilityException(
    super.message, {
    required this.capability,
    required this.reasons,
  });

  @override
  String toString() =>
      'DeviceCompatibilityException: $message';
}

/// Device passed the capability gate but native Gemma initialization still
/// failed.
class LocalModelInitializationException
    extends BootstrapException {
  final Object?
      originalError;

  LocalModelInitializationException(
    super.message, {
    this.originalError,
  });

  @override
  String toString() =>
      'LocalModelInitializationException: $message';
}
