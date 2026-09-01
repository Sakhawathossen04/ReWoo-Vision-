// download_page/logic/download_logic.dart
//
// Reliable large-model download pipeline.
//
// IMPORTANT DATA-SAFETY RULE:
//
// Normal download failures MUST NEVER delete already downloaded model bytes.
//
// Network failure
// Android worker failure
// Wi-Fi -> mobile switch
// app restart
// temporary server error
// retry unavailable
//
// => KEEP partial file.
//
// A partial model is deleted ONLY when:
//
// 1. The user explicitly chooses "Cancel Download", OR
// 2. FlutterDownloader reports COMPLETE but the final file fails validation.
//
// This prevents a 3+ GB model that reached 10%, 50%, 95%, etc. from being
// unnecessarily restarted from zero.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:gemma_chat/chat_page/gemma_vision_chat.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/constants.dart';
import '../models/enums.dart';
import '../models/models.dart';
import '../services/logger.dart';
import '../services/download_state_manager.dart';
import '../services/download_manager.dart';
import '../services/token_manager.dart';
import '../services/huggingface_oauth.dart';

/// Business logic for the model-download page.
class DownloadPageLogic {
  // ===========================================================================
  // UI CALLBACKS
  // ===========================================================================

  final Function(DownloadStatus) setDownloadStatus;
  final Function(DownloadProgress?) setProgress;
  final Function(List<String>) setErrorMessages;
  final Function(bool) setShowAgreementSheet;

  // ===========================================================================
  // DOWNLOAD MONITOR
  // ===========================================================================

  Timer? _monitoringTimer;

  // ===========================================================================
  // AUTO RECOVERY
  // ===========================================================================

  int _autoResumeAttempts = 0;

  static const int _maxAutoResumeAttempts = 5;

  // ===========================================================================
  // BYTE-ACCURATE PROGRESS
  // ===========================================================================

  int _expectedBytes = 0;

  int _lastSampledPercent = -1;

  DateTime _lastSampleTime = DateTime.now();

  /// Smoothed bytes/second.
  double _downloadRate = 0;

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
  // TASK HELPERS
  // ===========================================================================

  bool _isRecoverableStatus(
    DownloadTaskStatus status,
  ) {
    return status == DownloadTaskStatus.running ||
        status == DownloadTaskStatus.enqueued ||
        status == DownloadTaskStatus.paused ||
        status == DownloadTaskStatus.failed;
  }

  bool _isModelTask(
    DownloadTask task,
  ) {
    return task.filename == modelName;
  }

  String? _taskFilePath(
    DownloadTask task,
  ) {
    final filename = task.filename;

    if (filename == null ||
        filename.isEmpty ||
        task.savedDir.isEmpty) {
      return null;
    }

    return '${task.savedDir}/$filename';
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
          task.timeCreated > selected.timeCreated) {
        selected = task;
      }
    }

    return selected;
  }

  /// Returns the newest task that still contains recoverable progress.
  DownloadTask? _latestRecoverableModelTask(
    List<DownloadTask> tasks,
  ) {
    return _latestTaskWhere(
      tasks,
      (task) =>
          _isModelTask(task) &&
          _isRecoverableStatus(task.status),
    );
  }

  /// Returns the newest model task that Android believes completed.
  DownloadTask? _latestCompletedModelTask(
    List<DownloadTask> tasks,
  ) {
    return _latestTaskWhere(
      tasks,
      (task) =>
          _isModelTask(task) &&
          task.status == DownloadTaskStatus.complete,
    );
  }

  // ===========================================================================
  // MODEL VALIDATION
  // ===========================================================================

  /// Returns true only when a sufficiently large completed model exists.
  ///
  /// CRITICAL:
  ///
  /// An undersized file is NOT automatically deleted anymore.
  ///
  /// If the file belongs to:
  ///
  /// running / enqueued / paused / failed task
  ///
  /// it is treated as valid PARTIAL DOWNLOAD DATA and preserved.
  ///
  /// Only a file belonging to a task already marked COMPLETE is considered
  /// corrupt when it is undersized.
  Future<bool> checkIfModelExists() async {
    try {
      final tasks =
          await DownloadManager.getAllTasks();

      final documents =
          await getApplicationDocumentsDirectory();

      final minValid =
          (expectedModelFileSize *
                  modelSizeTolerance)
              .round();

      // -----------------------------------------------------------------------
      // Build every possible model location.
      // -----------------------------------------------------------------------

      final candidatePaths = <String>{
        '${documents.path}/$modelName',
      };

      for (final task in tasks) {
        if (!_isModelTask(task)) {
          continue;
        }

        final path =
            _taskFilePath(task);

        if (path != null) {
          candidatePaths.add(path);
        }
      }

      for (final path in candidatePaths) {
        final file = File(path);

        if (!await file.exists()) {
          continue;
        }

        final size =
            await file.length();

        // ---------------------------------------------------------------------
        // Valid final model.
        // ---------------------------------------------------------------------

        if (size >= minValid) {
          Logger.info(
            'Found valid model file: '
            '$path ($size bytes)',
          );

          setDownloadStatus(
            DownloadStatus.completed,
          );

          return true;
        }

        // ---------------------------------------------------------------------
        // File is undersized.
        //
        // Determine whether this is:
        //
        // A) legitimate partial data, or
        // B) corrupt "completed" output.
        // ---------------------------------------------------------------------

        DownloadTask? associatedTask;

        for (final task in tasks) {
          if (!_isModelTask(task)) {
            continue;
          }

          if (_taskFilePath(task) == path) {
            associatedTask = task;

            if (_isRecoverableStatus(
              task.status,
            )) {
              break;
            }
          }
        }

        // ---------------------------------------------------------------------
        // Recoverable partial download.
        //
        // NEVER DELETE.
        // ---------------------------------------------------------------------

        if (associatedTask != null &&
            _isRecoverableStatus(
              associatedTask.status,
            )) {
          Logger.info(
            'Preserving partial model file: '
            '$path '
            '($size bytes, task=${associatedTask.taskId}, '
            'status=${associatedTask.status})',
          );

          continue;
        }

        // ---------------------------------------------------------------------
        // Android reported COMPLETE but final model is too small.
        //
        // This is the one automatic corruption case where deletion is safe.
        // ---------------------------------------------------------------------

        if (associatedTask != null &&
            associatedTask.status ==
                DownloadTaskStatus.complete) {
          Logger.error(
            'Completed model is corrupt/truncated: '
            '$path '
            '($size bytes, minimum=$minValid).',
          );

          try {
            await file.delete();

            Logger.info(
              'Deleted corrupt completed model: $path',
            );
          } catch (e) {
            Logger.error(
              'Could not delete corrupt completed model: $e',
            );
          }

          // File was already explicitly handled above.
          // Remove only the stale DB/task record.
          try {
            await FlutterDownloader.remove(
              taskId:
                  associatedTask.taskId,
              shouldDeleteContent: false,
            );
          } catch (e) {
            Logger.warning(
              'Could not remove corrupt completed task record: $e',
            );
          }

          continue;
        }

        // ---------------------------------------------------------------------
        // Orphan undersized file.
        //
        // We cannot prove that it is corrupt.
        //
        // Preserve it instead of destroying potentially gigabytes of user data.
        // ---------------------------------------------------------------------

        Logger.warning(
          'Found undersized model artifact without a recoverable task: '
          '$path ($size bytes). '
          'Keeping it conservatively.',
        );
      }

      Logger.debug(
        'No verified completed model found.',
      );

      return false;
    } catch (e) {
      Logger.error(
        'Model validation failed: $e',
      );

      return false;
    }
  }

  // ===========================================================================
  // SAFE ARTIFACT CLEANUP
  // ===========================================================================

  /// Conservative cleanup.
  ///
  /// Previous behaviour deleted:
  ///
  /// - *.part
  /// - undersized modelName
  ///
  /// before starting a download.
  ///
  /// That could destroy several GB of resumable data.
  ///
  /// New behaviour:
  ///
  /// - non-empty partial file   -> KEEP
  /// - failed-task partial      -> KEEP
  /// - paused partial           -> KEEP
  /// - running partial          -> KEEP
  /// - orphan partial           -> KEEP conservatively
  /// - zero-byte orphan temp    -> DELETE
  ///
  /// Corrupt COMPLETE files are handled separately by checkIfModelExists().
  Future<void> _cleanupStaleModelArtifacts() async {
    try {
      final dir =
          await getApplicationDocumentsDirectory();

      final tasks =
          await DownloadManager.getAllTasks();

      final protectedPaths =
          <String>{};

      for (final task in tasks) {
        if (!_isModelTask(task) ||
            !_isRecoverableStatus(
              task.status,
            )) {
          continue;
        }

        final path =
            _taskFilePath(task);

        if (path != null) {
          protectedPaths.add(path);
        }
      }

      await for (final entity in dir.list()) {
        if (entity is! File) {
          continue;
        }

        final name =
            entity.uri.pathSegments.last
                .toLowerCase();

        final lowerModel =
            modelName.toLowerCase();

        final relevant =
            name == lowerModel ||
                name.startsWith(
                  '$lowerModel.',
                ) ||
                name.startsWith(
                  lowerModel,
                );

        if (!relevant) {
          continue;
        }

        final size =
            await entity.length();

        // Anything tied to a native recoverable task is protected.
        if (protectedPaths.contains(
          entity.path,
        )) {
          Logger.info(
            'Keeping active/recoverable download artifact: '
            '${entity.path} ($size bytes)',
          );

          continue;
        }

        // Never automatically destroy non-empty partial data.
        if (size > 0) {
          Logger.info(
            'Keeping non-empty model artifact conservatively: '
            '${entity.path} ($size bytes)',
          );

          continue;
        }

        // Zero-byte orphan files contain no useful progress.
        try {
          await entity.delete();

          Logger.info(
            'Removed zero-byte stale artifact: '
            '${entity.path}',
          );
        } catch (e) {
          Logger.warning(
            'Could not remove zero-byte artifact '
            '${entity.path}: $e',
          );
        }
      }
    } catch (e) {
      Logger.error(
        'Safe stale-artifact cleanup failed: $e',
      );
    }
  }

  // ===========================================================================
  // REMOTE FILE SIZE
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

      if (accessToken != null) {
        request.headers[
            'Authorization'] =
            'Bearer $accessToken';
      }

      request.followRedirects = true;

      final response =
          await client
              .send(request)
              .timeout(
        const Duration(seconds: 20),
      );

      final length =
          response.contentLength ?? 0;

      if (length > 0) {
        Logger.info(
          'Remote model size: $length bytes',
        );

        return length;
      }
    } catch (e) {
      Logger.warning(
        'Could not read Content-Length: $e',
      );
    } finally {
      client.close();
    }

    return expectedModelFileSize;
  }

  // ===========================================================================
  // EXISTING TASK RECOVERY
  // ===========================================================================

  /// Reuses an already existing model task instead of starting another one.
  ///
  /// Returns true when a task existed and this method handled it.
  Future<bool> _reuseExistingModelTask() async {
    try {
      final tasks =
          await DownloadManager.getAllTasks();

      final existing =
          _latestRecoverableModelTask(
        tasks,
      );

      if (existing == null) {
        return false;
      }

      Logger.info(
        'Found existing recoverable model task: '
        '${existing.taskId}, '
        'status=${existing.status}, '
        'progress=${existing.progress}%',
      );

      DownloadManager.attachToTask(
        existing.taskId,
      );

      await DownloadStateManager
          .saveDownloadInProgress(
        existing.taskId,
      );

      switch (existing.status) {
        case DownloadTaskStatus.running:
        case DownloadTaskStatus.enqueued:
          setDownloadStatus(
            DownloadStatus.downloading,
          );

          monitorDownload(
            existing.taskId,
            null,
          );

          return true;

        case DownloadTaskStatus.paused:
          final resumed =
              await DownloadManager
                  .resumeDownload();

          if (resumed != null) {
            await DownloadStateManager
                .saveDownloadInProgress(
              resumed,
            );

            setDownloadStatus(
              DownloadStatus.downloading,
            );

            monitorDownload(
              resumed,
              null,
            );
          } else {
            _showPreservedProgressError(
              'ডাউনলোডটি এখনই resume করা যায়নি। '
              'আগের ডাউনলোড করা অংশ মুছে ফেলা হয়নি। '
              'ইন্টারনেট সংযোগ পরীক্ষা করে আবার চেষ্টা করুন।',
            );
          }

          return true;

        case DownloadTaskStatus.failed:
          final retried =
              await DownloadManager
                  .retryDownload();

          if (retried != null) {
            await DownloadStateManager
                .saveDownloadInProgress(
              retried,
            );

            setDownloadStatus(
              DownloadStatus.downloading,
            );

            monitorDownload(
              retried,
              null,
            );
          } else {
            _showPreservedProgressError(
              'আগের ডাউনলোড task এখনই retry করা যায়নি। '
              'আংশিক ডাউনলোড করা model file রাখা হয়েছে; '
              'এটি স্বয়ংক্রিয়ভাবে delete করা হয়নি।',
            );
          }

          return true;

        default:
          return false;
      }
    } catch (e) {
      Logger.error(
        'Existing-task recovery failed: $e',
      );

      return false;
    }
  }

  // ===========================================================================
  // STARTUP DOWNLOAD RECOVERY
  // ===========================================================================

  Future<void> checkForOngoingDownloads(
    BuildContext context,
  ) async {
    try {
      final savedState =
          await DownloadStateManager
              .getDownloadState();

      final savedTaskId =
          await DownloadStateManager
              .getDownloadTaskId();

      Logger.info(
        'Checking download state - '
        'saved: $savedState, '
        'taskId: $savedTaskId',
      );

      if (savedState ==
              'in_progress' &&
          savedTaskId != null) {
        DownloadManager.attachToTask(
          savedTaskId,
        );

        final tasks =
            await DownloadManager
                .getAllTasks();

        DownloadTask? task;

        for (final candidate in tasks) {
          if (candidate.taskId ==
              savedTaskId) {
            task = candidate;
            break;
          }
        }

        // ---------------------------------------------------------------------
        // Native task disappeared.
        //
        // IMPORTANT:
        // Do NOT clean/delete the partial file here.
        // ---------------------------------------------------------------------

        if (task == null) {
          Logger.warning(
            'Saved task $savedTaskId is no longer present in '
            'FlutterDownloader. Partial file will be preserved.',
          );

          setDownloadStatus(
            DownloadStatus.failed,
          );

          setErrorMessages([
            'আগের ডাউনলোড task Android থেকে পাওয়া যাচ্ছে না। '
                'ইতিমধ্যে ডাউনলোড করা model data মুছে ফেলা হয়নি। '
                'ডাউনলোড recovery system আপডেটের পরে এটি পুনরায় ব্যবহার করা যাবে।',
          ]);

          return;
        }

        Logger.info(
          'Recovered download task: '
          '${task.taskId}, '
          '${task.status}, '
          '${task.progress}%',
        );

        switch (task.status) {
          case DownloadTaskStatus.paused:
            await resumeDownload();
            return;

          case DownloadTaskStatus.running:
          case DownloadTaskStatus.enqueued:
            setDownloadStatus(
              DownloadStatus.downloading,
            );

            monitorDownload(
              task.taskId,
              context,
            );

            return;

          case DownloadTaskStatus.failed:
            Logger.info(
              'Retrying preserved failed task.',
            );

            final retried =
                await DownloadManager
                    .retryDownload();

            if (retried != null) {
              await DownloadStateManager
                  .saveDownloadInProgress(
                retried,
              );

              setDownloadStatus(
                DownloadStatus.downloading,
              );

              monitorDownload(
                retried,
                context,
              );
            } else {
              _showPreservedProgressError(
                'আগের ডাউনলোড এখনই resume করা যায়নি। '
                'ডাউনলোড করা অংশ মুছে ফেলা হয়নি। '
                'ইন্টারনেট সংযোগ ঠিক হলে আবার চেষ্টা করুন।',
              );
            }

            return;

          case DownloadTaskStatus.complete:
            if (await checkIfModelExists()) {
              await DownloadStateManager
                  .saveDownloadCompleted();

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
            } else {
              // Completed task but final file failed validation.
              //
              // checkIfModelExists() already handles corrupt-complete cleanup.
              setDownloadStatus(
                DownloadStatus.failed,
              );

              setErrorMessages([
                'ডাউনলোড সম্পূর্ণ দেখালেও model file অসম্পূর্ণ ছিল। '
                    'Corrupt final file সরানো হয়েছে। আবার ডাউনলোড করুন।',
              ]);
            }

            return;

          case DownloadTaskStatus.canceled:
            // An explicit user cancellation is handled by cancelDownload().
            //
            // If Android unexpectedly reports canceled, do not delete anything
            // from this recovery path.
            _showPreservedProgressError(
              'ডাউনলোড task বাতিল অবস্থায় পাওয়া গেছে। '
              'যদি কোনো আংশিক file থাকে সেটি স্বয়ংক্রিয়ভাবে মুছে ফেলা হয়নি।',
            );

            return;

          case DownloadTaskStatus.undefined:
            _showPreservedProgressError(
              'আগের download task-এর অবস্থা নির্ধারণ করা যাচ্ছে না। '
              'আংশিক model file মুছে ফেলা হয়নি।',
            );

            return;
        }
      }

      if (savedState ==
          'completed') {
        if (await checkIfModelExists()) {
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
        } else {
          await DownloadStateManager
              .clearDownloadState();
        }

        return;
      }

      // No saved state.
      //
      // First check the final model.
      if (await checkIfModelExists()) {
        return;
      }

      // Then look for an existing native partial task.
      await _reuseExistingModelTask();
    } catch (e) {
      Logger.error(
        'Error checking ongoing downloads: $e',
      );

      // IMPORTANT:
      // Never clear download state merely because recovery inspection failed.
      //
      // Clearing state here could orphan several GB of useful progress.
      setDownloadStatus(
        DownloadStatus.failed,
      );

      setErrorMessages([
        'আগের ডাউনলোডের অবস্থা পরীক্ষা করা যায়নি। '
            'ডাউনলোড করা অংশ নিরাপদ রাখা হয়েছে।',
      ]);
    }
  }

  // ===========================================================================
  // AUTO-START CHECK
  // ===========================================================================

  Future<bool> canAutoStartDownload() async {
    if (await checkIfModelExists()) {
      return false;
    }

    final savedState =
        await DownloadStateManager
            .getDownloadState();

    if (savedState ==
        'in_progress') {
      return false;
    }

    final tasks =
        await DownloadManager.getAllTasks();

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

    if (code < 0) {
      Logger.warning(
        'Network unavailable for auto-start probe ($code)',
      );

      return false;
    }

    return false;
  }

  // ===========================================================================
  // AUTH + START
  // ===========================================================================

  Future<void> startDownload({
    bool autoStart = false,
  }) async {
    setDownloadStatus(
      DownloadStatus.checkingAccess,
    );

    setErrorMessages([]);

    Logger.info(
      'Starting download process for $modelFullName',
    );

    // Before authentication/network probing, try to recover an existing task.
    final reused =
        await _reuseExistingModelTask();

    if (reused) {
      return;
    }

    // -------------------------------------------------------------------------
    // 1. Anonymous access
    // -------------------------------------------------------------------------

    final anonymousCode =
        await DownloadManager
            .checkModelAccess(
      downloadUrl,
    );

    Logger.info(
      'Anonymous access check returned $anonymousCode',
    );

    if (anonymousCode == 200 ||
        anonymousCode == 302) {
      await downloadModel(null);

      return;
    }

    if (anonymousCode < 0) {
      handleError(
        'ইন্টারনেট সংযোগে সমস্যা হয়েছে। সংযোগ পরীক্ষা করুন।',
      );

      return;
    }

    // -------------------------------------------------------------------------
    // 2. Developer token
    // -------------------------------------------------------------------------

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

      Logger.info(
        'Developer token check returned $devCode',
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
          'Developer token lacks license access (403)',
        );
      } else if (devCode == 401) {
        Logger.warning(
          'Developer token rejected (401)',
        );
      }
    }

    // -------------------------------------------------------------------------
    // 3. Stored Hugging Face token
    // -------------------------------------------------------------------------

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

      Logger.info(
        'Stored token check returned $storedCode',
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

      Logger.warning(
        'Stored token unusable ($storedCode) — fresh login',
      );
    }

    // -------------------------------------------------------------------------
    // 4. Interactive OAuth
    // -------------------------------------------------------------------------

    if (autoStart) {
      setDownloadStatus(
        DownloadStatus.notStarted,
      );

      setErrorMessages([
        'প্রথমবার ডাউনলোডের জন্য একবার Hugging Face লগইন প্রয়োজন। '
            'নিচের "ডাউনলোড" বোতাম চাপুন — লগইন শেষ হলে '
            'ডাউনলোড স্বয়ংক্রিয়ভাবে শুরু হবে।',
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
      Logger.info(
        'Starting Hugging Face OAuth flow',
      );

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
          Uri.parse(result);

      final code =
          uri.queryParameters['code'];

      if (code != null) {
        await handleAuthorizationCode(
          code,
        );

        return;
      }

      if (uri.queryParameters[
              'error'] !=
          null) {
        handleError(
          'Hugging Face অনুমোদন দেয়নি '
          '(${uri.queryParameters['error']})। আবার চেষ্টা করুন।',
        );

        return;
      }

      handleError(
        'অনুমোদন সম্পন্ন হয়নি। আবার চেষ্টা করুন।',
      );
    } catch (e) {
      final errorText =
          e.toString();

      if (errorText.contains(
            'CANCELED',
          ) ||
          errorText.contains(
            'USER_CANCELED',
          ) ||
          errorText.contains(
            'cancelled',
          )) {
        setDownloadStatus(
          DownloadStatus.notStarted,
        );

        setErrorMessages([]);

        Logger.info(
          'OAuth flow cancelled by user',
        );

        return;
      }

      handleError(
        'Hugging Face লগইন ব্যর্থ হয়েছে: $e',
      );
    }
  }

  Future<void> handleAuthorizationCode(
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
          'Hugging Face অনুমোদন সম্পন্ন করা যায়নি। আবার চেষ্টা করুন।',
        );

        return;
      }

      Logger.info(
        'Hugging Face login successful — verifying model access',
      );

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

      if (responseCode < 0) {
        handleError(
          'ইন্টারনেট সংযোগে সমস্যা হয়েছে। সংযোগ পরীক্ষা করুন।',
        );

        return;
      }

      handleError(
        'মডেল অ্যাক্সেস করা যায়নি '
        '(কোড $responseCode)। '
        'লাইসেন্স গ্রহণ করা হয়েছে কি না পরীক্ষা করুন।',
      );
    } catch (e) {
      handleError(
        'অ্যাকাউন্ট যাচাইয়ে সমস্যা হয়েছে: $e',
      );
    }
  }

  // ===========================================================================
  // LICENSE
  // ===========================================================================

  void showUserAgreement() {
    setDownloadStatus(
      DownloadStatus.awaitingLicenseAcceptance,
    );

    setShowAgreementSheet(true);

    Logger.info(
      'Model requires license acceptance',
    );
  }

  Future<void> openLicenseAgreement() async {
    setShowAgreementSheet(false);

    try {
      final launched =
          await launchUrl(
        Uri.parse(modelCardUrl),
        mode:
            LaunchMode.externalApplication,
      );

      if (launched) {
        Logger.info(
          'Opened license agreement in browser',
        );
      } else {
        Logger.warning(
          'Could not open browser for license page',
        );
      }
    } catch (e) {
      Logger.error(
        'Failed to open license page: $e',
      );
    }

    setDownloadStatus(
      DownloadStatus.awaitingLicenseAcceptance,
    );
  }

  void cancelLicenseAgreement() {
    setShowAgreementSheet(false);

    setDownloadStatus(
      DownloadStatus.notStarted,
    );
  }

  // ===========================================================================
  // ACTUAL DOWNLOAD START
  // ===========================================================================

  Future<void> downloadModel(
    String? accessToken,
  ) async {
    setDownloadStatus(
      DownloadStatus.downloading,
    );

    setErrorMessages([]);

    _autoResumeAttempts = 0;

    // -------------------------------------------------------------------------
    // CRITICAL:
    // Before creating a brand-new task, attempt to reuse any existing
    // running/paused/failed model task.
    // -------------------------------------------------------------------------

    final reused =
        await _reuseExistingModelTask();

    if (reused) {
      return;
    }

    // -------------------------------------------------------------------------
    // SAFE cleanup only.
    //
    // No non-empty partial model is deleted.
    // -------------------------------------------------------------------------

    await _cleanupStaleModelArtifacts();

    // -------------------------------------------------------------------------
    // Resolve true file size.
    // -------------------------------------------------------------------------

    _expectedBytes =
        await _resolveExpectedBytes(
      accessToken,
    );

    _lastSampledPercent = -1;
    _lastSampleTime = DateTime.now();
    _downloadRate = 0;

    // -------------------------------------------------------------------------
    // IMPORTANT:
    //
    // DO NOT call:
    //
    // DownloadManager.cleanupFailedDownloads();
    //
    // here.
    //
    // A failed task may contain GBs of useful resumable data.
    // -------------------------------------------------------------------------

    final taskId =
        await DownloadManager
            .startDownload(
      url: downloadUrl,
      fileName: modelName,
      accessToken: accessToken,
    );

    if (taskId == null) {
      handleError(
        'ডাউনলোড শুরু করা যায়নি। '
        'আগের কোনো আংশিক model data থাকলে সেটি মুছে ফেলা হয়নি।',
      );

      return;
    }

    await DownloadStateManager
        .saveDownloadInProgress(
      taskId,
    );

    monitorDownload(
      taskId,
      null,
    );
  }

  // ===========================================================================
  // DOWNLOAD MONITOR
  // ===========================================================================

  void monitorDownload(
    String taskId,
    BuildContext? context,
  ) {
    _monitoringTimer?.cancel();

    Logger.info(
      'Starting download monitoring for task: $taskId',
    );

    _monitoringTimer =
        Timer.periodic(
      const Duration(seconds: 1),
      (
        timer,
      ) async {
        try {
          final tasks =
              await DownloadManager
                  .getAllTasks();

          DownloadTask? task;

          for (final candidate in tasks) {
            if (candidate.taskId ==
                taskId) {
              task = candidate;

              break;
            }
          }

          // -------------------------------------------------------------------
          // Task disappeared.
          //
          // DO NOT delete the partial file.
          // -------------------------------------------------------------------

          if (task == null) {
            Logger.warning(
              'Task $taskId disappeared from FlutterDownloader. '
              'Partial model data is being preserved.',
            );

            timer.cancel();
            _monitoringTimer = null;

            _showPreservedProgressError(
              'ডাউনলোড task Android থেকে পাওয়া যাচ্ছে না। '
              'ডাউনলোড করা model data মুছে ফেলা হয়নি।',
            );

            return;
          }

          // -------------------------------------------------------------------
          // PROGRESS CALCULATION
          // -------------------------------------------------------------------

          final total =
              _expectedBytes > 0
                  ? _expectedBytes
                  : expectedModelFileSize;

          final downloaded =
              ((task.progress / 100) *
                      total)
                  .round();

          final now =
              DateTime.now();

          if (_lastSampledPercent >=
                  0 &&
              task.progress >
                  _lastSampledPercent) {
            final dt =
                now
                    .difference(
                      _lastSampleTime,
                    )
                    .inMilliseconds;

            if (dt > 0) {
              final deltaBytes =
                  ((task.progress -
                              _lastSampledPercent) /
                          100) *
                      total;

              final instant =
                  deltaBytes /
                      (dt / 1000);

              _downloadRate =
                  _downloadRate <= 0
                      ? instant
                      : (_downloadRate *
                              0.7 +
                          instant *
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
              (total - downloaded)
                  .clamp(
            0,
            total,
          );

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
              totalBytes: total,
              downloadedBytes:
                  downloaded,
              downloadRate:
                  _downloadRate,
              remainingTime:
                  remainingTime,
              status: task.status,
            ),
          );

          // -------------------------------------------------------------------
          // STATUS
          // -------------------------------------------------------------------

          switch (task.status) {
            // -----------------------------------------------------------------
            // COMPLETE
            // -----------------------------------------------------------------

            case DownloadTaskStatus.complete:
              timer.cancel();
              _monitoringTimer = null;

              Logger.info(
                'Download completed: $taskId',
              );

              if (await checkIfModelExists()) {
                setDownloadStatus(
                  DownloadStatus.completed,
                );

                await DownloadStateManager
                    .saveDownloadCompleted();

                Logger.info(
                  'Downloaded model passed validation.',
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

                return;
              }

              // A COMPLETE task with an invalid/truncated final file is the
              // only non-user case where corrupt bytes may be removed.
              Logger.error(
                'Completed model failed final validation.',
              );

              await _autoRecoverOrFail(
                taskId,
                context,
              );

              return;

            // -----------------------------------------------------------------
            // FAILED
            //
            // KEEP CONTENT.
            // -----------------------------------------------------------------

            case DownloadTaskStatus.failed:
              timer.cancel();
              _monitoringTimer = null;

              Logger.warning(
                'Download task failed: $taskId. '
                'Partial content will be preserved.',
              );

              await _autoRecoverOrFail(
                taskId,
                context,
              );

              return;

            // -----------------------------------------------------------------
            // CANCELED
            //
            // If this came from explicit cancelDownload(), monitor was already
            // stopped first.
            //
            // Therefore an unexpected canceled status here is treated
            // conservatively and content is preserved.
            // -----------------------------------------------------------------

            case DownloadTaskStatus.canceled:
              timer.cancel();
              _monitoringTimer = null;

              Logger.warning(
                'Task $taskId reported canceled unexpectedly. '
                'No automatic content deletion will occur here.',
              );

              _showPreservedProgressError(
                'ডাউনলোড বন্ধ হয়েছে। '
                'যদি আংশিক model file থেকে থাকে সেটি নিরাপদ রাখা হয়েছে।',
              );

              return;

            // -----------------------------------------------------------------
            // PAUSED
            // -----------------------------------------------------------------

            case DownloadTaskStatus.paused:
              setDownloadStatus(
                DownloadStatus.downloading,
              );

              DownloadManager.attachToTask(
                taskId,
              );

              final resumed =
                  await DownloadManager
                      .resumeDownload();

              if (resumed != null) {
                await DownloadStateManager
                    .saveDownloadInProgress(
                  resumed,
                );

                timer.cancel();

                monitorDownload(
                  resumed,
                  context,
                );
              } else {
                timer.cancel();
                _monitoringTimer = null;

                _showPreservedProgressError(
                  'ডাউনলোড pause হয়েছে কিন্তু এখনই resume করা যায়নি। '
                  'আগের progress মুছে ফেলা হয়নি।',
                );
              }

              return;

            // -----------------------------------------------------------------
            // NORMAL ACTIVE STATES
            // -----------------------------------------------------------------

            case DownloadTaskStatus.running:
            case DownloadTaskStatus.enqueued:
              setDownloadStatus(
                DownloadStatus.downloading,
              );

              return;

            // -----------------------------------------------------------------
            // UNDEFINED
            // -----------------------------------------------------------------

            case DownloadTaskStatus.undefined:
              timer.cancel();
              _monitoringTimer = null;

              Logger.warning(
                'Task $taskId has undefined status. '
                'Preserving any downloaded bytes.',
              );

              _showPreservedProgressError(
                'ডাউনলোডের বর্তমান অবস্থা নির্ধারণ করা যাচ্ছে না। '
                'আগের progress মুছে ফেলা হয়নি।',
              );

              return;
          }
        } catch (e) {
          Logger.error(
            'ডাউনলোড পর্যবেক্ষণে সমস্যা হয়েছে: $e',
          );

          timer.cancel();
          _monitoringTimer = null;

          _showPreservedProgressError(
            'ডাউনলোড পর্যবেক্ষণে সমস্যা হয়েছে। '
            'ডাউনলোড করা model data মুছে ফেলা হয়নি।',
          );
        }
      },
    );
  }

  // ===========================================================================
  // AUTO RECOVERY
  // ===========================================================================

  /// Attempts to retry the SAME failed task.
  ///
  /// CRITICAL DIFFERENCE FROM THE OLD CODE:
  ///
  /// OLD:
  ///
  /// retry == null
  ///     ↓
  /// shouldDeleteContent: true
  ///     ↓
  /// downloadModel()
  ///     ↓
  /// 0%
  ///
  ///
  /// NEW:
  ///
  /// retry == null
  ///     ↓
  /// KEEP FILE
  ///     ↓
  /// KEEP TASK STATE
  ///     ↓
  /// show recoverable error
  ///
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
        'Retrying failed download '
        '$attempt/$_maxAutoResumeAttempts. '
        'Partial content is preserved.',
      );

      setDownloadStatus(
        DownloadStatus.downloading,
      );

      await Future.delayed(
        const Duration(seconds: 4),
      );

      // The user may have left/disposed the screen, but the native task can
      // still be recovered later.
      final retried =
          await DownloadManager
              .retryDownload();

      if (retried != null) {
        Logger.info(
          'Failed task resumed/retried successfully: '
          '$taskId -> $retried',
        );

        await DownloadStateManager
            .saveDownloadInProgress(
          retried,
        );

        monitorDownload(
          retried,
          context,
        );

        return;
      }

      Logger.warning(
        'Retry attempt $attempt unavailable. '
        'No content deleted.',
      );

      // Re-attach original task before another retry attempt.
      DownloadManager.attachToTask(
        taskId,
      );
    }

    // -------------------------------------------------------------------------
    // OUT OF AUTO RETRIES
    //
    // IMPORTANT:
    //
    // DO NOT:
    //
    // FlutterDownloader.remove(... shouldDeleteContent: true)
    // DownloadStateManager.clearDownloadState()
    // downloadModel(...)
    //
    // here.
    //
    // Keeping the task ID is important for later recovery.
    // -------------------------------------------------------------------------

    await DownloadStateManager
        .saveDownloadInProgress(
      taskId,
    );

    _showPreservedProgressError(
      'ডাউনলোড সাময়িকভাবে বন্ধ হয়েছে। '
      'ইন্টারনেট, ব্যাটারি restriction এবং ফোনের খালি জায়গা পরীক্ষা করুন। '
      'ইতিমধ্যে ডাউনলোড করা অংশ মুছে ফেলা হয়নি। '
      'আবার চেষ্টা করলে একই download task resume করার চেষ্টা করা হবে।',
    );
  }

  // ===========================================================================
  // TOKEN RESOLUTION
  // ===========================================================================

  Future<String?>
      resolveAccessToken() async {
    if (hfTokenConfigured) {
      return hfAppToken;
    }

    final tokenStatus =
        await TokenManager
            .getTokenStatus();

    if (tokenStatus ==
        TokenStatus.valid) {
      final token =
          await TokenManager
              .getStoredToken();

      return token?.accessToken;
    }

    return null;
  }

  // ===========================================================================
  // ERROR HELPERS
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

    Logger.error(error);
  }

  /// Failure helper specifically for errors where existing partial bytes must
  /// remain untouched.
  void _showPreservedProgressError(
    String message,
  ) {
    setDownloadStatus(
      DownloadStatus.failed,
    );

    setErrorMessages([
      message,
    ]);

    Logger.warning(
      '$message [partial download preserved]',
    );
  }

  // ===========================================================================
  // CANCEL CONFIRMATION
  // ===========================================================================

  Future<void> showCancelConfirmation(
    BuildContext context,
  ) async {
    final result =
        await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (BuildContext context) {
        return Dialog(
          shape:
              RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(
              20,
            ),
          ),
          child: Container(
            padding:
                const EdgeInsets.all(
              24,
            ),
            decoration:
                BoxDecoration(
              borderRadius:
                  BorderRadius.circular(
                20,
              ),
              color: Colors.white,
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
                        Colors.red[400]!,
                        Colors.red[600]!,
                      ],
                    ),
                  ),
                  child:
                      const Icon(
                    Icons.warning_rounded,
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
                        Colors.grey[800],
                  ),
                  textAlign:
                      TextAlign.center,
                ),

                const SizedBox(
                  height: 12,
                ),

                Text(
                  'আপনি কি নিশ্চিত? '
                  'শুধুমাত্র এই বোতাম দিয়ে বাতিল করলে বর্তমান progress '
                  'এবং আংশিক model file মুছে ফেলা হবে।',
                  style:
                      TextStyle(
                    fontSize: 16,
                    color:
                        Colors.grey[600],
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
                          Container(
                        constraints:
                            const BoxConstraints(
                          minHeight:
                              48,
                        ),
                        decoration:
                            BoxDecoration(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                          border:
                              Border.all(
                            color:
                                Colors
                                    .grey[
                                300]!,
                          ),
                        ),
                        child:
                            TextButton(
                          onPressed:
                              () {
                            Navigator.of(
                              context,
                            ).pop(
                              false,
                            );
                          },
                          child:
                              Text(
                            'ডাউনলোড চালিয়ে যান',
                            style:
                                TextStyle(
                              color:
                                  Colors
                                      .grey[
                                  700],
                              fontSize:
                                  16,
                              fontWeight:
                                  FontWeight
                                      .w600,
                            ),
                            textAlign:
                                TextAlign
                                    .center,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(
                      width: 16,
                    ),

                    Expanded(
                      child:
                          Container(
                        constraints:
                            const BoxConstraints(
                          minHeight:
                              48,
                        ),
                        decoration:
                            BoxDecoration(
                          gradient:
                              LinearGradient(
                            colors: [
                              Colors.red[
                                  400]!,
                              Colors.red[
                                  600]!,
                            ],
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                        ),
                        child:
                            TextButton(
                          onPressed:
                              () {
                            Navigator.of(
                              context,
                            ).pop(
                              true,
                            );
                          },
                          child:
                              const Text(
                            'ডাউনলোড বাতিল করুন',
                            style:
                                TextStyle(
                              color:
                                  Colors
                                      .white,
                              fontSize:
                                  16,
                              fontWeight:
                                  FontWeight
                                      .w600,
                            ),
                            textAlign:
                                TextAlign
                                    .center,
                          ),
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

    if (result == true) {
      await cancelDownload();
    }
  }

  // ===========================================================================
  // EXPLICIT USER CANCEL
  // ===========================================================================

  /// THIS is intentionally destructive.
  ///
  /// The user explicitly confirmed that they want to cancel and delete the
  /// partial model.
  Future<void> cancelDownload() async {
    _monitoringTimer?.cancel();
    _monitoringTimer = null;

    _autoResumeAttempts = 0;

    // Explicit user action:
    //
    // deleting partial content is allowed here.
    await DownloadManager
        .cancelAndDeleteDownload();

    await DownloadStateManager
        .clearDownloadState();

    setDownloadStatus(
      DownloadStatus.notStarted,
    );

    setProgress(null);

    Logger.info(
      'User explicitly cancelled download; '
      'partial content was deleted.',
    );
  }

  // ===========================================================================
  // PAUSE
  // ===========================================================================

  Future<void> pauseDownload() async {
    await DownloadManager
        .pauseDownload();

    // Keep persistent state as in_progress so restart recovery still sees it.
    setDownloadStatus(
      DownloadStatus.paused,
    );
  }

  // ===========================================================================
  // RESUME
  // ===========================================================================

  Future<void> resumeDownload() async {
    // -------------------------------------------------------------------------
    // Recover attached task first.
    // -------------------------------------------------------------------------

    final savedTaskId =
        await DownloadStateManager
            .getDownloadTaskId();

    if (savedTaskId != null) {
      DownloadManager.attachToTask(
        savedTaskId,
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

    final newTaskId =
        await DownloadManager
            .resumeDownload();

    if (newTaskId == null) {
      // -----------------------------------------------------------------------
      // CRITICAL:
      //
      // Do NOT start from scratch.
      // Do NOT delete content.
      // -----------------------------------------------------------------------

      _showPreservedProgressError(
        'ডাউনলোড এখনই resume করা যায়নি। '
        'আগের progress এবং partial model file মুছে ফেলা হয়নি। '
        'ইন্টারনেট সংযোগ ঠিক করে আবার চেষ্টা করুন।',
      );

      return;
    }

    await DownloadStateManager
        .saveDownloadInProgress(
      newTaskId,
    );

    setDownloadStatus(
      DownloadStatus.downloading,
    );

    monitorDownload(
      newTaskId,
      null,
    );
  }
}
