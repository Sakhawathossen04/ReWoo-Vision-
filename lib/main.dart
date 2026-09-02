// main.dart

import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:path_provider/path_provider.dart';

import 'package:gemma_chat/chat_page/gemma_vision_chat.dart';
import 'package:gemma_chat/download_page/config/constants.dart';
import 'package:gemma_chat/download_page/model_download_page.dart';
import 'package:gemma_chat/download_page/services/download_manager.dart';
import 'package:gemma_chat/download_page/services/download_state_manager.dart';

/// ---------------------------------------------------------------------------
/// LEGACY flutter_downloader CALLBACK
/// ---------------------------------------------------------------------------
///
/// Kept temporarily because the project is still in a migration period where
/// some download code depends on flutter_downloader compatibility.
///
/// background_downloader is the primary large-model download engine.
@pragma('vm:entry-point')
void downloadCallback(
  String id,
  int status,
  int progress,
) {
  final SendPort? send =
      IsolateNameServer.lookupPortByName(
    'downloader_send_port',
  );

  send?.send([
    id,
    status,
    progress,
  ]);
}

/// ---------------------------------------------------------------------------
/// APP ENTRY POINT
/// ---------------------------------------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // 1. LEGACY DOWNLOADER INITIALIZATION
  // -------------------------------------------------------------------------
  //
  // Keep this for now because the project still has flutter_downloader
  // compatibility code.
  //
  try {
    await FlutterDownloader.initialize(
      debug: kDebugMode,
      ignoreSsl: false,
    );

    FlutterDownloader.registerCallback(
      downloadCallback,
    );
  } catch (e) {
    debugPrint(
      '[main] Legacy flutter_downloader initialization warning: $e',
    );

    // Do NOT stop app startup.
    //
    // background_downloader / physical model-file detection may still work.
  }

  // -------------------------------------------------------------------------
  // 2. RESOLVE CORRECT STARTUP SCREEN
  // -------------------------------------------------------------------------

  final Widget startupHome =
      await _resolveStartupHome();

  runApp(
    MyApp(
      startupHome: startupHome,
    ),
  );
}

/// ---------------------------------------------------------------------------
/// STARTUP ROUTER
/// ---------------------------------------------------------------------------
///
/// Startup policy:
///
/// app starts
///      ↓
/// allow DownloadManager to recover/finalize completed native tasks
///      ↓
/// check canonical final Gemma model
///      ↓
/// valid final model?
///
/// YES
///      ↓
/// repair persistent state if necessary
///      ↓
/// ChatPage
///
/// NO
///      ↓
/// ModelDownloadPage
///
/// IMPORTANT:
///
/// This method never deletes:
///
/// - modelName
/// - modelName.part
/// - downloader task data
///
/// ModelDownloadPage / DownloadLogic remains responsible for recovery.
Future<Widget> _resolveStartupHome() async {
  // =========================================================================
  // PHASE 1
  // INITIALIZE BACKGROUND DOWNLOADER / FINALIZE COMPLETED .part
  // =========================================================================

  try {
    await DownloadManager.initialize();

    debugPrint(
      '[main] DownloadManager startup recovery completed.',
    );
  } catch (e, st) {
    debugPrint(
      '[main] DownloadManager initialization warning: $e',
    );

    debugPrint(
      '$st',
    );

    // Continue.
    //
    // Even if downloader DB initialization fails, a fully downloaded physical
    // model may still exist and must be reused.
  }

  // =========================================================================
  // PHASE 2
  // CHECK PHYSICAL FINAL MODEL
  // =========================================================================

  try {
    final directory =
        await getApplicationDocumentsDirectory();

    final modelPath =
        '${directory.path}/$modelName';

    final modelFile =
        File(modelPath);

    debugPrint(
      '[main] Checking existing model: $modelPath',
    );

    if (!await modelFile.exists()) {
      debugPrint(
        '[main] Final model not found. Opening download/recovery page.',
      );

      return const ModelDownloadPage();
    }

    final size =
        await modelFile.length();

    final minimumValidSize =
        (expectedModelFileSize *
                modelSizeTolerance)
            .round();

    debugPrint(
      '[main] Existing model size: '
      '$size bytes. '
      'Minimum accepted: '
      '$minimumValidSize bytes.',
    );

    // -----------------------------------------------------------------------
    // VALID EXISTING FINAL MODEL
    // -----------------------------------------------------------------------

    if (size >=
        minimumValidSize) {
      debugPrint(
        '[main] Existing model is valid. '
        'Skipping Hugging Face download page.',
      );

      // ---------------------------------------------------------------------
      // Repair persistent state.
      //
      // Example:
      //
      // Physical 3.14GB model exists
      // but SharedPreferences state was lost/stale.
      //
      // The physical verified model wins.
      // ---------------------------------------------------------------------

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

        debugPrint(
          '[main] Download state repaired to completed + verified.',
        );
      } catch (e) {
        debugPrint(
          '[main] Could not repair download state: $e',
        );

        // State repair failure must NOT force another 3+ GB download.
        //
        // The physical model has already passed the startup size gate.
      }

      return const ChatPage();
    }

    // -----------------------------------------------------------------------
    // FINAL FILE EXISTS BUT IS TOO SMALL
    // -----------------------------------------------------------------------
    //
    // DO NOT DELETE IT HERE.
    //
    // DownloadLogic/DownloadManager owns corruption/recovery decisions.
    // This is especially important during migration from older download
    // versions.
    // -----------------------------------------------------------------------

    debugPrint(
      '[main] Final model exists but is below minimum valid size. '
      'Preserving file and opening recovery page.',
    );

    return const ModelDownloadPage();
  } catch (e, st) {
    debugPrint(
      '[main] Startup model verification failed: $e',
    );

    debugPrint(
      '$st',
    );

    // Safe fallback:
    //
    // Never assume a failed check means "start downloading immediately".
    //
    // ModelDownloadPage first runs its recovery/model checks.
    return const ModelDownloadPage();
  }
}

/// ---------------------------------------------------------------------------
/// ROOT APP
/// ---------------------------------------------------------------------------
class MyApp extends StatelessWidget {
  final Widget startupHome;

  const MyApp({
    super.key,
    required this.startupHome,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      title:
          'ReWoo Vision',

      debugShowCheckedModeBanner:
          false,

      theme:
          ThemeData(
        useMaterial3:
            true,

        colorSchemeSeed:
            Colors.indigo,
      ),

      // ---------------------------------------------------------------------
      // IMPORTANT:
      //
      // OLD:
      //
      // home: const ModelDownloadPage()
      //
      // NEW:
      //
      // valid model      -> ChatPage
      // missing/recovery -> ModelDownloadPage
      // ---------------------------------------------------------------------

      home:
          startupHome,
    );
  }
}
