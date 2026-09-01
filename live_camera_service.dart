import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Process-wide owner of the video-call camera.
///
/// One instance for the whole app so the chat screen and its helpers share
/// the same warm controller — the camera opens once per screen visit and is
/// fully released the moment the screen is disposed.
class LiveCameraManager {
  LiveCameraManager._();
  static final LiveCameraService instance = LiveCameraService();
}

/// Video-call style persistent camera service.
///
/// The old flow opened the camera for every command (init → capture →
/// dispose), which cost 1–3 seconds of dead time per question and was a
/// common source of "sometimes works, sometimes doesn't" behaviour on OEM
/// camera stacks that dislike rapid open/close cycles.
///
/// This service keeps ONE warm [CameraController] alive for the whole time
/// the assistant screen is visible — exactly like a video call:
///   * start()  → camera opens once, the live preview runs continuously.
///   * capturePhoto() → instant takePicture() on the warm controller.
///   * startVideo()/stopVideo() → recording on the same controller, with an
///     automatic re-open afterwards so the preview never dies.
///   * dispose() → camera fully released. Nothing runs when the screen is
///     gone — no background camera, ever.
///
/// The microphone is never touched here (enableAudio: false), so the
/// continuous Bangla voice loop stays alive the whole time.
class LiveCameraService extends ChangeNotifier {
  CameraController? _controller;
  bool _starting = false;
  bool _disposed = false;
  bool _recording = false;
  String? _lastError;

  /// Serialises all camera operations — the camera HAL on many phones
  /// corrupts state when two operations overlap.
  Future<void> _opLock = Future<void>.value();

  CameraController? get controller => _controller;
  bool get isReady => _controller != null && _controller!.value.isInitialized;
  bool get isStarting => _starting;
  bool get isRecording => _recording;
  String? get lastError => _lastError;

  Future<T> _locked<T>(Future<T> Function() op) {
    final previous = _opLock;
    final completer = Completer<void>();
    _opLock = completer.future;
    return previous.then((_) => op()).whenComplete(() {
      if (!completer.isCompleted) completer.complete();
    });
  }

  /// Opens the camera and keeps it running until [dispose] is called.
  /// Safe to call repeatedly — an already-warm camera is returned as-is.
  Future<void> start() async {
    if (_disposed) return;
    if (isReady || _starting) return;
    await _locked(_startInternal);
  }

  Future<void> _startInternal() async {
    if (_disposed || isReady) return;
    _starting = true;
    _lastError = null;
    notifyListeners();

    try {
      final cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) {
        throw Exception('ক্যামেরার অনুমতি দেওয়া হয়নি');
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('কোনো ক্যামেরা পাওয়া যায়নি');
      }

      final description = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // Resolution fallback chain: a few low-end phones reject 'high'
      // outright — the video-call view must still come up.
      const presets = [
        ResolutionPreset.high,
        ResolutionPreset.medium,
        ResolutionPreset.low,
      ];

      Object? lastError;
      for (final preset in presets) {
        CameraController? candidate;
        try {
          candidate = CameraController(
            description,
            preset,
            // enableAudio: false — the microphone belongs to the Bangla
            // voice command loop, not the camera.
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.jpeg,
          );
          await candidate.initialize();
          _controller = candidate;
          _recording = false;
          _lastError = null;
          notifyListeners();
          return;
        } catch (e) {
          lastError = e;
          try {
            await candidate?.dispose();
          } catch (_) {}
          candidate = null;
        }
      }
      throw Exception('ক্যামেরা চালু করা যায়নি: $lastError');
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[LiveCameraService] start failed: $e');
      notifyListeners();
      rethrow;
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  /// Instantly captures one photo from the warm preview.
  ///
  /// Includes the proven OEM retry: a few camera HALs reject the first
  /// capture right after initialization, so we retry once before failing.
  Future<File> capturePhoto() {
    return _locked(() async {
      if (_disposed) {
        throw Exception('ক্যামেরা বন্ধ আছে');
      }
      if (_recording) {
        throw Exception('ভিডিও রেকর্ড চলছে — ছবি তোলা যাবে না');
      }
      if (!isReady) {
        await _startInternal();
      }
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) {
        throw Exception('ক্যামেরা প্রস্তুত নয়');
      }

      try {
        final image = await controller.takePicture();
        return File(image.path);
      } catch (e) {
        debugPrint('[LiveCameraService] first capture failed, retrying: $e');
        await Future.delayed(const Duration(milliseconds: 350));
        // If the controller died mid-capture, resurrect it once.
        if (!controller.value.isInitialized) {
          await _restartInternal();
          final warmed = _controller;
          if (warmed == null) throw Exception('ক্যামেরা পুনরায় চালু করা যায়নি');
          final image = await warmed.takePicture();
          return File(image.path);
        }
        final image = await controller.takePicture();
        return File(image.path);
      }
    });
  }

  /// Starts video recording on the warm controller.
  Future<void> startVideo() {
    return _locked(() async {
      if (_disposed) {
        throw Exception('ক্যামেরা বন্ধ আছে');
      }
      if (_recording) return;
      if (!isReady) {
        await _startInternal();
      }
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) {
        throw Exception('ক্যামেরা প্রস্তুত নয়');
      }
      try {
        await controller.prepareForVideoRecording();
      } catch (_) {
        // Not required on every platform/version; safe to ignore.
      }
      await controller.startVideoRecording();
      _recording = true;
      notifyListeners();
    });
  }

  /// Stops the current recording, then re-opens the camera so the
  /// video-call preview comes back immediately.
  Future<File> stopVideo() {
    return _locked(() async {
      final controller = _controller;
      if (controller == null || !_recording) {
        throw Exception('কোনো ভিডিও রেকর্ড হচ্ছে না');
      }
      late final XFile file;
      try {
        file = await controller.stopVideoRecording();
      } finally {
        _recording = false;
        notifyListeners();
      }
      final result = File(file.path);
      // Bring the live preview back — some devices stop the preview stream
      // after a recording ends.
      await _restartInternal();
      return result;
    });
  }

  /// Re-opens the camera in place (used after recording or a HAL crash).
  Future<void> restart() => _locked(_restartInternal);

  Future<void> _restartInternal() async {
    if (_disposed) return;
    final old = _controller;
    _controller = null;
    _recording = false;
    notifyListeners();
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }
    await _startInternal();
  }

  @override
  void dispose() {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    _recording = false;
    if (controller != null) {
      unawaited(() async {
        try {
          await controller.dispose();
        } catch (_) {}
      }());
    }
    super.dispose();
  }
}
