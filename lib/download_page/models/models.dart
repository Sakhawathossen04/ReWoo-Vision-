// download_page/models/models.dart
import 'package:flutter_downloader/flutter_downloader.dart';

// Download progress data with percentage calculation
class DownloadProgress {
  final int totalBytes;
  final int downloadedBytes;
  final double downloadRate;
  final Duration remainingTime;
  final DownloadTaskStatus status;

  DownloadProgress({
    required this.totalBytes,
    required this.downloadedBytes,
    required this.downloadRate,
    required this.remainingTime,
    required this.status,
  });

  // Calculate progress as 0.0-1.0 ratio
  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  // Convert to percentage (0-100)
  int get progressPercent => (progress * 100).round();
}

// Log entry with timestamp formatting for debug display
class LogEntry {
  final DateTime timestamp;
  final String level;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  // Format time as HH:MM:SS for logs display
  String get formattedTime =>
      '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';

  @override
  String toString() => '[$formattedTime] [$level] $message';
}
