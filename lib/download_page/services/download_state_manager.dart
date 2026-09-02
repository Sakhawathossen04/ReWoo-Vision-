import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import 'logger.dart';

/// Persistent download-state manager.
///
/// Core rules:
///
/// 1. failed != delete
/// 2. recoverable task metadata survives restart
/// 3. valid physical final model is stronger evidence than stale/missing prefs
/// 4. physical model repair NEVER deletes model/partial files
/// 5. destructive state clearing happens only on explicit reset/cancel
class DownloadStateManager {
  DownloadStateManager._();

  // ===========================================================================
  // CANONICAL DOWNLOAD STATES
  // ===========================================================================

  static const String notStarted =
      'not_started';

  static const String downloading =
      'downloading';

  static const String paused =
      'paused';

  static const String failedRecoverable =
      'failed_recoverable';

  static const String verifying =
      'verifying';

  static const String completed =
      'completed';

  // ===========================================================================
  // LEGACY STATE VALUES
  // ===========================================================================

  static const String _legacyInProgress =
      'in_progress';

  static const String _legacyCompleted =
      'completed';

  // ===========================================================================
  // SHARED PREFERENCES KEYS
  // ===========================================================================

  static const String _statusKey =
      'model_download_status_v2';

  static const String _progressPercentKey =
      'model_download_progress_percent_v2';

  static const String _downloadedBytesKey =
      'model_downloaded_bytes_v2';

  static const String _expectedBytesKey =
      'model_expected_bytes_v2';

  static const String _partialFilePathKey =
      'model_partial_file_path_v2';

  static const String _pausedKey =
      'model_download_paused_v2';

  static const String _failedKey =
      'model_download_failed_v2';

  static const String _completedKey =
      'model_download_completed_v2';

  static const String _verifiedKey =
      'model_download_verified_v2';

  static const String _updatedAtKey =
      'model_download_updated_at_v2';

  // ===========================================================================
  // PHYSICAL MODEL SELF-REPAIR
  // ===========================================================================

  /// Public startup repair hook.
  ///
  /// If SharedPreferences was:
  ///
  /// - lost
  /// - cleared
  /// - stale
  /// - still marked downloading/failed
  ///
  /// BUT the canonical final model physically exists and passes the same
  /// size-validation rule used by the rest of the application, rebuild the
  /// persistent state as:
  ///
  /// completed
  /// verified = true
  /// progress = 100
  ///
  /// This method NEVER deletes any file and NEVER starts a download.
  static Future<bool>
      repairCompletedStateFromPhysicalModelIfValid() async {
    final prefs =
        await SharedPreferences.getInstance();

    return _repairFromPhysicalModel(
      prefs,
    );
  }

  /// Internal physical-source-of-truth repair.
  static Future<bool> _repairFromPhysicalModel(
    SharedPreferences prefs,
  ) async {
    try {
      final documents =
          await getApplicationDocumentsDirectory();

      final modelPath =
          '${documents.path}/$modelName';

      final modelFile =
          File(modelPath);

      if (!await modelFile.exists()) {
        return false;
      }

      final size =
          await modelFile.length();

      final minimumValidSize =
          (expectedModelFileSize *
                  modelSizeTolerance)
              .round();

      if (size <
          minimumValidSize) {
        Logger.warning(
          'Physical model exists but is too small for '
          'persistent-state repair: '
          '$modelPath, '
          'size=$size, '
          'minimum=$minimumValidSize',
        );

        // IMPORTANT:
        //
        // Do not delete it here.
        //
        // DownloadLogic / DownloadManager owns corruption and recovery.
        return false;
      }

      // -----------------------------------------------------------------------
      // Check whether state is already completely correct.
      // -----------------------------------------------------------------------

      final currentStatus =
          prefs.getString(
        _statusKey,
      );

      final legacyStatus =
          prefs.getString(
        downloadStateKey,
      );

      final progress =
          prefs.getInt(
                _progressPercentKey,
              ) ??
              0;

      final downloadedBytes =
          prefs.getInt(
                _downloadedBytesKey,
              ) ??
              0;

      final expectedBytes =
          prefs.getInt(
                _expectedBytesKey,
              ) ??
              0;

      final completedFlag =
          prefs.getBool(
                _completedKey,
              ) ??
              false;

      final verifiedFlag =
          prefs.getBool(
                _verifiedKey,
              ) ??
              false;

      final pausedFlag =
          prefs.getBool(
                _pausedKey,
              ) ??
              false;

      final failedFlag =
          prefs.getBool(
                _failedKey,
              ) ??
              false;

      final taskId =
          prefs.getString(
        downloadTaskIdKey,
      );

      final partialPath =
          prefs.getString(
        _partialFilePathKey,
      );

      final stateAlreadyHealthy =
          currentStatus ==
                  completed &&
              legacyStatus ==
                  _legacyCompleted &&
              progress ==
                  100 &&
              completedFlag &&
              verifiedFlag &&
              !pausedFlag &&
              !failedFlag &&
              downloadedBytes >=
                  minimumValidSize &&
              expectedBytes >
                  0 &&
              (taskId == null ||
                  taskId
                      .trim()
                      .isEmpty) &&
              (partialPath == null ||
                  partialPath
                      .trim()
                      .isEmpty);

      if (stateAlreadyHealthy) {
        return true;
      }

      // -----------------------------------------------------------------------
      // REPAIR STALE / LOST PREFS
      // -----------------------------------------------------------------------

      Logger.warning(
        'Valid physical model found but persistent '
        'download state is stale/missing. '
        'Repairing state to completed + verified. '
        'path=$modelPath, '
        'size=$size',
      );

      await _writeCompletedState(
        prefs,
        downloadedBytes:
            size,
        expectedBytes:
            expectedModelFileSize,
        verified:
            true,
      );

      Logger.info(
        'Persistent model state repaired successfully: '
        'completed=true, '
        'verified=true, '
        'progress=100, '
        'size=$size',
      );

      return true;
    } catch (e, st) {
      Logger.warning(
        'Physical model state repair could not run: $e',
      );

      Logger.debug(
        '$st',
      );

      // State-repair failure must never trigger deletion.
      return false;
    }
  }

  /// Every important read first gives the physical final model an opportunity
  /// to repair stale SharedPreferences.
  static Future<SharedPreferences>
      _prefsForRead() async {
    final prefs =
        await SharedPreferences.getInstance();

    await _repairFromPhysicalModel(
      prefs,
    );

    return prefs;
  }

  // ===========================================================================
  // SAVE: DOWNLOAD STARTED / ACTIVE
  // ===========================================================================

  static Future<void> saveDownloadInProgress(
    String taskId, {
    int? progressPercent,
    int? downloadedBytes,
    int? expectedBytes,
    String? partialFilePath,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setString(
      downloadStateKey,
      _legacyInProgress,
    );

    await prefs.setString(
      downloadTaskIdKey,
      taskId,
    );

    await prefs.setString(
      _statusKey,
      downloading,
    );

    await prefs.setBool(
      _pausedKey,
      false,
    );

    await prefs.setBool(
      _failedKey,
      false,
    );

    await prefs.setBool(
      _completedKey,
      false,
    );

    await prefs.setBool(
      _verifiedKey,
      false,
    );

    await _saveOptionalProgressFields(
      prefs,
      progressPercent:
          progressPercent,
      downloadedBytes:
          downloadedBytes,
      expectedBytes:
          expectedBytes,
      partialFilePath:
          partialFilePath,
    );

    await _touch(
      prefs,
    );

    Logger.info(
      'Saved download state: '
      'status=$downloading, '
      'taskId=$taskId, '
      'progress=${progressPercent ?? 'unchanged'}%, '
      'downloadedBytes=${downloadedBytes ?? 'unchanged'}, '
      'expectedBytes=${expectedBytes ?? 'unchanged'}, '
      'partialFile=${partialFilePath ?? 'unchanged'}',
    );
  }

  // ===========================================================================
  // SAVE: PROGRESS
  // ===========================================================================

  static Future<void> saveProgress({
    required int progressPercent,
    required int downloadedBytes,
    required int expectedBytes,
    String? taskId,
    String? partialFilePath,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    if (taskId != null &&
        taskId
            .trim()
            .isNotEmpty) {
      await prefs.setString(
        downloadTaskIdKey,
        taskId.trim(),
      );
    }

    await prefs.setInt(
      _progressPercentKey,
      _normalizePercent(
        progressPercent,
      ),
    );

    await prefs.setInt(
      _downloadedBytesKey,
      _normalizeBytes(
        downloadedBytes,
      ),
    );

    await prefs.setInt(
      _expectedBytesKey,
      _normalizeBytes(
        expectedBytes,
      ),
    );

    if (partialFilePath != null &&
        partialFilePath
            .trim()
            .isNotEmpty) {
      await prefs.setString(
        _partialFilePathKey,
        partialFilePath.trim(),
      );
    }

    final currentStatus =
        prefs.getString(
      _statusKey,
    );

    // Normal progress callbacks must not turn paused / failed /
    // verifying / completed back into downloading.
    if (currentStatus == null ||
        currentStatus ==
            notStarted) {
      await prefs.setString(
        _statusKey,
        downloading,
      );

      await prefs.setString(
        downloadStateKey,
        _legacyInProgress,
      );
    }

    await _touch(
      prefs,
    );
  }

  // ===========================================================================
  // SAVE: PARTIAL FILE PATH
  // ===========================================================================

  static Future<void> savePartialFilePath(
    String path,
  ) async {
    final clean =
        path.trim();

    if (clean.isEmpty) {
      return;
    }

    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setString(
      _partialFilePathKey,
      clean,
    );

    await _touch(
      prefs,
    );

    Logger.info(
      'Saved model partial file path: $clean',
    );
  }

  // ===========================================================================
  // SAVE: PAUSED
  // ===========================================================================

  static Future<void> saveDownloadPaused({
    String? taskId,
    int? progressPercent,
    int? downloadedBytes,
    int? expectedBytes,
    String? partialFilePath,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    if (taskId != null &&
        taskId
            .trim()
            .isNotEmpty) {
      await prefs.setString(
        downloadTaskIdKey,
        taskId.trim(),
      );
    }

    await prefs.setString(
      downloadStateKey,
      _legacyInProgress,
    );

    await prefs.setString(
      _statusKey,
      paused,
    );

    await prefs.setBool(
      _pausedKey,
      true,
    );

    await prefs.setBool(
      _failedKey,
      false,
    );

    await prefs.setBool(
      _completedKey,
      false,
    );

    await prefs.setBool(
      _verifiedKey,
      false,
    );

    await _saveOptionalProgressFields(
      prefs,
      progressPercent:
          progressPercent,
      downloadedBytes:
          downloadedBytes,
      expectedBytes:
          expectedBytes,
      partialFilePath:
          partialFilePath,
    );

    await _touch(
      prefs,
    );

    Logger.info(
      'Saved download state: '
      '$paused '
      '(partial progress preserved)',
    );
  }

  // ===========================================================================
  // SAVE: FAILED BUT RECOVERABLE
  // ===========================================================================

  static Future<void>
      saveDownloadFailedRecoverable({
    String? taskId,
    int? progressPercent,
    int? downloadedBytes,
    int? expectedBytes,
    String? partialFilePath,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    if (taskId != null &&
        taskId
            .trim()
            .isNotEmpty) {
      await prefs.setString(
        downloadTaskIdKey,
        taskId.trim(),
      );
    }

    await prefs.setString(
      downloadStateKey,
      _legacyInProgress,
    );

    await prefs.setString(
      _statusKey,
      failedRecoverable,
    );

    await prefs.setBool(
      _pausedKey,
      false,
    );

    await prefs.setBool(
      _failedKey,
      true,
    );

    await prefs.setBool(
      _completedKey,
      false,
    );

    await prefs.setBool(
      _verifiedKey,
      false,
    );

    await _saveOptionalProgressFields(
      prefs,
      progressPercent:
          progressPercent,
      downloadedBytes:
          downloadedBytes,
      expectedBytes:
          expectedBytes,
      partialFilePath:
          partialFilePath,
    );

    await _touch(
      prefs,
    );

    Logger.warning(
      'Saved download state: '
      '$failedRecoverable. '
      'Task/progress/partial file preserved.',
    );
  }

  // ===========================================================================
  // SAVE: VERIFYING
  // ===========================================================================

  static Future<void> saveDownloadVerifying({
    String? taskId,
    int? downloadedBytes,
    int? expectedBytes,
    String? partialFilePath,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    if (taskId != null &&
        taskId
            .trim()
            .isNotEmpty) {
      await prefs.setString(
        downloadTaskIdKey,
        taskId.trim(),
      );
    }

    await prefs.setString(
      downloadStateKey,
      _legacyInProgress,
    );

    await prefs.setString(
      _statusKey,
      verifying,
    );

    await prefs.setInt(
      _progressPercentKey,
      100,
    );

    await prefs.setBool(
      _pausedKey,
      false,
    );

    await prefs.setBool(
      _failedKey,
      false,
    );

    await prefs.setBool(
      _completedKey,
      false,
    );

    await prefs.setBool(
      _verifiedKey,
      false,
    );

    await _saveOptionalProgressFields(
      prefs,
      progressPercent:
          100,
      downloadedBytes:
          downloadedBytes,
      expectedBytes:
          expectedBytes,
      partialFilePath:
          partialFilePath,
    );

    await _touch(
      prefs,
    );

    Logger.info(
      'Saved download state: $verifying',
    );
  }

  // ===========================================================================
  // SAVE: COMPLETED
  // ===========================================================================

  static Future<void> saveDownloadCompleted({
    int? downloadedBytes,
    int? expectedBytes,
    bool verified = true,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    await _writeCompletedState(
      prefs,
      downloadedBytes:
          downloadedBytes,
      expectedBytes:
          expectedBytes,
      verified:
          verified,
    );
  }

  /// Single completed-state writer shared by:
  ///
  /// - normal successful download
  /// - physical-model startup repair
  static Future<void> _writeCompletedState(
    SharedPreferences prefs, {
    int? downloadedBytes,
    int? expectedBytes,
    required bool verified,
  }) async {
    await prefs.setString(
      downloadStateKey,
      _legacyCompleted,
    );

    await prefs.setString(
      _statusKey,
      completed,
    );

    await prefs.setInt(
      _progressPercentKey,
      100,
    );

    final oldDownloadedBytes =
        prefs.getInt(
              _downloadedBytesKey,
            ) ??
            0;

    final oldExpectedBytes =
        prefs.getInt(
              _expectedBytesKey,
            ) ??
            0;

    final resolvedDownloadedBytes =
        downloadedBytes != null
            ? _normalizeBytes(
                downloadedBytes,
              )
            : oldDownloadedBytes >
                    0
                ? oldDownloadedBytes
                : expectedModelFileSize;

    final resolvedExpectedBytes =
        expectedBytes != null
            ? _normalizeBytes(
                expectedBytes,
              )
            : oldExpectedBytes >
                    0
                ? oldExpectedBytes
                : expectedModelFileSize;

    await prefs.setInt(
      _downloadedBytesKey,
      resolvedDownloadedBytes,
    );

    await prefs.setInt(
      _expectedBytesKey,
      resolvedExpectedBytes,
    );

    await prefs.setBool(
      _pausedKey,
      false,
    );

    await prefs.setBool(
      _failedKey,
      false,
    );

    await prefs.setBool(
      _completedKey,
      true,
    );

    await prefs.setBool(
      _verifiedKey,
      verified,
    );

    // Final verified model exists.
    //
    // Native task ID is no longer required for normal startup routing.
    await prefs.remove(
      downloadTaskIdKey,
    );

    // Final file has replaced the logical .part recovery path.
    await prefs.remove(
      _partialFilePathKey,
    );

    await _touch(
      prefs,
    );

    Logger.info(
      'Saved download state: '
      '$completed, '
      'verified=$verified, '
      'downloadedBytes=$resolvedDownloadedBytes, '
      'expectedBytes=$resolvedExpectedBytes',
    );
  }

  // ===========================================================================
  // SAVE: NOT STARTED
  // ===========================================================================

  static Future<void>
      saveDownloadNotStarted() async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setString(
      _statusKey,
      notStarted,
    );

    await prefs.remove(
      downloadStateKey,
    );

    await prefs.setBool(
      _pausedKey,
      false,
    );

    await prefs.setBool(
      _failedKey,
      false,
    );

    await prefs.setBool(
      _completedKey,
      false,
    );

    await prefs.setBool(
      _verifiedKey,
      false,
    );

    await _touch(
      prefs,
    );

    Logger.info(
      'Saved download state: $notStarted',
    );
  }

  // ===========================================================================
  // CLEAR STATE
  // ===========================================================================

  /// Full destructive metadata reset.
  ///
  /// IMPORTANT:
  ///
  /// This method deletes SharedPreferences state only.
  ///
  /// Physical file destruction remains DownloadManager's responsibility and
  /// must happen only after explicit user confirmation / intentional reset.
  static Future<void> clearDownloadState() async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.remove(
      downloadStateKey,
    );

    await prefs.remove(
      downloadTaskIdKey,
    );

    await prefs.remove(
      _statusKey,
    );

    await prefs.remove(
      _progressPercentKey,
    );

    await prefs.remove(
      _downloadedBytesKey,
    );

    await prefs.remove(
      _expectedBytesKey,
    );

    await prefs.remove(
      _partialFilePathKey,
    );

    await prefs.remove(
      _pausedKey,
    );

    await prefs.remove(
      _failedKey,
    );

    await prefs.remove(
      _completedKey,
    );

    await prefs.remove(
      _verifiedKey,
    );

    await prefs.remove(
      _updatedAtKey,
    );

    Logger.info(
      'Download state fully cleared',
    );
  }

  // ===========================================================================
  // LEGACY GETTERS
  // ===========================================================================

  static Future<String?>
      getDownloadState() async {
    final prefs =
        await _prefsForRead();

    final legacy =
        prefs.getString(
      downloadStateKey,
    );

    if (legacy != null) {
      return legacy;
    }

    final detailed =
        _readDetailedStatus(
      prefs,
    );

    if (detailed ==
        completed) {
      return _legacyCompleted;
    }

    if (detailed ==
            downloading ||
        detailed ==
            paused ||
        detailed ==
            failedRecoverable ||
        detailed ==
            verifying) {
      return _legacyInProgress;
    }

    return null;
  }

  static Future<String?>
      getDownloadTaskId() async {
    final prefs =
        await _prefsForRead();

    return prefs.getString(
      downloadTaskIdKey,
    );
  }

  // ===========================================================================
  // DETAILED GETTERS
  // ===========================================================================

  static Future<String>
      getDetailedStatus() async {
    final prefs =
        await _prefsForRead();

    return _readDetailedStatus(
      prefs,
    );
  }

  static String _readDetailedStatus(
    SharedPreferences prefs,
  ) {
    final state =
        prefs.getString(
      _statusKey,
    );

    if (state != null &&
        _isKnownState(
          state,
        )) {
      return state;
    }

    final legacy =
        prefs.getString(
      downloadStateKey,
    );

    if (legacy ==
        _legacyCompleted) {
      return completed;
    }

    if (legacy ==
        _legacyInProgress) {
      return downloading;
    }

    return notStarted;
  }

  static Future<int>
      getProgressPercent() async {
    final prefs =
        await _prefsForRead();

    return _normalizePercent(
      prefs.getInt(
            _progressPercentKey,
          ) ??
          0,
    );
  }

  static Future<int>
      getDownloadedBytes() async {
    final prefs =
        await _prefsForRead();

    return _normalizeBytes(
      prefs.getInt(
            _downloadedBytesKey,
          ) ??
          0,
    );
  }

  static Future<int>
      getExpectedBytes() async {
    final prefs =
        await _prefsForRead();

    return _normalizeBytes(
      prefs.getInt(
            _expectedBytesKey,
          ) ??
          0,
    );
  }

  static Future<String?>
      getPartialFilePath() async {
    final prefs =
        await _prefsForRead();

    final path =
        prefs.getString(
      _partialFilePathKey,
    );

    if (path == null ||
        path
            .trim()
            .isEmpty) {
      return null;
    }

    return path.trim();
  }

  static Future<bool>
      isPaused() async {
    final prefs =
        await _prefsForRead();

    return prefs.getBool(
          _pausedKey,
        ) ??
        false;
  }

  static Future<bool>
      isFailedRecoverable() async {
    final prefs =
        await _prefsForRead();

    final state =
        _readDetailedStatus(
      prefs,
    );

    return state ==
            failedRecoverable ||
        (prefs.getBool(
              _failedKey,
            ) ??
            false);
  }

  static Future<bool>
      isCompleted() async {
    final prefs =
        await _prefsForRead();

    final state =
        _readDetailedStatus(
      prefs,
    );

    return state ==
            completed &&
        (prefs.getBool(
              _completedKey,
            ) ??
            false);
  }

  static Future<bool>
      isVerified() async {
    final prefs =
        await _prefsForRead();

    return prefs.getBool(
          _verifiedKey,
        ) ??
        false;
  }

  static Future<DateTime?>
      getLastUpdatedAt() async {
    final prefs =
        await _prefsForRead();

    final value =
        prefs.getInt(
      _updatedAtKey,
    );

    if (value == null ||
        value <=
            0) {
      return null;
    }

    return DateTime
        .fromMillisecondsSinceEpoch(
      value,
    );
  }

  // ===========================================================================
  // FULL RECOVERY SNAPSHOT
  // ===========================================================================

  static Future<DownloadRecoveryState>
      getRecoveryState() async {
    // IMPORTANT:
    //
    // This one call is the normal startup entry point.
    //
    // _prefsForRead() first checks whether the physical final model can repair
    // stale/missing preference state.
    final prefs =
        await _prefsForRead();

    final status =
        _readDetailedStatus(
      prefs,
    );

    final taskId =
        prefs.getString(
      downloadTaskIdKey,
    );

    final progress =
        _normalizePercent(
      prefs.getInt(
            _progressPercentKey,
          ) ??
          0,
    );

    final downloadedBytes =
        _normalizeBytes(
      prefs.getInt(
            _downloadedBytesKey,
          ) ??
          0,
    );

    final expectedBytes =
        _normalizeBytes(
      prefs.getInt(
            _expectedBytesKey,
          ) ??
          0,
    );

    final rawPartialPath =
        prefs.getString(
      _partialFilePathKey,
    );

    final partialPath =
        rawPartialPath != null &&
                rawPartialPath
                    .trim()
                    .isNotEmpty
            ? rawPartialPath
                .trim()
            : null;

    final pausedValue =
        prefs.getBool(
              _pausedKey,
            ) ??
            false;

    final failedValue =
        prefs.getBool(
              _failedKey,
            ) ??
            false;

    final completedValue =
        prefs.getBool(
              _completedKey,
            ) ??
            false;

    final verifiedValue =
        prefs.getBool(
              _verifiedKey,
            ) ??
            false;

    final updatedAtMillis =
        prefs.getInt(
      _updatedAtKey,
    );

    return DownloadRecoveryState(
      taskId:
          taskId,
      status:
          status,
      progressPercent:
          progress,
      downloadedBytes:
          downloadedBytes,
      expectedBytes:
          expectedBytes,
      partialFilePath:
          partialPath,
      paused:
          pausedValue,
      failed:
          failedValue,
      completed:
          completedValue,
      verified:
          verifiedValue,
      updatedAt:
          updatedAtMillis !=
                  null
              ? DateTime
                  .fromMillisecondsSinceEpoch(
                  updatedAtMillis,
                )
              : null,
    );
  }

  // ===========================================================================
  // INTERNAL HELPERS
  // ===========================================================================

  static Future<void>
      _saveOptionalProgressFields(
    SharedPreferences prefs, {
    int? progressPercent,
    int? downloadedBytes,
    int? expectedBytes,
    String? partialFilePath,
  }) async {
    if (progressPercent !=
        null) {
      await prefs.setInt(
        _progressPercentKey,
        _normalizePercent(
          progressPercent,
        ),
      );
    }

    if (downloadedBytes !=
        null) {
      await prefs.setInt(
        _downloadedBytesKey,
        _normalizeBytes(
          downloadedBytes,
        ),
      );
    }

    if (expectedBytes !=
        null) {
      await prefs.setInt(
        _expectedBytesKey,
        _normalizeBytes(
          expectedBytes,
        ),
      );
    }

    if (partialFilePath != null &&
        partialFilePath
            .trim()
            .isNotEmpty) {
      await prefs.setString(
        _partialFilePathKey,
        partialFilePath.trim(),
      );
    }
  }

  static Future<void> _touch(
    SharedPreferences prefs,
  ) async {
    await prefs.setInt(
      _updatedAtKey,
      DateTime.now()
          .millisecondsSinceEpoch,
    );
  }

  static int _normalizePercent(
    int value,
  ) {
    if (value <
        0) {
      return 0;
    }

    if (value >
        100) {
      return 100;
    }

    return value;
  }

  static int _normalizeBytes(
    int value,
  ) {
    return value <
            0
        ? 0
        : value;
  }

  static bool _isKnownState(
    String value,
  ) {
    return value ==
            notStarted ||
        value ==
            downloading ||
        value ==
            paused ||
        value ==
            failedRecoverable ||
        value ==
            verifying ||
        value ==
            completed;
  }
}

// =============================================================================
// DOWNLOAD RECOVERY SNAPSHOT
// =============================================================================

class DownloadRecoveryState {
  final String? taskId;

  final String status;

  final int progressPercent;

  final int downloadedBytes;

  final int expectedBytes;

  final String? partialFilePath;

  final bool paused;

  final bool failed;

  final bool completed;

  final bool verified;

  final DateTime? updatedAt;

  const DownloadRecoveryState({
    required this.taskId,
    required this.status,
    required this.progressPercent,
    required this.downloadedBytes,
    required this.expectedBytes,
    required this.partialFilePath,
    required this.paused,
    required this.failed,
    required this.completed,
    required this.verified,
    required this.updatedAt,
  });

  // ===========================================================================
  // CONVENIENCE
  // ===========================================================================

  bool get hasTask =>
      taskId !=
          null &&
      taskId!
          .trim()
          .isNotEmpty;

  bool get hasPartialFile =>
      partialFilePath !=
          null &&
      partialFilePath!
          .trim()
          .isNotEmpty;

  bool get hasProgress =>
      progressPercent >
          0 ||
      downloadedBytes >
          0;

  bool get isRecoverable =>
      status ==
          DownloadStateManager
              .downloading ||
      status ==
          DownloadStateManager
              .paused ||
      status ==
          DownloadStateManager
              .failedRecoverable ||
      status ==
          DownloadStateManager
              .verifying;

  bool get isReady =>
      status ==
          DownloadStateManager
              .completed &&
      completed &&
      verified;

  double get progressFraction =>
      progressPercent /
      100.0;

  @override
  String toString() {
    return 'DownloadRecoveryState('
        'taskId: $taskId, '
        'status: $status, '
        'progressPercent: $progressPercent, '
        'downloadedBytes: $downloadedBytes, '
        'expectedBytes: $expectedBytes, '
        'partialFilePath: $partialFilePath, '
        'paused: $paused, '
        'failed: $failed, '
        'completed: $completed, '
        'verified: $verified, '
        'updatedAt: $updatedAt'
        ')';
  }
}
