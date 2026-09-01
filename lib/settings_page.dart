import 'package:flutter/material.dart';
import 'package:flutter_gemma/pigeon.g.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'chat_page/services/tts_engine_service.dart';
import 'chat_page/voice/bengali_voice_commands.dart';

/// Minimal, controller-free settings page for the Bengali assistant.
class SettingsPage extends StatefulWidget {
  final String systemContext;
  final PreferredBackend backend;

  /// Retained for compatibility with existing app/settings persistence.
  ///
  /// Direct five-command trigger mode does not require a separate wake word.
  final bool wakeWordMode;

  const SettingsPage({
    super.key,
    required this.systemContext,
    required this.backend,
    this.wakeWordMode = false,
  });

  @override
  State<SettingsPage> createState() =>
      _SettingsPageState();
}

class _SettingsPageState
    extends State<SettingsPage> {
  late final TextEditingController
      _systemContextController;

  late PreferredBackend _selectedBackend;

  /// Retained only for compatibility with existing settings/state code.
  late bool _wakeWordMode;

  bool _testingTts = false;

  late final FlutterTts _tts;

  // ===========================================================================
  // INIT
  // ===========================================================================

  @override
  void initState() {
    super.initState();

    _systemContextController =
        TextEditingController(
      text: widget.systemContext,
    );

    _selectedBackend =
        widget.backend;

    _wakeWordMode =
        widget.wakeWordMode;

    _tts =
        FlutterTts();
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  @override
  void dispose() {
    _systemContextController.dispose();

    try {
      _tts.stop();
    } catch (_) {}

    super.dispose();
  }

  // ===========================================================================
  // SAVE
  // ===========================================================================

  void _save() {
    Navigator.of(context).pop({
      'systemContext':
          _systemContextController.text.trim(),
      'backend':
          _selectedBackend,

      // Keep returning this value so existing caller/state code
      // remains source-compatible.
      'wakeWordMode':
          _wakeWordMode,
    });
  }

  // ===========================================================================
  // TTS TEST
  // ===========================================================================

  Future<void> _testTts() async {
    if (_testingTts) {
      return;
    }

    setState(() {
      _testingTts = true;
    });

    try {
      await TtsEngineService.configure(
        _tts,
      );

      await _tts.stop();

      await TtsEngineService.speakWithTimeout(
        _tts,
        'এটি একটি বাংলা কণ্ঠস্বর পরীক্ষা। '
        'যদি এই কথা শুনতে পান, তাহলে ভয়েস আউটপুট ঠিক আছে।',
      );

      if (!mounted) {
        return;
      }

      // Read the result AFTER configure(), not before it.
      final result =
          TtsEngineService.lastResult;

      final engine =
          result?.engine ??
              'ফোনের ডিফল্ট';

      final language =
          result?.language ??
              'ডিফল্ট';

      final bengaliVoice =
          result?.bengaliVoiceAvailable ==
                  true
              ? 'পাওয়া গেছে'
              : 'পাওয়া যায়নি '
                  '(ডিফল্ট ভয়েস ব্যবহার হচ্ছে)';

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'টেস্ট চালানো হয়েছে। '
            'ইঞ্জিন: $engine, '
            'ভাষা: $language, '
            'বাংলা ভয়েস: $bengaliVoice',
          ),
          duration:
              const Duration(
            seconds: 5,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'টেস্ট ব্যর্থ: $e',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _testingTts = false;
        });
      }
    }
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final ttsResult =
        TtsEngineService.lastResult;

    return Scaffold(
      backgroundColor:
          const Color(
        0xFFF7F8FA,
      ),

      appBar: AppBar(
        title:
            const Text(
          'সেটিংস',
        ),

        actions: [
          TextButton(
            onPressed:
                _save,
            child:
                const Text(
              'সেভ',
            ),
          ),

          const SizedBox(
            width: 8,
          ),
        ],
      ),

      body: ListView(
        padding:
            const EdgeInsets.all(
          16,
        ),

        children: [
          // ===================================================================
          // LANGUAGE
          // ===================================================================

          _section(
            title:
                'ভাষা',
            child:
                const ListTile(
              leading:
                  Icon(
                Icons.language_rounded,
              ),
              title:
                  Text(
                'বাংলা',
              ),
              subtitle:
                  Text(
                'ভয়েস কমান্ড, AI উত্তর ও টেক্সট-টু-স্পিচ '
                'বাংলা-প্রথম হিসেবে কনফিগার করা হয়েছে।',
              ),
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          // ===================================================================
          // TTS TEST
          // ===================================================================

          _section(
            title:
                'ভয়েস আউটপুট পরীক্ষা',
            child:
                Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,

              children: [
                ListTile(
                  leading:
                      _testingTts
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth:
                                    2,
                              ),
                            )
                          : const Icon(
                              Icons
                                  .volume_up_rounded,
                            ),

                  title:
                      const Text(
                    'কণ্ঠস্বর পরীক্ষা চালান',
                  ),

                  subtitle:
                      Text(
                    ttsResult == null
                        ? 'ইঞ্জিন ও ভাষা যাচাই করতে চাপুন'
                        : 'ইঞ্জিন: '
                            '${ttsResult.engine ?? "ডিফল্ট"} • '
                            'ভাষা: '
                            '${ttsResult.language ?? "ডিফল্ট"} • '
                            'বাংলা: '
                            '${ttsResult.bengaliVoiceAvailable ? "উপলব্ধ" : "ডিফল্ট ভয়েস"}',
                  ),

                  onTap:
                      _testingTts
                          ? null
                          : _testTts,
                ),

                const Padding(
                  padding:
                      EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    12,
                  ),
                  child:
                      Text(
                    'কোনো ফোনে আওয়াজ না শুনলে এই টেস্ট চালিয়ে দেখুন। '
                    'সমস্যা হলে ফোনের TTS সেটিংসে Google Text-to-Speech-এ '
                    'বাংলা ভাষা ইনস্টল করুন।',
                    style:
                        TextStyle(
                      fontSize:
                          13,
                      height:
                          1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          // ===================================================================
          // VOICE ACTIVATION
          // ===================================================================

          _section(
            title:
                'ভয়েস অ্যাক্টিভেশন',
            child:
                const Padding(
              padding:
                  EdgeInsets.all(
                16,
              ),

              child:
                  Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,

                children: [
                  Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,

                    children: [
                      Icon(
                        Icons
                            .record_voice_over_rounded,
                      ),

                      SizedBox(
                        width: 12,
                      ),

                      Expanded(
                        child:
                            Text(
                          'ReWoo Vision-এ আলাদা Wake Word প্রয়োজন নেই। '
                          'নিচের পাঁচটি নির্দিষ্ট বাংলা কমান্ডের যেকোনো একটি '
                          'সরাসরি বললেই অ্যাসিস্ট্যান্ট কাজ শুরু করবে।',
                        ),
                      ),
                    ],
                  ),

                  SizedBox(
                    height: 12,
                  ),

                  Text(
                    'ব্যাটারি ও প্রাইভেসি: অ্যাসিস্ট্যান্ট শুধু অ্যাপ '
                    'খোলা থাকা অবস্থায় শোনে — ব্যাকগ্রাউন্ডে নয়।',
                    style:
                        TextStyle(
                      fontSize:
                          13,
                      height:
                          1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          // ===================================================================
          // EXACT FIVE VOICE COMMANDS
          // ===================================================================

          _section(
            title:
                'ভয়েস কমান্ড',
            child:
                Column(
              children: [
                for (final command
                    in BengaliVoiceCommands
                        .triggerHelpCommands)
                  ListTile(
                    dense:
                        true,
                    leading:
                        const Icon(
                      Icons
                          .mic_none_rounded,
                    ),
                    title:
                        Text(
                      command,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          // ===================================================================
          // AI BACKEND
          // ===================================================================

          _section(
            title:
                'AI প্রসেসিং',
            child:
                Column(
              children: [
                RadioListTile<
                    PreferredBackend>(
                  value:
                      PreferredBackend.cpu,
                  groupValue:
                      _selectedBackend,
                  onChanged:
                      (value) {
                    if (value !=
                        null) {
                      setState(() {
                        _selectedBackend =
                            value;
                      });
                    }
                  },
                  title:
                      const Text(
                    'CPU',
                  ),
                  subtitle:
                      const Text(
                    'সর্বাধিক সামঞ্জস্যপূর্ণ অপশন',
                  ),
                ),

                RadioListTile<
                    PreferredBackend>(
                  value:
                      PreferredBackend.gpu,
                  groupValue:
                      _selectedBackend,
                  onChanged:
                      (value) {
                    if (value !=
                        null) {
                      setState(() {
                        _selectedBackend =
                            value;
                      });
                    }
                  },
                  title:
                      const Text(
                    'GPU',
                  ),
                  subtitle:
                      const Text(
                    'সমর্থিত শক্তিশালী ফোনে দ্রুত হতে পারে; '
                    'সমস্যা হলে CPU ব্যবহার করুন।',
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          // ===================================================================
          // SYSTEM CONTEXT
          // ===================================================================

          _section(
            title:
                'উন্নত AI নির্দেশনা',
            child:
                Padding(
              padding:
                  const EdgeInsets.all(
                14,
              ),
              child:
                  TextField(
                controller:
                    _systemContextController,
                minLines:
                    7,
                maxLines:
                    12,
                decoration:
                    const InputDecoration(
                  border:
                      OutlineInputBorder(),
                  helperText:
                      'এটি AI-এর নিরাপত্তা, সংক্ষিপ্ত উত্তর ও বাংলা ভাষার '
                      'আচরণ নিয়ন্ত্রণ করে। না বুঝলে পরিবর্তন করবেন না।',
                ),
              ),
            ),
          ),

          const SizedBox(
            height: 14,
          ),

          // ===================================================================
          // LIMITATIONS
          // ===================================================================

          _section(
            title:
                'গুরুত্বপূর্ণ সীমাবদ্ধতা',
            child:
                const Padding(
              padding:
                  EdgeInsets.all(
                16,
              ),
              child:
                  Text(
                'এই অ্যাপ পরিবেশ সম্পর্কে সহায়ক তথ্য দেয়। '
                'এটি সাদা ছড়ি, গাইড ডগ বা নিরাপদ চলাচল পদ্ধতির বিকল্প নয়। '
                'ক্যামেরার ডান/বাম কমান্ড বর্তমান ছবির ডান/বাম অংশকে বোঝায়। '
                'ভিডিও নীরব (অডিও ছাড়া) রেকর্ড হয় যাতে '
                'ভয়েস কমান্ড চালু থাকে।',
                style:
                    TextStyle(
                  height:
                      1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // SECTION
  // ===========================================================================

  Widget _section({
    required String title,
    required Widget child,
  }) {
    return Container(
      decoration:
          BoxDecoration(
        color:
            Colors.white,
        borderRadius:
            BorderRadius.circular(
          18,
        ),
        border:
            Border.all(
          color:
              Colors.grey.shade200,
        ),
      ),

      child:
          Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              6,
            ),
            child:
                Text(
              title,
              style:
                  const TextStyle(
                fontSize:
                    18,
                fontWeight:
                    FontWeight.w700,
              ),
            ),
          ),

          child,
        ],
      ),
    );
  }
}
