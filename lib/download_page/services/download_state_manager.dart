import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import 'logger.dart';

/// Persistent download-state manager.
///
/// This survives:
///
/// - app restart
/// - process kill
/// - phone reboot
/// - temporary network failure
/// - paused download
/// - recoverable failed download
///
/// IMPORTANT RULE:
///
/// failed != delete
///
/// A failed download is stored as [failedRecoverable].
/// Its task ID, partial file path and progress remain persisted so the
/// application can attempt to resume it later.
///
/// Download state is fully cleared ONLY after:
///
/// 1. explicit user cancel/delete, or
/// 2. an intentional full reset.
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

  /// Current DownloadLogic still checks:
  ///
  /// savedState == 'in_progress'
  ///
  /// During migration we keep writing that legacy value into
  /// [downloadStateKey] whenever the task remains recoverable.
  ///
  /// The new detailed state is stored separately.
  static const String _legacyInProgress =
      'in_progress';

  static const String _legacyCompleted =
      'completed';

  // ===========================================================================
  // SHARED-PREFERENCES KEYS
  // ===========================================================================

  /// New canonical state.
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
  // SAVE: DOWNLOAD STARTED / ACTIVE
  // ===========================================================================

  /// Saves a newly-created or resumed task.
  ///
  /// Existing call sites can continue using:
  ///
  /// saveDownloadInProgress(taskId)
  ///
  /// without modification.
  static Future<void> saveDownloadInProgress(
    String taskId, {
    int? progressPercent,
    int? downloadedBytes,
    int? expectedBytes,
    String? partialFilePath,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    // -------------------------------------------------------------------------
    // Migration compatibility.
    // -------------------------------------------------------------------------

    await prefs.setString(
      downloadStateKey,
      _legacyInProgress,
    );

    await prefs.setString(
      downloadTaskIdKey,
      taskId,
    );

    // -------------------------------------------------------------------------
    // New canonical state.
    // -------------------------------------------------------------------------

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

    if (progressPercent != null) {
      await prefs.setInt(
        _progressPercentKey,
        _normalizePercent(
          progressPercent,
        ),
      );
    }

    if (downloadedBytes != null) {
      await prefs.setInt(
        _downloadedBytesKey,
        _normalizeBytes(
          downloadedBytes,
        ),
      );
    }

    if (expectedBytes != null) {
      await prefs.setInt(
        _expectedBytesKey,
        _normalizeBytes(
          expectedBytes,
        ),
      );
    }

    if (partialFilePath != null &&
        partialFilePath.trim().isNotEmpty) {
      await prefs.setString(
        _partialFilePathKey,
        partialFilePath.trim(),
      );
    }

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

  /// Updates byte/progress state while preserving the current task.
  ///
  /// This method should be called periodically by DownloadLogic.
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
        taskId.trim().isNotEmpty) {
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
        partialFilePath.trim().isNotEmpty) {
      await prefs.setString(
        _partialFilePathKey,
        partialFilePath.trim(),
      );
    }

    final currentStatus =
        prefs.getString(
          _statusKey,
        ) ??
        downloading;

    // A normal progress callback must not accidentally turn paused,
    // failed-recoverable, verifying or completed back into downloading.
    if (currentStatus == notStarted) {
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

  /// Paused means recoverable.
  ///
  /// Task ID and downloaded bytes are deliberately retained.
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
        taskId.trim().isNotEmpty) {
      await prefs.setString(
        downloadTaskIdKey,
        taskId.trim(),
      );
    }

    // Legacy DownloadLogic must still consider this recoverable.
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
      'Saved download state: $paused '
      '(partial progress preserved)',
    );
  }

  // ===========================================================================
  // SAVE: FAILED BUT RECOVERABLE
  // ===========================================================================

  /// Stores a temporary/recoverable failure.
  ///
  /// CRITICAL:
  ///
  /// This method DOES NOT:
  ///
  /// - remove taskId
  /// - remove partialFilePath
  /// - zero progress
  /// - delete any file
  ///
  /// failed != delete.
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
        taskId.trim().isNotEmpty) {
      await prefs.setString(
        downloadTaskIdKey,
        taskId.trim(),
      );
    }

    // Keep legacy recovery enabled.
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

  /// Called after native download reaches 100% but BEFORE the application
  /// declares the model usable.
  ///
  /// Flow:
  ///
  /// 100%
  /// ↓
  /// verifying
  /// ↓
  /// expected size / checksum
  /// ↓
  /// .part -> final
  /// ↓
  /// completed + verified
  static Future<void> saveDownloadVerifying({
    String? taskId,
    int? downloadedBytes,
    int? expectedBytes,
    String? partialFilePath,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    if (taskId != null &&
        taskId.trim().isNotEmpty) {
      await prefs.setString(
        downloadTaskIdKey,
        taskId.trim(),
      );
    }

    // During verification the task is not yet safely complete.
    // Keep legacy recovery state as in-progress.
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
      progressPercent: 100,
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

  /// Marks the model as fully downloaded AND verified.
  ///
  /// Existing callers can still use:
  ///
  /// saveDownloadCompleted()
  ///
  /// without arguments.
  static Future<void> saveDownloadCompleted({
    int? downloadedBytes,
    int? expectedBytes,
    bool verified = true,
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

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

    if (downloadedBytes != null) {
      await prefs.setInt(
        _downloadedBytesKey,
        _normalizeBytes(
          downloadedBytes,
        ),
      );
    }

    if (expectedBytes != null) {
      await prefs.setInt(
        _expectedBytesKey,
        _normalizeBytes(
          expectedBytes,
        ),
      );
    }

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

    // Once final verification succeeds, the native task ID is no longer
    // necessary for normal startup recovery.
    await prefs.remove(
      downloadTaskIdKey,
    );

    // .part has become the real model file.
    await prefs.remove(
      _partialFilePathKey,
    );

    await _touch(
      prefs,
    );

    Logger.info(
      'Saved download state: '
      '$completed, verified=$verified',
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

  /// FULL destructive state reset.
  ///
  /// Call only when:
  ///
  /// - user explicitly canceled/deleted the download
  /// - application intentionally performs a clean reset
  ///
  /// Do NOT call this merely because a network download failed.
  static Future<void> clearDownloadState() async {
    final prefs =
        await SharedPreferences.getInstance();

    // Legacy keys.
    await prefs.remove(
      downloadStateKey,
    );

    await prefs.remove(
      downloadTaskIdKey,
    );

    // New detailed state.
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

  /// Existing DownloadLogic compatibility.
  ///
  /// Returns:
  ///
  /// in_progress
  /// completed
  /// null
  ///
  /// New code should prefer [getDetailedStatus].
  static Future<String?>
      getDownloadState() async {
    final prefs =
        await SharedPreferences.getInstance();

    final legacy =
        prefs.getString(
      downloadStateKey,
    );

    if (legacy != null) {
      return legacy;
    }

    // -----------------------------------------------------------------------
    // Migration recovery:
    //
    // If v2 data exists but legacy key disappeared, reconstruct a value that
    // older DownloadLogic understands.
    // -----------------------------------------------------------------------

    final detailed =
        prefs.getString(
      _statusKey,
    );

    if (detailed == completed) {
      return _legacyCompleted;
    }

    if (detailed == downloading ||
        detailed == paused ||
        detailed ==
            failedRecoverable ||
        detailed == verifying) {
      return _legacyInProgress;
    }

    return null;
  }

  static Future<String?>
      getDownloadTaskId() async {
    final prefs =
        await SharedPreferences.getInstance();

    return prefs.getString(
      downloadTaskIdKey,
    );
  }

  // ===========================================================================
  // NEW DETAILED GETTERS
  // ===========================================================================

  static Future<String>
      getDetailedStatus() async {
    final prefs =
        await SharedPreferences.getInstance();

    final state =
        prefs.getString(
      _statusKey,
    );

    if (state != null &&
        _isKnownState(state)) {
      return state;
    }

    // -----------------------------------------------------------------------
    // Migrate legacy state if necessary.
    // -----------------------------------------------------------------------

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
        await SharedPreferences.getInstance();

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
        await SharedPreferences.getInstance();

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
        await SharedPreferences.getInstance();

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
        await SharedPreferences.getInstance();

    final path =
        prefs.getString(
      _partialFilePathKey,
    );

    if (path == null ||
        path.trim().isEmpty) {
      return null;
    }

    return path.trim();
  }

  static Future<bool>
      isPaused() async {
    final prefs =
        await SharedPreferences.getInstance();

    return prefs.getBool(
          _pausedKey,
        ) ??
        false;
  }

  static Future<bool>
      isFailedRecoverable() async {
    final prefs =
        await SharedPreferences.getInstance();

    final state =
        await getDetailedStatus();

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
        await SharedPreferences.getInstance();

    final state =
        await getDetailedStatus();

    return state ==
            completed ||
        (prefs.getBool(
              _completedKey,
            ) ??
            false);
  }

  static Future<bool>
      isVerified() async {
    final prefs =
        await SharedPreferences.getInstance();

    return prefs.getBool(
          _verifiedKey,
        ) ??
        false;
  }

  static Future<DateTime?>
      getLastUpdatedAt() async {
    final prefs =
        await SharedPreferences.getInstance();

    final value =
        prefs.getInt(
      _updatedAtKey,
    );

    if (value == null ||
        value <= 0) {
      return null;
    }

    return DateTime
        .fromMillisecondsSinceEpoch(
      value,
    );
  }

  // ===========================================================================
  // FULL SNAPSHOT
  // ===========================================================================

  /// Returns every recovery-related field in one object.
  ///
  /// This will be useful when DownloadLogic is fully migrated.
  static Future<DownloadRecoveryState>
      getRecoveryState() async {
    final prefs =
        await SharedPreferences.getInstance();

    final status =
        await getDetailedStatus();

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

    final partialPath =
        prefs.getString(
      _partialFilePathKey,
    );

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
      taskId: taskId,
      status: status,
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
          updatedAtMillis != null
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
    if (progressPercent != null) {
      await prefs.setInt(
        _progressPercentKey,
        _normalizePercent(
          progressPercent,
        ),
      );
    }

    if (downloadedBytes != null) {
      await prefs.setInt(
        _downloadedBytesKey,
        _normalizeBytes(
          downloadedBytes,
        ),
      );
    }

    if (expectedBytes != null) {
      await prefs.setInt(
        _expectedBytesKey,
        _normalizeBytes(
          expectedBytes,
        ),
      );
    }

    if (partialFilePath != null &&
        partialFilePath.trim().isNotEmpty) {
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
    if (value < 0) {
      return 0;
    }

    if (value > 100) {
      return 100;
    }

    return value;
  }

  static int _normalizeBytes(
    int value,
  ) {
    return value < 0
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

/// Immutable snapshot of persistent model-download state.
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
      taskId != null &&
      taskId!.trim().isNotEmpty;

  bool get hasPartialFile =>
      partialFilePath != null &&
      partialFilePath!
          .trim()
          .isNotEmpty;

  bool get hasProgress =>
      progressPercent > 0 ||
      downloadedBytes > 0;

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
      progressPercent / 100.0;

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
