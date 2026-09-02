import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:flutter_downloader/flutter_downloader.dart' as legacy;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/constants.dart';
import 'download_state_manager.dart';
import 'logger.dart';

/// Reliable manager for the large ReWoo Vision model.
///
/// Canonical flow:
///
/// model.task.part
///      ↓
/// native COMPLETE
///      ↓
/// verify size
///      ↓
/// atomic rename
///      ↓
/// model.task
///
/// Safety rules:
///
/// 1. Network/system failure NEVER deletes partial data.
/// 2. Restart NEVER creates a second task while a recoverable task exists.
/// 3. A valid final model always wins over downloader metadata.
/// 4. Completed-task finalization is idempotent / single-flight.
/// 5. Failed/paused tasks resume the SAME background task.
/// 6. Legacy failed tasks are never blindly retried from zero.
/// 7. Explicit user cancel/delete remains destructive.
/// 8. A replacement task is permitted only for a PROVEN corrupt completed task,
///    and only after another valid final/recoverable task is ruled out.
class DownloadManager {
  DownloadManager._();

  // ===========================================================================
  // CONFIG
  // ===========================================================================

  static const String _downloadGroup =
      'rewoo_vision_model';

  static const int _minimumFreeAfterDownloadMb =
      3000;

  static const int _foregroundThresholdMb =
      100;

  static const int _automaticRetries =
      5;

  static final bg.FileDownloader _downloader =
      bg.FileDownloader();

  static String? _currentTaskId;

  static Future<void>? _initializationFuture;

  /// Prevents the same completed task from being finalized concurrently by:
  ///
  /// - background callback
  /// - startup scan
  /// - getAllTasks()
  /// - retryDownload()
  static final Map<String, Future<bool>>
      _finalizationFutures =
      <String, Future<bool>>{};

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  static Future<void> initialize() {
    return _initializationFuture ??=
        _initializeInternal();
  }

  static Future<void> _initializeInternal() async {
    Logger.info(
      'Initializing background_downloader for model downloads',
    );

    _downloader.registerCallbacks(
      group:
          _downloadGroup,
      taskStatusCallback:
          _handleStatusUpdate,
      taskProgressCallback:
          _handleProgressUpdate,
    );

    _downloader.configureNotificationForGroup(
      _downloadGroup,
      running:
          const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড হচ্ছে — {progress}%',
      ),
      complete:
          const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড সম্পূর্ণ হয়েছে।',
      ),
      error:
          const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড সাময়িকভাবে বন্ধ হয়েছে।',
      ),
      paused:
          const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড pause হয়েছে।',
      ),
      canceled:
          const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড বাতিল হয়েছে।',
      ),
      progressBar:
          true,
      tapOpensFile:
          false,
    );

    final configResult =
        await _downloader.configure(
      globalConfig: [
        (
          bg.Config.checkAvailableSpace,
          _minimumFreeAfterDownloadMb,
        ),
        (
          bg.Config.requestTimeout,
          const Duration(
            seconds: 60,
          ),
        ),
      ],
      androidConfig: [
        (
          bg.Config.runInForegroundIfFileLargerThan,
          _foregroundThresholdMb,
        ),
      ],
    );

    if (configResult.isNotEmpty) {
      for (final result
          in configResult) {
        Logger.warning(
          'Downloader configuration result: $result',
        );
      }
    }

    await _downloader.start(
      doTrackTasks:
          true,
      markDownloadedComplete:
          true,
      doRescheduleKilledTasks:
          true,
      autoCleanDatabase:
          false,
    );

    // Deliver native updates that happened while Dart was suspended.
    await _downloader
        .resumeFromBackground();

    // App may have died after native 100% but before .part -> final.
    await _finalizeCompletedTasksFromDatabase();

    // If a recoverable task survived process death, attach to it immediately.
    await _restoreLatestRecoverableTaskFromDatabase();

    // Physical final model is stronger than stale SharedPreferences.
    await _repairCompletedStateFromCanonicalModel();

    Logger.info(
      'background_downloader initialization completed',
    );
  }

  static Future<void> _ensureInitialized() async {
    await initialize();
  }

  // ===========================================================================
  // BACKGROUND CALLBACKS
  // ===========================================================================

  static void _handleProgressUpdate(
    bg.TaskProgressUpdate update,
  ) {
    if (update.task.group !=
        _downloadGroup) {
      return;
    }

    final percent =
        update.progress >=
                0
            ? (update.progress *
                    100)
                .clamp(
                  0,
                  100,
                )
                .round()
            : 0;

    Logger.debug(
      'Model task ${update.task.taskId}: $percent%',
    );
  }

  static void _handleStatusUpdate(
    bg.TaskStatusUpdate update,
  ) {
    if (update.task.group !=
        _downloadGroup) {
      return;
    }

    Logger.info(
      'Model task ${update.task.taskId}: '
      '${update.status}',
    );

    if (update.status ==
        bg.TaskStatus.complete) {
      // Single-flight finalizer prevents duplicate rename races.
      unawaited(
        _finalizeCompletedTask(
          update.task,
        ),
      );
    }
  }

  // ===========================================================================
  // ATTACH
  // ===========================================================================

  static void attachToTask(
    String taskId,
  ) {
    _currentTaskId =
        taskId;

    Logger.info(
      'Attached DownloadManager to task: $taskId',
    );
  }

  // ===========================================================================
  // MODEL ACCESS CHECK
  // ===========================================================================

  static Future<int> checkModelAccess(
    String url, [
    String? accessToken,
  ]) async {
    final client =
        http.Client();

    try {
      Logger.info(
        'Checking model access at: $url',
      );

      final request =
          http.Request(
        'HEAD',
        Uri.parse(
          url,
        ),
      );

      request.followRedirects =
          true;

      if (accessToken != null &&
          accessToken
              .trim()
              .isNotEmpty) {
        request.headers[
                'Authorization'] =
            'Bearer $accessToken';
      }

      final response =
          await client
              .send(
                request,
              )
              .timeout(
        const Duration(
          seconds:
              25,
        ),
      );

      Logger.info(
        'Model access response: '
        '${response.statusCode}',
      );

      return response.statusCode;
    } on TimeoutException catch (e) {
      Logger.error(
        'Model access timeout: $e',
      );

      return -1;
    } catch (e) {
      Logger.error(
        'Network error during access check: $e',
      );

      return -1;
    } finally {
      client.close();
    }
  }

  // ===========================================================================
  // START NEW DOWNLOAD
  // ===========================================================================

  static Future<String?> startDownload({
    required String url,
    required String fileName,
    String? accessToken,
  }) async {
    try {
      await _ensureInitialized();

      // =====================================================================
      // HARD DUPLICATE-DOWNLOAD GUARD
      // =====================================================================
      //
      // Before creating a new 3+ GB task:
      //
      // 1. reuse valid canonical final
      // 2. finalize old COMPLETE .part
      // 3. reuse existing active/paused/failed task
      // 4. reuse legacy task when safe
      //
      // Only if NONE exist may a new task be enqueued.
      // =====================================================================

      final reconciliation =
          await _reconcileBeforeNewDownload(
        fileName,
      );

      if (reconciliation
          .validFinalExists) {
        Logger.info(
          'New model download blocked: '
          'a valid final model already exists.',
        );

        return null;
      }

      if (reconciliation
              .existingTaskId !=
          null) {
        _currentTaskId =
            reconciliation
                .existingTaskId;

        Logger.info(
          'New model download blocked. '
          'Reusing existing task '
          '${reconciliation.existingTaskId}.',
        );

        return reconciliation
            .existingTaskId;
      }

      // ---------------------------------------------------------------------
      // Notification permission.
      // ---------------------------------------------------------------------

      if (Platform.isAndroid) {
        try {
          final notificationStatus =
              await Permission
                  .notification
                  .request();

          if (!notificationStatus
              .isGranted) {
            Logger.warning(
              'Notification permission denied. '
              'Background download will still be attempted.',
            );
          }
        } catch (e) {
          Logger.warning(
            'Notification permission check failed: $e',
          );
        }
      }

      // ---------------------------------------------------------------------
      // Authentication
      // ---------------------------------------------------------------------

      final headers =
          <String, String>{};

      if (accessToken != null &&
          accessToken
              .trim()
              .isNotEmpty) {
        headers[
                'Authorization'] =
            'Bearer $accessToken';
      }

      final partFileName =
          _partFileName(
        fileName,
      );

      final task =
          bg.DownloadTask(
        url:
            url,
        filename:
            partFileName,
        baseDirectory:
            bg.BaseDirectory
                .applicationDocuments,
        directory:
            '',
        headers:
            headers,
        group:
            _downloadGroup,
        updates:
            bg.Updates
                .statusAndProgress,
        requiresWiFi:
            false,
        retries:
            _automaticRetries,
        allowPause:
            true,
        priority:
            5,

        // Persistent REAL final filename.
        metaData:
            fileName,

        displayName:
            'ReWoo Vision AI model',
      );

      Logger.info(
        'Starting NEW model download:\n'
        'URL: $url\n'
        'temporary destination: $partFileName\n'
        'final destination: $fileName\n'
        'taskId: ${task.taskId}',
      );

      final enqueued =
          await _downloader
              .enqueue(
        task,
      );

      if (!enqueued) {
        Logger.error(
          'background_downloader rejected the download task',
        );

        return null;
      }

      _currentTaskId =
          task.taskId;

      Logger.info(
        'Background model task created: '
        '${task.taskId}',
      );

      return task.taskId;
    } catch (e, st) {
      Logger.error(
        'Failed to start model download: $e',
      );

      Logger.error(
        '$st',
      );

      return null;
    }
  }

  // ===========================================================================
  // PRE-DOWNLOAD RECONCILIATION
  // ===========================================================================

  static Future<_DownloadReconciliation>
      _reconcileBeforeNewDownload(
    String fileName,
  ) async {
    // -----------------------------------------------------------------------
    // 1. Canonical final model already exists.
    // -----------------------------------------------------------------------

    if (await _canonicalFinalModelIsValid(
      fileName,
      repairState:
          true,
    )) {
      return const _DownloadReconciliation(
        validFinalExists:
            true,
      );
    }

    // -----------------------------------------------------------------------
    // 2. Reconcile background_downloader records.
    // -----------------------------------------------------------------------

    try {
      final records =
          await _downloader
              .database
              .allRecords(
        group:
            _downloadGroup,
      );

      // -------------------------------------------------------------
      // COMPLETE records first.
      //
      // App might have died at:
      //
      // model.task.part = 100%
      //
      // but before rename.
      // -------------------------------------------------------------

      for (final record
          in records) {
        if (record.task
            is! bg.DownloadTask) {
          continue;
        }

        final task =
            record.task
                as bg.DownloadTask;

        if (_logicalFileName(
              task,
            ) !=
            fileName) {
          continue;
        }

        if (record.status !=
            bg.TaskStatus.complete) {
          continue;
        }

        final finalized =
            await _finalizeCompletedTask(
          task,
        );

        if (finalized &&
            await _canonicalFinalModelIsValid(
              fileName,
              repairState:
                  true,
            )) {
          Logger.info(
            'Completed native task was reconciled '
            'into an existing valid final model.',
          );

          return const _DownloadReconciliation(
            validFinalExists:
                true,
          );
        }
      }

      // -------------------------------------------------------------
      // Find newest recoverable SAME task.
      // -------------------------------------------------------------

      bg.DownloadTask?
          selected;

      for (final record
          in records) {
        if (record.task
            is! bg.DownloadTask) {
          continue;
        }

        final task =
            record.task
                as bg.DownloadTask;

        if (_logicalFileName(
              task,
            ) !=
            fileName) {
          continue;
        }

        if (!_isRecoverableBackgroundStatus(
          record.status,
        )) {
          continue;
        }

        if (selected == null ||
            task.creationTime
                .isAfter(
              selected
                  .creationTime,
            )) {
          selected =
              task;
        }
      }

      if (selected != null) {
        _currentTaskId =
            selected.taskId;

        Logger.info(
          'Existing background task recovered instead of '
          'starting fresh: ${selected.taskId}',
        );

        return _DownloadReconciliation(
          existingTaskId:
              selected.taskId,
        );
      }
    } catch (e) {
      Logger.warning(
        'Background-task reconciliation warning: $e',
      );
    }

    // -----------------------------------------------------------------------
    // 3. Legacy flutter_downloader reconciliation.
    // -----------------------------------------------------------------------

    try {
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      legacy.DownloadTask?
          newestRecoverable;

      for (final task
          in oldTasks) {
        final filename =
            task.filename;

        if (filename == null) {
          continue;
        }

        final matches =
            filename ==
                    fileName ||
                filename ==
                    _partFileName(
                      fileName,
                    );

        if (!matches) {
          continue;
        }

        // -------------------------------------------------------------
        // Completed legacy final file.
        // -------------------------------------------------------------

        if (task.status ==
            legacy
                .DownloadTaskStatus
                .complete) {
          final candidate =
              File(
            '${task.savedDir}/$filename',
          );

          if (await _isValidCompletedFile(
            candidate,
          )) {
            Logger.info(
              'Valid completed legacy model found: '
              '${candidate.path}. '
              'Fresh download blocked.',
            );

            // If legacy file happens to be canonical, repair state too.
            await _repairCompletedStateFromCanonicalModel();

            return const _DownloadReconciliation(
              validFinalExists:
                  true,
            );
          }

          continue;
        }

        if (!_isRecoverableLegacyStatus(
          task.status,
        )) {
          continue;
        }

        if (newestRecoverable ==
                null ||
            task.timeCreated >
                newestRecoverable
                    .timeCreated) {
          newestRecoverable =
              task;
        }
      }

      if (newestRecoverable !=
          null) {
        _currentTaskId =
            newestRecoverable
                .taskId;

        Logger.info(
          'Existing legacy task found. '
          'Fresh download blocked: '
          '${newestRecoverable.taskId}',
        );

        return _DownloadReconciliation(
          existingTaskId:
              newestRecoverable
                  .taskId,
        );
      }
    } catch (e) {
      Logger.debug(
        'Legacy reconciliation unavailable: $e',
      );
    }

    return const _DownloadReconciliation();
  }

  // ===========================================================================
  // PAUSE
  // ===========================================================================

  static Future<void> pauseDownload() async {
    await _ensureInitialized();

    final taskId =
        _currentTaskId;

    if (taskId == null) {
      Logger.warning(
        'No current task to pause',
      );

      return;
    }

    final task =
        await _backgroundTaskForId(
      taskId,
    );

    if (task != null) {
      try {
        final paused =
            await _downloader
                .pause(
          task,
        );

        if (paused) {
          Logger.info(
            'Model download paused: $taskId',
          );
        } else {
          Logger.warning(
            'Downloader could not pause task: $taskId',
          );
        }

        return;
      } catch (e) {
        Logger.error(
          'Error pausing background task: $e',
        );

        return;
      }
    }

    try {
      await legacy
          .FlutterDownloader
          .pause(
        taskId:
            taskId,
      );

      Logger.info(
        'Legacy download paused: $taskId',
      );
    } catch (e) {
      Logger.error(
        'Could not pause legacy task: $e',
      );
    }
  }

  // ===========================================================================
  // RESUME
  // ===========================================================================

  /// Resume means:
  ///
  /// SAME TASK
  /// SAME partial transfer
  ///
  /// It never creates a replacement.
  static Future<String?> resumeDownload() async {
    await _ensureInitialized();

    final taskId =
        _currentTaskId;

    if (taskId == null) {
      await _restoreLatestRecoverableTaskFromDatabase();
    }

    final resolvedTaskId =
        _currentTaskId;

    if (resolvedTaskId == null) {
      Logger.warning(
        'No task available to resume',
      );

      return null;
    }

    final task =
        await _backgroundTaskForId(
      resolvedTaskId,
    );

    if (task != null) {
      try {
        final record =
            await _downloader
                .database
                .recordForId(
          resolvedTaskId,
        );

        // Already active.
        if (record != null &&
            (record.status ==
                    bg.TaskStatus
                        .running ||
                record.status ==
                    bg.TaskStatus
                        .enqueued ||
                record.status ==
                    bg.TaskStatus
                        .waitingToRetry)) {
          return task.taskId;
        }

        final resumed =
            await _downloader
                .resume(
          task,
        );

        if (resumed) {
          _currentTaskId =
              task.taskId;

          Logger.info(
            'Model download resumed using SAME task: '
            '${task.taskId}',
          );

          return task.taskId;
        }

        Logger.warning(
          'Native resume unavailable for '
          '${task.taskId}. '
          'No fresh task created. '
          'Partial data preserved.',
        );

        return null;
      } catch (e) {
        Logger.error(
          'Error resuming background task: $e',
        );

        Logger.warning(
          'Partial model data preserved. '
          'No fresh task created.',
        );

        return null;
      }
    }

    // -----------------------------------------------------------------------
    // Legacy paused task only.
    //
    // Do not use retry() here.
    // -----------------------------------------------------------------------

    try {
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      legacy.DownloadTask?
          oldTask;

      for (final item
          in oldTasks) {
        if (item.taskId ==
            resolvedTaskId) {
          oldTask =
              item;

          break;
        }
      }

      if (oldTask == null) {
        return null;
      }

      if (oldTask.status ==
              legacy
                  .DownloadTaskStatus
                  .running ||
          oldTask.status ==
              legacy
                  .DownloadTaskStatus
                  .enqueued) {
        return oldTask.taskId;
      }

      if (oldTask.status !=
          legacy
              .DownloadTaskStatus
              .paused) {
        Logger.warning(
          'Legacy task ${oldTask.taskId} is ${oldTask.status}; '
          'automatic fresh retry is intentionally disabled.',
        );

        return null;
      }

      final resumedId =
          await legacy
              .FlutterDownloader
              .resume(
        taskId:
            oldTask.taskId,
      );

      if (resumedId !=
          null) {
        _currentTaskId =
            resumedId;

        Logger.info(
          'Legacy paused task resumed: '
          '${oldTask.taskId} -> $resumedId',
        );
      }

      return resumedId;
    } catch (e) {
      Logger.error(
        'Legacy resume failed: $e',
      );

      return null;
    }
  }

  // ===========================================================================
  // RETRY / RECOVERY
  // ===========================================================================

  static Future<String?> retryDownload() async {
    await _ensureInitialized();

    final taskId =
        _currentTaskId;

    if (taskId == null) {
      await _restoreLatestRecoverableTaskFromDatabase();
    }

    final resolvedTaskId =
        _currentTaskId;

    if (resolvedTaskId ==
        null) {
      Logger.warning(
        'No failed task available to recover',
      );

      return null;
    }

    final record =
        await _downloader
            .database
            .recordForId(
      resolvedTaskId,
    );

    if (record != null &&
        record.task
            is bg.DownloadTask) {
      final task =
          record.task
              as bg.DownloadTask;

      // ---------------------------------------------------------------------
      // Already active.
      // ---------------------------------------------------------------------

      if (record.status ==
              bg.TaskStatus.running ||
          record.status ==
              bg.TaskStatus.enqueued ||
          record.status ==
              bg.TaskStatus
                  .waitingToRetry) {
        return task.taskId;
      }

      // ---------------------------------------------------------------------
      // Failed / paused:
      //
      // SAME task native resume only.
      // ---------------------------------------------------------------------

      if (record.status ==
              bg.TaskStatus.paused ||
          record.status ==
              bg.TaskStatus.failed) {
        try {
          final resumed =
              await _downloader
                  .resume(
            task,
          );

          if (resumed) {
            _currentTaskId =
                task.taskId;

            Logger.info(
              'Failed/paused task resumed using SAME task: '
              '${task.taskId}',
            );

            return task.taskId;
          }

          Logger.warning(
            'Could not resume task ${task.taskId}. '
            'No zero-start task was created. '
            'Partial data preserved.',
          );

          return null;
        } catch (e) {
          Logger.error(
            'Retry/resume failed: $e',
          );

          Logger.warning(
            'No replacement task created. '
            'Partial data preserved.',
          );

          return null;
        }
      }

      // ---------------------------------------------------------------------
      // COMPLETE
      // ---------------------------------------------------------------------

      if (record.status ==
          bg.TaskStatus.complete) {
        final valid =
            await _finalizeCompletedTask(
          task,
        );

        if (valid) {
          // CRITICAL:
          //
          // COMPLETE + valid final model
          // NEVER enqueue replacement.
          Logger.info(
            'Completed task already has a valid final model. '
            'Replacement download blocked.',
          );

          return task.taskId;
        }

        // Only this case may create a clean replacement:
        //
        // native says COMPLETE
        // AND final/.part verification proved corruption
        // AND no valid final/recoverable sibling exists.
        Logger.warning(
          'Completed task output is proven corrupt/truncated. '
          'Checking whether a clean replacement is safe.',
        );

        return _enqueueReplacementTask(
          task,
        );
      }

      return null;
    }

    // -----------------------------------------------------------------------
    // LEGACY FAILED TASK
    //
    // flutter_downloader.retry() may create another task ID and cannot give
    // this manager the same strong byte-resume guarantee.
    //
    // Therefore DO NOT automatically call legacy.retry().
    // -----------------------------------------------------------------------

    try {
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      legacy.DownloadTask?
          oldTask;

      for (final item
          in oldTasks) {
        if (item.taskId ==
            resolvedTaskId) {
          oldTask =
              item;

          break;
        }
      }

      if (oldTask == null) {
        return null;
      }

      if (oldTask.status ==
              legacy
                  .DownloadTaskStatus
                  .running ||
          oldTask.status ==
              legacy
                  .DownloadTaskStatus
                  .enqueued) {
        return oldTask.taskId;
      }

      if (oldTask.status ==
          legacy
              .DownloadTaskStatus
              .paused) {
        final resumedId =
            await legacy
                .FlutterDownloader
                .resume(
          taskId:
              oldTask.taskId,
        );

        if (resumedId !=
            null) {
          _currentTaskId =
              resumedId;
        }

        return resumedId;
      }

      if (oldTask.status ==
          legacy
              .DownloadTaskStatus
              .complete) {
        final filename =
            oldTask.filename;

        if (filename !=
                null &&
            oldTask.savedDir
                .isNotEmpty) {
          final file =
              File(
            '${oldTask.savedDir}/$filename',
          );

          if (await _isValidCompletedFile(
            file,
          )) {
            Logger.info(
              'Legacy completed task already has a valid model. '
              'Fresh retry blocked.',
            );

            return oldTask.taskId;
          }
        }
      }

      Logger.warning(
        'Legacy failed task cannot be guaranteed to resume byte-for-byte. '
        'Automatic legacy.retry() is disabled. '
        'Existing file data is preserved.',
      );

      return null;
    } catch (e) {
      Logger.error(
        'Legacy recovery check failed: $e',
      );

      return null;
    }
  }

  // ===========================================================================
  // CANCEL WITHOUT DELETE
  // ===========================================================================

  static Future<void> cancelDownload() async {
    await _ensureInitialized();

    final taskId =
        _currentTaskId;

    if (taskId == null) {
      return;
    }

    final task =
        await _backgroundTaskForId(
      taskId,
    );

    if (task != null) {
      try {
        await _downloader
            .cancel(
          task,
        );

        Logger.info(
          'Background download canceled: $taskId',
        );
      } catch (e) {
        Logger.error(
          'Download cancellation failed: $e',
        );
      }

      _currentTaskId =
          null;

      return;
    }

    try {
      await legacy
          .FlutterDownloader
          .cancel(
        taskId:
            taskId,
      );
    } catch (e) {
      Logger.error(
        'Legacy download cancellation failed: $e',
      );
    }

    _currentTaskId =
        null;
  }

  // ===========================================================================
  // EXPLICIT CANCEL + DELETE
  // ===========================================================================

  static Future<void>
      cancelAndDeleteDownload() async {
    await _ensureInitialized();

    final taskId =
        _currentTaskId;

    if (taskId == null) {
      Logger.info(
        'No current task to cancel/delete',
      );

      return;
    }

    final task =
        await _backgroundTaskForId(
      taskId,
    );

    if (task != null) {
      try {
        final logicalFileName =
            _logicalFileName(
          task,
        );

        final partPath =
            await task
                .filePath();

        final finalPath =
            await task
                .filePath(
          withFilename:
              logicalFileName,
        );

        try {
          await _downloader
              .cancel(
            task,
          );
        } catch (_) {}

        // EXPLICIT USER DELETE.
        await _deleteIfExists(
          partPath,
        );

        await _deleteIfExists(
          finalPath,
        );

        try {
          await _downloader
              .database
              .deleteRecordWithId(
            taskId,
          );
        } catch (e) {
          Logger.warning(
            'Could not delete downloader record: $e',
          );
        }

        _currentTaskId =
            null;

        Logger.info(
          'User explicitly canceled model download; '
          'partial/final task files deleted.',
        );

        return;
      } catch (e) {
        Logger.error(
          'Explicit background download cleanup failed: $e',
        );

        _currentTaskId =
            null;

        return;
      }
    }

    try {
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      legacy.DownloadTask?
          oldTask;

      for (final item
          in oldTasks) {
        if (item.taskId ==
            taskId) {
          oldTask =
              item;
          break;
        }
      }

      try {
        await legacy
            .FlutterDownloader
            .cancel(
          taskId:
              taskId,
        );
      } catch (_) {}

      await legacy
          .FlutterDownloader
          .remove(
        taskId:
            taskId,
        shouldDeleteContent:
            true,
      );

      if (oldTask != null &&
          oldTask.filename !=
              null &&
          oldTask.savedDir
              .isNotEmpty) {
        await _deleteLegacyTaskFiles(
          oldTask.savedDir,
          oldTask.filename!,
        );
      }

      _currentTaskId =
          null;

      Logger.info(
        'Legacy download canceled and deleted.',
      );
    } catch (e) {
      Logger.error(
        'Legacy cancel/delete failed: $e',
      );

      _currentTaskId =
          null;
    }
  }

  // ===========================================================================
  // SINGLE-FLIGHT COMPLETED FINALIZATION
  // ===========================================================================

  static Future<bool> _finalizeCompletedTask(
    bg.Task rawTask,
  ) {
    if (rawTask
        is! bg.DownloadTask) {
      return Future<bool>.value(
        false,
      );
    }

    final task =
        rawTask;

    final existing =
        _finalizationFutures[
          task.taskId
        ];

    if (existing !=
        null) {
      Logger.debug(
        'Finalization already running for '
        '${task.taskId}; joining existing operation.',
      );

      return existing;
    }

    final future =
        _finalizeCompletedTaskInternal(
      task,
    );

    _finalizationFutures[
            task.taskId] =
        future;

    future.whenComplete(
      () {
        _finalizationFutures
            .remove(
          task.taskId,
        );
      },
    );

    return future;
  }

  static Future<bool>
      _finalizeCompletedTaskInternal(
    bg.DownloadTask task,
  ) async {
    final logicalFileName =
        _logicalFileName(
      task,
    );

    try {
      final partPath =
          await task
              .filePath();

      final finalPath =
          await task
              .filePath(
        withFilename:
            logicalFileName,
      );

      final partFile =
          File(
        partPath,
      );

      final finalFile =
          File(
        finalPath,
      );

      final minimumValidSize =
          _minimumValidModelSize;

      // ---------------------------------------------------------------------
      // 1. FINAL ALREADY VALID
      // ---------------------------------------------------------------------

      if (await finalFile
          .exists()) {
        final finalSize =
            await finalFile
                .length();

        if (finalSize >=
            minimumValidSize) {
          Logger.info(
            'Verified final model already exists: '
            '$finalPath ($finalSize bytes). '
            'No replacement download required.',
          );

          // This task is COMPLETE, therefore its leftover .part is safe to
          // remove only AFTER final is proven valid.
          if (partPath !=
                  finalPath &&
              await partFile
                  .exists()) {
            try {
              await partFile
                  .delete();

              Logger.info(
                'Removed leftover completed .part after '
                'valid final was confirmed.',
              );
            } catch (e) {
              Logger.warning(
                'Could not remove leftover completed .part: $e',
              );
            }
          }

          await _repairCompletedStateFromCanonicalModel();

          return true;
        }

        // COMPLETE task + undersized final = proven bad completed output.
        Logger.error(
          'Corrupt completed final file: '
          '$finalSize bytes; '
          'minimum=$minimumValidSize',
        );

        try {
          await finalFile
              .delete();

          Logger.info(
            'Deleted proven corrupt completed final file.',
          );
        } catch (e) {
          Logger.warning(
            'Could not delete corrupt completed final: $e',
          );
        }
      }

      // ---------------------------------------------------------------------
      // 2. COMPLETED .part MUST EXIST
      // ---------------------------------------------------------------------

      if (!await partFile
          .exists()) {
        // Race safety:
        //
        // A previous finalizer might have renamed it just before this check.
        // Re-check final before declaring failure.
        if (await finalFile
            .exists()) {
          final finalSize =
              await finalFile
                  .length();

          if (finalSize >=
              minimumValidSize) {
            await _repairCompletedStateFromCanonicalModel();

            Logger.info(
              'Final file appeared during reconciliation; '
              'treating task as successfully finalized.',
            );

            return true;
          }
        }

        Logger.warning(
          'Completed task has neither valid final nor .part: '
          '$partPath',
        );

        return false;
      }

      final partSize =
          await partFile
              .length();

      // ---------------------------------------------------------------------
      // 3. COMPLETE + TOO-SMALL .part = PROVEN CORRUPT
      // ---------------------------------------------------------------------

      if (partSize <
          minimumValidSize) {
        Logger.error(
          'Completed .part file is truncated: '
          '$partSize bytes; '
          'minimum=$minimumValidSize',
        );

        try {
          await partFile
              .delete();

          Logger.info(
            'Deleted proven corrupt completed .part file.',
          );
        } catch (e) {
          Logger.error(
            'Could not delete corrupt completed .part file: $e',
          );
        }

        return false;
      }

      // ---------------------------------------------------------------------
      // 4. ATOMIC SAME-FILESYSTEM RENAME
      // ---------------------------------------------------------------------

      if (partPath !=
          finalPath) {
        await partFile
            .rename(
          finalPath,
        );
      }

      // ---------------------------------------------------------------------
      // 5. POST-RENAME VALIDATION
      // ---------------------------------------------------------------------

      if (!await finalFile
          .exists()) {
        Logger.error(
          'Final model missing after rename.',
        );

        return false;
      }

      final finalSize =
          await finalFile
              .length();

      if (finalSize <
          minimumValidSize) {
        Logger.error(
          'Final model failed post-rename validation: '
          '$finalSize bytes',
        );

        try {
          await finalFile
              .delete();
        } catch (_) {}

        return false;
      }

      await _repairCompletedStateFromCanonicalModel();

      Logger.info(
        'Model finalized exactly once:\n'
        '$partPath\n'
        '->\n'
        '$finalPath\n'
        '$finalSize bytes',
      );

      return true;
    } catch (e, st) {
      // A filesystem/rename error is NOT a reason to delete valid .part data.
      Logger.error(
        'Model finalization failed: $e',
      );

      Logger.error(
        '$st',
      );

      Logger.warning(
        'Downloaded .part file was preserved whenever still present.',
      );

      // Last race-safe check.
      try {
        if (await _canonicalFinalModelIsValid(
          logicalFileName,
          repairState:
              true,
        )) {
          return true;
        }
      } catch (_) {}

      return false;
    }
  }

  // ===========================================================================
  // STARTUP COMPLETED TASK RECONCILIATION
  // ===========================================================================

  static Future<void>
      _finalizeCompletedTasksFromDatabase() async {
    try {
      final records =
          await _downloader
              .database
              .allRecords(
        group:
            _downloadGroup,
      );

      for (final record
          in records) {
        if (record.status !=
                bg.TaskStatus
                    .complete ||
            record.task
                is! bg.DownloadTask) {
          continue;
        }

        await _finalizeCompletedTask(
          record.task,
        );
      }
    } catch (e) {
      Logger.warning(
        'Startup model finalization scan failed: $e',
      );
    }
  }

  // ===========================================================================
  // RESTORE RECOVERABLE TASK AFTER PROCESS RESTART
  // ===========================================================================

  static Future<void>
      _restoreLatestRecoverableTaskFromDatabase() async {
    try {
      final records =
          await _downloader
              .database
              .allRecords(
        group:
            _downloadGroup,
      );

      bg.DownloadTask?
          selected;

      for (final record
          in records) {
        if (record.task
            is! bg.DownloadTask) {
          continue;
        }

        if (!_isRecoverableBackgroundStatus(
          record.status,
        )) {
          continue;
        }

        final task =
            record.task
                as bg.DownloadTask;

        if (selected ==
                null ||
            task.creationTime
                .isAfter(
              selected
                  .creationTime,
            )) {
          selected =
              task;
        }
      }

      if (selected ==
          null) {
        return;
      }

      _currentTaskId =
          selected.taskId;

      Logger.info(
        'Restored recoverable background task after restart: '
        '${selected.taskId}',
      );
    } catch (e) {
      Logger.warning(
        'Could not restore background task after restart: $e',
      );
    }
  }

  // ===========================================================================
  // REPLACEMENT — ONLY PROVEN CORRUPT COMPLETE
  // ===========================================================================

  static Future<String?>
      _enqueueReplacementTask(
    bg.DownloadTask previous,
  ) async {
    final logicalFileName =
        _logicalFileName(
      previous,
    );

    // -----------------------------------------------------------------------
    // Re-check final immediately before replacement.
    //
    // Another callback/finalizer may have completed successfully.
    // -----------------------------------------------------------------------

    if (await _canonicalFinalModelIsValid(
      logicalFileName,
      repairState:
          true,
    )) {
      Logger.info(
        'Replacement canceled: '
        'valid final model appeared during reconciliation.',
      );

      return previous.taskId;
    }

    // -----------------------------------------------------------------------
    // Never enqueue a replacement while ANOTHER recoverable task exists.
    // -----------------------------------------------------------------------

    final sibling =
        await _findRecoverableBackgroundTask(
      logicalFileName,
      excludingTaskId:
          previous.taskId,
    );

    if (sibling !=
        null) {
      _currentTaskId =
          sibling.taskId;

      Logger.warning(
        'Replacement canceled: '
        'another recoverable task already exists '
        '(${sibling.taskId}).',
      );

      return sibling.taskId;
    }

    final replacement =
        bg.DownloadTask(
      url:
          previous.url,
      filename:
          _partFileName(
        logicalFileName,
      ),
      baseDirectory:
          previous
              .baseDirectory,
      directory:
          previous.directory,
      headers:
          previous.headers,
      group:
          _downloadGroup,
      updates:
          bg.Updates
              .statusAndProgress,
      requiresWiFi:
          previous.requiresWiFi,
      retries:
          _automaticRetries,
      allowPause:
          true,
      priority:
          5,
      metaData:
          logicalFileName,
      displayName:
          previous.displayName
                  .isNotEmpty
              ? previous.displayName
              : 'ReWoo Vision AI model',
    );

    final enqueued =
        await _downloader
            .enqueue(
      replacement,
    );

    if (!enqueued) {
      Logger.error(
        'Could not enqueue replacement model task.',
      );

      return null;
    }

    _currentTaskId =
        replacement.taskId;

    Logger.warning(
      'Clean replacement created ONLY because '
      'the previous COMPLETE output was proven corrupt: '
      '${replacement.taskId}',
    );

    return replacement.taskId;
  }

  // ===========================================================================
  // BACKGROUND TASK LOOKUP
  // ===========================================================================

  static Future<bg.DownloadTask?>
      _backgroundTaskForId(
    String taskId,
  ) async {
    try {
      final activeTask =
          await _downloader
              .taskForId(
        taskId,
      );

      if (activeTask
          is bg.DownloadTask) {
        return activeTask;
      }

      final record =
          await _downloader
              .database
              .recordForId(
        taskId,
      );

      if (record?.task
          is bg.DownloadTask) {
        return record!.task
            as bg.DownloadTask;
      }
    } catch (e) {
      Logger.warning(
        'Could not resolve background task $taskId: $e',
      );
    }

    return null;
  }

  static Future<bg.DownloadTask?>
      _findRecoverableBackgroundTask(
    String logicalFileName, {
    String? excludingTaskId,
  }) async {
    try {
      final records =
          await _downloader
              .database
              .allRecords(
        group:
            _downloadGroup,
      );

      bg.DownloadTask?
          selected;

      for (final record
          in records) {
        if (record.task
            is! bg.DownloadTask) {
          continue;
        }

        final task =
            record.task
                as bg.DownloadTask;

        if (excludingTaskId !=
                null &&
            task.taskId ==
                excludingTaskId) {
          continue;
        }

        if (_logicalFileName(
              task,
            ) !=
            logicalFileName) {
          continue;
        }

        if (!_isRecoverableBackgroundStatus(
          record.status,
        )) {
          continue;
        }

        if (selected ==
                null ||
            task.creationTime
                .isAfter(
              selected
                  .creationTime,
            )) {
          selected =
              task;
        }
      }

      return selected;
    } catch (e) {
      Logger.warning(
        'Recoverable-task lookup failed: $e',
      );

      return null;
    }
  }

  // ===========================================================================
  // COMPATIBILITY TASK LIST
  // ===========================================================================

  static Future<List<legacy.DownloadTask>>
      getAllTasks() async {
    await _ensureInitialized();

    final result =
        <legacy.DownloadTask>[];

    final ids =
        <String>{};

    try {
      final records =
          await _downloader
              .database
              .allRecords(
        group:
            _downloadGroup,
      );

      for (final record
          in records) {
        if (record.task
            is! bg.DownloadTask) {
          continue;
        }

        final converted =
            await _toLegacyTask(
          record,
        );

        result.add(
          converted,
        );

        ids.add(
          converted.taskId,
        );
      }
    } catch (e) {
      Logger.error(
        'Could not read background download database: $e',
      );
    }

    try {
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      for (final task
          in oldTasks) {
        if (ids.add(
          task.taskId,
        )) {
          result.add(
            task,
          );
        }
      }
    } catch (e) {
      Logger.debug(
        'Legacy task database unavailable: $e',
      );
    }

    return result;
  }

  static Future<legacy.DownloadTask>
      _toLegacyTask(
    bg.TaskRecord record,
  ) async {
    final task =
        record.task
            as bg.DownloadTask;

    bg.TaskStatus
        effectiveStatus =
        record.status;

    if (record.status ==
        bg.TaskStatus.complete) {
      final finalized =
          await _finalizeCompletedTask(
        task,
      );

      if (!finalized) {
        effectiveStatus =
            bg.TaskStatus.failed;
      }
    }

    final filePath =
        await task
            .filePath();

    final savedDir =
        File(
      filePath,
    ).parent.path;

    final progress =
        _legacyProgressPercent(
      record.progress,
    );

    return legacy.DownloadTask(
      taskId:
          task.taskId,
      status:
          _legacyStatus(
        effectiveStatus,
      ),
      progress:
          progress,
      url:
          task.url,

      // Logical model filename, not physical .part filename.
      filename:
          _logicalFileName(
        task,
      ),

      savedDir:
          savedDir,
      timeCreated:
          task.creationTime
              .millisecondsSinceEpoch,
      allowCellular:
          !task.requiresWiFi,
    );
  }

  static legacy.DownloadTaskStatus
      _legacyStatus(
    bg.TaskStatus status,
  ) {
    switch (status) {
      case bg.TaskStatus.enqueued:
      case bg.TaskStatus.waitingToRetry:
        return legacy
            .DownloadTaskStatus
            .enqueued;

      case bg.TaskStatus.running:
        return legacy
            .DownloadTaskStatus
            .running;

      case bg.TaskStatus.complete:
        return legacy
            .DownloadTaskStatus
            .complete;

      case bg.TaskStatus.paused:
        return legacy
            .DownloadTaskStatus
            .paused;

      case bg.TaskStatus.canceled:
        return legacy
            .DownloadTaskStatus
            .canceled;

      case bg.TaskStatus.notFound:
      case bg.TaskStatus.failed:
        return legacy
            .DownloadTaskStatus
            .failed;
    }
  }

  static int _legacyProgressPercent(
    double progress,
  ) {
    if (progress <=
        0) {
      return 0;
    }

    if (progress >=
        1) {
      return 100;
    }

    return (progress *
            100)
        .round()
        .clamp(
          0,
          100,
        );
  }

  // ===========================================================================
  // STATUS HELPERS
  // ===========================================================================

  static bool _isRecoverableBackgroundStatus(
    bg.TaskStatus status,
  ) {
    return status ==
            bg.TaskStatus
                .running ||
        status ==
            bg.TaskStatus
                .enqueued ||
        status ==
            bg.TaskStatus
                .waitingToRetry ||
        status ==
            bg.TaskStatus
                .paused ||
        status ==
            bg.TaskStatus
                .failed;
  }

  static bool _isRecoverableLegacyStatus(
    legacy.DownloadTaskStatus status,
  ) {
    return status ==
            legacy
                .DownloadTaskStatus
                .running ||
        status ==
            legacy
                .DownloadTaskStatus
                .enqueued ||
        status ==
            legacy
                .DownloadTaskStatus
                .paused ||
        status ==
            legacy
                .DownloadTaskStatus
                .failed;
  }

  // ===========================================================================
  // PHYSICAL FINAL MODEL
  // ===========================================================================

  static int get _minimumValidModelSize =>
      (expectedModelFileSize *
              modelSizeTolerance)
          .round();

  static Future<bool>
      _isValidCompletedFile(
    File file,
  ) async {
    try {
      if (!await file
          .exists()) {
        return false;
      }

      final size =
          await file
              .length();

      return size >=
          _minimumValidModelSize;
    } catch (_) {
      return false;
    }
  }

  static Future<bool>
      _canonicalFinalModelIsValid(
    String fileName, {
    required bool repairState,
  }) async {
    try {
      final documents =
          await getApplicationDocumentsDirectory();

      final file =
          File(
        '${documents.path}/$fileName',
      );

      if (!await _isValidCompletedFile(
        file,
      )) {
        return false;
      }

      if (repairState) {
        try {
          final size =
              await file
                  .length();

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
            'Canonical model is valid but state repair failed: $e',
          );
        }
      }

      return true;
    } catch (e) {
      Logger.warning(
        'Canonical final model check failed: $e',
      );

      return false;
    }
  }

  static Future<bool>
      _repairCompletedStateFromCanonicalModel() async {
    return _canonicalFinalModelIsValid(
      modelName,
      repairState:
          true,
    );
  }

  // ===========================================================================
  // SAFE FAILED DOWNLOAD CLEANUP
  // ===========================================================================

  static Future<void>
      cleanupFailedDownloads() async {
    Logger.info(
      'cleanupFailedDownloads(): '
      'failed/paused partial model downloads are intentionally preserved.',
    );
  }

  // ===========================================================================
  // EXPLICIT FULL MODEL CLEANUP
  // ===========================================================================

  static Future<void>
      cleanupAllModelFiles() async {
    await _ensureInitialized();

    try {
      try {
        await _downloader
            .cancelAll(
          group:
              _downloadGroup,
        );
      } catch (_) {}

      final records =
          await _downloader
              .database
              .allRecords(
        group:
            _downloadGroup,
      );

      for (final record
          in records) {
        if (record.task
            is bg.DownloadTask) {
          final task =
              record.task
                  as bg.DownloadTask;

          try {
            final partPath =
                await task
                    .filePath();

            final finalPath =
                await task
                    .filePath(
              withFilename:
                  _logicalFileName(
                task,
              ),
            );

            await _deleteIfExists(
              partPath,
            );

            await _deleteIfExists(
              finalPath,
            );
          } catch (_) {}
        }

        try {
          await _downloader
              .database
              .deleteRecordWithId(
            record.taskId,
          );
        } catch (_) {}
      }

      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      for (final task
          in oldTasks) {
        final filename =
            task.filename;

        if (filename ==
            null) {
          continue;
        }

        final lower =
            filename
                .toLowerCase();

        if (lower ==
                modelName
                    .toLowerCase() ||
            lower ==
                '${modelName.toLowerCase()}.part') {
          try {
            await legacy
                .FlutterDownloader
                .remove(
              taskId:
                  task.taskId,
              shouldDeleteContent:
                  true,
            );
          } catch (_) {}
        }
      }

      _currentTaskId =
          null;

      Logger.info(
        'All model download data explicitly cleaned.',
      );
    } catch (e) {
      Logger.error(
        'cleanupAllModelFiles failed: $e',
      );
    }
  }

  // ===========================================================================
  // FILE HELPERS
  // ===========================================================================

  static String _partFileName(
    String finalFileName,
  ) {
    if (finalFileName
        .endsWith(
      '.part',
    )) {
      return finalFileName;
    }

    return '$finalFileName.part';
  }

  static String _logicalFileName(
    bg.DownloadTask task,
  ) {
    final meta =
        task.metaData
            .trim();

    if (meta.isNotEmpty) {
      return meta;
    }

    final filename =
        task.filename;

    if (filename
        .endsWith(
      '.part',
    )) {
      return filename
          .substring(
        0,
        filename.length -
            '.part'.length,
      );
    }

    return filename;
  }

  static Future<void> _deleteIfExists(
    String path,
  ) async {
    final file =
        File(
      path,
    );

    if (!await file
        .exists()) {
      return;
    }

    try {
      await file
          .delete();

      Logger.info(
        'Deleted file: $path',
      );
    } catch (e) {
      Logger.error(
        'Could not delete $path: $e',
      );
    }
  }

  static Future<void>
      _deleteLegacyTaskFiles(
    String savedDir,
    String filename,
  ) async {
    if (savedDir
            .isEmpty ||
        filename
            .isEmpty) {
      return;
    }

    final basePath =
        '$savedDir/$filename';

    await _deleteIfExists(
      basePath,
    );

    await _deleteIfExists(
      '$basePath.part',
    );

    await _deleteIfExists(
      '$basePath.tmp',
    );

    await _deleteIfExists(
      '$basePath.download',
    );

    await _deleteIfExists(
      '$basePath.crdownload',
    );
  }
}

// =============================================================================
// INTERNAL RECONCILIATION RESULT
// =============================================================================

class _DownloadReconciliation {
  final bool validFinalExists;

  final String? existingTaskId;

  const _DownloadReconciliation({
    this.validFinalExists =
        false,
    this.existingTaskId,
  });
}
