import 'package:flutter/material.dart';
import 'package:flutter_gemma/pigeon.g.dart';

import 'chat_page/voice/bengali_voice_commands.dart';

/// Minimal, controller-free settings page for the Bengali assistant.
class SettingsPage extends StatefulWidget {
  final String systemContext;
  final PreferredBackend backend;

  const SettingsPage({
    super.key,
    required this.systemContext,
    required this.backend,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _systemContextController;
  late PreferredBackend _selectedBackend;

  @override
  void initState() {
    super.initState();
    _systemContextController = TextEditingController(text: widget.systemContext);
    _selectedBackend = widget.backend;
  }

  @override
  void dispose() {
    _systemContextController.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop({
      'systemContext': _systemContextController.text.trim(),
      'backend': _selectedBackend,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: const Text('সেটিংস'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('সেভ'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section(
            title: 'ভাষা',
            child: const ListTile(
              leading: Icon(Icons.language_rounded),
              title: Text('বাংলা'),
              subtitle: Text(
                'ভয়েস কমান্ড, AI উত্তর ও টেক্সট-টু-স্পিচ বাংলা-প্রথম হিসেবে কনফিগার করা হয়েছে।',
              ),
            ),
          ),
          const SizedBox(height: 14),
          _section(
            title: 'ভয়েস কমান্ড',
            child: Column(
              children: [
                for (final command in BengaliVoiceCommands.primaryHelpCommands)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.mic_none_rounded),
                    title: Text(command),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _section(
            title: 'AI প্রসেসিং',
            child: Column(
              children: [
                RadioListTile<PreferredBackend>(
                  value: PreferredBackend.cpu,
                  groupValue: _selectedBackend,
                  onChanged: (value) {
                    if (value != null) setState(() => _selectedBackend = value);
                  },
                  title: const Text('CPU'),
                  subtitle: const Text('সর্বাধিক সামঞ্জস্যপূর্ণ অপশন'),
                ),
                RadioListTile<PreferredBackend>(
                  value: PreferredBackend.gpu,
                  groupValue: _selectedBackend,
                  onChanged: (value) {
                    if (value != null) setState(() => _selectedBackend = value);
                  },
                  title: const Text('GPU'),
                  subtitle: const Text(
                    'সমর্থিত শক্তিশালী ফোনে দ্রুত হতে পারে; সমস্যা হলে CPU ব্যবহার করুন।',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _section(
            title: 'উন্নত AI নির্দেশনা',
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                controller: _systemContextController,
                minLines: 7,
                maxLines: 12,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  helperText:
                      'এটি AI-এর নিরাপত্তা, সংক্ষিপ্ত উত্তর ও বাংলা ভাষার আচরণ নিয়ন্ত্রণ করে। না বুঝলে পরিবর্তন করবেন না।',
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _section(
            title: 'গুরুত্বপূর্ণ সীমাবদ্ধতা',
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'এই অ্যাপ পরিবেশ সম্পর্কে সহায়ক তথ্য দেয়। এটি সাদা ছড়ি, গাইড ডগ বা নিরাপদ চলাচল পদ্ধতির বিকল্প নয়। ক্যামেরার ডান/বাম কমান্ড বর্তমান ছবির ডান/বাম অংশকে বোঝায়।',
                style: TextStyle(height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section({required String title, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
