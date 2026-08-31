// lib/chat_page/services/chat_history_store.dart
//
// Priority 6 — complete conversation history.
// Persists the chat (user commands, captured images, AI answers) as JSON in
// SharedPreferences so the conversation survives an app restart. Image and
// video files live in the app documents directory and are referenced by path.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message_models.dart';

class ChatHistoryStore {
  ChatHistoryStore._();

  static const String _historyKey = 'rewoo_chat_history_v1';
  static const int _maxMessages = 200;

  /// Saves the current conversation. Streaming placeholders and empty
  /// messages are skipped.
  static Future<void> save(List<ChatMessage> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = <Map<String, dynamic>>[];
      for (final m in messages) {
        if (m.isStreaming) continue;
        if (m.text.trim().isEmpty && !m.hasImage && !m.hasVideo) continue;
        items.add({
          'text': m.text,
          'isUser': m.isUser,
          'createdAt': m.createdAt.toIso8601String(),
          'imagePath': m.imageFile?.path,
          'videoPath': m.videoFile?.path,
        });
      }
      // Keep the last [_maxMessages] entries to bound storage growth.
      if (items.length > _maxMessages) {
        items.removeRange(0, items.length - _maxMessages);
      }
      await prefs.setString(_historyKey, json.encode(items));
    } catch (e) {
      debugPrint('[ChatHistoryStore] save failed: $e');
    }
  }

  /// Loads the persisted conversation. Entries whose media files were
  /// removed by the OS are still shown as text-only messages.
  static Future<List<ChatMessage>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw == null || raw.isEmpty) return [];

      final decoded = json.decode(raw);
      if (decoded is! List) return [];

      final messages = <ChatMessage>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final text = (item['text'] ?? '') as String;
        final isUser = (item['isUser'] ?? false) as bool;
        final imagePath = item['imagePath'] as String?;
        final videoPath = item['videoPath'] as String?;
        final createdAt = DateTime.tryParse(
          (item['createdAt'] ?? '') as String,
        );

        if (videoPath != null && videoPath.isNotEmpty) {
          messages.add(
            ChatMessage.withVideoFile(
              text,
              isUser: isUser,
              videoFile: videoPath.isEmpty ? null : _safeFile(videoPath),
              createdAt: createdAt,
            ),
          );
        } else if (imagePath != null && imagePath.isNotEmpty) {
          messages.add(
            ChatMessage.withImageFile(
              text,
              isUser: isUser,
              imageFile: _safeFile(imagePath),
              createdAt: createdAt,
            ),
          );
        } else {
          messages.add(ChatMessage.text(text, isUser: isUser, createdAt: createdAt));
        }
      }
      return messages;
    } catch (e) {
      debugPrint('[ChatHistoryStore] load failed: $e');
      return [];
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    } catch (e) {
      debugPrint('[ChatHistoryStore] clear failed: $e');
    }
  }

  static File? _safeFile(String path) {
    try {
      final file = File(path);
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }
}
