// download_page/logic/download_logic.dart
//
// Priority 1 + Priority 2 implementation — FIXED download pipeline.
//
// The previous build refused to download unless a developer token was
// compiled into the app ("ডেভেলপার Hugging Face টোকেন যোগ করা হয়নি").
// This file now resolves access through a robust chain, so the model
// download ALWAYS works:
//
//   1. Public / anonymous access          → download immediately.
//   2. Bundled developer token (optional) → download automatically.
//      (set --dart-define=HF_APP_TOKEN=hf_... when building)
//   3. Stored Hugging Face login          → download automatically.
//   4. Hugging Face login (the proven old-version flow)
//      → in-app OAuth browser → token stored → download.
//
// 403 after a successful login means the Gemma license was not accepted
// yet — the app shows the license bottom sheet and opens the model page.
//
// The download itself runs as an Android background task
// (flutter_downloader / WorkManager + foreground notification) and keeps
// running when the app goes to the background, is minimised, or the phone
// switches from Wi-Fi to mobile data (allowCellular: true). Transient
// failures are resumed automatically a few times before the user is asked
// to intervene.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:gemma_chat/chat_page/gemma_vision_chat.dart';
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

/// Business logic class that handles all download-related operations.
class DownloadPageLogic {
  // Callback functions to update UI state
  final Function(DownloadStatus) setDownloadStatus;
  final Function(DownloadProgress?) setProgress;
  final Function(List<String>) setErrorMessages;
  final Function(bool) setShowAgreementSheet;

  // Timer for monitoring download progress - needs to be tracked for cleanup
  Timer? _monitoringTimer;

  // Auto-recovery bookkeeping (Priority 2: downloads must not just die).
  int _autoResumeAttempts = 0;
  static const int _maxAutoResumeAttempts = 5;

  DownloadPageLogic({
    required this.setDownloadStatus,
    required this.setProgress,
    required this.setErrorMessages,
    required this.setShowAgreementSheet,
  });

  /// Clean up resources when this logic instance is no longer needed.
  /// Prevents memory leaks by canceling any active timers.
  void dispose() {
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
  }

  /// Checks if the model file already exists on the device and is valid.
  /// Returns true when the model file is present and > 0 bytes.
  /// Also updates the UI state to `DownloadStatus.completed` if found.
  Future<bool> checkIfModelExists() async {
    // Step 1: Find a completed download task that matches our model filename
    final tasks = await DownloadManager.getAllTasks();
    DownloadTask? task;
    for (final t in tasks) {
      if (t.filename == modelName && t.status == DownloadTaskStatus.complete) {
        task = t;
        break;
      }
    }

    // Step 2: Determine the file path - prefer the exact path from flutter_downloader
    // If no task found, fall back to the standard app documents directory
    final String filePath = task != null && task.filename != null
        ? '${task.savedDir}/${task.filename}'
        : '${(await getApplicationDocumentsDirectory()).path}/$modelName';

    // Step 3: Validate that the file exists and has content
    final file = File(filePath);
    if (await file.exists()) {
      final size = await file.length();
      if (size > 0) {
        Logger.info('Found model file ($size bytes) at $filePath');
        setDownloadStatus(DownloadStatus.completed);
        return true;
      }
    }

    Logger.debug('Model file not found at $filePath');
    return false;
  }

  /// Checks for downloads that were in progress when the app was last closed.
  /// This enables graceful handling of app restarts during downloads.
  Future<void> checkForOngoingDownloads(BuildContext context) async {
    try {
      // Retrieve saved download state from persistent storage
      final savedState = await DownloadStateManager.getDownloadState();
      final savedTaskId = await DownloadStateManager.getDownloadTaskId();

      Logger.info(
        'Checking download state - saved: $savedState, taskId: $savedTaskId',
      );

      // If we had a download in progress, re-attach and keep it running
      if (savedState == 'in_progress' && savedTaskId != null) {
        Logger.info(
          'Found saved download in progress with task ID: $savedTaskId',
        );

        // Re-attach the download manager to the existing task
        // This is crucial for pause/resume functionality to work
        DownloadManager.attachToTask(savedTaskId);

        // Query the current status of the saved task
        final tasks = await DownloadManager.getAllTasks();
        final task = tasks.firstWhere(
          (t) => t.taskId == savedTaskId,
          // Return empty task if not found (handles cleanup scenarios)
          orElse: () => DownloadTask(
            taskId: '',
            status: DownloadTaskStatus.undefined,
            progress: 0,
            url: '',
            filename: null,
            savedDir: '',
            timeCreated: 0,
            allowCellular: true,
          ),
        );

        // Handle case where task was cleaned up by system
        if (task.taskId.isEmpty) {
          Logger.warning('Task ID not found in download manager');
          await DownloadStateManager.clearDownloadState();
          return;
        }

        Logger.info(
          'Found download task: ${task.taskId}, '
          'status: ${task.status}, progress: ${task.progress}%',
        );

        // Resume appropriate behavior based on the task's current status
        switch (task.status) {
          case DownloadTaskStatus.paused:
            // Priority 2: never leave a paused download stuck — resume it.
            Logger.info('Auto-resuming paused download from previous session');
            await resumeDownload();
            break;
          case DownloadTaskStatus.running:
          case DownloadTaskStatus.enqueued:
            setDownloadStatus(DownloadStatus.downloading);
            monitorDownload(task.taskId, context);
            break;
          case DownloadTaskStatus.failed:
            // Priority 2: a failed download from a killed app is retried
            // automatically instead of showing an error immediately.
            Logger.info('Auto-retrying failed download from previous session');
            final retriedId = await DownloadManager.retryDownload();
            if (retriedId != null) {
              await DownloadStateManager.saveDownloadInProgress(retriedId);
              setDownloadStatus(DownloadStatus.downloading);
              monitorDownload(retriedId, context);
            } else {
              await resumeDownload();
            }
            break;
          case DownloadTaskStatus.complete:
            // Verify the file actually exists before declaring success
            if (await checkIfModelExists()) {
              await DownloadStateManager.saveDownloadCompleted();
              // Navigate to chat page since download is complete
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (context) => ChatPage()),
                );
              });
            } else {
              // File missing despite completion - clean up state
              await DownloadStateManager.clearDownloadState();
            }
            break;
          case DownloadTaskStatus.canceled:
          default:
            // Clean up any stale state for canceled/unknown tasks
            await DownloadStateManager.clearDownloadState();
            break;
        }
      } else if (savedState == 'completed') {
        // Check if completed file still exists (user might have deleted it)
        if (await checkIfModelExists()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (context) => ChatPage()),
            );
          });
        } else {
          // File was deleted - reset state
          await DownloadStateManager.clearDownloadState();
        }
      } else {
        // No saved state - check if file exists anyway (manual installation)
        await checkIfModelExists();
      }
    } catch (e) {
      Logger.error('Error checking for ongoing downloads: $e');
      await DownloadStateManager.clearDownloadState();
    }
  }

  /// Whether the automatic (no-touch) download can run right now.
  ///
  /// A zero-touch path exists when the model URL is reachable without
  /// credentials, a developer token was bundled at build time, or the user
  /// has a stored (valid) Hugging Face login. When none of these hold the
  /// page shows the Download button, and pressing it starts the one-time
  /// Hugging Face login — the proven old-version flow.
  Future<bool> canAutoStartDownload() async {
    if (await checkIfModelExists()) return false;

    final savedState = await DownloadStateManager.getDownloadState();
    if (savedState == 'in_progress') return false;

    // Cheap local checks first.
    if (hfTokenConfigured) return true;

    final tokenStatus = await TokenManager.getTokenStatus();
    if (tokenStatus == TokenStatus.valid) return true;

    // Network probe: some mirrors of the model are public. If the HEAD
    // check fails (offline), auto-starting would only produce a network
    // error dialog, so wait for the user to press Download instead.
    final code = await DownloadManager.checkModelAccess(downloadUrl);
    if (code == 200 || code == 302) return true;
    if (code < 0) {
      Logger.warning('Network unavailable for auto-start probe ($code)');
      return false;
    }
    return false;
  }

  /// Initiates the download process.
  ///
  /// [autoStart] is true when the page triggered this without a tap. In that
  /// mode a missing login must NOT silently open a browser — the page falls
  /// back to the Download button with a clear Bengali explanation instead.
  Future<void> startDownload({bool autoStart = false}) async {
    setDownloadStatus(DownloadStatus.checkingAccess);
    setErrorMessages([]); // Clear any previous errors

    Logger.info('Starting download process for $modelFullName');

    // ── Step 1: is the model reachable without any credentials? ──
    final anonymousCode = await DownloadManager.checkModelAccess(downloadUrl);
    Logger.info('Anonymous access check returned $anonymousCode');

    if (anonymousCode == 200 || anonymousCode == 302) {
      await downloadModel(null);
      return;
    }
    if (anonymousCode < 0) {
      handleError('ইন্টারনেট সংযোগে সমস্যা হয়েছে। সংযোগ পরীক্ষা করুন।');
      return;
    }

    // ── Step 2: bundled developer token (optional, zero-touch) ──
    if (hfTokenConfigured) {
      setDownloadStatus(DownloadStatus.authenticating);
      final devCode = await DownloadManager.checkModelAccess(
        downloadUrl,
        hfAppToken,
      );
      Logger.info('Developer token check returned $devCode');

      if (devCode == 200 || devCode == 302) {
        await downloadModel(hfAppToken);
        return;
      }
      if (devCode == 403) {
        // License not accepted for the developer account — this cannot be
        // fixed by the user logging in with their own account unless the
        // developer account itself is broken; still try the stored login
        // and the interactive flow below before giving up.
        Logger.warning('Developer token lacks license access (403)');
      } else if (devCode == 401) {
        Logger.warning('Developer token rejected (401)');
      }
    }

    // ── Step 3: stored Hugging Face login (zero-touch after first use) ──
    final tokenStatus = await TokenManager.getTokenStatus();
    if (tokenStatus == TokenStatus.valid) {
      setDownloadStatus(DownloadStatus.authenticating);
      final token = await TokenManager.getStoredToken();
      final storedCode = await DownloadManager.checkModelAccess(
        downloadUrl,
        token?.accessToken,
      );
      Logger.info('Stored token check returned $storedCode');

      if (storedCode == 200 || storedCode == 302) {
        await downloadModel(token?.accessToken);
        return;
      }
      if (storedCode == 403) {
        // Logged in, but the Gemma license was never accepted.
        showUserAgreement();
        return;
      }
      Logger.warning('Stored token unusable ($storedCode) — fresh login');
    }

    // ── Step 4: Hugging Face login — the proven old-version flow ──
    if (autoStart) {
      // Never open a browser without a user action. Show the Download
      // button with a clear one-time-login explanation instead.
      setDownloadStatus(DownloadStatus.notStarted);
      setErrorMessages([
        'প্রথমবার ডাউনলোডের জন্য একবার Hugging Face লগইন প্রয়োজন। '
        'নিচের "ডাউনলোড" বোতাম চাপুন — লগইন শেষ হলে ডাউনলোড স্বয়ংক্রিয়ভাবে শুরু হবে।',
      ]);
      Logger.info('Login required — waiting for the user to press Download');
      return;
    }

    await startOAuthFlow();
  }

  /// Initiates the OAuth authentication flow with HuggingFace (old version).
  /// Uses web authentication to get user consent and authorization code.
  Future<void> startOAuthFlow() async {
    setDownloadStatus(DownloadStatus.authenticating);
    try {
      Logger.info('Starting Hugging Face OAuth flow');
      // Generate the authorization URL with proper scopes and redirect
      final authUrl = await HuggingFaceOAuth.generateAuthUrl();

      // Launch web authentication flow — this opens the browser once.
      final result = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: hfCallbackUrlScheme,
      );

      // Parse the callback URL to extract the authorization code
      final uri = Uri.parse(result);
      final code = uri.queryParameters['code'];

      if (code != null) {
        // Successfully got authorization code - exchange it for access token
        await handleAuthorizationCode(code);
      } else if (uri.queryParameters['error'] != null) {
        handleError(
          'Hugging Face অনুমোদন দেয়নি (${uri.queryParameters['error']})। আবার চেষ্টা করুন।',
        );
      } else {
        // OAuth flow completed but no code received - this shouldn't happen
        handleError('অনুমোদন সম্পন্ন হয়নি। আবার চেষ্টা করুন।');
      }
    } catch (e) {
      // Handle user cancellation gracefully vs actual errors
      final errorText = e.toString();
      if (errorText.contains('CANCELED') ||
          errorText.contains('USER_CANCELED') ||
          errorText.contains('cancelled')) {
        setDownloadStatus(DownloadStatus.notStarted);
        setErrorMessages([]);
        Logger.info('OAuth flow cancelled by user');
      } else {
        handleError('Hugging Face লগইন ব্যর্থ হয়েছে: $e');
      }
    }
  }

  /// Exchanges the OAuth authorization code for an access token.
  /// Then attempts to use the token to access the model.
  Future<void> handleAuthorizationCode(String code) async {
    setDownloadStatus(DownloadStatus.authenticating);

    try {
      // Exchange authorization code for access token
      final tokenData = await HuggingFaceOAuth.exchangeCodeForToken(code);
      if (tokenData != null) {
        Logger.info('Hugging Face login successful — verifying model access');

        // Test the new token by checking model access
        final responseCode = await DownloadManager.checkModelAccess(
          downloadUrl,
          tokenData.accessToken,
        );

        if (responseCode == 200 || responseCode == 302) {
          // Token works - start download
          await downloadModel(tokenData.accessToken);
        } else if (responseCode == 403) {
          // Token is valid but user needs to accept license
          showUserAgreement();
        } else if (responseCode < 0) {
          handleError('ইন্টারনেট সংযোগে সমস্যা হয়েছে। সংযোগ পরীক্ষা করুন।');
        } else {
          // Token doesn't work for some reason
          handleError(
            'মডেল অ্যাক্সেস করা যায়নি (কোড $responseCode)। '
            'লাইসেন্স গ্রহণ করা হয়েছে কি না পরীক্ষা করুন।',
          );
        }
      } else {
        // Token exchange failed
        handleError('Hugging Face অনুমোদন সম্পন্ন করা যায়নি। আবার চেষ্টা করুন।');
      }
    } catch (e) {
      handleError('অ্যাকাউন্ট যাচাইয়ে সমস্যা হয়েছে: $e');
    }
  }

  /// Shows the license agreement UI when the model requires user acceptance.
  /// This happens when the logged-in account has not accepted the Gemma
  /// license terms on huggingface.co yet.
  void showUserAgreement() {
    setDownloadStatus(DownloadStatus.awaitingLicenseAcceptance);
    setShowAgreementSheet(true);
    Logger.info('Model requires license acceptance');
  }

  /// Opens the license agreement in the user's browser.
  /// After accepting there, the Download button resumes the pipeline.
  Future<void> openLicenseAgreement() async {
    setShowAgreementSheet(false);

    try {
      final launched = await launchUrl(
        Uri.parse(modelCardUrl),
        mode: LaunchMode.externalApplication, // Force external browser
      );
      if (launched) {
        Logger.info('Opened license agreement in browser');
      } else {
        Logger.warning('Could not open browser for license page');
      }
    } catch (e) {
      Logger.error('Failed to open license page: $e');
    }

    // After opening the license, allow the user to retry the download.
    setDownloadStatus(DownloadStatus.awaitingLicenseAcceptance);
  }

  /// Cancels the license agreement process and returns to initial state.
  /// Called when user dismisses the license agreement sheet.
  void cancelLicenseAgreement() {
    setShowAgreementSheet(false);
    setDownloadStatus(DownloadStatus.notStarted);
  }

  /// Actually starts the file download process.
  /// This is called after authentication is complete (if required).
  Future<void> downloadModel(String? accessToken) async {
    setDownloadStatus(DownloadStatus.downloading);
    _autoResumeAttempts = 0;

    // Clean up any failed downloads from previous attempts
    await DownloadManager.cleanupFailedDownloads();

    // Start the actual download with flutter_downloader.
    // The task keeps running in the background (WorkManager foreground
    // service) even when the app leaves the screen.
    final taskId = await DownloadManager.startDownload(
      url: downloadUrl,
      fileName: modelName,
      accessToken: accessToken,
    );

    if (taskId != null) {
      // Save that we have a download in progress for crash recovery
      await DownloadStateManager.saveDownloadInProgress(taskId);
      monitorDownload(taskId, null); // Start monitoring progress
    } else {
      handleError('ডাউনলোড শুরু করা যায়নি।');
    }
  }

  /// Monitors the progress of an ongoing download using a periodic timer.
  /// Updates UI with progress and handles status changes.
  void monitorDownload(String taskId, BuildContext? context) {
    // Cancel any existing monitoring timer to prevent duplicates
    _monitoringTimer?.cancel();

    Logger.info('Starting download monitoring for task: $taskId');

    // Create a timer that checks download status every second
    _monitoringTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      try {
        // Get current status of all download tasks
        final tasks = await DownloadManager.getAllTasks();
        final task = tasks.firstWhere(
          (task) => task.taskId == taskId,
          // Return empty task if not found
          orElse: () => DownloadTask(
            taskId: '',
            status: DownloadTaskStatus.undefined,
            progress: 0,
            url: '',
            filename: null,
            savedDir: '',
            timeCreated: 0,
            allowCellular: true,
          ),
        );

        // Stop monitoring if task disappeared (system cleanup)
        if (task.taskId.isEmpty) {
          Logger.warning('Task $taskId not found, stopping monitoring');
          timer.cancel();
          _monitoringTimer = null;
          return;
        }

        // Update UI with current progress information
        setProgress(
          DownloadProgress(
            totalBytes: 100, // Using percentage-based progress
            downloadedBytes: task.progress,
            downloadRate: 0, // Rate calculation not implemented
            remainingTime: Duration.zero, // Time calculation not implemented
            status: task.status,
          ),
        );

        // Handle different download status changes
        switch (task.status) {
          case DownloadTaskStatus.complete:
            Logger.info('Download completed for task: $taskId');
            timer.cancel();
            _monitoringTimer = null;

            // Download successfully completed
            setDownloadStatus(DownloadStatus.completed);
            await DownloadStateManager.saveDownloadCompleted();
            Logger.info('Download completed successfully');

            // Automatically navigate to the chat page
            if (context != null && context.mounted) {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (context) => ChatPage()),
              );
            }
            break;

          case DownloadTaskStatus.failed:
            Logger.error('Download failed for task: $taskId');
            timer.cancel();
            _monitoringTimer = null;
            await _autoRecoverOrFail(taskId, context);
            break;

          case DownloadTaskStatus.canceled:
            Logger.info('Download cancelled for task: $taskId');
            timer.cancel();
            _monitoringTimer = null;
            // Reset to initial state instead of showing "cancelled"
            setDownloadStatus(DownloadStatus.notStarted);
            setProgress(null);
            await DownloadStateManager.clearDownloadState();
            Logger.info('Download was cancelled and reset to initial state');
            break;

          case DownloadTaskStatus.paused:
            // Priority 2: if the platform paused the task on its own
            // (network switch, battery saver…), resume it automatically.
            setDownloadStatus(DownloadStatus.downloading);
            final resumed = await DownloadManager.resumeDownload();
            if (resumed != null) {
              Logger.info('Auto-resumed paused task → $resumed');
              monitorDownload(resumed, context);
              timer.cancel();
            }
            break;

          case DownloadTaskStatus.running:
          case DownloadTaskStatus.enqueued:
            // Keep current downloading status
            if (task.status == DownloadTaskStatus.running) {
              setDownloadStatus(DownloadStatus.downloading);
            }
            break;

          case DownloadTaskStatus.undefined:
            Logger.warning(
              'Task $taskId has undefined status, stopping monitoring',
            );
            timer.cancel();
            _monitoringTimer = null;
            break;
        }
      } catch (e) {
        Logger.error('ডাউনলোড পর্যবেক্ষণে সমস্যা হয়েছে: $e');
        timer.cancel();
        _monitoringTimer = null;
        handleError('ডাউনলোড পর্যবেক্ষণে সমস্যা হয়েছে: $e');
      }
    });
  }

  /// Priority 2 recovery path: transient failures (network blips, data
  /// switch) are retried automatically by resuming the task. After
  /// [_maxAutoResumeAttempts] attempts the user sees a proper error.
  Future<void> _autoRecoverOrFail(String taskId, BuildContext? context) async {
    if (_autoResumeAttempts < _maxAutoResumeAttempts) {
      _autoResumeAttempts++;
      final attempt = _autoResumeAttempts;
      Logger.warning(
        'Download failed — auto-retry attempt $attempt/$_maxAutoResumeAttempts in 4s',
      );

      setDownloadStatus(DownloadStatus.downloading);
      await Future.delayed(const Duration(seconds: 4));

      final resumed = await DownloadManager.retryDownload();
      if (resumed != null) {
        await DownloadStateManager.saveDownloadInProgress(resumed);
        monitorDownload(resumed, context);
        return;
      }

      // Retry refused (task dead) — fall back to a fresh download attempt.
      Logger.warning('Retry unavailable; restarting download from scratch');
      final tasks = await DownloadManager.getAllTasks();
      for (final t in tasks) {
        if (t.taskId == taskId) {
          await FlutterDownloader.remove(
            taskId: t.taskId,
            shouldDeleteContent: true,
          );
        }
      }
      await downloadModel(await resolveAccessToken());
      return;
    }

    // Out of automatic attempts.
    setDownloadStatus(DownloadStatus.failed);
    await DownloadStateManager.clearDownloadState();
    handleError(
      'ডাউনলোড ব্যর্থ হয়েছে। ইন্টারনেট বা ফোনের খালি জায়গা পরীক্ষা করুন। '
      'ডাউনলোড বোতাম চেপে আবার শুরু করুন।',
    );
  }

  /// Picks the best available access token for a fresh download attempt:
  /// developer token first, then the stored Hugging Face login.
  Future<String?> resolveAccessToken() async {
    if (hfTokenConfigured) return hfAppToken;
    final tokenStatus = await TokenManager.getTokenStatus();
    if (tokenStatus == TokenStatus.valid) {
      final token = await TokenManager.getStoredToken();
      return token?.accessToken;
    }
    return null;
  }

  /// Handles error states by updating UI and logging the error.
  /// Centralizes error handling for consistent behavior.
  void handleError(String error) {
    setDownloadStatus(DownloadStatus.failed);
    setErrorMessages([error]);
    Logger.error(error);
  }

  /// Shows a confirmation dialog before canceling a download.
  /// This prevents accidental cancellation of large downloads.
  Future<void> showCancelConfirmation(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // Force user to choose an option
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Colors.white,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Warning icon with gradient background
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Colors.red[400]!, Colors.red[600]!],
                    ),
                  ),
                  child: const Icon(
                    Icons.warning_rounded,
                    size: 32,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 20),

                // Dialog title
                Text(
                  'ডাউনলোড বাতিল করবেন?',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),

                // Warning message explaining consequences
                Text(
                  'আপনি কি নিশ্চিত? বাতিল করলে বর্তমান অগ্রগতি ও আংশিক ডাউনলোড করা ফাইল মুছে যাবে।',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[600],
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),

                // Action buttons
                Row(
                  children: [
                    // "Keep Downloading" button (cancel the cancellation)
                    Expanded(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'ডাউনলোড চালিয়ে যান',
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // "Cancel Download" button (confirm the cancellation)
                    Expanded(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.red[400]!, Colors.red[600]!],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red[400]!.withOpacity(0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            'ডাউনলোড বাতিল করুন',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
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

    // If user confirmed cancellation, proceed with it
    if (result == true) {
      await cancelDownload();
    }
  }

  /// Cancels the current download and cleans up all related state.
  /// This completely removes the download and resets the UI.
  Future<void> cancelDownload() async {
    // Stop monitoring first to prevent timer conflicts
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _autoResumeAttempts = 0;

    // Cancel the download and delete any partial files
    await DownloadManager.cancelAndDeleteDownload();
    await DownloadStateManager.clearDownloadState();

    // Reset UI to initial state
    setDownloadStatus(DownloadStatus.notStarted);
    setProgress(null);
    Logger.info('Download cancelled and completely cleaned up');
  }

  /// Pauses the current download while preserving progress.
  /// The download can be resumed later from where it left off.
  Future<void> pauseDownload() async {
    await DownloadManager.pauseDownload();
    // Keep the download state as in_progress when paused
    setDownloadStatus(DownloadStatus.paused);
  }

  /// Resumes a previously paused download from where it left off.
  /// Gets a new task ID and restarts monitoring for the resumed download.
  Future<void> resumeDownload() async {
    // Ask the download manager to resume and get the new task ID
    final newTaskId = await DownloadManager.resumeDownload();
    if (newTaskId == null) {
      handleError('ডাউনলোড আবার চালু করা যায়নি। নতুন করে শুরু করুন।');
      return;
    }

    // Persist the fresh task ID so we survive app restarts
    await DownloadStateManager.saveDownloadInProgress(newTaskId);

    // Start monitoring progress from the correct task
    monitorDownload(newTaskId, null);

    setDownloadStatus(DownloadStatus.downloading);
  }
}
