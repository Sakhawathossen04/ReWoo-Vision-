// models/message_models.dart
import 'dart:io';
import 'dart:typed_data';

/// Chat message with image and video support for the vision assistant.
class ChatMessage {
  String text;
  final bool isUser;
  bool isStreaming;
  MessageStats? stats;
  File? imageFile; // Camera captured images
  Uint8List? imageBytes; // In-memory images
  File? videoFile; // Recorded videos (voice command "ভিডিও রেকর্ড করো")
  DateTime createdAt; // Shown in the chat bubble + history ordering

  ChatMessage(
    this.text, {
    required this.isUser,
    this.isStreaming = false,
    this.stats,
    this.imageFile,
    this.imageBytes,
    this.videoFile,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Text-only message constructor
  ChatMessage.text(
    this.text, {
    required this.isUser,
    this.isStreaming = false,
    this.stats,
    DateTime? createdAt,
  }) : imageFile = null,
       imageBytes = null,
       videoFile = null,
       createdAt = createdAt ?? DateTime.now();

  /// Message with camera image file
  ChatMessage.withImageFile(
    this.text, {
    required this.isUser,
    required this.imageFile,
    this.isStreaming = false,
    this.stats,
    DateTime? createdAt,
  }) : imageBytes = null,
       videoFile = null,
       createdAt = createdAt ?? DateTime.now();

  /// Message with image data in memory
  ChatMessage.withImageBytes(
    this.text, {
    required this.isUser,
    required this.imageBytes,
    this.isStreaming = false,
    this.stats,
    DateTime? createdAt,
  }) : imageFile = null,
       videoFile = null,
       createdAt = createdAt ?? DateTime.now();

  /// Message with a recorded video file
  ChatMessage.withVideoFile(
    this.text, {
    required this.isUser,
    required this.videoFile,
    this.isStreaming = false,
    this.stats,
    DateTime? createdAt,
  }) : imageFile = null,
       imageBytes = null,
       createdAt = createdAt ?? DateTime.now();

  bool get hasImage => imageFile != null || imageBytes != null;
  bool get hasVideo => videoFile != null;

  /// Convert image to bytes for API calls (handles both file and memory images)
  Future<Uint8List?> getImageBytes() async {
    if (imageBytes != null) return imageBytes;
    if (imageFile != null) return await imageFile!.readAsBytes();
    return null;
  }
}

/// AI response performance metrics
class MessageStats {
  final double? timeToFirstToken;
  final double? totalLatency;
  final double? prefillSpeed;
  final double? decodeSpeed;
  final int? tokenCount;

  const MessageStats({
    this.timeToFirstToken,
    this.totalLatency,
    this.prefillSpeed,
    this.decodeSpeed,
    this.tokenCount,
  });
}
