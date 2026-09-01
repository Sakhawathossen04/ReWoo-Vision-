import 'dart:io';

import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Overall suitability of the current device.
///
/// [supported]
///   Device meets the recommended local-Gemma requirements and the checked
///   assistant hardware/services are available.
///
/// [supportedWithWarning]
///   The APK/local model can probably run, but one or more optional/runtime
///   capabilities need attention.
///
/// [unsupported]
///   Do not attempt to load the 3+ GB local Gemma model.
enum DeviceSupportLevel {
  supported,
  supportedWithWarning,
  unsupported,
}

/// Availability result for capabilities that may not yet have been initialized.
///
/// Speech recognition is intentionally allowed to remain [unknown].
///
/// IMPORTANT:
/// speech_to_text should be initialized only once per app session. SpeechService
/// owns that initialization, so DeviceCapabilityService must NOT initialize a
/// second SpeechToText instance just to probe availability.
enum CapabilityAvailability {
  available,
  unavailable,
  unknown,
}

/// Immutable result returned by [DeviceCapabilityService.check].
class DeviceCapabilityResult {
  // ===========================================================================
  // DEVICE
  // ===========================================================================

  final String manufacturer;
  final String model;

  final int androidSdk;

  final bool android9OrLater;

  // ===========================================================================
  // CPU / ABI
  // ===========================================================================

  final List<String> supportedAbis;
  final List<String> supported64BitAbis;

  final bool is64BitCapable;
  final bool hasArm64;

  // ===========================================================================
  // MEMORY
  // ===========================================================================

  /// Total physical RAM reported by Android, in MB.
  final int physicalRamMb;

  final bool isLowRamDevice;

  // ===========================================================================
  // STORAGE
  // ===========================================================================

  /// Available storage in the application documents filesystem, in MB.
  final double freeStorageMb;

  final bool hasEnoughStorageForDownload;

  // ===========================================================================
  // CAMERA
  // ===========================================================================

  final bool cameraHardwarePresent;
  final bool cameraAvailable;
  final PermissionStatus cameraPermission;

  // ===========================================================================
  // MICROPHONE
  // ===========================================================================

  final bool microphoneHardwarePresent;
  final PermissionStatus microphonePermission;

  bool get microphonePermissionGranted =>
      microphonePermission.isGranted;

  // ===========================================================================
  // SPEECH
  // ===========================================================================

  /// This should normally be supplied later from SpeechService after its one
  /// legitimate SpeechToText.initialize() call.
  final CapabilityAvailability speechRecognizer;

  final CapabilityAvailability bengaliSpeechRecognition;

  // ===========================================================================
  // TTS
  // ===========================================================================

  final bool ttsEngineAvailable;
  final bool bengaliTtsAvailable;

  // ===========================================================================
  // LOCAL GEMMA
  // ===========================================================================

  final bool localGemmaSupported;

  final DeviceSupportLevel supportLevel;

  // ===========================================================================
  // HUMAN-READABLE RESULTS
  // ===========================================================================

  final List<String> blockers;
  final List<String> warnings;

  const DeviceCapabilityResult({
    required this.manufacturer,
    required this.model,
    required this.androidSdk,
    required this.android9OrLater,
    required this.supportedAbis,
    required this.supported64BitAbis,
    required this.is64BitCapable,
    required this.hasArm64,
    required this.physicalRamMb,
    required this.isLowRamDevice,
    required this.freeStorageMb,
    required this.hasEnoughStorageForDownload,
    required this.cameraHardwarePresent,
    required this.cameraAvailable,
    required this.cameraPermission,
    required this.microphoneHardwarePresent,
    required this.microphonePermission,
    required this.speechRecognizer,
    required this.bengaliSpeechRecognition,
    required this.ttsEngineAvailable,
    required this.bengaliTtsAvailable,
    required this.localGemmaSupported,
    required this.supportLevel,
    required this.blockers,
    required this.warnings,
  });

  // ===========================================================================
  // CONVENIENCE
  // ===========================================================================

  double get freeStorageGb =>
      freeStorageMb / 1024.0;

  double get physicalRamGb =>
      physicalRamMb / 1024.0;

  bool get canDownloadModel =>
      android9OrLater &&
      is64BitCapable &&
      hasEnoughStorageForDownload;

  bool get coreVisionHardwareReady =>
      cameraHardwarePresent &&
      cameraAvailable &&
      microphoneHardwarePresent;

  bool get voiceReady =>
      microphonePermissionGranted &&
      speechRecognizer == CapabilityAvailability.available &&
      ttsEngineAvailable;

  bool get fullyReady =>
      localGemmaSupported &&
      coreVisionHardwareReady &&
      voiceReady;

  String get deviceLabel {
    final cleanManufacturer =
        manufacturer.trim();

    final cleanModel =
        model.trim();

    if (cleanManufacturer.isEmpty) {
      return cleanModel;
    }

    if (cleanModel
        .toLowerCase()
        .startsWith(
          cleanManufacturer.toLowerCase(),
        )) {
      return cleanModel;
    }

    return '$cleanManufacturer $cleanModel';
  }

  String get supportMessage {
    switch (supportLevel) {
      case DeviceSupportLevel.supported:
        return 'এই ফোনটি ReWoo Vision local AI চালানোর জন্য উপযুক্ত।';

      case DeviceSupportLevel.supportedWithWarning:
        if (warnings.isNotEmpty) {
          return warnings.first;
        }

        return 'এই ফোনে ReWoo Vision চলতে পারে, তবে কিছু capability সীমিত।';

      case DeviceSupportLevel.unsupported:
        if (blockers.isNotEmpty) {
          return blockers.first;
        }

        return 'এই ফোনে local AI model নিরাপদভাবে চালানো যাবে না।';
    }
  }

  @override
  String toString() {
    return 'DeviceCapabilityResult('
        'device: $deviceLabel, '
        'sdk: $androidSdk, '
        '64bit: $is64BitCapable, '
        'arm64: $hasArm64, '
        'ramMb: $physicalRamMb, '
        'lowRam: $isLowRamDevice, '
        'freeStorageMb: ${freeStorageMb.toStringAsFixed(0)}, '
        'camera: $cameraAvailable, '
        'micHardware: $microphoneHardwarePresent, '
        'micPermission: $microphonePermission, '
        'speech: $speechRecognizer, '
        'bengaliSpeech: $bengaliSpeechRecognition, '
        'tts: $ttsEngineAvailable, '
        'bengaliTts: $bengaliTtsAvailable, '
        'localGemma: $localGemmaSupported, '
        'support: $supportLevel'
        ')';
  }
}

/// Checks whether the current Android device is suitable for ReWoo Vision.
///
/// IMPORTANT ARCHITECTURE:
///
/// This class performs SIDE-EFFECT-FREE capability checks.
///
/// It does NOT:
///
/// - request microphone permission
/// - request camera permission
/// - initialize SpeechToText
/// - start camera
/// - load Gemma
///
/// Permission requests remain owned by the actual feature services.
///
/// SpeechService remains the ONLY owner of:
///
/// SpeechToText.initialize()
///
/// because speech_to_text recommends initializing one instance once per
/// application session.
class DeviceCapabilityService {
  DeviceCapabilityService._();

  // ===========================================================================
  // MINIMUM REQUIREMENTS
  // ===========================================================================

  /// Android 9 = API 28.
  static const int minimumAndroidSdk =
      28;

  /// Absolute minimum free storage before starting the large-model download.
  ///
  /// 6 GiB = 6144 MiB.
  static const double minimumDownloadStorageMb =
      6144;

  /// Local Gemma minimum RAM.
  ///
  /// This is an application policy, not an Android installation requirement.
  ///
  /// APK can install on lower-RAM Android 9+ devices, but attempting to load
  /// the ~3 GB local vision model there is unsafe / likely too slow.
  static const int minimumLocalGemmaRamMb =
      6144;

  /// Recommended RAM for a better local-model experience.
  static const int recommendedLocalGemmaRamMb =
      8192;

  /// 64-bit ARM is the preferred Android target for local AI.
  static const String arm64Abi =
      'arm64-v8a';

  // ===========================================================================
  // PUBLIC STORAGE CHECK
  // ===========================================================================

  /// Fast storage-only gate for DownloadPage.
  ///
  /// Use this immediately before allowing a new model download.
  static Future<StorageCapabilityResult>
      checkDownloadStorage() async {
    try {
      final directory =
          await getApplicationDocumentsDirectory();

      final disk =
          DiskSpacePlus();

      // disk_space_plus reports MB.
      final freeMb =
          await disk.getFreeDiskSpaceForPath(
                directory.path,
              ) ??
              await disk.getFreeDiskSpace ??
              0;

      final enough =
          freeMb >=
              minimumDownloadStorageMb;

      return StorageCapabilityResult(
        freeStorageMb:
            freeMb,
        enoughForModelDownload:
            enough,
        message: enough
            ? 'Model download-এর জন্য পর্যাপ্ত storage আছে।'
            : _storageErrorMessage(
                freeMb,
              ),
      );
    } catch (e) {
      debugPrint(
        '[DeviceCapabilityService] '
        'storage check failed: $e',
      );

      return const StorageCapabilityResult(
        freeStorageMb: 0,
        enoughForModelDownload: false,
        message:
            'ফোনের খালি storage নির্ধারণ করা যায়নি। '
            'নিরাপত্তার জন্য model download শুরু করা হয়নি।',
      );
    }
  }

  // ===========================================================================
  // COMPLETE DEVICE CHECK
  // ===========================================================================

  /// Performs the complete base-device capability check.
  ///
  /// [speechRecognizerAvailable] and [bengaliSpeechAvailable] should be passed
  /// from SpeechService AFTER SpeechService owns and performs its single
  /// SpeechToText.initialize() call.
  ///
  /// Before SpeechService initialization, leave them null.
  ///
  /// They will be reported as [CapabilityAvailability.unknown].
  static Future<DeviceCapabilityResult> check({
    bool? speechRecognizerAvailable,
    bool? bengaliSpeechAvailable,
  }) async {
    // -------------------------------------------------------------------------
    // Non-Android builds are unsupported for this Android APK architecture.
    // -------------------------------------------------------------------------

    if (!Platform.isAndroid) {
      return const DeviceCapabilityResult(
        manufacturer: '',
        model: '',
        androidSdk: 0,
        android9OrLater: false,
        supportedAbis: [],
        supported64BitAbis: [],
        is64BitCapable: false,
        hasArm64: false,
        physicalRamMb: 0,
        isLowRamDevice: true,
        freeStorageMb: 0,
        hasEnoughStorageForDownload: false,
        cameraHardwarePresent: false,
        cameraAvailable: false,
        cameraPermission: PermissionStatus.denied,
        microphoneHardwarePresent: false,
        microphonePermission: PermissionStatus.denied,
        speechRecognizer: CapabilityAvailability.unknown,
        bengaliSpeechRecognition: CapabilityAvailability.unknown,
        ttsEngineAvailable: false,
        bengaliTtsAvailable: false,
        localGemmaSupported: false,
        supportLevel: DeviceSupportLevel.unsupported,
        blockers: [
          'এই build শুধুমাত্র Android device-এর জন্য।',
        ],
        warnings: [],
      );
    }

    final blockers =
        <String>[];

    final warnings =
        <String>[];

    // =========================================================================
    // ANDROID DEVICE INFO
    // =========================================================================

    AndroidDeviceInfo? androidInfo;

    String manufacturer =
        '';

    String model =
        '';

    int sdk =
        0;

    List<String> supportedAbis =
        const [];

    List<String> supported64BitAbis =
        const [];

    int physicalRamMb =
        0;

    bool lowRamDevice =
        false;

    List<String> systemFeatures =
        const [];

    try {
      androidInfo =
          await DeviceInfoPlugin()
              .androidInfo;

      manufacturer =
          androidInfo.manufacturer;

      model =
          androidInfo.model;

      sdk =
          androidInfo.version.sdkInt;

      supportedAbis =
          List<String>.from(
        androidInfo.supportedAbis,
      );

      supported64BitAbis =
          List<String>.from(
        androidInfo.supported64BitAbis,
      );

      physicalRamMb =
          androidInfo.physicalRamSize;

      lowRamDevice =
          androidInfo.isLowRamDevice;

      systemFeatures =
          List<String>.from(
        androidInfo.systemFeatures,
      );
    } catch (e) {
      debugPrint(
        '[DeviceCapabilityService] '
        'device info failed: $e',
      );

      blockers.add(
        'ফোনের Android/RAM/CPU capability নির্ধারণ করা যায়নি।',
      );
    }

    // =========================================================================
    // ANDROID VERSION
    // =========================================================================

    final android9OrLater =
        sdk >=
            minimumAndroidSdk;

    if (!android9OrLater) {
      blockers.add(
        'ReWoo Vision-এর জন্য Android 9 বা তার পরের version প্রয়োজন।',
      );
    }

    // =========================================================================
    // ARCHITECTURE
    // =========================================================================

    final normalized64 =
        supported64BitAbis
            .map(
              (e) =>
                  e.toLowerCase(),
            )
            .toList(
              growable: false,
            );

    final is64BitCapable =
        normalized64.isNotEmpty;

    final hasArm64 =
        normalized64.contains(
      arm64Abi,
    );

    if (!is64BitCapable) {
      blockers.add(
        'এই ফোনটি 64-bit Android AI runtime support করে না। '
        'Local Gemma model চালানো হবে না।',
      );
    } else if (!hasArm64) {
      warnings.add(
        'ফোনটি 64-bit হলেও ARM64 architecture পাওয়া যায়নি। '
        'Local Gemma compatibility নিশ্চিত নয়।',
      );
    }

    // =========================================================================
    // RAM
    // =========================================================================

    if (physicalRamMb <=
        0) {
      warnings.add(
        'ফোনের RAM size নির্ধারণ করা যায়নি।',
      );
    } else if (physicalRamMb <
        minimumLocalGemmaRamMb) {
      blockers.add(
        'এই ফোনে ${(physicalRamMb / 1024).toStringAsFixed(1)} GB RAM আছে। '
        'প্রায় 3 GB local Gemma model চালাতে অন্তত 6 GB RAM প্রয়োজন।',
      );
    } else if (physicalRamMb <
        recommendedLocalGemmaRamMb) {
      warnings.add(
        'এই ফোনে ${(physicalRamMb / 1024).toStringAsFixed(1)} GB RAM আছে। '
        'Model চলতে পারে, তবে 8 GB বা বেশি RAM recommended।',
      );
    }

    if (lowRamDevice) {
      blockers.add(
        'Android এই ফোনটিকে low-RAM device হিসেবে চিহ্নিত করেছে। '
        'Local 3 GB AI model load করা নিরাপদ নয়।',
      );
    }

    // =========================================================================
    // STORAGE
    // =========================================================================

    final storage =
        await checkDownloadStorage();

    if (!storage.enoughForModelDownload) {
      blockers.add(
        storage.message,
      );
    }

    // =========================================================================
    // CAMERA HARDWARE
    // =========================================================================

    final cameraHardwarePresent =
        systemFeatures.contains(
              'android.hardware.camera',
            ) ||
            systemFeatures.contains(
              'android.hardware.camera.any',
            ) ||
            systemFeatures.contains(
              'android.hardware.camera.autofocus',
            );

    bool cameraAvailable =
        false;

    try {
      final cameras =
          await availableCameras();

      cameraAvailable =
          cameras.isNotEmpty;
    } catch (e) {
      debugPrint(
        '[DeviceCapabilityService] '
        'camera capability check failed: $e',
      );
    }

    final cameraPermission =
        await Permission.camera.status;

    if (!cameraHardwarePresent &&
        !cameraAvailable) {
      blockers.add(
        'এই ফোনে ব্যবহারযোগ্য camera পাওয়া যায়নি। '
        'ReWoo Vision visual assistant কাজ করবে না।',
      );
    }

    if (!cameraPermission.isGranted) {
      warnings.add(
        cameraPermission
                .isPermanentlyDenied
            ? 'Camera permission স্থায়ীভাবে বন্ধ আছে। Settings থেকে Camera permission চালু করতে হবে।'
            : 'Camera permission এখনো Allow করা হয়নি।',
      );
    }

    // =========================================================================
    // MICROPHONE HARDWARE / PERMISSION
    // =========================================================================

    final microphoneHardwarePresent =
        systemFeatures.contains(
      'android.hardware.microphone',
    );

    final microphonePermission =
        await Permission.microphone.status;

    if (!microphoneHardwarePresent) {
      blockers.add(
        'এই ফোনে microphone hardware পাওয়া যায়নি। '
        'Voice command ব্যবহার করা যাবে না।',
      );
    }

    if (!microphonePermission.isGranted) {
      if (microphonePermission
          .isPermanentlyDenied) {
        warnings.add(
          'Microphone permission স্থায়ীভাবে বন্ধ আছে। '
          'Settings থেকে permission চালু করতে হবে।',
        );
      } else {
        warnings.add(
          'Microphone permission এখনো Allow করা হয়নি।',
        );
      }
    }

    // =========================================================================
    // SPEECH RECOGNIZER
    // =========================================================================
    //
    // DO NOT initialize speech_to_text here.
    //
    // speech_to_text should only be initialized once per app session, and its
    // first initialize() call owns status/error callbacks.
    //
    // SpeechService already owns that lifecycle.
    // =========================================================================

    final speechRecognizer =
        _availabilityFromBool(
      speechRecognizerAvailable,
    );

    final bengaliSpeechRecognition =
        _availabilityFromBool(
      bengaliSpeechAvailable,
    );

    if (speechRecognizer ==
        CapabilityAvailability.unavailable) {
      warnings.add(
        'এই ফোনে ব্যবহারযোগ্য Speech Recognition service পাওয়া যায়নি।',
      );
    }

    if (bengaliSpeechRecognition ==
        CapabilityAvailability.unavailable) {
      warnings.add(
        'Speech recognizer পাওয়া গেলেও Bengali recognition পাওয়া যায়নি। '
        'Google Speech Services-এ বাংলা ভাষা চালু করুন।',
      );
    }

    // =========================================================================
    // TTS
    // =========================================================================

    final ttsResult =
        await _checkTts();

    if (!ttsResult.engineAvailable) {
      warnings.add(
        'এই ফোনে ব্যবহারযোগ্য Text-to-Speech engine পাওয়া যায়নি। '
        'Google Speech Services অথবা অন্য Android TTS engine install/enable করুন।',
      );
    } else if (!ttsResult
        .bengaliAvailable) {
      warnings.add(
        'TTS engine পাওয়া গেছে, কিন্তু Bengali voice/language পাওয়া যায়নি।',
      );
    }

    // =========================================================================
    // LOCAL GEMMA SUITABILITY
    // =========================================================================
    //
    // Local-model suitability is intentionally separate from microphone/TTS.
    //
    // Example:
    //
    // Android 9 + ARM64 + 8 GB RAM + 10 GB free
    // but microphone permission denied
    //
    // -> localGemmaSupported = true
    // -> overall status = supportedWithWarning
    //
    // This prevents a permission choice from incorrectly being treated as a
    // hardware incompatibility.
    // =========================================================================

    final localGemmaSupported =
        android9OrLater &&
            is64BitCapable &&
            hasArm64 &&
            !lowRamDevice &&
            physicalRamMb >=
                minimumLocalGemmaRamMb &&
            storage
                .enoughForModelDownload &&
            cameraAvailable;

    DeviceSupportLevel supportLevel;

    if (!localGemmaSupported ||
        blockers.isNotEmpty) {
      supportLevel =
          DeviceSupportLevel
              .unsupported;
    } else if (warnings.isNotEmpty ||
        speechRecognizer ==
            CapabilityAvailability
                .unknown ||
        bengaliSpeechRecognition ==
            CapabilityAvailability
                .unknown) {
      supportLevel =
          DeviceSupportLevel
              .supportedWithWarning;
    } else {
      supportLevel =
          DeviceSupportLevel
              .supported;
    }

    final result =
        DeviceCapabilityResult(
      manufacturer:
          manufacturer,
      model:
          model,
      androidSdk:
          sdk,
      android9OrLater:
          android9OrLater,
      supportedAbis:
          supportedAbis,
      supported64BitAbis:
          supported64BitAbis,
      is64BitCapable:
          is64BitCapable,
      hasArm64:
          hasArm64,
      physicalRamMb:
          physicalRamMb,
      isLowRamDevice:
          lowRamDevice,
      freeStorageMb:
          storage.freeStorageMb,
      hasEnoughStorageForDownload:
          storage
              .enoughForModelDownload,
      cameraHardwarePresent:
          cameraHardwarePresent,
      cameraAvailable:
          cameraAvailable,
      cameraPermission:
          cameraPermission,
      microphoneHardwarePresent:
          microphoneHardwarePresent,
      microphonePermission:
          microphonePermission,
      speechRecognizer:
          speechRecognizer,
      bengaliSpeechRecognition:
          bengaliSpeechRecognition,
      ttsEngineAvailable:
          ttsResult.engineAvailable,
      bengaliTtsAvailable:
          ttsResult.bengaliAvailable,
      localGemmaSupported:
          localGemmaSupported,
      supportLevel:
          supportLevel,
      blockers:
          List.unmodifiable(
        blockers,
      ),
      warnings:
          List.unmodifiable(
        warnings,
      ),
    );

    debugPrint(
      '[DeviceCapabilityService] $result',
    );

    return result;
  }

  // ===========================================================================
  // RECHECK AFTER SPEECH SERVICE INITIALIZATION
  // ===========================================================================

  /// Call this after SpeechService.initialize() if you want a full capability
  /// result including actual speech-recognizer state.
  ///
  /// Example:
  ///
  /// final capability = await DeviceCapabilityService.checkAfterSpeechInit(
  ///   speechRecognizerAvailable: speech.speechRecognizerAvailable,
  ///   bengaliSpeechAvailable: speech.hasBengaliSpeechLocale,
  /// );
  static Future<DeviceCapabilityResult>
      checkAfterSpeechInit({
    required bool speechRecognizerAvailable,
    required bool bengaliSpeechAvailable,
  }) {
    return check(
      speechRecognizerAvailable:
          speechRecognizerAvailable,
      bengaliSpeechAvailable:
          bengaliSpeechAvailable,
    );
  }

  // ===========================================================================
  // DOWNLOAD GATE
  // ===========================================================================

  /// Simple helper for ModelDownloadPage.
  ///
  /// This blocks a new download when storage is below 6 GiB.
  static Future<bool>
      canStartModelDownload() async {
    final storage =
        await checkDownloadStorage();

    return storage
        .enoughForModelDownload;
  }

  /// Returns an actionable Bengali error instead of only true/false.
  static Future<String?>
      modelDownloadBlockReason() async {
    final storage =
        await checkDownloadStorage();

    if (!storage
        .enoughForModelDownload) {
      return storage.message;
    }

    return null;
  }

  // ===========================================================================
  // TTS PROBE
  // ===========================================================================

  static Future<_TtsCapability>
      _checkTts() async {
    final tts =
        FlutterTts();

    try {
      final rawEngines =
          await tts.getEngines;

      final engines =
          _dynamicListToStrings(
        rawEngines,
      );

      final rawLanguages =
          await tts.getLanguages;

      final languages =
          _dynamicListToStrings(
        rawLanguages,
      );

      final normalizedLanguages =
          languages
              .map(
                (value) =>
                    value
                        .toLowerCase()
                        .replaceAll(
                          '_',
                          '-',
                        ),
              )
              .toList(
                growable: false,
              );

      final bengaliAvailable =
          normalizedLanguages.any(
        (language) =>
            language == 'bn' ||
            language.startsWith(
              'bn-',
            ),
      );

      // Some OEM engines may return an empty engines list while still exposing
      // languages. Therefore either signal can confirm TTS availability.
      final engineAvailable =
          engines.isNotEmpty ||
              languages.isNotEmpty;

      return _TtsCapability(
        engineAvailable:
            engineAvailable,
        bengaliAvailable:
            bengaliAvailable,
      );
    } catch (e) {
      debugPrint(
        '[DeviceCapabilityService] '
        'TTS capability check failed: $e',
      );

      return const _TtsCapability(
        engineAvailable: false,
        bengaliAvailable: false,
      );
    } finally {
      try {
        await tts.stop();
      } catch (_) {}
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  static CapabilityAvailability
      _availabilityFromBool(
    bool? value,
  ) {
    if (value == null) {
      return CapabilityAvailability
          .unknown;
    }

    return value
        ? CapabilityAvailability
            .available
        : CapabilityAvailability
            .unavailable;
  }

  static List<String>
      _dynamicListToStrings(
    dynamic raw,
  ) {
    if (raw is! Iterable) {
      return const [];
    }

    return raw
        .map(
          (value) =>
              value
                  .toString()
                  .trim(),
        )
        .where(
          (value) =>
              value.isNotEmpty,
        )
        .toList(
          growable: false,
        );
  }

  static String _storageErrorMessage(
    double freeMb,
  ) {
    final freeGb =
        freeMb / 1024;

    final requiredGb =
        minimumDownloadStorageMb /
            1024;

    return 'Model download শুরু করতে অন্তত '
        '${requiredGb.toStringAsFixed(0)} GB খালি storage প্রয়োজন। '
        'এই ফোনে বর্তমানে প্রায় '
        '${freeGb.toStringAsFixed(1)} GB খালি আছে। '
        'কিছু file মুছে জায়গা খালি করে আবার চেষ্টা করুন।';
  }
}

// =============================================================================
// STORAGE RESULT
// =============================================================================

class StorageCapabilityResult {
  final double freeStorageMb;

  final bool enoughForModelDownload;

  final String message;

  const StorageCapabilityResult({
    required this.freeStorageMb,
    required this.enoughForModelDownload,
    required this.message,
  });

  double get freeStorageGb =>
      freeStorageMb / 1024.0;
}

// =============================================================================
// INTERNAL TTS RESULT
// =============================================================================

class _TtsCapability {
  final bool engineAvailable;

  final bool bengaliAvailable;

  const _TtsCapability({
    required this.engineAvailable,
    required this.bengaliAvailable,
  });
}
