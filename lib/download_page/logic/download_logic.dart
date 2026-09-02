// download_page/logic/download_logic.dart
//
// ReWoo Vision large-model download orchestration.
//
// Core safety rules:
//
// 1. Network/system failure NEVER deletes partial download data.
// 2. App restart NEVER starts a fresh task while a recoverable task exists.
// 3. 100% progress is NOT treated as success until the final model is verified.
// 4. background_downloader/DownloadManager owns .part -> final rename.
// 5. This layer verifies the resulting final model again.
// 6. Recoverable failure is persisted as "failed_recoverable".
// 7. Only explicit user cancel/delete destroys partial download data.
//
// Optional SHA-256:
//
// Build with:
//
//   flutter build apk \
//     --dart-define=MODEL_SHA256=<64-character-official-sha256>
//
// If MODEL_SHA256 is absent, size validation remains mandatory.
// Hashing is streamed; the 3+ GB model is never loaded entirely into RAM.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

// Temporary compatibility import.
//
// DownloadManager currently exposes flutter_downloader-compatible DownloadTask
// objects while the project migrates internally to background_downloader.
import 'package:flutter_downloader/flutter_downloader.dart';

import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:gemma_chat/chat_page/gemma_vision_chat.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/constants.dart';
import '../models/enums.dart';
import '../models/models.dart';
import '../services/download_manager.dart';
import '../services/download_state_manager.dart';
import '../services/huggingface_oauth.dart';
import '../services/logger.dart';
import '../services/token_manager.dart';

class DownloadPageLogic {
  // ===========================================================================
  // UI CALLBACKS
  // ===========================================================================

  final Function(DownloadStatus) setDownloadStatus;
  final Function(DownloadProgress?) setProgress;
  final Function(List<String>) setErrorMessages;
  final Function(bool) setShowAgreementSheet;

  // ===========================================================================
  // MONITORING
  // ===========================================================================

  Timer? _monitoringTimer;

  int _autoResumeAttempts = 0;

  static const int _maxAutoResumeAttempts = 5;

  // ===========================================================================
  // PROGRESS
  // ===========================================================================

  int _expectedBytes = 0;

  int _lastSampledPercent = -1;

  int _lastPersistedPercent = -1;

  DateTime _lastSampleTime = DateTime.now();

  double _downloadRate = 0;


  /// Set when a complete verified model exists in a legacy location but could
  /// not yet be promoted to the canonical ApplicationDocuments path.
  ///
  /// This blocks ALL fresh downloads while still allowing the UI to show a
  /// migration/recovery error instead of pretending the canonical model is ready.
  bool _verifiedModelFoundButNotCanonical = false;

  // ===========================================================================
  // OPTIONAL MODEL SHA-256
  // ===========================================================================

  static const String _configuredModelSha256 =
      String.fromEnvironment(
    'MODEL_SHA256',
    defaultValue: '',
  );


  // ===========================================================================
  // INSTALLED MODEL REGISTRATION / PATH RECOVERY
  // ===========================================================================

  /// flutter_gemma 0.10.6 stores the active model filename in this
  /// SharedPreferences key.
  ///
  /// IMPORTANT:
  ///
  /// In flutter_gemma 0.10.6, the first isModelInstalled check performs an
  /// orphan cleanup. A valid .task file that is not registered under this key
  /// and is older than 30 minutes can be treated as an orphan.
  ///
  /// Our downloader owns the network transfer, so once WE verify the model we
  /// also register its filename here before Gemma gets a chance to run cleanup.
  static const String _flutterGemmaInstalledModelFileNameKey =
      'installed_model_file_name';

  /// Stores the last physically verified model path.
  ///
  /// Normally this is the canonical ApplicationDocuments/modelName path.
  /// During migration it may temporarily point to a valid legacy location.
  ///
  /// GemmaService can use the same key as a final fallback while the migration
  /// period is still active.
  static const String _resolvedModelPathKey =
      'rewoo_verified_model_path_v1';

  // ===========================================================================
  // CONSTRUCTOR
  // ===========================================================================

  DownloadPageLogic({
    required this.setDownloadStatus,
    required this.setProgress,
    required this.setErrorMessages,
    required this.setShowAgreementSheet,
  });

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  void dispose() {
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
  }

  // ===========================================================================
  // BASIC TASK HELPERS
  // ===========================================================================

  bool _isModelTask(
    DownloadTask task,
  ) {
    return task.filename == modelName;
  }

  bool _isRecoverableStatus(
    DownloadTaskStatus status,
  ) {
    return status ==
            DownloadTaskStatus.running ||
        status ==
            DownloadTaskStatus.enqueued ||
        status ==
            DownloadTaskStatus.paused ||
        status ==
            DownloadTaskStatus.failed;
  }

  DownloadTask? _latestTaskWhere(
    List<DownloadTask> tasks,
    bool Function(DownloadTask task) test,
  ) {
    DownloadTask? selected;

    for (final task in tasks) {
      if (!test(task)) {
        continue;
      }

      if (selected == null ||
          task.timeCreated >
              selected.timeCreated) {
        selected = task;
      }
    }

    return selected;
  }

  DownloadTask?
      _latestRecoverableModelTask(
    List<DownloadTask> tasks,
  ) {
    return _latestTaskWhere(
      tasks,
      (task) =>
          _isModelTask(task) &&
          _isRecoverableStatus(
            task.status,
          ),
    );
  }

  DownloadTask?
      _findTaskById(
    List<DownloadTask> tasks,
    String taskId,
  ) {
    for (final task in tasks) {
      if (task.taskId ==
          taskId) {
        return task;
      }
    }

    return null;
  }

  String? _taskFinalFilePath(
    DownloadTask task,
  ) {
    final filename =
        task.filename;

    if (filename == null ||
        filename.trim().isEmpty ||
        task.savedDir.trim().isEmpty) {
      return null;
    }

    return '${task.savedDir}/$filename';
  }

  String? _taskPartialFilePath(
    DownloadTask task,
  ) {
    final finalPath =
        _taskFinalFilePath(
      task,
    );

    if (finalPath == null) {
      return null;
    }

    return '$finalPath.part';
  }

  Future<String>
      _defaultPartialFilePath() async {
    final dir =
        await getApplicationDocumentsDirectory();

    return '${dir.path}/$modelName.part';
  }

  // ===========================================================================
  // EXPECTED SIZE
  // ===========================================================================

  Future<int> _resolveExpectedBytes(
    String? accessToken,
  ) async {
    final client =
        http.Client();

    try {
      final request =
          http.Request(
        'HEAD',
        Uri.parse(downloadUrl),
      );

      request.followRedirects =
          true;

      if (accessToken != null &&
          accessToken.trim().isNotEmpty) {
        request.headers[
            'Authorization'] =
            'Bearer $accessToken';
      }

      final response =
          await client
              .send(request)
              .timeout(
        const Duration(
          seconds: 20,
        ),
      );

      final length =
          response.contentLength ??
              0;

      if (length > 0) {
        Logger.info(
          'Remote model Content-Length: '
          '$length bytes',
        );

        return length;
      }
    } on TimeoutException catch (e) {
      Logger.warning(
        'Model size lookup timed out: $e',
      );
    } on SocketException catch (e) {
      Logger.warning(
        'Model size lookup network error: $e',
      );
    } catch (e) {
      Logger.warning(
        'Could not resolve model size: $e',
      );
    } finally {
      client.close();
    }

    Logger.info(
      'Using bundled expected model size: '
      '$expectedModelFileSize bytes',
    );

    return expectedModelFileSize;
  }

  // ===========================================================================
  // FINAL MODEL VERIFICATION
  // ===========================================================================

  Future<_ModelVerificationResult>
      _verifyFinalFile(
    File file, {
    required bool verifyChecksum,
  }) async {
    if (!await file.exists()) {
      return const _ModelVerificationResult(
        valid: false,
        reason: _ModelVerificationFailure.missing,
        size: 0,
      );
    }

    final size =
        await file.length();

    // Use the published model size as the stable verification baseline.
    //
    // HEAD responses can vary across CDN/proxy implementations, so the
    // published constant is safer for corruption detection.
    final minimumValidSize =
        (expectedModelFileSize *
                modelSizeTolerance)
            .round();

    if (size <
        minimumValidSize) {
      return _ModelVerificationResult(
        valid: false,
        reason:
            _ModelVerificationFailure.tooSmall,
        size: size,
      );
    }

    // -----------------------------------------------------------------------
    // Optional SHA-256
    // -----------------------------------------------------------------------

    if (verifyChecksum &&
        _configuredModelSha256
            .trim()
            .isNotEmpty) {
      final expectedHash =
          _configuredModelSha256
              .trim()
              .toLowerCase();

      final validHashFormat =
          RegExp(
        r'^[0-9a-f]{64}$',
      ).hasMatch(
        expectedHash,
      );

      if (!validHashFormat) {
        return _ModelVerificationResult(
          valid: false,
          reason:
              _ModelVerificationFailure
                  .invalidChecksumConfiguration,
          size: size,
        );
      }

      Logger.info(
        'Calculating SHA-256 for final model...',
      );

      try {
        // Streaming hash:
        // no 3+ GB memory allocation.
        final digest =
            await sha256
                .bind(
                  file.openRead(),
                )
                .first;

        final actualHash =
            digest
                .toString()
                .toLowerCase();

        if (actualHash !=
            expectedHash) {
          Logger.error(
            'Model SHA-256 mismatch. '
            'Expected=$expectedHash '
            'Actual=$actualHash',
          );

          return _ModelVerificationResult(
            valid: false,
            reason:
                _ModelVerificationFailure
                    .checksumMismatch,
            size: size,
          );
        }

        Logger.info(
          'Model SHA-256 verified successfully.',
        );
      } catch (e) {
        Logger.error(
          'SHA-256 verification failed: $e',
        );

        return _ModelVerificationResult(
          valid: false,
          reason:
              _ModelVerificationFailure
                  .checksumCalculationFailed,
          size: size,
        );
      }
    }

    return _ModelVerificationResult(
      valid: true,
      reason:
          _ModelVerificationFailure.none,
      size: size,
    );
  }

  /// Verifies whether a usable final model already exists.
  ///
  /// Recoverable partial data is NEVER deleted here.
  ///
  /// A final file may be deleted only when we can prove it belongs to a
  /// completed result and verification fails.
  // ===========================================================================
  // MODEL PATH DISCOVERY / MIGRATION
  // ===========================================================================

  String _basename(
    String path,
  ) {
    final normalized =
        path.replaceAll(
      r'\',
      '/',
    );

    final index =
        normalized.lastIndexOf('/');

    if (index < 0) {
      return normalized;
    }

    return normalized.substring(
      index + 1,
    );
  }

  void _addCandidatePath(
    List<String> ordered,
    Set<String> seen,
    String? path,
  ) {
    if (path == null) {
      return;
    }

    final clean =
        path.trim();

    if (clean.isEmpty) {
      return;
    }

    if (seen.add(clean)) {
      ordered.add(clean);
    }
  }

  Future<void> _scanForExactModelFile(
    Directory root,
    List<String> ordered,
    Set<String> seen, {
    required int maxDepth,
    Set<String>? visited,
  }) async {
    if (maxDepth < 0) {
      return;
    }

    final visitedDirs =
        visited ?? <String>{};

    final rootPath =
        root.absolute.path;

    if (!visitedDirs.add(rootPath)) {
      return;
    }

    if (!await root.exists()) {
      return;
    }

    try {
      await for (final entity
          in root.list(
        followLinks: false,
      )) {
        if (entity is File) {
          if (_basename(
                entity.path,
              ) ==
              modelName) {
            _addCandidatePath(
              ordered,
              seen,
              entity.path,
            );
          }

          continue;
        }

        if (entity is Directory &&
            maxDepth > 0) {
          await _scanForExactModelFile(
            entity,
            ordered,
            seen,
            maxDepth:
                maxDepth - 1,
            visited:
                visitedDirs,
          );
        }
      }
    } catch (e) {
      Logger.debug(
        'Could not scan model directory '
        '$rootPath: $e',
      );
    }
  }

  /// Builds an ordered list of possible FINAL model locations.
  ///
  /// Order:
  ///
  /// 1. canonical ApplicationDocuments path
  /// 2. downloader task-derived final paths
  /// 3. last previously verified path
  /// 4. known app-owned legacy/cache/support/external locations
  ///
  /// .part files are deliberately NOT accepted here. Completed .part files are
  /// finalized by DownloadManager before this method scans for final models.
  Future<List<String>> _discoverFinalModelPaths(
    List<DownloadTask> tasks,
  ) async {
    final ordered =
        <String>[];

    final seen =
        <String>{};

    final documents =
        await getApplicationDocumentsDirectory();

    _addCandidatePath(
      ordered,
      seen,
      '${documents.path}/$modelName',
    );

    // -----------------------------------------------------------------------
    // Downloader-record locations.
    // -----------------------------------------------------------------------

    for (final task in tasks) {
      if (!_isModelTask(
        task,
      )) {
        continue;
      }

      _addCandidatePath(
        ordered,
        seen,
        _taskFinalFilePath(
          task,
        ),
      );
    }

    // -----------------------------------------------------------------------
    // Last path that this app physically verified.
    // -----------------------------------------------------------------------

    try {
      final prefs =
          await SharedPreferences.getInstance();

      _addCandidatePath(
        ordered,
        seen,
        prefs.getString(
          _resolvedModelPathKey,
        ),
      );
    } catch (e) {
      Logger.debug(
        'Could not read remembered model path: $e',
      );
    }

    // -----------------------------------------------------------------------
    // Known app-owned directories.
    //
    // We intentionally do NOT scan arbitrary public storage.
    // -----------------------------------------------------------------------

    final roots =
        <Directory>[];

    void addRoot(
      Directory? directory,
    ) {
      if (directory == null) {
        return;
      }

      final path =
          directory.absolute.path;

      for (final existing
          in roots) {
        if (existing.absolute.path ==
            path) {
          return;
        }
      }

      roots.add(
        directory,
      );
    }

    addRoot(
      documents,
    );

    // App data root catches older app-owned files under sibling directories
    // such as files/cache/app_flutter without scanning outside our sandbox.
    addRoot(
      documents.parent,
    );

    try {
      addRoot(
        await getApplicationSupportDirectory(),
      );
    } catch (e) {
      Logger.debug(
        'ApplicationSupport lookup unavailable: $e',
      );
    }

    try {
      addRoot(
        await getTemporaryDirectory(),
      );
    } catch (e) {
      Logger.debug(
        'TemporaryDirectory lookup unavailable: $e',
      );
    }

    if (Platform.isAndroid) {
      try {
        addRoot(
          await getExternalStorageDirectory(),
        );
      } catch (e) {
        Logger.debug(
          'ExternalStorage lookup unavailable: $e',
        );
      }
    }

    final visited =
        <String>{};

    for (final root
        in roots) {
      await _scanForExactModelFile(
        root,
        ordered,
        seen,
        maxDepth: 3,
        visited:
            visited,
      );
    }

    Logger.info(
      'Model discovery found '
      '${ordered.length} candidate final path(s).',
    );

    return ordered;
  }

  bool _isTaskActivelyWriting(
    DownloadTask task,
  ) {
    return task.status ==
            DownloadTaskStatus.running ||
        task.status ==
            DownloadTaskStatus.enqueued ||
        task.status ==
            DownloadTaskStatus.paused;
  }

  DownloadTask? _associatedTaskForPath(
    List<DownloadTask> tasks,
    String path,
  ) {
    DownloadTask? selected;

    for (final task
        in tasks) {
      if (!_isModelTask(
        task,
      )) {
        continue;
      }

      if (_taskFinalFilePath(
            task,
          ) !=
          path) {
        continue;
      }

      if (selected == null ||
          task.timeCreated >
              selected.timeCreated) {
        selected =
            task;
      }
    }

    return selected;
  }

  /// Attempts to move a verified legacy final model into the canonical
  /// ApplicationDocuments/modelName path.
  ///
  /// Strategy:
  ///
  /// rename first
  ///   -> cheap / atomic on the same filesystem
  ///
  /// if rename is not possible
  ///   -> streaming copy to .migration
  ///   -> verify copied bytes
  ///   -> rename .migration to canonical
  ///   -> only then remove the old duplicate
  ///
  /// The original verified source is preserved on every failure path.
  Future<File> _promoteVerifiedModelToCanonical(
    File source,
  ) async {
    final documents =
        await getApplicationDocumentsDirectory();

    final canonical =
        File(
      '${documents.path}/$modelName',
    );

    final sourcePath =
        source.absolute.path;

    final canonicalPath =
        canonical.absolute.path;

    if (sourcePath ==
        canonicalPath) {
      return canonical;
    }

    // If canonical appeared in the meantime, use it only if it is valid.
    if (await canonical.exists()) {
      final existingVerification =
          await _verifyFinalFile(
        canonical,
        verifyChecksum: false,
      );

      if (existingVerification.valid) {
        Logger.info(
          'Canonical model became available during recovery: '
          '$canonicalPath',
        );

        return canonical;
      }

      // Do not overwrite or delete an unknown canonical artifact here.
      Logger.warning(
        'A non-valid canonical model artifact already exists at '
        '$canonicalPath. '
        'Verified legacy source is being preserved at $sourcePath.',
      );

      return source;
    }

    // -----------------------------------------------------------------------
    // 1. Same-filesystem atomic rename.
    // -----------------------------------------------------------------------

    try {
      await canonical.parent.create(
        recursive: true,
      );

      final renamed =
          await source.rename(
        canonicalPath,
      );

      final verification =
          await _verifyFinalFile(
        renamed,
        verifyChecksum: false,
      );

      if (verification.valid) {
        Logger.info(
          'Migrated verified model by rename: '
          '$sourcePath -> $canonicalPath',
        );

        return renamed;
      }

      Logger.error(
        'Renamed model failed verification. '
        'Attempting to restore original path.',
      );

      try {
        if (await renamed.exists() &&
            !await source.exists()) {
          await renamed.rename(
            sourcePath,
          );
        }
      } catch (restoreError) {
        Logger.error(
          'Could not restore model after failed rename verification: '
          '$restoreError',
        );
      }

      return source;
    } catch (e) {
      Logger.info(
        'Direct model rename unavailable: $e. '
        'Trying safe streaming migration.',
      );
    }

    // -----------------------------------------------------------------------
    // 2. Cross-filesystem safe copy.
    // -----------------------------------------------------------------------

    final migrationFile =
        File(
      '$canonicalPath.migration',
    );

    try {
      // This is our own migration scratch file, not network partial data.
      if (await migrationFile.exists()) {
        await migrationFile.delete();
      }

      await source
          .openRead()
          .pipe(
        migrationFile.openWrite(),
      );

      final copyVerification =
          await _verifyFinalFile(
        migrationFile,
        verifyChecksum: false,
      );

      if (!copyVerification.valid) {
        Logger.error(
          'Migrated model copy failed verification: '
          '${copyVerification.reason}',
        );

        try {
          await migrationFile.delete();
        } catch (_) {}

        return source;
      }

      // Race safety: never overwrite a file that appeared while copying.
      if (await canonical.exists()) {
        final existingVerification =
            await _verifyFinalFile(
          canonical,
          verifyChecksum: false,
        );

        if (existingVerification.valid) {
          try {
            await migrationFile.delete();
          } catch (_) {}

          return canonical;
        }

        Logger.warning(
          'Canonical artifact appeared during migration but is not valid. '
          'Keeping verified source and removing only migration scratch file.',
        );

        try {
          await migrationFile.delete();
        } catch (_) {}

        return source;
      }

      final promoted =
          await migrationFile.rename(
        canonicalPath,
      );

      final finalVerification =
          await _verifyFinalFile(
        promoted,
        verifyChecksum: false,
      );

      if (!finalVerification.valid) {
        Logger.error(
          'Canonical model failed verification after migration.',
        );

        // Preserve the original verified source.
        try {
          if (await promoted.exists()) {
            await promoted.delete();
          }
        } catch (_) {}

        return source;
      }

      // We now have a proven-good canonical copy. Remove only the old duplicate.
      try {
        if (await source.exists()) {
          await source.delete();
        }
      } catch (e) {
        Logger.warning(
          'Canonical migration succeeded but old duplicate '
          'could not be removed: $e',
        );
      }

      Logger.info(
        'Migrated verified model by streaming copy: '
        '$sourcePath -> $canonicalPath',
      );

      return promoted;
    } catch (e, st) {
      Logger.error(
        'Safe model migration failed: $e',
      );

      Logger.error(
        '$st',
      );

      // Never remove the verified source on migration failure.
      try {
        if (await migrationFile.exists()) {
          await migrationFile.delete();
        }
      } catch (_) {}

      return source;
    }
  }

  /// Repairs BOTH ReWoo's download state and flutter_gemma 0.10.6's model
  /// registration after a physical model has been verified.
  Future<bool> _registerVerifiedModel(
    File verifiedFile,
  ) async {
    final size =
        await verifiedFile.length();

    final documents =
        await getApplicationDocumentsDirectory();

    final canonical =
        File(
      '${documents.path}/$modelName',
    );

    final verifiedPath =
        verifiedFile.absolute.path;

    bool canonicalReady =
        false;

    try {
      final prefs =
          await SharedPreferences.getInstance();

      // Always remember the actual verified path.
      await prefs.setString(
        _resolvedModelPathKey,
        verifiedPath,
      );

      // flutter_gemma 0.10.6 resolves this filename inside
      // getApplicationDocumentsDirectory().
      //
      // Register only after the canonical physical file is proven valid.
      if (await canonical.exists()) {
        final canonicalVerification =
            await _verifyFinalFile(
          canonical,
          verifyChecksum: false,
        );

        if (canonicalVerification.valid) {
          await prefs.setString(
            _flutterGemmaInstalledModelFileNameKey,
            modelName,
          );

          canonicalReady =
              true;

          Logger.info(
            'Registered verified model for flutter_gemma: '
            '$modelName',
          );
        }
      }
    } catch (e) {
      Logger.warning(
        'Could not repair flutter_gemma model registration: $e',
      );
    }

    if (canonicalReady) {
      // Physical canonical model is the source of truth.
      //
      // Repair stale/lost app metadata so restart never triggers a fresh
      // 3+ GB download merely because SharedPreferences was out of sync.
      try {
        await DownloadStateManager
            .saveDownloadCompleted(
          downloadedBytes:
              size,
          expectedBytes:
              expectedModelFileSize,
          verified:
              true,
        );
      } catch (e) {
        Logger.warning(
          'Could not repair completed download state: $e',
        );
      }

      setDownloadStatus(
        DownloadStatus.completed,
      );

      setErrorMessages([]);

      return true;
    }

    // A valid legacy file exists but could not be promoted to the canonical
    // path. Preserve it and block fresh download, but do not pretend the
    // current Gemma runtime can already open the canonical path.
    setDownloadStatus(
      DownloadStatus.failed,
    );

    setErrorMessages([
      'আগের সম্পূর্ণ AI model file পাওয়া গেছে এবং নিরাপদ রাখা হয়েছে। '
          'কিন্তু সেটিকে app-এর canonical model path-এ migrate করা যায়নি। '
          'Fresh Hugging Face download শুরু করা হবে না।',
    ]);

    return false;
  }

  /// Verifies whether a usable final model already exists.
  ///
  /// Physical verified model bytes are the primary source of truth.
  ///
  /// Recovery priority:
  ///
  /// 1. canonical ApplicationDocuments/modelName
  /// 2. completed downloader task locations
  /// 3. previously verified/legacy app-owned locations
  /// 4. app cache/support/external app directory scan
  ///
  /// A valid legacy model is migrated to the canonical location when possible.
  ///
  /// Recoverable .part data is NEVER deleted here.
  Future<bool> checkIfModelExists() async {
    _verifiedModelFoundButNotCanonical = false;

    try {
      // getAllTasks() also allows DownloadManager to finalize completed:
      //
      // modelName.part -> modelName
      final tasks =
          await DownloadManager
              .getAllTasks();

      final recovery =
          await DownloadStateManager
              .getRecoveryState();

      final candidatePaths =
          await _discoverFinalModelPaths(
        tasks,
      );

      for (final path
          in candidatePaths) {
        final file =
            File(
          path,
        );

        if (!await file.exists()) {
          continue;
        }

        final associatedTask =
            _associatedTaskForPath(
          tasks,
          path,
        );

        // -------------------------------------------------------------------
        // An active legacy downloader may write directly to modelName.
        //
        // Never treat 98-99% of an active transfer as a finished model.
        // -------------------------------------------------------------------

        if (associatedTask != null &&
            _isTaskActivelyWriting(
              associatedTask,
            )) {
          Logger.info(
            'Preserving active model artifact without final validation: '
            '$path, '
            'task=${associatedTask.taskId}, '
            'status=${associatedTask.status}',
          );

          continue;
        }

        // A failed legacy task can occasionally have a stale status even when
        // the full file landed. To avoid accepting a 98-99% file, require the
        // exact published size before overriding a FAILED task status.
        if (associatedTask?.status ==
            DownloadTaskStatus.failed) {
          final size =
              await file.length();

          if (size <
              expectedModelFileSize) {
            Logger.info(
              'Failed task artifact is not full size; '
              'preserving for recovery: '
              '$path ($size bytes)',
            );

            continue;
          }
        }

        // If app state already says verified, avoid an expensive repeated hash
        // on every launch. Newly discovered/unverified files still get the
        // configured SHA-256 check when MODEL_SHA256 is provided.
        final verifyChecksum =
            !recovery.verified;

        final verification =
            await _verifyFinalFile(
          file,
          verifyChecksum:
              verifyChecksum,
        );

        if (verification.valid) {
          Logger.info(
            'Verified physical model found: '
            '$path '
            '(${verification.size} bytes)',
          );

          // Promote old/cache/task locations into the canonical model path.
          final resolved =
              await _promoteVerifiedModelToCanonical(
            file,
          );

          final resolvedVerification =
              await _verifyFinalFile(
            resolved,
            verifyChecksum: false,
          );

          if (!resolvedVerification.valid) {
            // This should be extremely rare because the source was already
            // verified. Preserve everything and block fresh-download logic.
            Logger.error(
              'Verified model became unreadable during path recovery. '
              'No fresh download will be started from this check.',
            );

            try {
              final prefs =
                  await SharedPreferences.getInstance();

              await prefs.setString(
                _resolvedModelPathKey,
                path,
              );
            } catch (_) {}

            _verifiedModelFoundButNotCanonical = true;

            setDownloadStatus(
              DownloadStatus.failed,
            );

            setErrorMessages([
              'আগের সম্পূর্ণ model file পাওয়া গেছে, কিন্তু canonical storage '
                  'path-এ recover করা যায়নি। File delete করা হয়নি এবং fresh '
                  'download শুরু করা হবে না।',
            ]);

            return true;
          }

          final canonicalReady =
              await _registerVerifiedModel(
            resolved,
          );

          _verifiedModelFoundButNotCanonical =
              !canonicalReady;

          Logger.info(
            canonicalReady
                ? 'Existing canonical model accepted. '
                    'Fresh Hugging Face download is blocked.'
                : 'Verified legacy model found but canonical migration is '
                    'not complete. Fresh Hugging Face download is blocked.',
          );

          return true;
        }

        // -------------------------------------------------------------------
        // INVALID FINAL FILE DELETION POLICY
        //
        // Delete only when completion is provable.
        // Unknown legacy/cache artifacts are preserved.
        // -------------------------------------------------------------------

        final pathIsCanonical =
            path ==
                '${(await getApplicationDocumentsDirectory()).path}/$modelName';

        final finalWasSupposedToBeComplete =
            associatedTask?.status ==
                    DownloadTaskStatus
                        .complete ||
                (pathIsCanonical &&
                    (recovery.completed ||
                        recovery.status ==
                            DownloadStateManager
                                .verifying));

        if (finalWasSupposedToBeComplete) {
          Logger.error(
            'Provably completed final model failed verification: '
            '$path '
            'reason=${verification.reason}',
          );

          try {
            await file.delete();

            Logger.info(
              'Deleted verified corrupt completed final model: '
              '$path',
            );
          } catch (e) {
            Logger.error(
              'Could not delete corrupt completed final model: $e',
            );
          }

          continue;
        }

        Logger.warning(
          'Non-valid but unproven model artifact preserved: '
          '$path '
          'reason=${verification.reason}',
        );
      }

      return false;
    } catch (e, st) {
      Logger.error(
        'Model discovery/verification failed: $e',
      );

      Logger.error(
        '$st',
      );

      // A failed verification pass is NOT permission to delete anything.
      return false;
    }
  }

  // ===========================================================================
  // FINAL DOWNLOAD COMPLETION
  // ===========================================================================

  Future<bool> _verifyCompletedDownload({
    required String taskId,
    required BuildContext? context,
  }) async {
    final tasks =
        await DownloadManager
            .getAllTasks();

    final task =
        _findTaskById(
      tasks,
      taskId,
    );

    final total =
        _expectedBytes > 0
            ? _expectedBytes
            : expectedModelFileSize;

    final partialPath =
        task != null
            ? _taskPartialFilePath(
                task,
              )
            : await _defaultPartialFilePath();

    await DownloadStateManager
        .saveDownloadVerifying(
      taskId: taskId,
      downloadedBytes: total,
      expectedBytes: total,
      partialFilePath:
          partialPath,
    );

    Logger.info(
      'Native task reached completion. '
      'Performing application-level final verification.',
    );

    // DownloadManager.getAllTasks() performs manager-level finalization for
    // background_downloader:
    //
    // modelName.part
    //   -> size verification
    //   -> atomic rename
    //   -> modelName
    //
    // We now independently verify the final output again.
    final valid =
        await checkIfModelExists();

    if (!valid) {
      await DownloadStateManager
          .saveDownloadFailedRecoverable(
        taskId: taskId,
        progressPercent: 100,
        downloadedBytes:
            total,
        expectedBytes:
            total,
        partialFilePath:
            partialPath,
      );

      setDownloadStatus(
        DownloadStatus.failed,
      );

      setErrorMessages([
        'মডেল ডাউনলোড ১০০% দেখালেও final verification ব্যর্থ হয়েছে। '
            'ফাইল অসম্পূর্ণ, corrupt, অথবা checksum মিলেনি। '
            'Corrupt final file থাকলে সেটি সরানো হয়েছে। '
            'আংশিক recoverable data স্বয়ংক্রিয়ভাবে মুছে ফেলা হয়নি।',
      ]);

      Logger.error(
        'Model completion verification failed.',
      );

      return false;
    }

    await DownloadStateManager
        .saveDownloadCompleted(
      downloadedBytes:
          total,
      expectedBytes:
          total,
      verified: true,
    );

    setDownloadStatus(
      DownloadStatus.completed,
    );

    setErrorMessages([]);

    setProgress(
      DownloadProgress(
        totalBytes: total,
        downloadedBytes:
            total,
        downloadRate: 0,
        remainingTime:
            Duration.zero,
        status:
            DownloadTaskStatus.complete,
      ),
    );

    Logger.info(
      'Model download finalized and verified successfully.',
    );

    if (context != null &&
        context.mounted) {
      Navigator.of(context)
          .pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              const ChatPage(),
        ),
      );
    }

    return true;
  }

  // ===========================================================================
  // SAFE STALE-ARTIFACT CLEANUP
  // ===========================================================================

  /// Removes ONLY zero-byte stale files.
  ///
  /// Non-empty .part files are always preserved unless explicit user delete
  /// occurs elsewhere.
  Future<void>
      _cleanupStaleModelArtifacts() async {
    try {
      final dir =
          await getApplicationDocumentsDirectory();

      final tasks =
          await DownloadManager
              .getAllTasks();

      final protectedPaths =
          <String>{};

      for (final task in tasks) {
        if (!_isModelTask(
              task,
            ) ||
            !_isRecoverableStatus(
              task.status,
            )) {
          continue;
        }

        final finalPath =
            _taskFinalFilePath(
          task,
        );

        final partPath =
            _taskPartialFilePath(
          task,
        );

        if (finalPath != null) {
          protectedPaths.add(
            finalPath,
          );
        }

        if (partPath != null) {
          protectedPaths.add(
            partPath,
          );
        }
      }

      await for (final entity
          in dir.list()) {
        if (entity is! File) {
          continue;
        }

        final filename =
            entity.uri.pathSegments
                .last
                .toLowerCase();

        final lowerModel =
            modelName.toLowerCase();

        final relevant =
            filename ==
                    lowerModel ||
                filename ==
                    '$lowerModel.part' ||
                filename.startsWith(
                  '$lowerModel.',
                );

        if (!relevant) {
          continue;
        }

        final size =
            await entity.length();

        if (protectedPaths
            .contains(
          entity.path,
        )) {
          Logger.debug(
            'Preserving active model artifact: '
            '${entity.path}',
          );

          continue;
        }

        // Non-empty unknown file:
        // preserve conservatively.
        if (size > 0) {
          Logger.info(
            'Preserving non-empty model artifact: '
            '${entity.path} '
            '($size bytes)',
          );

          continue;
        }

        try {
          await entity.delete();

          Logger.info(
            'Deleted zero-byte stale artifact: '
            '${entity.path}',
          );
        } catch (e) {
          Logger.warning(
            'Could not delete zero-byte artifact: $e',
          );
        }
      }
    } catch (e) {
      Logger.error(
        'Safe artifact cleanup failed: $e',
      );
    }
  }

  // ===========================================================================
  // RESTORE PROGRESS VARIABLES FROM PERSISTENT STATE
  // ===========================================================================

  Future<void>
      _restoreProgressState() async {
    final recovery =
        await DownloadStateManager
            .getRecoveryState();

    _expectedBytes =
        recovery.expectedBytes > 0
            ? recovery.expectedBytes
            : expectedModelFileSize;

    _lastSampledPercent =
        recovery.progressPercent;

    _lastPersistedPercent =
        recovery.progressPercent;

    _lastSampleTime =
        DateTime.now();

    _downloadRate = 0;
  }

  // ===========================================================================
  // REUSE EXISTING TASK
  // ===========================================================================

  Future<bool>
      _reuseExistingModelTask({
    BuildContext? context,
  }) async {
    try {
      final tasks =
          await DownloadManager
              .getAllTasks();

      final existing =
          _latestRecoverableModelTask(
        tasks,
      );

      if (existing == null) {
        return false;
      }

      Logger.info(
        'Existing recoverable model task found: '
        '${existing.taskId}, '
        'status=${existing.status}, '
        'progress=${existing.progress}%',
      );

      await _restoreProgressState();

      DownloadManager.attachToTask(
        existing.taskId,
      );

      final total =
          _expectedBytes > 0
              ? _expectedBytes
              : expectedModelFileSize;

      final downloaded =
          ((existing.progress / 100) *
                  total)
              .round();

      final partialPath =
          _taskPartialFilePath(
        existing,
      );

      switch (existing.status) {
        // -------------------------------------------------------------------
        // ACTIVE
        // -------------------------------------------------------------------

        case DownloadTaskStatus.running:
        case DownloadTaskStatus.enqueued:
          await DownloadStateManager
              .saveDownloadInProgress(
            existing.taskId,
            progressPercent:
                existing.progress,
            downloadedBytes:
                downloaded,
            expectedBytes:
                total,
            partialFilePath:
                partialPath,
          );

          setDownloadStatus(
            DownloadStatus.downloading,
          );

          monitorDownload(
            existing.taskId,
            context,
          );

          return true;

        // -------------------------------------------------------------------
        // PAUSED
        // -------------------------------------------------------------------

        case DownloadTaskStatus.paused:
          await DownloadStateManager
              .saveDownloadPaused(
            taskId:
                existing.taskId,
            progressPercent:
                existing.progress,
            downloadedBytes:
                downloaded,
            expectedBytes:
                total,
            partialFilePath:
                partialPath,
          );

          final resumed =
              await DownloadManager
                  .resumeDownload();

          if (resumed != null) {
            await DownloadStateManager
                .saveDownloadInProgress(
              resumed,
              progressPercent:
                  existing.progress,
              downloadedBytes:
                  downloaded,
              expectedBytes:
                  total,
              partialFilePath:
                  partialPath,
            );

            setDownloadStatus(
              DownloadStatus.downloading,
            );

            monitorDownload(
              resumed,
              context,
            );
          } else {
            await _markRecoverableFailure(
              taskId:
                  existing.taskId,
              progressPercent:
                  existing.progress,
              downloadedBytes:
                  downloaded,
              expectedBytes:
                  total,
              partialFilePath:
                  partialPath,
              message:
                  'ডাউনলোডটি pause অবস্থায় আছে, কিন্তু এখনই resume করা যায়নি। '
                  'আগের ${existing.progress}% progress নিরাপদ রাখা হয়েছে। '
                  'ইন্টারনেট সংযোগ ঠিক করে আবার চেষ্টা করুন।',
            );
          }

          return true;

        // -------------------------------------------------------------------
        // FAILED BUT RECOVERABLE
        // -------------------------------------------------------------------

        case DownloadTaskStatus.failed:
          await DownloadStateManager
              .saveDownloadFailedRecoverable(
            taskId:
                existing.taskId,
            progressPercent:
                existing.progress,
            downloadedBytes:
                downloaded,
            expectedBytes:
                total,
            partialFilePath:
                partialPath,
          );

          final retried =
              await DownloadManager
                  .retryDownload();

          if (retried != null) {
            await DownloadStateManager
                .saveDownloadInProgress(
              retried,
              progressPercent:
                  existing.progress,
              downloadedBytes:
                  downloaded,
              expectedBytes:
                  total,
              partialFilePath:
                  partialPath,
            );

            setDownloadStatus(
              DownloadStatus.downloading,
            );

            monitorDownload(
              retried,
              context,
            );
          } else {
            await _markRecoverableFailure(
              taskId:
                  existing.taskId,
              progressPercent:
                  existing.progress,
              downloadedBytes:
                  downloaded,
              expectedBytes:
                  total,
              partialFilePath:
                  partialPath,
              message:
                  'আগের download task এখনই resume করা যায়নি। '
                  'ডাউনলোড করা ${existing.progress}% data মুছে ফেলা হয়নি। '
                  'আবার চেষ্টা করলে একই task recover করার চেষ্টা করা হবে।',
            );
          }

          return true;

        default:
          return false;
      }
    } catch (e) {
      Logger.error(
        'Existing task recovery failed: $e',
      );

      return false;
    }
  }

  // ===========================================================================
  // STARTUP RECOVERY
  // ===========================================================================

  Future<void> checkForOngoingDownloads(
    BuildContext context,
  ) async {

    // =======================================================================
    // PHYSICAL MODEL WINS OVER STALE METADATA
    // =======================================================================
    //
    // This MUST run before interpreting old SharedPreferences state.
    //
    // Example:
    //
    // final 3.14 GB model exists
    // + saved state still says failed/downloading
    //
    // OLD behavior:
    //   recover/start download flow
    //
    // NEW behavior:
    //   verify physical model
    //   repair completed state
    //   go directly to ChatPage
    //
    try {
      if (await checkIfModelExists()) {
        final documents =
            await getApplicationDocumentsDirectory();

        final canonical =
            File(
          '${documents.path}/$modelName',
        );

        bool canonicalReady =
            false;

        int canonicalSize =
            0;

        if (await canonical.exists()) {
          final verification =
              await _verifyFinalFile(
            canonical,
            verifyChecksum: false,
          );

          canonicalReady =
              verification.valid;

          canonicalSize =
              verification.size;
        }

        if (!canonicalReady) {
          // A valid legacy model may have been discovered but migration could
          // not complete. Do not auto-download another copy and do not enter
          // ChatPage until Gemma has a canonical usable model.
          setDownloadStatus(
            DownloadStatus.failed,
          );

          setErrorMessages([
            'আগের সম্পূর্ণ AI model file পাওয়া গেছে, কিন্তু canonical '
                'storage path-এ migrate করা যায়নি। File delete করা হয়নি এবং '
                'নতুন Hugging Face download স্বয়ংক্রিয়ভাবে শুরু হবে না।',
          ]);

          return;
        }

        setDownloadStatus(
          DownloadStatus.completed,
        );

        setErrorMessages([]);

        await DownloadStateManager
            .saveDownloadCompleted(
          downloadedBytes:
              canonicalSize,
          expectedBytes:
              expectedModelFileSize,
          verified:
              true,
        );

        WidgetsBinding.instance
            .addPostFrameCallback(
          (_) {
            if (!context.mounted) {
              return;
            }

            Navigator.of(context)
                .pushReplacement(
              MaterialPageRoute(
                builder: (_) =>
                    const ChatPage(),
              ),
            );
          },
        );

        return;
      }
    } catch (e, st) {
      Logger.warning(
        'Physical-model startup guard could not complete: $e',
      );

      Logger.debug(
        '$st',
      );

      // Continue into non-destructive recovery logic below.
    }

    try {
      final recovery =
          await DownloadStateManager
              .getRecoveryState();

      Logger.info(
        'Persistent download recovery state: '
        '$recovery',
      );

      _expectedBytes =
          recovery.expectedBytes > 0
              ? recovery.expectedBytes
              : expectedModelFileSize;

      // -----------------------------------------------------------------------
      // COMPLETED + VERIFIED
      // -----------------------------------------------------------------------

      if (recovery.status ==
              DownloadStateManager
                  .completed &&
          recovery.verified) {
        if (await checkIfModelExists()) {
          setDownloadStatus(
            DownloadStatus.completed,
          );

          WidgetsBinding.instance
              .addPostFrameCallback(
            (_) {
              if (!context.mounted) {
                return;
              }

              Navigator.of(context)
                  .pushReplacement(
                MaterialPageRoute(
                  builder: (_) =>
                      const ChatPage(),
                ),
              );
            },
          );

          return;
        }

        // Metadata said verified, but final model disappeared or became
        // invalid. No partial file is destroyed here.
        setDownloadStatus(
          DownloadStatus.failed,
        );

        setErrorMessages([
          'আগে verified model ছিল, কিন্তু final model file এখন পাওয়া যাচ্ছে না '
              'অথবা file validation ব্যর্থ হয়েছে। নতুন করে model download করতে হবে।',
        ]);

        Logger.error(
          'Persistent state said completed/verified but final model is invalid.',
        );

        return;
      }

      // -----------------------------------------------------------------------
      // VERIFYING
      //
      // App may have been killed after 100% but before final verification or
      // .part -> final state was persisted.
      // -----------------------------------------------------------------------

      if (recovery.status ==
          DownloadStateManager
              .verifying) {
        Logger.info(
          'Recovering interrupted model verification.',
        );

        // getAllTasks() lets DownloadManager finalize any completed .part file.
        final tasks =
            await DownloadManager
                .getAllTasks();

        DownloadTask? task;

        if (recovery.taskId !=
            null) {
          task =
              _findTaskById(
            tasks,
            recovery.taskId!,
          );
        }

        if (await checkIfModelExists()) {
          await DownloadStateManager
              .saveDownloadCompleted(
            downloadedBytes:
                recovery.downloadedBytes,
            expectedBytes:
                recovery.expectedBytes >
                        0
                    ? recovery
                        .expectedBytes
                    : expectedModelFileSize,
            verified: true,
          );

          setDownloadStatus(
            DownloadStatus.completed,
          );

          WidgetsBinding.instance
              .addPostFrameCallback(
            (_) {
              if (!context.mounted) {
                return;
              }

              Navigator.of(context)
                  .pushReplacement(
                MaterialPageRoute(
                  builder: (_) =>
                      const ChatPage(),
                ),
              );
            },
          );

          return;
        }

        // If the task still exists and is not actually complete, recover it
        // rather than starting over.
        if (task != null &&
            _isRecoverableStatus(
              task.status,
            )) {
          DownloadManager.attachToTask(
            task.taskId,
          );

          await _handleRecoveredTask(
            task,
            context,
          );

          return;
        }

        await DownloadStateManager
            .saveDownloadFailedRecoverable(
          taskId:
              recovery.taskId,
          progressPercent:
              recovery.progressPercent,
          downloadedBytes:
              recovery.downloadedBytes,
          expectedBytes:
              recovery.expectedBytes,
          partialFilePath:
              recovery.partialFilePath,
        );

        setDownloadStatus(
          DownloadStatus.failed,
        );

        setErrorMessages([
          'মডেল ১০০% হওয়ার পর verification সম্পন্ন করা যায়নি। '
              'Partial/final recovery data মুছে ফেলা হয়নি। '
              'আবার চেষ্টা করলে verification/recovery পুনরায় চেষ্টা করা হবে।',
        ]);

        return;
      }

      // -----------------------------------------------------------------------
      // DOWNLOADING / PAUSED / FAILED_RECOVERABLE
      // -----------------------------------------------------------------------

      if (recovery.isRecoverable) {
        final tasks =
            await DownloadManager
                .getAllTasks();

        DownloadTask? task;

        if (recovery.taskId !=
            null) {
          task =
              _findTaskById(
            tasks,
            recovery.taskId!,
          );
        }

        // Exact task ID survived.
        if (task != null) {
          DownloadManager.attachToTask(
            task.taskId,
          );

          await _handleRecoveredTask(
            task,
            context,
          );

          return;
        }

        // Task ID may have changed after native resume or a migration.
        final latest =
            _latestRecoverableModelTask(
          tasks,
        );

        if (latest != null) {
          Logger.warning(
            'Saved task ID not found; '
            'using newest recoverable model task '
            '${latest.taskId}.',
          );

          DownloadManager.attachToTask(
            latest.taskId,
          );

          await _handleRecoveredTask(
            latest,
            context,
          );

          return;
        }

        // -------------------------------------------------------------------
        // IMPORTANT:
        // Saved recovery state exists but native task disappeared.
        //
        // DO NOT start a fresh download automatically.
        // DO NOT delete the saved partial path.
        // -------------------------------------------------------------------

        await DownloadStateManager
            .saveDownloadFailedRecoverable(
          taskId:
              recovery.taskId,
          progressPercent:
              recovery.progressPercent,
          downloadedBytes:
              recovery.downloadedBytes,
          expectedBytes:
              recovery.expectedBytes,
          partialFilePath:
              recovery.partialFilePath,
        );

        setDownloadStatus(
          DownloadStatus.failed,
        );

        setErrorMessages([
          'আগের download task Android-এর task database-এ পাওয়া যাচ্ছে না। '
              'তবে আগের progress এবং partial file information মুছে ফেলা হয়নি। '
              'Fresh download স্বয়ংক্রিয়ভাবে শুরু করা হয়নি।',
        ]);

        return;
      }

      // -----------------------------------------------------------------------
      // NO PERSISTED ACTIVE STATE
      //
      // First verify final model.
      // -----------------------------------------------------------------------

      if (await checkIfModelExists()) {
        await DownloadStateManager
            .saveDownloadCompleted(
          downloadedBytes:
              expectedModelFileSize,
          expectedBytes:
              expectedModelFileSize,
          verified: true,
        );

        setDownloadStatus(
          DownloadStatus.completed,
        );

        return;
      }

      // Native database may still contain a task even if SharedPreferences
      // were lost/upgraded.
      final reused =
          await _reuseExistingModelTask(
        context: context,
      );

      if (reused) {
        return;
      }

      // Nothing exists.
      setDownloadStatus(
        DownloadStatus.notStarted,
      );
    } catch (e, st) {
      Logger.error(
        'Startup download recovery failed: $e',
      );

      Logger.error(
        '$st',
      );

      setDownloadStatus(
        DownloadStatus.failed,
      );

      setErrorMessages([
        _friendlyExceptionMessage(
          e,
          fallback:
              'আগের ডাউনলোডের অবস্থা পরীক্ষা করা যায়নি। '
              'Partial download data নিরাপদ রাখা হয়েছে।',
        ),
      ]);
    }
  }

  Future<void> _handleRecoveredTask(
    DownloadTask task,
    BuildContext? context,
  ) async {
    final total =
        _expectedBytes > 0
            ? _expectedBytes
            : expectedModelFileSize;

    final downloaded =
        ((task.progress / 100) *
                total)
            .round();

    final partialPath =
        _taskPartialFilePath(
      task,
    );

    switch (task.status) {
      case DownloadTaskStatus.running:
      case DownloadTaskStatus.enqueued:
        await DownloadStateManager
            .saveDownloadInProgress(
          task.taskId,
          progressPercent:
              task.progress,
          downloadedBytes:
              downloaded,
          expectedBytes:
              total,
          partialFilePath:
              partialPath,
        );

        setDownloadStatus(
          DownloadStatus.downloading,
        );

        monitorDownload(
          task.taskId,
          context,
        );

        return;

      case DownloadTaskStatus.paused:
        await DownloadStateManager
            .saveDownloadPaused(
          taskId:
              task.taskId,
          progressPercent:
              task.progress,
          downloadedBytes:
              downloaded,
          expectedBytes:
              total,
          partialFilePath:
              partialPath,
        );

        final resumed =
            await DownloadManager
                .resumeDownload();

        if (resumed != null) {
          await DownloadStateManager
              .saveDownloadInProgress(
            resumed,
            progressPercent:
                task.progress,
            downloadedBytes:
                downloaded,
            expectedBytes:
                total,
            partialFilePath:
                partialPath,
          );

          setDownloadStatus(
            DownloadStatus.downloading,
          );

          monitorDownload(
            resumed,
            context,
          );
        } else {
          await _markRecoverableFailure(
            taskId:
                task.taskId,
            progressPercent:
                task.progress,
            downloadedBytes:
                downloaded,
            expectedBytes:
                total,
            partialFilePath:
                partialPath,
            message:
                'ডাউনলোড pause অবস্থায় আছে কিন্তু এখন resume করা যাচ্ছে না। '
                'আগের progress রাখা হয়েছে।',
          );
        }

        return;

      case DownloadTaskStatus.failed:
        await DownloadStateManager
            .saveDownloadFailedRecoverable(
          taskId:
              task.taskId,
          progressPercent:
              task.progress,
          downloadedBytes:
              downloaded,
          expectedBytes:
              total,
          partialFilePath:
              partialPath,
        );

        await _autoRecoverOrFail(
          task.taskId,
          context,
        );

        return;

      case DownloadTaskStatus.complete:
        await _verifyCompletedDownload(
          taskId:
              task.taskId,
          context:
              context,
        );

        return;

      case DownloadTaskStatus.canceled:
        await _markRecoverableFailure(
          taskId:
              task.taskId,
          progressPercent:
              task.progress,
          downloadedBytes:
              downloaded,
          expectedBytes:
              total,
          partialFilePath:
              partialPath,
          message:
              'Download task canceled অবস্থায় পাওয়া গেছে। '
              'যদি partial data থাকে সেটি automatic delete করা হয়নি।',
        );

        return;

      case DownloadTaskStatus.undefined:
        await _markRecoverableFailure(
          taskId:
              task.taskId,
          progressPercent:
              task.progress,
          downloadedBytes:
              downloaded,
          expectedBytes:
              total,
          partialFilePath:
              partialPath,
          message:
              'Download task-এর অবস্থা নির্ধারণ করা যাচ্ছে না। '
              'আগের progress মুছে ফেলা হয়নি।',
        );

        return;
    }
  }

  // ===========================================================================
  // AUTO START CHECK
  // ===========================================================================

  Future<bool>
      canAutoStartDownload() async {
    if (await checkIfModelExists()) {
      return false;
    }

    final recovery =
        await DownloadStateManager
            .getRecoveryState();

    if (recovery.isRecoverable ||
        recovery.status ==
            DownloadStateManager
                .verifying ||
        recovery.isReady) {
      return false;
    }

    final tasks =
        await DownloadManager
            .getAllTasks();

    if (_latestRecoverableModelTask(
          tasks,
        ) !=
        null) {
      return false;
    }

    if (hfTokenConfigured) {
      return true;
    }

    final tokenStatus =
        await TokenManager
            .getTokenStatus();

    if (tokenStatus ==
        TokenStatus.valid) {
      return true;
    }

    final code =
        await DownloadManager
            .checkModelAccess(
      downloadUrl,
    );

    if (code == 200 ||
        code == 302) {
      return true;
    }

    return false;
  }

  // ===========================================================================
  // START DOWNLOAD / AUTH
  // ===========================================================================

  Future<void> startDownload({
    bool autoStart = false,
  }) async {

    // HARD DUPLICATE-DOWNLOAD GUARD.
    //
    // A verified physical model always wins over auth/token/download flow.
    if (await checkIfModelExists()) {
      Logger.info(
        'startDownload() blocked because a verified model already exists.',
      );

      if (!_verifiedModelFoundButNotCanonical) {
        setDownloadStatus(
          DownloadStatus.completed,
        );

        setErrorMessages([]);
      }

      return;
    }

    setDownloadStatus(
      DownloadStatus.checkingAccess,
    );

    setErrorMessages([]);

    Logger.info(
      'Starting model download flow for '
      '$modelFullName',
    );

    // -----------------------------------------------------------------------
    // Recovery ALWAYS comes before fresh authentication/download.
    // -----------------------------------------------------------------------

    final reused =
        await _reuseExistingModelTask();

    if (reused) {
      return;
    }

    final recovery =
        await DownloadStateManager
            .getRecoveryState();

    if (recovery.isRecoverable) {
      setDownloadStatus(
        DownloadStatus.failed,
      );

      setErrorMessages([
        'আগের download recovery state এখনো আছে। '
            'Fresh download শুরু করে আগের progress overwrite করা হবে না। '
            'আগের task recover/resume করুন অথবা download explicitly cancel করুন।',
      ]);

      return;
    }

    // -----------------------------------------------------------------------
    // 1. Anonymous access
    // -----------------------------------------------------------------------

    final anonymousCode =
        await DownloadManager
            .checkModelAccess(
      downloadUrl,
    );

    Logger.info(
      'Anonymous model access: '
      '$anonymousCode',
    );

    if (anonymousCode == 200 ||
        anonymousCode == 302) {
      await downloadModel(
        null,
      );

      return;
    }

    if (anonymousCode < 0) {
      handleError(
        'ইন্টারনেট সংযোগ পাওয়া যাচ্ছে না। '
        'Wi-Fi বা mobile data চালু আছে কিনা পরীক্ষা করুন।',
      );

      return;
    }

    // -----------------------------------------------------------------------
    // 2. Bundled developer token
    // -----------------------------------------------------------------------

    if (hfTokenConfigured) {
      setDownloadStatus(
        DownloadStatus.authenticating,
      );

      final devCode =
          await DownloadManager
              .checkModelAccess(
        downloadUrl,
        hfAppToken,
      );

      if (devCode == 200 ||
          devCode == 302) {
        await downloadModel(
          hfAppToken,
        );

        return;
      }

      if (devCode == 403) {
        Logger.warning(
          'Developer token does not have Gemma license access.',
        );
      } else if (devCode == 401) {
        Logger.warning(
          'Developer Hugging Face token is invalid/expired.',
        );
      } else if (devCode < 0) {
        handleError(
          'Hugging Face server-এর সাথে connection করা যাচ্ছে না। '
          'ইন্টারনেট সংযোগ পরীক্ষা করুন।',
        );

        return;
      }
    }

    // -----------------------------------------------------------------------
    // 3. Stored user token
    // -----------------------------------------------------------------------

    final tokenStatus =
        await TokenManager
            .getTokenStatus();

    if (tokenStatus ==
        TokenStatus.valid) {
      setDownloadStatus(
        DownloadStatus.authenticating,
      );

      final token =
          await TokenManager
              .getStoredToken();

      final storedCode =
          await DownloadManager
              .checkModelAccess(
        downloadUrl,
        token?.accessToken,
      );

      if (storedCode == 200 ||
          storedCode == 302) {
        await downloadModel(
          token?.accessToken,
        );

        return;
      }

      if (storedCode == 403) {
        showUserAgreement();

        return;
      }

      if (storedCode == 401) {
        Logger.warning(
          'Stored Hugging Face login is no longer valid.',
        );
      }

      if (storedCode < 0) {
        handleError(
          'Hugging Face server-এর সাথে connection করা যাচ্ছে না। '
          'ইন্টারনেট সংযোগ পরীক্ষা করুন।',
        );

        return;
      }
    }

    // -----------------------------------------------------------------------
    // 4. Interactive login
    // -----------------------------------------------------------------------

    if (autoStart) {
      setDownloadStatus(
        DownloadStatus.notStarted,
      );

      setErrorMessages([
        'প্রথমবার model download করার জন্য একবার Hugging Face login প্রয়োজন। '
            '"ডাউনলোড" বোতাম চাপুন। Login শেষ হলে download শুরু হবে।',
      ]);

      return;
    }

    await startOAuthFlow();
  }

  // ===========================================================================
  // OAUTH
  // ===========================================================================

  Future<void> startOAuthFlow() async {
    setDownloadStatus(
      DownloadStatus.authenticating,
    );

    try {
      final authUrl =
          await HuggingFaceOAuth
              .generateAuthUrl();

      final result =
          await FlutterWebAuth2
              .authenticate(
        url: authUrl,
        callbackUrlScheme:
            hfCallbackUrlScheme,
      );

      final uri =
          Uri.parse(
        result,
      );

      final code =
          uri.queryParameters[
            'code'
          ];

      if (code != null) {
        await handleAuthorizationCode(
          code,
        );

        return;
      }

      final oauthError =
          uri.queryParameters[
            'error'
          ];

      if (oauthError != null) {
        handleError(
          'Hugging Face অনুমোদন দেয়নি: $oauthError',
        );

        return;
      }

      handleError(
        'Hugging Face login সম্পন্ন হয়নি। আবার চেষ্টা করুন।',
      );
    } catch (e) {
      final text =
          e.toString()
              .toLowerCase();

      if (text.contains(
            'canceled',
          ) ||
          text.contains(
            'cancelled',
          ) ||
          text.contains(
            'user_canceled',
          )) {
        setDownloadStatus(
          DownloadStatus.notStarted,
        );

        setErrorMessages([]);

        return;
      }

      handleError(
        _friendlyExceptionMessage(
          e,
          fallback:
              'Hugging Face login ব্যর্থ হয়েছে। আবার চেষ্টা করুন।',
        ),
      );
    }
  }

  Future<void>
      handleAuthorizationCode(
    String code,
  ) async {
    setDownloadStatus(
      DownloadStatus.authenticating,
    );

    try {
      final tokenData =
          await HuggingFaceOAuth
              .exchangeCodeForToken(
        code,
      );

      if (tokenData == null) {
        handleError(
          'Hugging Face authorization token পাওয়া যায়নি। আবার চেষ্টা করুন।',
        );

        return;
      }

      final responseCode =
          await DownloadManager
              .checkModelAccess(
        downloadUrl,
        tokenData.accessToken,
      );

      if (responseCode == 200 ||
          responseCode == 302) {
        await downloadModel(
          tokenData.accessToken,
        );

        return;
      }

      if (responseCode == 403) {
        showUserAgreement();

        return;
      }

      if (responseCode == 401) {
        handleError(
          'Hugging Face login সফল হলেও access token গ্রহণ করা হয়নি। '
          'আবার login করুন।',
        );

        return;
      }

      if (responseCode < 0) {
        handleError(
          'Hugging Face server-এর সাথে connection করা যাচ্ছে না। '
          'ইন্টারনেট পরীক্ষা করুন।',
        );

        return;
      }

      handleError(
        'Model access ব্যর্থ হয়েছে। '
        'Server response code: $responseCode',
      );
    } catch (e) {
      handleError(
        _friendlyExceptionMessage(
          e,
          fallback:
              'Hugging Face account verification ব্যর্থ হয়েছে।',
        ),
      );
    }
  }

  // ===========================================================================
  // LICENSE
  // ===========================================================================

  void showUserAgreement() {
    setDownloadStatus(
      DownloadStatus
          .awaitingLicenseAcceptance,
    );

    setShowAgreementSheet(
      true,
    );

    Logger.info(
      'Gemma license acceptance required.',
    );
  }

  Future<void>
      openLicenseAgreement() async {
    setShowAgreementSheet(
      false,
    );

    try {
      final launched =
          await launchUrl(
        Uri.parse(
          modelCardUrl,
        ),
        mode:
            LaunchMode
                .externalApplication,
      );

      if (!launched) {
        setErrorMessages([
          'লাইসেন্স page browser-এ খোলা যায়নি।',
        ]);
      }
    } catch (e) {
      setErrorMessages([
        'লাইসেন্স page খোলা যায়নি: $e',
      ]);
    }

    setDownloadStatus(
      DownloadStatus
          .awaitingLicenseAcceptance,
    );
  }

  void cancelLicenseAgreement() {
    setShowAgreementSheet(
      false,
    );

    setDownloadStatus(
      DownloadStatus.notStarted,
    );
  }

  // ===========================================================================
  // START ACTUAL DOWNLOAD
  // ===========================================================================

  Future<void> downloadModel(
    String? accessToken,
  ) async {

    // FINAL SAFETY GATE:
    //
    // Even if an auth callback reaches this method, never enqueue a new
    // multi-GB task when verified model bytes already exist.
    if (await checkIfModelExists()) {
      Logger.info(
        'downloadModel() blocked because a verified model already exists.',
      );

      if (!_verifiedModelFoundButNotCanonical) {
        setDownloadStatus(
          DownloadStatus.completed,
        );

        setErrorMessages([]);
      }

      return;
    }

    setDownloadStatus(
      DownloadStatus.downloading,
    );

    setErrorMessages([]);

    _autoResumeAttempts =
        0;

    // Never create another task if one already exists.
    if (await _reuseExistingModelTask()) {
      return;
    }

    await _cleanupStaleModelArtifacts();

    _expectedBytes =
        await _resolveExpectedBytes(
      accessToken,
    );

    _lastSampledPercent =
        -1;

    _lastPersistedPercent =
        -1;

    _lastSampleTime =
        DateTime.now();

    _downloadRate =
        0;

    final partPath =
        await _defaultPartialFilePath();

    final taskId =
        await DownloadManager
            .startDownload(
      url:
          downloadUrl,
      fileName:
          modelName,
      accessToken:
          accessToken,
    );

    if (taskId == null) {
      handleError(
        'Model download task তৈরি করা যায়নি। '
        'Storage, network এবং Android background-download permission পরীক্ষা করুন।',
      );

      return;
    }

    await DownloadStateManager
        .saveDownloadInProgress(
      taskId,
      progressPercent: 0,
      downloadedBytes: 0,
      expectedBytes:
          _expectedBytes,
      partialFilePath:
          partPath,
    );

    monitorDownload(
      taskId,
      null,
    );
  }

  // ===========================================================================
  // MONITOR
  // ===========================================================================

  void monitorDownload(
    String taskId,
    BuildContext? context,
  ) {
    _monitoringTimer
        ?.cancel();

    Logger.info(
      'Monitoring model download task: '
      '$taskId',
    );

    _monitoringTimer =
        Timer.periodic(
      const Duration(
        seconds: 1,
      ),
      (
        timer,
      ) async {
        try {
          final tasks =
              await DownloadManager
                  .getAllTasks();

          final task =
              _findTaskById(
            tasks,
            taskId,
          );

          if (task == null) {
            timer.cancel();
            _monitoringTimer =
                null;

            final recovery =
                await DownloadStateManager
                    .getRecoveryState();

            await DownloadStateManager
                .saveDownloadFailedRecoverable(
              taskId:
                  taskId,
              progressPercent:
                  recovery
                      .progressPercent,
              downloadedBytes:
                  recovery
                      .downloadedBytes,
              expectedBytes:
                  recovery
                              .expectedBytes >
                          0
                      ? recovery
                          .expectedBytes
                      : _expectedBytes,
              partialFilePath:
                  recovery
                      .partialFilePath,
            );

            setDownloadStatus(
              DownloadStatus.failed,
            );

            setErrorMessages([
              'Android download task আর খুঁজে পাওয়া যাচ্ছে না। '
                  'আগের downloaded data এবং recovery information মুছে ফেলা হয়নি।',
            ]);

            return;
          }

          final total =
              _expectedBytes > 0
                  ? _expectedBytes
                  : expectedModelFileSize;

          final downloaded =
              ((task.progress /
                          100) *
                      total)
                  .round();

          final now =
              DateTime.now();

          if (_lastSampledPercent >=
                  0 &&
              task.progress >
                  _lastSampledPercent) {
            final milliseconds =
                now
                    .difference(
                      _lastSampleTime,
                    )
                    .inMilliseconds;

            if (milliseconds > 0) {
              final deltaBytes =
                  ((task.progress -
                              _lastSampledPercent) /
                          100) *
                      total;

              final instantRate =
                  deltaBytes /
                      (milliseconds /
                          1000);

              _downloadRate =
                  _downloadRate <= 0
                      ? instantRate
                      : (_downloadRate *
                              0.7) +
                          (instantRate *
                              0.3);
            }
          }

          if (task.progress !=
              _lastSampledPercent) {
            _lastSampledPercent =
                task.progress;

            _lastSampleTime =
                now;
          }

          final remainingBytes =
              (total -
                      downloaded)
                  .clamp(
                    0,
                    total,
                  )
                  .toInt();

          final remainingTime =
              _downloadRate > 1024
                  ? Duration(
                      seconds:
                          (remainingBytes /
                                  _downloadRate)
                              .round(),
                    )
                  : Duration.zero;

          setProgress(
            DownloadProgress(
              totalBytes:
                  total,
              downloadedBytes:
                  downloaded,
              downloadRate:
                  _downloadRate,
              remainingTime:
                  remainingTime,
              status:
                  task.status,
            ),
          );

          // Persist only when percentage changes to avoid unnecessary
          // SharedPreferences writes every second.
          if (task.progress !=
              _lastPersistedPercent) {
            _lastPersistedPercent =
                task.progress;

            await DownloadStateManager
                .saveProgress(
              taskId:
                  task.taskId,
              progressPercent:
                  task.progress,
              downloadedBytes:
                  downloaded,
              expectedBytes:
                  total,
              partialFilePath:
                  _taskPartialFilePath(
                task,
              ),
            );
          }

          switch (task.status) {
            // ===============================================================
            // COMPLETE
            // ===============================================================

            case DownloadTaskStatus.complete:
              timer.cancel();
              _monitoringTimer =
                  null;

              Logger.info(
                'Native model download reports 100%. '
                'Starting final verification.',
              );

              await _verifyCompletedDownload(
                taskId:
                    task.taskId,
                context:
                    context,
              );

              return;

            // ===============================================================
            // FAILED
            // ===============================================================

            case DownloadTaskStatus.failed:
              timer.cancel();
              _monitoringTimer =
                  null;

              await DownloadStateManager
                  .saveDownloadFailedRecoverable(
                taskId:
                    task.taskId,
                progressPercent:
                    task.progress,
                downloadedBytes:
                    downloaded,
                expectedBytes:
                    total,
                partialFilePath:
                    _taskPartialFilePath(
                  task,
                ),
              );

              Logger.warning(
                'Download failed at '
                '${task.progress}%. '
                'Partial data preserved.',
              );

              await _autoRecoverOrFail(
                task.taskId,
                context,
              );

              return;

            // ===============================================================
            // PAUSED
            // ===============================================================

            case DownloadTaskStatus.paused:
              timer.cancel();
              _monitoringTimer =
                  null;

              await DownloadStateManager
                  .saveDownloadPaused(
                taskId:
                    task.taskId,
                progressPercent:
                    task.progress,
                downloadedBytes:
                    downloaded,
                expectedBytes:
                    total,
                partialFilePath:
                    _taskPartialFilePath(
                  task,
                ),
              );

              DownloadManager
                  .attachToTask(
                task.taskId,
              );

              final resumed =
                  await DownloadManager
                      .resumeDownload();

              if (resumed != null) {
                await DownloadStateManager
                    .saveDownloadInProgress(
                  resumed,
                  progressPercent:
                      task.progress,
                  downloadedBytes:
                      downloaded,
                  expectedBytes:
                      total,
                  partialFilePath:
                      _taskPartialFilePath(
                    task,
                  ),
                );

                setDownloadStatus(
                  DownloadStatus
                      .downloading,
                );

                monitorDownload(
                  resumed,
                  context,
                );
              } else {
                await _markRecoverableFailure(
                  taskId:
                      task.taskId,
                  progressPercent:
                      task.progress,
                  downloadedBytes:
                      downloaded,
                  expectedBytes:
                      total,
                  partialFilePath:
                      _taskPartialFilePath(
                    task,
                  ),
                  message:
                      'Download pause হয়েছে এবং এখন resume করা যাচ্ছে না। '
                      'আগের ${task.progress}% progress রাখা হয়েছে।',
                );
              }

              return;

            // ===============================================================
            // UNEXPECTED CANCELED
            // ===============================================================

            case DownloadTaskStatus.canceled:
              timer.cancel();
              _monitoringTimer =
                  null;

              await _markRecoverableFailure(
                taskId:
                    task.taskId,
                progressPercent:
                    task.progress,
                downloadedBytes:
                    downloaded,
                expectedBytes:
                    total,
                partialFilePath:
                    _taskPartialFilePath(
                  task,
                ),
                message:
                    'Android download task canceled হয়েছে। '
                    'এটি user-confirmed delete নয়, তাই partial data automatic delete করা হয়নি।',
              );

              return;

            // ===============================================================
            // ACTIVE
            // ===============================================================

            case DownloadTaskStatus.running:
            case DownloadTaskStatus.enqueued:
              setDownloadStatus(
                DownloadStatus
                    .downloading,
              );

              return;

            // ===============================================================
            // UNDEFINED
            // ===============================================================

            case DownloadTaskStatus.undefined:
              timer.cancel();
              _monitoringTimer =
                  null;

              await _markRecoverableFailure(
                taskId:
                    task.taskId,
                progressPercent:
                    task.progress,
                downloadedBytes:
                    downloaded,
                expectedBytes:
                    total,
                partialFilePath:
                    _taskPartialFilePath(
                  task,
                ),
                message:
                    'Download task-এর status Android থেকে নির্ধারণ করা যাচ্ছে না। '
                    'Partial data রাখা হয়েছে।',
              );

              return;
          }
        } catch (e, st) {
          timer.cancel();

          _monitoringTimer =
              null;

          Logger.error(
            'Download monitoring exception: $e',
          );

          Logger.error(
            '$st',
          );

          final recovery =
              await DownloadStateManager
                  .getRecoveryState();

          await DownloadStateManager
              .saveDownloadFailedRecoverable(
            taskId:
                recovery.taskId ??
                    taskId,
            progressPercent:
                recovery
                    .progressPercent,
            downloadedBytes:
                recovery
                    .downloadedBytes,
            expectedBytes:
                recovery
                            .expectedBytes >
                        0
                    ? recovery
                        .expectedBytes
                    : _expectedBytes,
            partialFilePath:
                recovery
                    .partialFilePath,
          );

          setDownloadStatus(
            DownloadStatus.failed,
          );

          setErrorMessages([
            _friendlyExceptionMessage(
              e,
              fallback:
                  'Download monitoring বন্ধ হয়েছে। '
                  'আগের partial progress নিরাপদ রাখা হয়েছে।',
            ),
          ]);
        }
      },
    );
  }

  // ===========================================================================
  // AUTO RECOVERY
  // ===========================================================================

  Future<void> _autoRecoverOrFail(
    String taskId,
    BuildContext? context,
  ) async {
    DownloadManager.attachToTask(
      taskId,
    );

    while (_autoResumeAttempts <
        _maxAutoResumeAttempts) {
      _autoResumeAttempts++;

      final attempt =
          _autoResumeAttempts;

      Logger.warning(
        'Recoverable download retry '
        '$attempt/$_maxAutoResumeAttempts',
      );

      setDownloadStatus(
        DownloadStatus.downloading,
      );

      await Future.delayed(
        const Duration(
          seconds: 4,
        ),
      );

      final retried =
          await DownloadManager
              .retryDownload();

      if (retried != null) {
        final recovery =
            await DownloadStateManager
                .getRecoveryState();

        await DownloadStateManager
            .saveDownloadInProgress(
          retried,
          progressPercent:
              recovery.progressPercent,
          downloadedBytes:
              recovery.downloadedBytes,
          expectedBytes:
              recovery.expectedBytes > 0
                  ? recovery.expectedBytes
                  : _expectedBytes,
          partialFilePath:
              recovery.partialFilePath,
        );

        Logger.info(
          'Recoverable task resumed: '
          '$taskId -> $retried',
        );

        monitorDownload(
          retried,
          context,
        );

        return;
      }

      Logger.warning(
        'Retry $attempt unavailable. '
        'Nothing deleted.',
      );

      DownloadManager.attachToTask(
        taskId,
      );
    }

    final recovery =
        await DownloadStateManager
            .getRecoveryState();

    await DownloadStateManager
        .saveDownloadFailedRecoverable(
      taskId: taskId,
      progressPercent:
          recovery.progressPercent,
      downloadedBytes:
          recovery.downloadedBytes,
      expectedBytes:
          recovery.expectedBytes > 0
              ? recovery.expectedBytes
              : _expectedBytes,
      partialFilePath:
          recovery.partialFilePath,
    );

    setDownloadStatus(
      DownloadStatus.failed,
    );

    setErrorMessages([
      _recoverableFailureMessage(
        recovery.progressPercent,
      ),
    ]);

    Logger.warning(
      'Automatic recovery exhausted. '
      'Task/data preserved.',
    );
  }

  String _recoverableFailureMessage(
    int progressPercent,
  ) {
    final progressText =
        progressPercent > 0
            ? 'আগের $progressPercent% progress রাখা হয়েছে। '
            : '';

    return 'Download সাময়িকভাবে বন্ধ হয়েছে। '
        '$progressText'
        'ইন্টারনেট সংযোগ, battery restriction এবং phone storage পরীক্ষা করুন। '
        'Partial model delete করা হয়নি। '
        'আবার চেষ্টা করলে একই task resume করার চেষ্টা হবে।';
  }

  Future<void>
      _markRecoverableFailure({
    required String? taskId,
    required int progressPercent,
    required int downloadedBytes,
    required int expectedBytes,
    required String? partialFilePath,
    required String message,
  }) async {
    await DownloadStateManager
        .saveDownloadFailedRecoverable(
      taskId: taskId,
      progressPercent:
          progressPercent,
      downloadedBytes:
          downloadedBytes,
      expectedBytes:
          expectedBytes,
      partialFilePath:
          partialFilePath,
    );

    setDownloadStatus(
      DownloadStatus.failed,
    );

    setErrorMessages([
      message,
    ]);

    Logger.warning(
      '$message '
      '[recoverable data preserved]',
    );
  }

  // ===========================================================================
  // ERROR CLASSIFICATION
  // ===========================================================================

  String _friendlyExceptionMessage(
    Object error, {
    required String fallback,
  }) {
    if (error is SocketException) {
      return 'ইন্টারনেট connection বিচ্ছিন্ন হয়েছে। '
          'Download করা অংশ রাখা হয়েছে; connection ফিরে এলে resume করুন।';
    }

    if (error is TimeoutException) {
      return 'Network request timeout হয়েছে। '
          'Download করা অংশ রাখা হয়েছে; আবার resume করা যাবে।';
    }

    final text =
        error
            .toString()
            .toLowerCase();

    if (text.contains(
          'no space',
        ) ||
        text.contains(
          'not enough space',
        ) ||
        text.contains(
          'insufficient space',
        ) ||
        text.contains(
          'storage',
        ) &&
            text.contains(
              'low',
            ) ||
        text.contains(
          'enospc',
        )) {
      return 'ফোনে পর্যাপ্ত খালি storage নেই। '
          'Model download-এর জন্য অন্তত প্রায় ৬ GB খালি জায়গা রাখুন। '
          'আগের partial download মুছে ফেলা হয়নি।';
    }

    if (text.contains(
          '401',
        )) {
      return 'Hugging Face authorization ব্যর্থ হয়েছে। '
          'Login/token আবার যাচাই করুন।';
    }

    if (text.contains(
          '403',
        )) {
      return 'Hugging Face model access পাওয়া যায়নি। '
          'Gemma license গ্রহণ করা হয়েছে কিনা পরীক্ষা করুন।';
    }

    if (text.contains(
          'checksum',
        ) ||
        text.contains(
          'hash',
        )) {
      return 'Downloaded model-এর checksum verification ব্যর্থ হয়েছে। '
          'Final model corrupt হতে পারে।';
    }

    if (text.contains(
          'connection',
        ) ||
        text.contains(
          'network',
        ) ||
        text.contains(
          'socket',
        )) {
      return 'Network connection-এর কারণে download বন্ধ হয়েছে। '
          'আগের progress রাখা হয়েছে এবং resume করা যাবে।';
    }

    return fallback;
  }

  // ===========================================================================
  // TOKEN
  // ===========================================================================

  Future<String?>
      resolveAccessToken() async {
    if (hfTokenConfigured) {
      return hfAppToken;
    }

    final status =
        await TokenManager
            .getTokenStatus();

    if (status ==
        TokenStatus.valid) {
      final token =
          await TokenManager
              .getStoredToken();

      return token
          ?.accessToken;
    }

    return null;
  }

  // ===========================================================================
  // GENERIC ERROR
  // ===========================================================================

  void handleError(
    String error,
  ) {
    setDownloadStatus(
      DownloadStatus.failed,
    );

    setErrorMessages([
      error,
    ]);

    Logger.error(
      error,
    );
  }

  // ===========================================================================
  // CANCEL CONFIRMATION
  // ===========================================================================

  Future<void>
      showCancelConfirmation(
    BuildContext context,
  ) async {
    final result =
        await showDialog<bool>(
      context: context,
      barrierDismissible:
          false,
      builder: (
        BuildContext context,
      ) {
        return Dialog(
          shape:
              RoundedRectangleBorder(
            borderRadius:
                BorderRadius
                    .circular(
              20,
            ),
          ),
          child: Container(
            padding:
                const EdgeInsets
                    .all(
              24,
            ),
            decoration:
                BoxDecoration(
              borderRadius:
                  BorderRadius
                      .circular(
                20,
              ),
              color:
                  Colors.white,
            ),
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration:
                      BoxDecoration(
                    shape:
                        BoxShape.circle,
                    gradient:
                        LinearGradient(
                      colors: [
                        Colors.red[
                            400]!,
                        Colors.red[
                            600]!,
                      ],
                    ),
                  ),
                  child:
                      const Icon(
                    Icons
                        .warning_rounded,
                    size: 32,
                    color:
                        Colors.white,
                  ),
                ),

                const SizedBox(
                  height: 20,
                ),

                Text(
                  'ডাউনলোড বাতিল করবেন?',
                  style:
                      TextStyle(
                    fontSize: 22,
                    fontWeight:
                        FontWeight.bold,
                    color:
                        Colors
                            .grey[
                        800],
                  ),
                  textAlign:
                      TextAlign.center,
                ),

                const SizedBox(
                  height: 12,
                ),

                Text(
                  'আপনি নিশ্চিত হলে বর্তমান download task, '
                  'progress এবং partial model file মুছে যাবে। '
                  'Network failure হলে app নিজে এই data মুছে দেয় না।',
                  style:
                      TextStyle(
                    fontSize: 16,
                    color:
                        Colors
                            .grey[
                        600],
                    height: 1.4,
                  ),
                  textAlign:
                      TextAlign.center,
                ),

                const SizedBox(
                  height: 28,
                ),

                Row(
                  children: [
                    Expanded(
                      child:
                          OutlinedButton(
                        onPressed:
                            () =>
                                Navigator
                                    .of(
                                      context,
                                    )
                                    .pop(
                                      false,
                                    ),
                        child:
                            const Text(
                          'ডাউনলোড চালিয়ে যান',
                          textAlign:
                              TextAlign
                                  .center,
                        ),
                      ),
                    ),

                    const SizedBox(
                      width: 16,
                    ),

                    Expanded(
                      child:
                          ElevatedButton(
                        onPressed:
                            () =>
                                Navigator
                                    .of(
                                      context,
                                    )
                                    .pop(
                                      true,
                                    ),
                        child:
                            const Text(
                          'ডাউনলোড বাতিল করুন',
                          textAlign:
                              TextAlign
                                  .center,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (result ==
        true) {
      await cancelDownload();
    }
  }

  // ===========================================================================
  // EXPLICIT USER CANCEL + DELETE
  // ===========================================================================

  Future<void> cancelDownload() async {
    _monitoringTimer
        ?.cancel();

    _monitoringTimer =
        null;

    _autoResumeAttempts =
        0;

    // THIS is intentionally destructive.
    //
    // User explicitly confirmed delete.
    await DownloadManager
        .cancelAndDeleteDownload();

    await DownloadStateManager
        .clearDownloadState();

    setDownloadStatus(
      DownloadStatus.notStarted,
    );

    setProgress(
      null,
    );

    setErrorMessages([]);

    Logger.info(
      'User explicitly canceled download; '
      'task and partial data deleted.',
    );
  }

  // ===========================================================================
  // PAUSE
  // ===========================================================================

  Future<void> pauseDownload() async {
    final recovery =
        await DownloadStateManager
            .getRecoveryState();

    await DownloadManager
        .pauseDownload();

    await DownloadStateManager
        .saveDownloadPaused(
      taskId:
          recovery.taskId,
      progressPercent:
          recovery.progressPercent,
      downloadedBytes:
          recovery.downloadedBytes,
      expectedBytes:
          recovery.expectedBytes,
      partialFilePath:
          recovery.partialFilePath,
    );

    setDownloadStatus(
      DownloadStatus.paused,
    );
  }

  // ===========================================================================
  // RESUME
  // ===========================================================================

  Future<void> resumeDownload() async {
    final recovery =
        await DownloadStateManager
            .getRecoveryState();

    if (recovery.taskId !=
        null) {
      DownloadManager.attachToTask(
        recovery.taskId!,
      );
    } else {
      final tasks =
          await DownloadManager
              .getAllTasks();

      final recoverable =
          _latestRecoverableModelTask(
        tasks,
      );

      if (recoverable != null) {
        DownloadManager.attachToTask(
          recoverable.taskId,
        );
      }
    }

    final resumedTaskId =
        await DownloadManager
            .resumeDownload();

    if (resumedTaskId ==
        null) {
      await DownloadStateManager
          .saveDownloadFailedRecoverable(
        taskId:
            recovery.taskId,
        progressPercent:
            recovery.progressPercent,
        downloadedBytes:
            recovery.downloadedBytes,
        expectedBytes:
            recovery.expectedBytes,
        partialFilePath:
            recovery.partialFilePath,
      );

      setDownloadStatus(
        DownloadStatus.failed,
      );

      setErrorMessages([
        'Download এখন resume করা যাচ্ছে না। '
            'আগের ${recovery.progressPercent}% progress এবং partial model রাখা হয়েছে। '
            'ইন্টারনেট connection ঠিক করে আবার চেষ্টা করুন।',
      ]);

      return;
    }

    await DownloadStateManager
        .saveDownloadInProgress(
      resumedTaskId,
      progressPercent:
          recovery.progressPercent,
      downloadedBytes:
          recovery.downloadedBytes,
      expectedBytes:
          recovery.expectedBytes > 0
              ? recovery.expectedBytes
              : expectedModelFileSize,
      partialFilePath:
          recovery.partialFilePath,
    );

    setDownloadStatus(
      DownloadStatus.downloading,
    );

    setErrorMessages([]);

    monitorDownload(
      resumedTaskId,
      null,
    );
  }
}

// =============================================================================
// MODEL VERIFICATION TYPES
// =============================================================================

enum _ModelVerificationFailure {
  none,
  missing,
  tooSmall,
  checksumMismatch,
  checksumCalculationFailed,
  invalidChecksumConfiguration,
}

class _ModelVerificationResult {
  final bool valid;

  final _ModelVerificationFailure
      reason;

  final int size;

  const _ModelVerificationResult({
    required this.valid,
    required this.reason,
    required this.size,
  });
}
