// lib/chat_page/widgets/chat_bubble.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models/message_models.dart';
import '../services/media_service.dart';

/// Chat message bubble with support for text, images, videos, markdown,
/// timestamps and performance stats. Handles different message types:
/// text-only, image-only, video-only, or combined image+text messages.
class ChatBubble extends StatelessWidget {
  final ChatMessage msg;

  const ChatBubble({Key? key, required this.msg}) : super(key: key);

  String get _timeLabel {
    final t = msg.createdAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    // Combined image+text messages: show as connected bubbles
    if (msg.imageFile != null && msg.text.isNotEmpty) {
      return Column(
        crossAxisAlignment: msg.isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _buildImageBubble(context),
          const SizedBox(height: 2), // Tight spacing to feel connected
          _buildTextBubble(context),
        ],
      );
    }

    // Video message
    if (msg.videoFile != null) {
      return Column(
        crossAxisAlignment: msg.isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _buildVideoBubble(context),
          const SizedBox(height: 2),
          if (msg.text.isNotEmpty) _buildTextBubble(context),
        ],
      );
    }

    // Image-only message
    if (msg.imageFile != null) {
      return _buildImageBubble(context);
    }

    // Text-only message (most common case)
    return _buildTextBubble(context);
  }

  Widget _buildMetaRow(Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4.0),
      child: Text(
        _timeLabel,
        style: TextStyle(color: color, fontSize: 10),
      ),
    );
  }

  /// Video bubble with a play affordance — tapping opens the system player
  /// through the native channel.
  Widget _buildVideoBubble(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: msg.isUser ? 60.0 : 8.0,
        right: msg.isUser ? 8.0 : 60.0,
        top: 2.0,
        bottom: 2.0,
      ),
      child: Align(
        alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.7,
          ),
          decoration: BoxDecoration(
            color: Colors.deepPurple.shade50,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.deepPurple.shade200),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: () => MediaService.openMedia(msg.videoFile!.path),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.deepPurple.shade600,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ভিডিও',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'চালাতে ট্যাপ করুন • $_timeLabel',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Image bubble with tap-to-expand and error handling
  Widget _buildImageBubble(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: msg.isUser ? 60.0 : 8.0,
        right: msg.isUser ? 8.0 : 60.0,
        top: 2.0,
        bottom: 2.0,
      ),
      child: Align(
        alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.7,
            maxHeight: MediaQuery.of(context).size.height * 0.4,
          ),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: GestureDetector(
              onTap: () => _showFullScreenImage(context, msg.imageFile!),
              child: Hero(
                tag: 'image_${msg.text}_${msg.imageFile!.path}',
                child: Stack(
                  children: [
                    Image.file(
                      msg.imageFile!,
                      fit: BoxFit.contain,
                      // Graceful error handling for corrupted/missing images
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          height: 200,
                          width: double.infinity,
                          color: Colors.grey.shade200,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 48,
                                color: Colors.grey.shade600,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'ছবি দেখানো যায়নি',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _timeLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Text bubble with markdown support, streaming indicator, and performance stats
  Widget _buildTextBubble(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: msg.isUser ? 60.0 : 8.0,
        right: msg.isUser ? 8.0 : 60.0,
        top: 4.0,
        bottom: 4.0,
      ),
      child: Align(
        alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.7,
          ),
          decoration: BoxDecoration(
            // User messages: blue, AI messages: light gray
            color: msg.isUser ? Colors.blueAccent : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14.0,
              vertical: 10.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (msg.text.isNotEmpty) _buildMessageContent(context),

                // Performance stats for completed AI responses
                if (msg.stats != null &&
                    !msg.isStreaming &&
                    msg.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: _buildStatsWidget(msg.stats!),
                  ),

                // Streaming indicator for messages being generated
                if (msg.isStreaming)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          msg.isUser ? Colors.white : Colors.blueAccent,
                        ),
                      ),
                    ),
                  ),

                _buildMetaRow(
                  msg.isUser ? Colors.white70 : Colors.black45,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Render message content with markdown support for AI responses
  Widget _buildMessageContent(BuildContext context) {
    // GptMarkdown handles AI responses with markdown formatting, LaTeX, code blocks
    // User messages use simple text since they typically don't contain markdown
    return GptMarkdown(
      msg.text,
      style: TextStyle(
        color: msg.isUser ? Colors.white : Colors.black87,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.3, // Line height for readability
      ),
    );
  }

  /// Full-screen image viewer with pinch-to-zoom
  void _showFullScreenImage(BuildContext context, File imageFile) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: const Text('ছবি', style: TextStyle(color: Colors.white)),
          ),
          body: Center(
            child: Hero(
              tag: 'image_${msg.text}_${imageFile.path}',
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 3.0, // Allow 3x zoom
                child: Image.file(
                  imageFile,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'ছবি দেখানো যায়নি',
                          style: TextStyle(color: Colors.white, fontSize: 18),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Performance statistics widget showing AI response metrics
  Widget _buildStatsWidget(MessageStats stats) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.analytics_outlined,
            size: 10,
            color: msg.isUser ? Colors.white70 : Colors.black54,
          ),
          const SizedBox(width: 3),
          // Core metrics: token count and total time
          Text(
            '${stats.tokenCount} টোকেন • ${stats.totalLatency!.toStringAsFixed(1)} সেকেন্ড',
            style: TextStyle(
              color: msg.isUser ? Colors.white70 : Colors.black54,
              fontSize: 10,
              fontWeight: FontWeight.w400,
            ),
          ),
          // Time to first token (latency metric)
          if (stats.timeToFirstToken != null) ...[
            Text(
              ' • প্রথম উত্তর ${stats.timeToFirstToken!.toStringAsFixed(1)} সেকেন্ড',
              style: TextStyle(
                color: msg.isUser ? Colors.white70 : Colors.black54,
                fontSize: 10,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
          // Generation speed (tokens per second)
          if (stats.decodeSpeed != null) ...[
            Text(
              ' • ${stats.decodeSpeed!.toStringAsFixed(1)} টোকেন/সেকেন্ড',
              style: TextStyle(
                color: msg.isUser ? Colors.white70 : Colors.black54,
                fontSize: 10,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
