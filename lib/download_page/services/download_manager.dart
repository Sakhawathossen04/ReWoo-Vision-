import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:flutter_downloader/flutter_downloader.dart' as legacy;
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../config/constants.dart';
import 'logger.dart';

/// Reliable manager for the large ReWoo Vision model.
///
/// NEW DOWNLOAD ENGINE:
///
/// background_downloader
///
/// TEMPORARY COMPATIBILITY:
///
/// flutter_downloader types are still exposed from [getAllTasks] so the
/// current download_logic.dart can continue compiling during the migration.
///
/// Final architecture:
///
/// model.task
///      ↑
/// atomic rename after validation
///      ↑
/// model.task.part
///      ↑
/// background_downloader resumable temporary data
///
/// IMPORTANT:
///
/// Network/system failures NEVER delete partial download data.
///
/// Partial content is destroyed only when:
///
/// 1. user explicitly calls [cancelAndDeleteDownload], or
/// 2. a task reports complete but its file is verified as truncated/corrupt.
class DownloadManager {
  DownloadManager._();

  // ===========================================================================
  // CONFIG
  // ===========================================================================

  static const String _downloadGroup =
      'rewoo_vision_model';

  /// Keep roughly 3 GB free AFTER the model has downloaded.
  ///
  /// The model itself is roughly 3.1 GB, so this creates an additional
  /// low-storage guard roughly equivalent to requiring ~6 GB before download.
  ///
  /// DeviceCapabilityService will later perform the explicit pre-download
  /// free-storage check too.
  static const int _minimumFreeAfterDownloadMb =
      3000;

  /// Any download larger than this uses foreground mode on Android.
  ///
  /// Our 3.1 GB model will therefore always use the foreground path.
  static const int _foregroundThresholdMb =
      100;

  static const int _automaticRetries =
      5;

  static final bg.FileDownloader _downloader =
      bg.FileDownloader();

  static String? _currentTaskId;

  static Future<void>? _initializationFuture;

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

    // -----------------------------------------------------------------------
    // Register callbacks BEFORE start().
    //
    // Group callbacks avoid taking ownership of the global updates stream.
    // -----------------------------------------------------------------------

    _downloader.registerCallbacks(
      group: _downloadGroup,
      taskStatusCallback:
          _handleStatusUpdate,
      taskProgressCallback:
          _handleProgressUpdate,
    );

    // -----------------------------------------------------------------------
    // Notifications
    //
    // A running notification is also necessary for Android foreground mode.
    // -----------------------------------------------------------------------

    _downloader.configureNotificationForGroup(
      _downloadGroup,

      running: const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড হচ্ছে — {progress}%',
      ),

      complete: const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড সম্পূর্ণ হয়েছে।',
      ),

      error: const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড সাময়িকভাবে বন্ধ হয়েছে।',
      ),

      paused: const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড pause হয়েছে।',
      ),

      canceled: const bg.TaskNotification(
        'ReWoo Vision',
        'AI model ডাউনলোড বাতিল হয়েছে।',
      ),

      progressBar: true,
      tapOpensFile: false,
    );

    // -----------------------------------------------------------------------
    // Global downloader configuration.
    // -----------------------------------------------------------------------

    final configResult =
        await _downloader.configure(
      globalConfig: [
        // Fail before exhausting storage.
        (
          bg.Config.checkAvailableSpace,
          _minimumFreeAfterDownloadMb,
        ),

        // Give slow servers enough time to establish connections.
        (
          bg.Config.requestTimeout,
          const Duration(seconds: 60),
        ),
      ],

      androidConfig: [
        // 3.1 GB model should use Android foreground mode.
        (
          bg.Config.runInForegroundIfFileLargerThan,
          _foregroundThresholdMb,
        ),
      ],
    );

    if (configResult.isNotEmpty) {
      for (final result in configResult) {
        Logger.warning(
          'Downloader configuration result: $result',
        );
      }
    }

    // -----------------------------------------------------------------------
    // Enable persistent database tracking.
    //
    // autoCleanDatabase is deliberately FALSE. We do not want useful failed
    // task history disappearing automatically.
    // -----------------------------------------------------------------------

    await _downloader.start(
      doTrackTasks: true,
      markDownloadedComplete: true,
      doRescheduleKilledTasks: true,
      autoCleanDatabase: false,
    );

    // Deliver any updates that happened while Dart was suspended.
    await _downloader.resumeFromBackground();

    // A download may have completed while the application was terminated.
    // Finish .part -> final rename now.
    await _finalizeCompletedTasksFromDatabase();

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
        update.progress >= 0
            ? (update.progress * 100)
                .clamp(0, 100)
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
      unawaited(
        _finalizeCompletedTask(
          update.task,
        ),
      );
    }
  }

  // ===========================================================================
  // ATTACH TO SAVED TASK
  // ===========================================================================

  static void attachToTask(
    String taskId,
  ) {
    _currentTaskId = taskId;

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
        Uri.parse(url),
      );

      request.followRedirects = true;

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
        const Duration(seconds: 25),
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

      // ---------------------------------------------------------------------
      // Android 13+ notification runtime permission.
      //
      // The download itself may continue without this permission, but
      // foreground notification behavior can be degraded if denied.
      // ---------------------------------------------------------------------

      if (Platform.isAndroid) {
        try {
          final notificationStatus =
              await Permission.notification
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
      // Authentication headers
      // ---------------------------------------------------------------------

      final headers =
          <String, String>{};

      if (accessToken != null &&
          accessToken.trim().isNotEmpty) {
        headers['Authorization'] =
            'Bearer $accessToken';
      }

      // ---------------------------------------------------------------------
      // IMPORTANT:
      //
      // Never download directly into the final Gemma filename.
      //
      // Example:
      //
      // gemma.task
      //
      // becomes:
      //
      // gemma.task.part
      //
      // Only after completion + size validation do we atomically rename it.
      // ---------------------------------------------------------------------

      final partFileName =
          _partFileName(
        fileName,
      );

      final task =
          bg.DownloadTask(
        url: url,

        filename:
            partFileName,

        baseDirectory:
            bg.BaseDirectory
                .applicationDocuments,

        directory: '',

        headers:
            headers,

        group:
            _downloadGroup,

        updates:
            bg.Updates
                .statusAndProgress,

        // Mobile data is allowed.
        requiresWiFi: false,

        // Native retry support.
        retries:
            _automaticRetries,

        // CRITICAL for multi-GB Android downloads.
        //
        // Allows temporary failures / Android worker timeout to pause and
        // resume when the server supports partial transfers.
        allowPause: true,

        // Do NOT use priority 0 here.
        //
        // Priority 0 activates Android UIDT behavior on newer Android and
        // requires additional manifest/config work. Foreground mode above is
        // our selected large-file path.
        priority: 5,

        // Store the REAL final filename persistently with the task.
        metaData:
            fileName,

        displayName:
            'ReWoo Vision AI model',
      );

      Logger.info(
        'Starting model download:\n'
        'URL: $url\n'
        'temporary destination: $partFileName\n'
        'final destination: $fileName\n'
        'taskId: ${task.taskId}',
      );

      final enqueued =
          await _downloader.enqueue(
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

      Logger.error('$st');

      return null;
    }
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

    // -----------------------------------------------------------------------
    // New background_downloader task
    // -----------------------------------------------------------------------

    final task =
        await _backgroundTaskForId(
      taskId,
    );

    if (task != null) {
      try {
        final paused =
            await _downloader.pause(
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

    // -----------------------------------------------------------------------
    // Temporary migration compatibility:
    // old flutter_downloader task from a previous app build.
    // -----------------------------------------------------------------------

    try {
      await legacy.FlutterDownloader
          .pause(
        taskId: taskId,
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

  /// Attempts to continue the existing partial transfer.
  ///
  /// IMPORTANT:
  ///
  /// If native resume fails, this method returns null.
  ///
  /// It DOES NOT:
  ///
  /// - delete the partial file
  /// - create a fresh task
  /// - restart from zero
  static Future<String?> resumeDownload() async {
    await _ensureInitialized();

    final taskId =
        _currentTaskId;

    if (taskId == null) {
      Logger.warning(
        'No task available to resume',
      );

      return null;
    }

    final task =
        await _backgroundTaskForId(
      taskId,
    );

    if (task != null) {
      try {
        final resumed =
            await _downloader.resume(
          task,
        );

        if (resumed) {
          _currentTaskId =
              task.taskId;

          Logger.info(
            'Model download resumed: '
            '${task.taskId}',
          );

          return task.taskId;
        }

        Logger.warning(
          'Native resume was not available for '
          '${task.taskId}. '
          'Partial data was NOT deleted.',
        );

        return null;
      } catch (e) {
        Logger.error(
          'Error resuming background task: $e',
        );

        Logger.warning(
          'Partial model data is being preserved.',
        );

        return null;
      }
    }

    // -----------------------------------------------------------------------
    // Legacy migration fallback
    // -----------------------------------------------------------------------

    try {
      final newTaskId =
          await legacy
              .FlutterDownloader
              .resume(
        taskId: taskId,
      );

      if (newTaskId != null) {
        _currentTaskId =
            newTaskId;

        Logger.info(
          'Legacy download resumed: '
          '$taskId -> $newTaskId',
        );
      }

      return newTaskId;
    } catch (e) {
      Logger.error(
        'Legacy resume failed: $e',
      );

      return null;
    }
  }

  // ===========================================================================
  // RETRY
  // ===========================================================================

  /// Recovery for a failed download.
  ///
  /// For background_downloader, retry means:
  ///
  /// first try RESUME of the existing partial transfer.
  ///
  /// We deliberately DO NOT create a brand-new task when resume fails.
  ///
  /// Exception:
  ///
  /// If the task was reported COMPLETE but its downloaded file is proven
  /// corrupt/truncated, a clean replacement task is allowed.
  static Future<String?> retryDownload() async {
    await _ensureInitialized();

    final taskId =
        _currentTaskId;

    if (taskId == null) {
      Logger.warning(
        'No failed task available to retry',
      );

      return null;
    }

    final record =
        await _downloader.database
            .recordForId(
      taskId,
    );

    if (record != null &&
        record.task is bg.DownloadTask) {
      final task =
          record.task
              as bg.DownloadTask;

      // ---------------------------------------------------------------------
      // Active task: nothing to recreate.
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
      // Paused / failed:
      // attempt native byte resume.
      // ---------------------------------------------------------------------

      if (record.status ==
              bg.TaskStatus.paused ||
          record.status ==
              bg.TaskStatus.failed) {
        try {
          final resumed =
              await _downloader.resume(
            task,
          );

          if (resumed) {
            _currentTaskId =
                task.taskId;

            Logger.info(
              'Failed/paused model task resumed: '
              '${task.taskId}',
            );

            return task.taskId;
          }

          Logger.warning(
            'Retry could not resume task '
            '${task.taskId}. '
            'Partial data remains preserved.',
          );

          return null;
        } catch (e) {
          Logger.error(
            'Retry/resume failed: $e',
          );

          return null;
        }
      }

      // ---------------------------------------------------------------------
      // COMPLETE but corrupt.
      //
      // A genuinely completed but truncated file has no useful resumable
      // transfer anymore. A fresh task is permitted in this specific case.
      // ---------------------------------------------------------------------

      if (record.status ==
          bg.TaskStatus.complete) {
        final valid =
            await _finalizeCompletedTask(
          task,
        );

        if (valid) {
          return task.taskId;
        }

        Logger.warning(
          'Completed task was corrupt. '
          'Creating a clean replacement download.',
        );

        return _enqueueReplacementTask(
          task,
        );
      }

      // canceled / notFound:
      // never silently create a new multi-GB task.
      return null;
    }

    // -----------------------------------------------------------------------
    // Legacy failed task migration fallback.
    // -----------------------------------------------------------------------

    try {
      final newTaskId =
          await legacy
              .FlutterDownloader
              .retry(
        taskId: taskId,
      );

      if (newTaskId != null) {
        _currentTaskId =
            newTaskId;

        Logger.info(
          'Legacy task retried: '
          '$taskId -> $newTaskId',
        );
      }

      return newTaskId;
    } catch (e) {
      Logger.error(
        'Legacy retry failed: $e',
      );

      return null;
    }
  }

  // ===========================================================================
  // CANCEL WITHOUT EXTRA CLEANUP
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
        await _downloader.cancel(
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

      _currentTaskId = null;

      return;
    }

    try {
      await legacy.FlutterDownloader
          .cancel(
        taskId: taskId,
      );
    } catch (e) {
      Logger.error(
        'Legacy download cancellation failed: $e',
      );
    }

    _currentTaskId = null;
  }

  // ===========================================================================
  // EXPLICIT CANCEL + DELETE
  // ===========================================================================

  /// Destructive operation.
  ///
  /// Call ONLY after the user explicitly confirms cancellation.
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
            await task.filePath();

        final finalPath =
            await task.filePath(
          withFilename:
              logicalFileName,
        );

        // Cancel native worker first.
        try {
          await _downloader.cancel(
            task,
          );
        } catch (_) {}

        // User explicitly requested deletion.
        await _deleteIfExists(
          partPath,
        );

        await _deleteIfExists(
          finalPath,
        );

        // Remove persistent task record.
        try {
          await _downloader.database
              .deleteRecordWithId(
            taskId,
          );
        } catch (e) {
          Logger.warning(
            'Could not delete downloader record: $e',
          );
        }

        _currentTaskId = null;

        Logger.info(
          'User canceled model download; '
          'partial/final task files deleted.',
        );

        return;
      } catch (e) {
        Logger.error(
          'Explicit background download cleanup failed: $e',
        );

        _currentTaskId = null;

        return;
      }
    }

    // -----------------------------------------------------------------------
    // Old flutter_downloader task.
    // -----------------------------------------------------------------------

    try {
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      legacy.DownloadTask? oldTask;

      for (final item in oldTasks) {
        if (item.taskId ==
            taskId) {
          oldTask = item;

          break;
        }
      }

      try {
        await legacy
            .FlutterDownloader
            .cancel(
          taskId: taskId,
        );
      } catch (_) {}

      await legacy.FlutterDownloader
          .remove(
        taskId: taskId,
        shouldDeleteContent: true,
      );

      if (oldTask != null &&
          oldTask.filename != null &&
          oldTask.savedDir.isNotEmpty) {
        await _deleteLegacyTaskFiles(
          oldTask.savedDir,
          oldTask.filename!,
        );
      }

      _currentTaskId = null;

      Logger.info(
        'Legacy download canceled and deleted.',
      );
    } catch (e) {
      Logger.error(
        'Legacy cancel/delete failed: $e',
      );

      _currentTaskId = null;
    }
  }

  // ===========================================================================
  // FINALIZATION
  // ===========================================================================

  /// Convert:
  ///
  /// model.task.part
  ///
  /// into:
  ///
  /// model.task
  ///
  /// only after final size validation.
  ///
  /// Returns true when a verified final file exists.
  static Future<bool> _finalizeCompletedTask(
    bg.Task rawTask,
  ) async {
    if (rawTask is! bg.DownloadTask) {
      return false;
    }

    final task =
        rawTask;

    final logicalFileName =
        _logicalFileName(
      task,
    );

    try {
      final partPath =
          await task.filePath();

      final finalPath =
          await task.filePath(
        withFilename:
            logicalFileName,
      );

      final partFile =
          File(partPath);

      final finalFile =
          File(finalPath);

      final minimumValidSize =
          (expectedModelFileSize *
                  modelSizeTolerance)
              .round();

      // ---------------------------------------------------------------------
      // Final model already exists and is valid.
      // ---------------------------------------------------------------------

      if (await finalFile.exists()) {
        final finalSize =
            await finalFile.length();

        if (finalSize >=
            minimumValidSize) {
          Logger.info(
            'Verified final model already exists: '
            '$finalPath ($finalSize bytes)',
          );

          // Remove leftover .part only after final model is proven valid.
          if (partPath !=
                  finalPath &&
              await partFile.exists()) {
            try {
              await partFile.delete();
            } catch (_) {}
          }

          return true;
        }

        // A task is COMPLETE and its final file is provably truncated.
        // Safe to remove this corrupt final result.
        Logger.error(
          'Corrupt completed final file: '
          '$finalSize bytes; '
          'minimum required: $minimumValidSize',
        );

        try {
          await finalFile.delete();
        } catch (_) {}
      }

      // ---------------------------------------------------------------------
      // Completed .part result must exist.
      // ---------------------------------------------------------------------

      if (!await partFile.exists()) {
        Logger.warning(
          'Completed task has no .part output: '
          '$partPath',
        );

        return false;
      }

      final partSize =
          await partFile.length();

      // ---------------------------------------------------------------------
      // COMPLETE + undersized means corruption/truncation.
      //
      // This is NOT a normal network-failure case.
      // ---------------------------------------------------------------------

      if (partSize <
          minimumValidSize) {
        Logger.error(
          'Completed .part file is truncated: '
          '$partSize bytes; '
          'minimum required: $minimumValidSize',
        );

        try {
          await partFile.delete();

          Logger.info(
            'Deleted verified corrupt completed .part file.',
          );
        } catch (e) {
          Logger.error(
            'Could not delete corrupt .part file: $e',
          );
        }

        return false;
      }

      // ---------------------------------------------------------------------
      // Atomic same-filesystem rename.
      // ---------------------------------------------------------------------

      if (partPath !=
          finalPath) {
        await partFile.rename(
          finalPath,
        );
      }

      // ---------------------------------------------------------------------
      // Verify again after rename.
      // ---------------------------------------------------------------------

      if (!await finalFile.exists()) {
        Logger.error(
          'Final model missing after rename.',
        );

        return false;
      }

      final finalSize =
          await finalFile.length();

      if (finalSize <
          minimumValidSize) {
        Logger.error(
          'Final model failed post-rename validation.',
        );

        try {
          await finalFile.delete();
        } catch (_) {}

        return false;
      }

      Logger.info(
        'Model finalized successfully:\n'
        '$partPath\n'
        '->\n'
        '$finalPath\n'
        '$finalSize bytes',
      );

      return true;
    } catch (e, st) {
      // A rename/filesystem error is NOT grounds for deleting a valid .part.
      Logger.error(
        'Model finalization failed: $e',
      );

      Logger.error('$st');

      Logger.warning(
        'Downloaded .part file was preserved.',
      );

      return false;
    }
  }

  /// App may have been killed after native completion but before Dart had a
  /// chance to rename .part -> final.
  static Future<void>
      _finalizeCompletedTasksFromDatabase() async {
    try {
      final records =
          await _downloader.database
              .allRecords(
        group:
            _downloadGroup,
      );

      for (final record in records) {
        if (record.status ==
                bg.TaskStatus.complete &&
            record.task
                is bg.DownloadTask) {
          await _finalizeCompletedTask(
            record.task,
          );
        }
      }
    } catch (e) {
      Logger.warning(
        'Startup model finalization scan failed: $e',
      );
    }
  }

  // ===========================================================================
  // FRESH REPLACEMENT — ONLY FOR VERIFIED CORRUPT COMPLETE TASK
  // ===========================================================================

  static Future<String?>
      _enqueueReplacementTask(
    bg.DownloadTask previous,
  ) async {
    final logicalFileName =
        _logicalFileName(
      previous,
    );

    final replacement =
        bg.DownloadTask(
      url:
          previous.url,

      filename:
          _partFileName(
        logicalFileName,
      ),

      baseDirectory:
          previous.baseDirectory,

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

      allowPause: true,

      priority: 5,

      metaData:
          logicalFileName,

      displayName:
          previous.displayName
                  .isNotEmpty
              ? previous.displayName
              : 'ReWoo Vision AI model',
    );

    final enqueued =
        await _downloader.enqueue(
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

    Logger.info(
      'Created replacement task after verified corruption: '
      '${replacement.taskId}',
    );

    return replacement.taskId;
  }

  // ===========================================================================
  // GET BACKGROUND TASK
  // ===========================================================================

  static Future<bg.DownloadTask?>
      _backgroundTaskForId(
    String taskId,
  ) async {
    try {
      final activeTask =
          await _downloader.taskForId(
        taskId,
      );

      if (activeTask
          is bg.DownloadTask) {
        return activeTask;
      }

      final record =
          await _downloader.database
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

  // ===========================================================================
  // COMPATIBILITY TASK LIST
  // ===========================================================================

  /// Returns flutter_downloader-compatible task objects so the existing
  /// download_logic.dart can continue working during migration.
  ///
  /// NEW background_downloader records are converted into legacy-looking
  /// DownloadTask objects.
  ///
  /// Old flutter_downloader tasks are appended as-is.
  static Future<List<legacy.DownloadTask>>
      getAllTasks() async {
    await _ensureInitialized();

    final result =
        <legacy.DownloadTask>[];

    final ids =
        <String>{};

    // -----------------------------------------------------------------------
    // New background_downloader records.
    // -----------------------------------------------------------------------

    try {
      final records =
          await _downloader.database
              .allRecords(
        group:
            _downloadGroup,
      );

      for (final record in records) {
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

    // -----------------------------------------------------------------------
    // Old tasks created before migration.
    // -----------------------------------------------------------------------

    try {
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      for (final task in oldTasks) {
        if (ids.add(
          task.taskId,
        )) {
          result.add(
            task,
          );
        }
      }
    } catch (e) {
      // This can happen once flutter_downloader initialization is removed
      // from main.dart at the END of the migration.
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
        record.task as bg.DownloadTask;

    bg.TaskStatus effectiveStatus =
        record.status;

    // -----------------------------------------------------------------------
    // When native task says complete, perform .part -> final processing before
    // exposing the task as completed to the old DownloadLogic.
    // -----------------------------------------------------------------------

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
        await task.filePath();

    final savedDir =
        File(filePath)
            .parent
            .path;

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

      // IMPORTANT:
      //
      // Existing download_logic.dart expects modelName here.
      //
      // The physical downloader output is modelName.part.
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
    if (progress <= 0) {
      return 0;
    }

    if (progress >= 1) {
      return 100;
    }

    return (progress * 100)
        .round()
        .clamp(
          0,
          100,
        );
  }

  // ===========================================================================
  // FAILED DOWNLOAD CLEANUP
  // ===========================================================================

  /// SAFE compatibility method.
  ///
  /// OLD behavior:
  ///
  /// failed
  /// -> shouldDeleteContent:true
  /// -> partial progress destroyed
  ///
  /// NEW behavior:
  ///
  /// failed
  /// -> KEEP
  ///
  /// This method intentionally performs no destructive cleanup.
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

  /// Destructive maintenance/reset operation.
  ///
  /// Do not call automatically after a network failure.
  static Future<void>
      cleanupAllModelFiles() async {
    await _ensureInitialized();

    try {
      // Cancel tasks from our model group.
      try {
        await _downloader.cancelAll(
          group:
              _downloadGroup,
        );
      } catch (_) {}

      final records =
          await _downloader.database
              .allRecords(
        group:
            _downloadGroup,
      );

      for (final record in records) {
        if (record.task
            is bg.DownloadTask) {
          final task =
              record.task
                  as bg.DownloadTask;

          try {
            final partPath =
                await task.filePath();

            final finalPath =
                await task.filePath(
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
          await _downloader.database
              .deleteRecordWithId(
            record.taskId,
          );
        } catch (_) {}
      }

      // Also clean old files/tasks from the migration period.
      final oldTasks =
          await legacy
                  .FlutterDownloader
              .loadTasks() ??
              [];

      for (final task in oldTasks) {
        final filename =
            task.filename;

        if (filename == null) {
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

      _currentTaskId = null;

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
    if (finalFileName.endsWith(
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
        task.metaData.trim();

    if (meta.isNotEmpty) {
      return meta;
    }

    final filename =
        task.filename;

    if (filename.endsWith(
      '.part',
    )) {
      return filename.substring(
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
        File(path);

    if (!await file.exists()) {
      return;
    }

    try {
      await file.delete();

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
    if (savedDir.isEmpty ||
        filename.isEmpty) {
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
