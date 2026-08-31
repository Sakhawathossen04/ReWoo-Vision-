// lib/chat_page/services/media_service.dart
//
// Photo / video support for voice commands:
//   "ছবি তোলো"  → capture + save + show in chat
//   "ভিডিও রেকর্ড করো" / "ভিডিও বন্ধ করো" → record + save + show in chat
//
// Media lives under <app documents>/media/{photos,videos} so it survives
// reboots and never requires storage permissions on any Android version.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../download_page/config/constants.dart';

class MediaService {
  MediaService._();

  static const MethodChannel _channel = MethodChannel('rewoo_vision/media');

  static String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  static Future<Directory> _ensureFolder(String sub) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$mediaFolderName/$sub');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Moves a freshly captured camera picture into the managed photo folder.
  static Future<File> savePhoto(File captured) async {
    final dir = await _ensureFolder('photos');
    final target = File('${dir.path}/IMG_${_timestamp()}.jpg');
    try {
      return await captured.rename(target.path);
    } on FileSystemException {
      // rename can fail across mount points — fall back to copy+delete.
      final copy = await captured.copy(target.path);
      try {
        await captured.delete();
      } catch (_) {}
      return copy;
    }
  }

  /// Moves a finished video recording into the managed video folder.
  static Future<File> saveVideo(File recorded) async {
    final dir = await _ensureFolder('videos');
    final target = File('${dir.path}/VID_${_timestamp()}.mp4');
    try {
      return await recorded.rename(target.path);
    } on FileSystemException {
      final copy = await recorded.copy(target.path);
      try {
        await recorded.delete();
      } catch (_) {}
      return copy;
    }
  }

  /// Opens saved media with the system viewer (photo viewer / video player)
  /// through the native channel. Returns false when nothing can open it.
  static Future<bool> openMedia(String path) async {
    try {
      final result = await _channel.invokeMethod<bool>('openMedia', {
        'path': path,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }
}
