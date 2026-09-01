// download_page/model_download_page.dart
//
// ReWoo Vision model download screen.
//
// Responsibilities:
//
// 1. Restore/resume an existing model download.
// 2. Use the same robust TTS engine configuration as the main assistant.
// 3. Before a NEW ~3.1 GB download, verify device capability and free storage.
// 4. Block unsupported/weak devices gracefully instead of downloading a model
//    that cannot realistically run.
// 5. Preserve existing partial downloads.
// 6. Show + speak clear Bengali compatibility/storage errors.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../chat_page/gemma_vision_chat.dart';
import '../chat_page/services/tts_engine_service.dart';
import '../services/device_capability_service.dart';

import 'logic/download_logic.dart';
import 'models/enums.dart';
import 'models/models.dart';
import 'services/download_manager.dart';
import 'services/download_state_manager.dart';
import 'services/logger.dart';
import 'ui/modern_ui_widgets.dart';
import 'ui/ui_helpers.dart';

class ModelDownloadPage extends StatefulWidget {
  const ModelDownloadPage({
    super.key,
  });

  @override
  State<ModelDownloadPage> createState() =>
      _ModelDownloadPageState();
}

class _ModelDownloadPageState
    extends State<ModelDownloadPage> {
  // ===========================================================================
  // TTS
  // ===========================================================================

  final FlutterTts _tts = FlutterTts();

  bool _ttsConfigured = false;

  // ===========================================================================
  // DOWNLOAD STATE
  // ===========================================================================

  DownloadStatus _downloadStatus =
      DownloadStatus.notStarted;

  DownloadProgress? _progress;

  List<String> _errorMessages = [];

  bool _showAgreementSheet = false;

  // ===========================================================================
  // CAPABILITY STATE
  // ===========================================================================

  DeviceCapabilityResult? _deviceCapability;

  bool _checkingCapability = false;

  bool _startingDownload = false;

  String? _capabilityMessage;

  // ===========================================================================
  // OTHER STATE
  // ===========================================================================

  late DownloadPageLogic _logic;

  StreamSubscription? _logSubscription;

  bool _autoStartAttempted = false;

  bool _disposed = false;

  // ===========================================================================
  // INIT
  // ===========================================================================

  @override
  void initState() {
    super.initState();

    _initializeLogic();

    _setupLogListener();

    unawaited(
      _initializePage(),
    );
  }

  Future<void> _initializePage() async {
    try {
      // -----------------------------------------------------------------------
      // 1. Robust TTS
      // -----------------------------------------------------------------------

      await _configureTts();

      if (!mounted || _disposed) {
        return;
      }

      // -----------------------------------------------------------------------
      // 2. Accessibility startup message
      // -----------------------------------------------------------------------

      await _announceInitialSetup();

      if (!mounted || _disposed) {
        return;
      }

      // -----------------------------------------------------------------------
      // 3. Downloader
      // -----------------------------------------------------------------------

      await DownloadManager.initialize();

      Logger.info(
        'Download manager initialized',
      );

      if (!mounted || _disposed) {
        return;
      }

      // -----------------------------------------------------------------------
      // 4. Existing-task recovery / auto-start
      // -----------------------------------------------------------------------

      await _checkDownloadState();
    } catch (e, st) {
      Logger.error(
        'ModelDownloadPage initialization failed: $e',
      );

      debugPrint('$st');

      if (!mounted || _disposed) {
        return;
      }

      final message =
          _friendlyInitializationError(
        e,
      );

      setState(() {
        _downloadStatus =
            DownloadStatus.failed;

        _errorMessages = [
          message,
        ];
      });

      await _speak(
        message,
      );
    }
  }

  // ===========================================================================
  // DOWNLOAD LOGIC
  // ===========================================================================

  void _initializeLogic() {
    _logic = DownloadPageLogic(
      setDownloadStatus:
          (status) {
        if (!mounted || _disposed) {
          return;
        }

        setState(() {
          _downloadStatus = status;
        });
      },

      setProgress:
          (progress) {
        if (!mounted || _disposed) {
          return;
        }

        setState(() {
          _progress = progress;
        });
      },

      setErrorMessages:
          (messages) {
        if (!mounted || _disposed) {
          return;
        }

        setState(() {
          _errorMessages =
              List<String>.from(
            messages,
          );
        });
      },

      setShowAgreementSheet:
          (show) {
        if (!mounted || _disposed) {
          return;
        }

        setState(() {
          _showAgreementSheet = show;
        });
      },
    );
  }

  // ===========================================================================
  // TTS
  // ===========================================================================

  Future<void> _configureTts() async {
    if (_ttsConfigured ||
        _disposed) {
      return;
    }

    try {
      await TtsEngineService.configure(
        _tts,
      );

      _ttsConfigured = true;

      Logger.info(
        'Download-page TTS configured through TtsEngineService',
      );
    } catch (e) {
      // TTS is an accessibility enhancement here.
      // Failure must not crash/block the download page.
      Logger.warning(
        'Download-page TTS configuration failed: $e',
      );
    }
  }

  Future<void> _speak(
    String message,
  ) async {
    final text =
        message.trim();

    if (text.isEmpty ||
        _disposed) {
      return;
    }

    try {
      if (!_ttsConfigured) {
        await _configureTts();
      }

      if (_disposed) {
        return;
      }

      await TtsEngineService
          .speakWithTimeout(
        _tts,
        text,
      );
    } catch (e) {
      Logger.warning(
        'Download-page TTS unavailable: $e',
      );
    }
  }

  Future<void>
      _announceInitialSetup() async {
    await Future.delayed(
      const Duration(
        milliseconds: 650,
      ),
    );

    if (!mounted || _disposed) {
      return;
    }

    await _speak(
      'ReWoo Vision প্রস্তুত হচ্ছে। '
      'প্রয়োজনীয় AI মডেল ডাউনলোড হবে। '
      'প্রথমবার প্রয়োজন হলে ডাউনলোড বোতাম চেপে '
      'Hugging Face লগইন করুন। '
      'ইন্টারনেট সংযোগ চালু রাখুন।',
    );
  }

  // ===========================================================================
  // LOG LISTENER
  // ===========================================================================

  void _setupLogListener() {
    _logSubscription =
        Logger.logStream.listen(
      (_) {
        if (!mounted || _disposed) {
          return;
        }

        setState(
          () {},
        );
      },
    );
  }

  // ===========================================================================
  // DOWNLOAD RECOVERY / AUTO START
  // ===========================================================================

  Future<void>
      _checkDownloadState() async {
    // -------------------------------------------------------------------------
    // Existing task recovery ALWAYS happens first.
    //
    // If a previous download is at 23%, 50%, 95%, etc., DownloadLogic should
    // attach/resume it instead of creating another download.
    // -------------------------------------------------------------------------

    await _logic
        .checkForOngoingDownloads(
      context,
    );

    if (!mounted || _disposed) {
      return;
    }

    if (_autoStartAttempted) {
      return;
    }

    _autoStartAttempted = true;

    final canAutoStart =
        await _logic
            .canAutoStartDownload();

    if (!mounted ||
        _disposed ||
        !canAutoStart) {
      return;
    }

    await Future.delayed(
      const Duration(
        milliseconds: 1200,
      ),
    );

    if (!mounted || _disposed) {
      return;
    }

    if (_downloadStatus ==
            DownloadStatus.notStarted ||
        _downloadStatus ==
            DownloadStatus.failed) {
      await _startDownloadSafely(
        autoStart: true,
      );
    }
  }

  // ===========================================================================
  // SAFE START
  // ===========================================================================

  Future<void> _startDownloadSafely({
    bool autoStart = false,
  }) async {
    if (_disposed ||
        _startingDownload) {
      return;
    }

    _startingDownload = true;

    try {
      // -----------------------------------------------------------------------
      // EXISTING RECOVERABLE DOWNLOAD
      //
      // Do not demand 6 GB of NEW storage again merely to retry/resume an
      // already existing transfer.
      //
      // DownloadManager itself still enforces remaining-space protection.
      // -----------------------------------------------------------------------

      final recovery =
          await DownloadStateManager
              .getRecoveryState();

      if (recovery.isRecoverable) {
        Logger.info(
          'Existing recoverable model task found at '
          '${recovery.progressPercent}%. '
          'Fresh-download capability gate skipped.',
        );

        await _logic.startDownload(
          autoStart:
              autoStart,
        );

        return;
      }

      // -----------------------------------------------------------------------
      // INTERRUPTED VERIFICATION
      // -----------------------------------------------------------------------

      if (recovery.status ==
          DownloadStateManager
              .verifying) {
        const message =
            'মডেল ডাউনলোড শেষ হয়েছে এবং verification সম্পন্ন হওয়ার অপেক্ষায় আছে। '
            'নতুন download শুরু করা হবে না।';

        _setCapabilityError(
          message,
        );

        await _speak(
          message,
        );

        return;
      }

      // -----------------------------------------------------------------------
      // NEW DOWNLOAD
      //
      // Before downloading 3+ GB, validate this device.
      // -----------------------------------------------------------------------

      final allowed =
          await _checkCapabilityForNewDownload();

      if (!allowed) {
        return;
      }

      if (!mounted || _disposed) {
        return;
      }

      await _logic.startDownload(
        autoStart:
            autoStart,
      );
    } finally {
      _startingDownload = false;
    }
  }

  // ===========================================================================
  // DEVICE CAPABILITY GATE
  // ===========================================================================

  Future<bool>
      _checkCapabilityForNewDownload() async {
    if (_checkingCapability ||
        _disposed) {
      return false;
    }

    _checkingCapability = true;

    if (mounted) {
      setState(() {
        _capabilityMessage =
            null;
      });
    }

    try {
      Logger.info(
        'Checking device capability before new model download',
      );

      final capability =
          await DeviceCapabilityService
              .check();

      _deviceCapability =
          capability;

      if (!mounted || _disposed) {
        return false;
      }

      final reason =
          _getDownloadBlockReason(
        capability,
      );

      if (reason != null) {
        Logger.warning(
          'Model download blocked: $reason',
        );

        _setCapabilityError(
          reason,
        );

        await _speak(
          reason,
        );

        return false;
      }

      setState(() {
        _capabilityMessage =
            null;

        _errorMessages =
            [];
      });

      Logger.info(
        'Device passed model-download gate. '
        'Device=${capability.deviceLabel}, '
        'RAM=${capability.physicalRamGb.toStringAsFixed(1)}GB, '
        'free=${capability.freeStorageGb.toStringAsFixed(1)}GB',
      );

      return true;
    } catch (e, st) {
      Logger.error(
        'Device capability check failed: $e',
      );

      debugPrint(
        '$st',
      );

      if (!mounted || _disposed) {
        return false;
      }

      const message =
          'ফোনের storage এবং hardware capability নির্ভরযোগ্যভাবে '
          'পরীক্ষা করা যায়নি। '
          'নিরাপত্তার জন্য বড় AI model download শুরু করা হয়নি।';

      _setCapabilityError(
        message,
      );

      await _speak(
        message,
      );

      return false;
    } finally {
      _checkingCapability = false;

      if (mounted &&
          !_disposed) {
        setState(
          () {},
        );
      }
    }
  }

  // ===========================================================================
  // DOWNLOAD BLOCK REASON
  // ===========================================================================

  String? _getDownloadBlockReason(
    DeviceCapabilityResult capability,
  ) {
    // -------------------------------------------------------------------------
    // 1. FREE STORAGE
    // -------------------------------------------------------------------------

    if (!capability
        .hasEnoughStorageForDownload) {
      return 'মডেল ডাউনলোড করতে অন্তত ৬ জিবি খালি জায়গা প্রয়োজন। '
          'এই ফোনে বর্তমানে প্রায় '
          '${capability.freeStorageGb.toStringAsFixed(1)} জিবি খালি আছে। '
          'কিছু ফাইল মুছে জায়গা খালি করে আবার চেষ্টা করুন।';
    }

    // -------------------------------------------------------------------------
    // 2. ANDROID VERSION
    // -------------------------------------------------------------------------

    if (!capability
        .android9OrLater) {
      return 'ReWoo Vision ব্যবহার করতে Android 9 '
          'বা তার পরের version প্রয়োজন।';
    }

    // -------------------------------------------------------------------------
    // 3. 64-BIT
    // -------------------------------------------------------------------------

    if (!capability
        .is64BitCapable) {
      return 'এই ফোনে 64-bit AI runtime support নেই। '
          'এই device-এ local Gemma model চালানো যাবে না।';
    }

    // -------------------------------------------------------------------------
    // 4. ARM64
    // -------------------------------------------------------------------------

    if (!capability
        .hasArm64) {
      return 'এই ফোনে ARM64 architecture পাওয়া যায়নি। '
          'বর্তমান local Gemma runtime এই device-এর সাথে compatible নয়।';
    }

    // -------------------------------------------------------------------------
    // 5. RAM
    // -------------------------------------------------------------------------

    if (capability
            .physicalRamMb <=
        0) {
      return 'এই ফোনের RAM capacity নির্ভরযোগ্যভাবে যাচাই করা যায়নি। '
          'নিরাপত্তার জন্য বড় local AI model download শুরু করা হয়নি।';
    }

    if (capability
            .physicalRamMb <
        DeviceCapabilityService
            .minimumLocalGemmaRamMb) {
      return 'এই ফোনে প্রায় '
          '${capability.physicalRamGb.toStringAsFixed(1)} জিবি RAM আছে। '
          'Local Gemma model চালাতে অন্তত ৬ জিবি RAM প্রয়োজন। '
          'তাই model download শুরু করা হচ্ছে না।';
    }

    if (capability
        .isLowRamDevice) {
      return 'Android এই ফোনটিকে low-RAM device হিসেবে চিহ্নিত করেছে। '
          'এই device-এ বড় local AI model নিরাপদভাবে চালানো যাবে না।';
    }

    // -------------------------------------------------------------------------
    // 6. CAMERA
    // -------------------------------------------------------------------------

    if (!capability
        .cameraAvailable) {
      return 'এই ফোনে ব্যবহারযোগ্য camera পাওয়া যায়নি। '
          'ReWoo Vision-এর visual assistant feature চালানো যাবে না।';
    }

    // -------------------------------------------------------------------------
    // ADDITIONAL HARD BLOCKER
    // -------------------------------------------------------------------------

    if (!capability
            .localGemmaSupported &&
        capability
            .blockers
            .isNotEmpty) {
      return capability
          .blockers
          .first;
    }

    return null;
  }

  // ===========================================================================
  // CAPABILITY ERROR UI
  // ===========================================================================

  void _setCapabilityError(
    String message,
  ) {
    if (!mounted || _disposed) {
      return;
    }

    setState(() {
      _downloadStatus =
          DownloadStatus.failed;

      _capabilityMessage =
          message;

      _errorMessages = [
        message,
      ];
    });
  }

  // ===========================================================================
  // RESUME
  // ===========================================================================

  Future<void>
      _resumeDownload() async {
    if (_disposed) {
      return;
    }

    // Resume is not a NEW download.
    //
    // Therefore do not block an existing 95% transfer simply because there is
    // currently less than 6 GB of completely unused storage.
    //
    // DownloadManager still applies its own low-storage safety constraint.

    if (mounted) {
      setState(() {
        _capabilityMessage =
            null;
      });
    }

    await _logic
        .resumeDownload();
  }

  // ===========================================================================
  // INITIALIZATION ERROR CLASSIFICATION
  // ===========================================================================

  String _friendlyInitializationError(
    Object error,
  ) {
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
          'enospc',
        )) {
      return 'ফোনে পর্যাপ্ত খালি storage নেই। '
          'Model download-এর জন্য অন্তত ৬ জিবি খালি জায়গা রাখুন।';
    }

    if (text.contains(
          'network',
        ) ||
        text.contains(
          'connection',
        ) ||
        text.contains(
          'socket',
        )) {
      return 'ইন্টারনেট সংযোগে সমস্যা হয়েছে। '
          'আগের partial download থাকলে সেটি মুছে ফেলা হয়নি।';
    }

    return 'Model download system চালু করা যায়নি। '
        'Storage, internet এবং Android background-download support পরীক্ষা করুন।';
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  @override
  void dispose() {
    _disposed = true;

    _logSubscription
        ?.cancel();

    _logic.dispose();

    try {
      _tts.stop();
    } catch (_) {}

    super.dispose();
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final controlsDisabled =
        _checkingCapability ||
            _startingDownload;

    return Scaffold(
      backgroundColor:
          Colors.grey[50],

      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding:
                  const EdgeInsets
                      .all(
                24,
              ),

              child: Column(
                children: [
                  const Spacer(
                    flex: 1,
                  ),

                  Column(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .center,

                    children: [
                      // =======================================================
                      // LOGO
                      // =======================================================

                      Center(
                        child:
                            Container(
                          width: 104,
                          height: 104,

                          decoration:
                              BoxDecoration(
                            borderRadius:
                                BorderRadius
                                    .circular(
                              26,
                            ),

                            border:
                                Border.all(
                              color:
                                  Colors
                                      .grey
                                      .shade200,
                            ),

                            boxShadow: [
                              BoxShadow(
                                color:
                                    Colors
                                        .black
                                        .withOpacity(
                                  0.06,
                                ),
                                blurRadius:
                                    14,
                                offset:
                                    const Offset(
                                  0,
                                  5,
                                ),
                              ),
                            ],
                          ),

                          child:
                              ClipRRect(
                            borderRadius:
                                BorderRadius
                                    .circular(
                              25,
                            ),

                            child:
                                Image.asset(
                              'assets/logo.png',
                              fit:
                                  BoxFit.cover,
                              excludeFromSemantics:
                                  true,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(
                        height: 28,
                      ),

                      // =======================================================
                      // DOWNLOAD ICON
                      // =======================================================

                      ModernUIWidgets
                          .buildDownloadIcon(
                        _downloadStatus,
                        _progress,
                      ),

                      const SizedBox(
                        height: 32,
                      ),

                      // =======================================================
                      // STATUS
                      // =======================================================

                      ModernUIWidgets
                          .buildStatusMessage(
                        _downloadStatus,
                        _progress,
                        _errorMessages,
                      ),

                      // =======================================================
                      // DEVICE / STORAGE WARNING
                      // =======================================================

                      if (_capabilityMessage !=
                          null) ...[
                        const SizedBox(
                          height: 20,
                        ),

                        Semantics(
                          liveRegion:
                              true,

                          label:
                              _capabilityMessage,

                          child:
                              Container(
                            width:
                                double.infinity,

                            padding:
                                const EdgeInsets
                                    .all(
                              16,
                            ),

                            decoration:
                                BoxDecoration(
                              color:
                                  Colors
                                      .orange[
                                50,
                              ],

                              borderRadius:
                                  BorderRadius
                                      .circular(
                                14,
                              ),

                              border:
                                  Border.all(
                                color:
                                    Colors
                                        .orange[
                                  300,
                                ]!,
                              ),
                            ),

                            child:
                                Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,

                              children: [
                                Icon(
                                  Icons
                                      .warning_amber_rounded,
                                  color:
                                      Colors
                                          .orange[
                                    800,
                                  ],
                                ),

                                const SizedBox(
                                  width: 12,
                                ),

                                Expanded(
                                  child:
                                      Text(
                                    _capabilityMessage!,
                                    style:
                                        TextStyle(
                                      fontSize:
                                          15,
                                      height:
                                          1.4,
                                      fontWeight:
                                          FontWeight
                                              .w600,
                                      color:
                                          Colors
                                              .orange[
                                        900,
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      const SizedBox(
                        height: 24,
                      ),

                      // =======================================================
                      // PROGRESS BAR
                      // =======================================================

                      ModernUIWidgets
                          .buildProgressBar(
                        _progress,
                        _downloadStatus,
                      ),

                      const SizedBox(
                        height: 32,
                      ),

                      // =======================================================
                      // CAPABILITY CHECKING
                      // =======================================================

                      if (_checkingCapability) ...[
                        const Semantics(
                          liveRegion:
                              true,

                          label:
                              'ফোনের storage এবং AI capability পরীক্ষা করা হচ্ছে',

                          child:
                              Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,

                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,

                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      2.5,
                                ),
                              ),

                              SizedBox(
                                width: 12,
                              ),

                              Flexible(
                                child:
                                    Text(
                                  'ফোনের storage ও AI capability পরীক্ষা করা হচ্ছে...',
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(
                          height: 20,
                        ),
                      ],

                      // =======================================================
                      // ACTION BUTTONS
                      // =======================================================

                      IgnorePointer(
                        ignoring:
                            controlsDisabled,

                        child:
                            Opacity(
                          opacity:
                              controlsDisabled
                                  ? 0.55
                                  : 1.0,

                          child:
                              ModernUIWidgets
                                  .buildActionButtons(
                            _downloadStatus,

                            // START
                            () {
                              unawaited(
                                _startDownloadSafely(),
                              );
                            },

                            // PAUSE
                            () {
                              unawaited(
                                _logic
                                    .pauseDownload(),
                              );
                            },

                            // RESUME
                            () {
                              unawaited(
                                _resumeDownload(),
                              );
                            },

                            // CANCEL
                            () {
                              unawaited(
                                _logic
                                    .showCancelConfirmation(
                                  context,
                                ),
                              );
                            },

                            // CONTINUE
                            //
                            // DownloadLogic only sets completed after final
                            // model verification succeeds.
                            () {
                              Navigator.of(
                                context,
                              ).pushReplacement(
                                MaterialPageRoute(
                                  builder:
                                      (_) =>
                                          const ChatPage(),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),

                  const Spacer(
                    flex: 1,
                  ),

                  // =========================================================
                  // ERROR DETAILS
                  // =========================================================

                  if (_errorMessages
                          .isNotEmpty &&
                      _downloadStatus ==
                          DownloadStatus
                              .failed) ...[
                    Container(
                      width:
                          double.infinity,

                      decoration:
                          BoxDecoration(
                        color:
                            Colors
                                .red[
                          50,
                        ],

                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),

                        border:
                            Border.all(
                          color:
                              Colors
                                  .red[
                            200,
                          ]!,
                        ),
                      ),

                      child:
                          TextButton
                              .icon(
                        onPressed:
                            () {
                          UIHelpers
                              .showErrorDialog(
                            context,
                            _errorMessages,
                          );
                        },

                        icon:
                            Icon(
                          Icons
                              .error_outline,
                          color:
                              Colors
                                  .red[
                            600,
                          ],
                        ),

                        label:
                            Text(
                          'সমস্যার বিস্তারিত দেখুন',
                          style:
                              TextStyle(
                            color:
                                Colors
                                    .red[
                              600,
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 16,
                    ),
                  ],
                ],
              ),
            ),

            // ===============================================================
            // LOGS
            // ===============================================================

            ModernUIWidgets
                .buildLogsButton(
              context,
              () {
                UIHelpers
                    .showLogsDialog(
                  context,
                );
              },
            ),
          ],
        ),
      ),

      // =========================================================================
      // LICENSE AGREEMENT
      // =========================================================================

      bottomSheet:
          _showAgreementSheet
              ? ModernUIWidgets
                  .buildLicenseBottomSheet(
                  context,

                  () {
                    _logic
                        .cancelLicenseAgreement();
                  },

                  () {
                    unawaited(
                      _logic
                          .openLicenseAgreement(),
                    );
                  },
                )
              : null,
    );
  }
}
