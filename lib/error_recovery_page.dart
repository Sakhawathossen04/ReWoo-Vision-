import 'package:flutter/material.dart';
import 'package:gemma_chat/download_page/services/download_manager.dart';
import 'package:gemma_chat/download_page/services/download_state_manager.dart';
import 'package:gemma_chat/download_page/model_download_page.dart';

class ErrorRecoveryPage extends StatefulWidget {
  const ErrorRecoveryPage({super.key});

  @override
  State<ErrorRecoveryPage> createState() => _ErrorRecoveryPageState();
}

class _ErrorRecoveryPageState extends State<ErrorRecoveryPage> {
  bool _isCleaningUp = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.red.shade50,
                  ),
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 48,
                    color: Colors.red.shade700,
                  ),
                ),
                const SizedBox(height: 26),
                const Text(
                  'AI মডেল চালু করা যায়নি',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'মডেল ফাইলটি অসম্পূর্ণ বা নষ্ট হতে পারে। সাধারণত ডাউনলোড মাঝপথে বন্ধ হলে এমন হয়।',
                  style: TextStyle(
                    fontSize: 17,
                    height: 1.5,
                    color: Colors.grey.shade700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                if (_isCleaningUp) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  const Text('পুরোনো ফাইল পরিষ্কার করা হচ্ছে…'),
                ] else
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _handleDeleteAndRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text(
                        'নতুন করে মডেল ডাউনলোড করুন',
                        style: TextStyle(fontSize: 17),
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                Text(
                  'সমস্যা থাকলে অ্যাপ সম্পূর্ণ বন্ধ করে আবার খুলুন। তারপরও কাজ না করলে অ্যাপ পুনরায় ইনস্টল করুন।',
                  style: TextStyle(color: Colors.grey.shade600, height: 1.45),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleDeleteAndRetry() async {
    setState(() => _isCleaningUp = true);

    try {
      await DownloadManager.cancelAndDeleteDownload();
      await DownloadStateManager.clearDownloadState();
      await DownloadManager.cleanupAllModelFiles();
    } catch (e) {
      debugPrint('Error cleaning up files: $e');
    }

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ModelDownloadPage()),
      );
    }
  }
}
