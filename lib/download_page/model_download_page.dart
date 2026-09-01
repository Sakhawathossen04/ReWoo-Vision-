// download_page/model_download_page.dart
//
// Shows the model download progress. Authentication is resolved
// automatically (developer token or stored Hugging Face login). On the very
// first download the proven old-version Hugging Face login runs once when
// the user presses Download; afterwards every download is fully automatic.
// The download continues in the background (Priority 2) even if the user
// leaves the app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:gemma_chat/chat_page/gemma_vision_chat.dart';

import 'models/enums.dart';
import 'models/models.dart';
import 'services/logger.dart';
import 'services/download_manager.dart';
import 'logic/download_logic.dart';
import 'ui/modern_ui_widgets.dart';
import 'ui/ui_helpers.dart';

/// Main page widget that handles the model download UI and state management.
class ModelDownloadPage extends StatefulWidget {
  const ModelDownloadPage({Key? key}) : super(key: key);

  @override
  State<ModelDownloadPage> createState() => _ModelDownloadPageState();
}

class _ModelDownloadPageState extends State<ModelDownloadPage> {
  final FlutterTts _tts = FlutterTts();
  // Current status of the download process (notStarted, downloading, completed, etc.)
  DownloadStatus _downloadStatus = DownloadStatus.notStarted;

  // Progress information including bytes downloaded, speed, and estimated time
  DownloadProgress? _progress;

  // List of error messages to display to the user when downloads fail
  List<String> _errorMessages = [];

  // Controls visibility of the license agreement bottom sheet
  bool _showAgreementSheet = false;

  // Subscription to listen for log updates and refresh UI accordingly
  late StreamSubscription _logSubscription;

  // Business logic handler that manages all download operations
  late DownloadPageLogic _logic;

  // Prevents double auto-starts and re-entry after status changes.
  bool _autoStartAttempted = false;

  @override
  void initState() {
    super.initState();
    // Initialize all components in the correct order
    _initializeLogic();
    _initializeDownloader();
    _checkDownloadState();
    _setupLogListener();
    _announceInitialSetup();
  }

  @override
  void dispose() {
    // Clean up resources to prevent memory leaks
    _logSubscription.cancel();
    _logic.dispose(); // Dispose the logic to clean up timers
    try {
      _tts.stop();
    } catch (_) {}
    super.dispose();
  }

  /// Initializes the download logic with callback functions that update the UI state.
  void _initializeLogic() {
    _logic = DownloadPageLogic(
      // Callback to update download status (triggers UI rebuilds)
      setDownloadStatus: (status) => setState(() => _downloadStatus = status),
      // Callback to update progress information (updates progress bars/text)
      setProgress: (progress) => setState(() => _progress = progress),
      // Callback to update error messages (shows error dialogs/messages)
      setErrorMessages: (messages) => setState(() => _errorMessages = messages),
      // Callback to show/hide license agreement sheet
      setShowAgreementSheet: (show) => setState(() => _showAgreementSheet = show),
    );
  }

  Future<void> _announceInitialSetup() async {
    try {
      await _tts.setLanguage('bn-BD');
    } catch (_) {
      // Bengali voice missing on this device — platform default is fine.
    }
    try {
      await _tts.setSpeechRate(0.46);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(false);
      await Future.delayed(const Duration(milliseconds: 650));
      if (!mounted) return;
      await _tts.speak(
        'ReWoo Vision প্রস্তুত হচ্ছে। প্রয়োজনীয় AI মডেল ডাউনলোড হবে। '
        'প্রথমবার প্রয়োজন হলে ডাউনলোড বোতাম চেপে Hugging Face লগইন করুন — '
        'এটি একবারই লাগবে। ইন্টারনেট সংযোগ চালু রাখুন।',
        focus: true,
      );
    } catch (e) {
      debugPrint('[ModelDownloadPage] onboarding TTS unavailable: $e');
    }
  }

  /// Sets up a listener for log entries to refresh the UI when new logs are added.
  void _setupLogListener() {
    _logSubscription = Logger.logStream.listen((logEntry) {
      if (mounted) setState(() {});
    });
  }

  /// Initializes the download manager system.
  Future<void> _initializeDownloader() async {
    await DownloadManager.initialize();
    Logger.info('Download manager initialized');
  }

  /// Checks for previous download sessions and, when everything is ready,
  /// automatically starts the download — the user does not have to tap
  /// anything when a zero-touch authentication path is available.
  Future<void> _checkDownloadState() async {
    await _logic.checkForOngoingDownloads(context);

    if (!mounted) return;
    if (_autoStartAttempted) return;
    _autoStartAttempted = true;

    final canAutoStart = await _logic.canAutoStartDownload();
    if (!canAutoStart) return;

    Logger.info('Auto-starting model download (no user action required)');
    // Small delay so the first frame, TTS greeting and permission prompts
    // are all settled before the network work begins.
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      if (_downloadStatus == DownloadStatus.notStarted ||
          _downloadStatus == DownloadStatus.failed) {
        _logic.startDownload(autoStart: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50], // Light background for modern look
      body: SafeArea(
        child: Stack(
          children: [
            // Main content area with padding and centered layout
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  // Top spacer to center the main content vertically
                  const Spacer(flex: 1),

                  // Main content area - centered vertically
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // ReWoo Vision brand logo
                      Center(
                        child: Container(
                          width: 104,
                          height: 104,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(color: Colors.grey.shade200),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.06),
                                blurRadius: 14,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(25),
                            child: Image.asset(
                              'assets/logo.png',
                              fit: BoxFit.cover,
                              excludeFromSemantics: true,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 28),

                      // Animated download icon that changes based on status
                      ModernUIWidgets.buildDownloadIcon(
                        _downloadStatus,
                        _progress,
                      ),

                      const SizedBox(height: 32),

                      // Status message text that explains current download state
                      ModernUIWidgets.buildStatusMessage(
                        _downloadStatus,
                        _progress,
                        _errorMessages,
                      ),

                      const SizedBox(height: 24),

                      // Progress bar showing download completion percentage
                      ModernUIWidgets.buildProgressBar(
                        _progress,
                        _downloadStatus,
                      ),

                      const SizedBox(height: 40),

                      // Action buttons (Start, Pause, Resume, Cancel, Continue)
                      // Different buttons appear based on current download status
                      ModernUIWidgets.buildActionButtons(
                        _downloadStatus,
                        // User-initiated start — may open the one-time
                        // Hugging Face login when no token is available.
                        () => _logic.startDownload(),
                        () => _logic.pauseDownload(), // Pause active download
                        () => _logic.resumeDownload(), // Resume paused download
                        () => _logic.showCancelConfirmation(
                          context,
                        ), // Cancel with confirmation
                        // Navigate to chat page when download is complete
                        () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (context) => ChatPage()),
                        ),
                      ),
                    ],
                  ),

                  // Bottom spacer to balance the layout
                  const Spacer(flex: 1),

                  // Error details button - only shown when there are errors
                  if (_errorMessages.isNotEmpty &&
                      _downloadStatus == DownloadStatus.failed) ...[
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.red[50], // Light red background
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.red[200]!),
                      ),
                      child: TextButton.icon(
                        onPressed: () =>
                            UIHelpers.showErrorDialog(context, _errorMessages),
                        icon: Icon(Icons.error_outline, color: Colors.red[600]),
                        label: Text(
                          'সমস্যার বিস্তারিত দেখুন',
                          style: TextStyle(color: Colors.red[600]),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),

            // Logs button positioned at top right corner for debugging
            ModernUIWidgets.buildLogsButton(
              context,
              () => UIHelpers.showLogsDialog(context),
            ),
          ],
        ),
      ),
      // License agreement bottom sheet - shown when model requires acceptance
      bottomSheet: _showAgreementSheet
          ? ModernUIWidgets.buildLicenseBottomSheet(
              context,
              () => _logic.cancelLicenseAgreement(), // Cancel agreement
              () => _logic.openLicenseAgreement(), // Open license in browser
            )
          : null,
    );
  }
}
