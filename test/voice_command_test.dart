import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_chat/chat_page/voice/bengali_voice_commands.dart';
import 'package:gemma_chat/chat_page/voice/voice_intent.dart';

void main() {
  group('BengaliVoiceCommands — core fixed commands', () {
    test('matches the primary product phrase exactly', () {
      // This exact phrase was broken before the matcher rewrite.
      expect(
        BengaliVoiceCommands.match('সামনে কী আছে দেখো'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('সামনে কী আছে?'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('সামনে কি আছে দেখুন'),
        VoiceIntent.describeFront,
      );
      expect(BengaliVoiceCommands.match('এটা কী'), VoiceIntent.identifyObject);
      expect(
        BengaliVoiceCommands.match('এটা পড়ে শোনাও'),
        VoiceIntent.readText,
      );
      expect(
        BengaliVoiceCommands.match('লেখাটা পড়ে শোনাও'),
        VoiceIntent.readText,
      );
      expect(
        BengaliVoiceCommands.match('সামনে কী লেখা আছে'),
        VoiceIntent.readText,
      );
      expect(BengaliVoiceCommands.match('আবার বলো'), VoiceIntent.repeatLast);
      expect(BengaliVoiceCommands.match('চুপ করো'), VoiceIntent.stopSpeaking);
    });

    test('matches directional commands', () {
      expect(
        BengaliVoiceCommands.match('ডান পাশে কি আছে'),
        VoiceIntent.describeRight,
      );
      expect(
        BengaliVoiceCommands.match('বামে কী আছে'),
        VoiceIntent.describeLeft,
      );
      expect(
        BengaliVoiceCommands.match('এদিকে দেখো'),
        VoiceIntent.describeCurrent,
      );
    });

    test('allows polite prefixes and punctuation noise', () {
      expect(
        BengaliVoiceCommands.match('একটু সামনে কী আছে'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('দয়া করে এটা কী'),
        VoiceIntent.identifyObject,
      );
      expect(
        BengaliVoiceCommands.match('সহায়ক, সামনে কী আছে দেখো?'),
        VoiceIntent.describeFront,
      );
    });

    test('fuzzy recovery for recogniser noise', () {
      expect(
        BengaliVoiceCommands.match('সামনে কি আসে দেখো'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('এটা কি দেখাও'),
        VoiceIntent.identifyObject,
      );
    });

    test('media commands', () {
      expect(BengaliVoiceCommands.match('ছবি তোলো'), VoiceIntent.takePhoto);
      expect(
        BengaliVoiceCommands.match('ছবি তুলে দাও'),
        VoiceIntent.takePhoto,
      );
      expect(
        BengaliVoiceCommands.match('ভিডিও রেকর্ড করো'),
        VoiceIntent.startVideo,
      );
      expect(
        BengaliVoiceCommands.match('ভিডিও রেকর্ড শুরু করো'),
        VoiceIntent.startVideo,
      );
      expect(
        BengaliVoiceCommands.match('ভিডিও বন্ধ করো'),
        VoiceIntent.stopVideo,
      );
      expect(
        BengaliVoiceCommands.match('ভিডিও রেকর্ড বন্ধ করো'),
        VoiceIntent.stopVideo,
      );
      expect(
        BengaliVoiceCommands.match('রেকর্ডিং বন্ধ করো'),
        VoiceIntent.stopVideo,
      );
    });

    test('does not activate on unrelated conversation', () {
      expect(BengaliVoiceCommands.match('আজকে বাজারে যাব'), isNull);
      expect(BengaliVoiceCommands.match('ভাত খেয়েছ'), isNull);
      expect(BengaliVoiceCommands.match('দরজাটা বন্ধ করো'), isNull);
      expect(BengaliVoiceCommands.match('আজ আবহাওয়া খারাপ'), isNull);
    });

    test('wake word helpers', () {
      expect(BengaliVoiceCommands.containsWakeWord('রিউ সামনে কী আছে'), isTrue);
      expect(BengaliVoiceCommands.containsWakeWord('সামনে কী আছে'), isFalse);
      expect(
        BengaliVoiceCommands.stripWakeWord('রিউ সামনে কী আছে'),
        'সামনে কী আছে',
      );
      expect(BengaliVoiceCommands.stripWakeWord('রিউ'), '');
      expect(
        BengaliVoiceCommands.stripWakeWord('সামনে কী আছে'),
        isNull,
      );
    });

    test('wake-word gating', () {
      // Without a wake word and not primed → nothing matches.
      expect(
        BengaliVoiceCommands.match(
          'সামনে কী আছে',
          requireWakeWord: true,
          wakePrimed: false,
        ),
        isNull,
      );
      // With wake word → matches.
      expect(
        BengaliVoiceCommands.match(
          'রিউ সামনে কী আছে',
          requireWakeWord: true,
          wakePrimed: false,
        ),
        VoiceIntent.describeFront,
      );
      // Primed window → direct commands accepted.
      expect(
        BengaliVoiceCommands.match(
          'সামনে কী আছে',
          requireWakeWord: true,
          wakePrimed: true,
        ),
        VoiceIntent.describeFront,
      );
      // Wake word alone → no command (priming event).
      expect(
        BengaliVoiceCommands.match(
          'সহায়ক',
          requireWakeWord: true,
          wakePrimed: false,
        ),
        isNull,
      );
    });
  });

  group('BengaliVoiceCommands — real-world recognition variants', () {
    test('the six product commands with speech noise', () {
      // 1. "সামনে কী আছে দেখো" (scene description) — reported broken.
      expect(
        BengaliVoiceCommands.match('সামনে কী আছে দেখো'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('সামনে কি আছে দেখো'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('সামনে কী আছে দেখো।'),
        VoiceIntent.describeFront,
      );
      // 2. "এটা পড়ে শোনাও" (OCR read aloud).
      expect(
        BengaliVoiceCommands.match('এটা পড়ে শোনাও'),
        VoiceIntent.readText,
      );
      expect(
        BengaliVoiceCommands.match('এইটা পড়ে শোনাও'),
        VoiceIntent.readText,
      );
      expect(
        BengaliVoiceCommands.match('এটা পড়ে শোনাও দয়া করে'.replaceAll('দয়া করে ', '')),
        VoiceIntent.readText,
      );
      // 3. "সামনে কী লেখা আছে" (front text).
      expect(
        BengaliVoiceCommands.match('সামনে কি লেখা আছে'),
        VoiceIntent.readText,
      );
      // 4. "ছবি তোলো" (take photo) + common mis-hearings.
      expect(BengaliVoiceCommands.match('ছবি তোলো'), VoiceIntent.takePhoto);
      expect(BengaliVoiceCommands.match('ছবি তোলে'), VoiceIntent.takePhoto);
      expect(BengaliVoiceCommands.match('ছবি তুলো'), VoiceIntent.takePhoto);
      expect(
        BengaliVoiceCommands.match('একটা ছবি তোলো'),
        VoiceIntent.takePhoto,
      );
      // 5. Video start/stop in one breath with wake word.
      expect(
        BengaliVoiceCommands.match('রিউ ভিডিও রেকর্ড করো'),
        VoiceIntent.startVideo,
      );
      expect(
        BengaliVoiceCommands.match('ভিডিও শেষ করো'),
        VoiceIntent.stopVideo,
      );
      // 6. Repeat / silence / help / new chat.
      expect(BengaliVoiceCommands.match('আরেকবার বলো'), VoiceIntent.repeatLast);
      expect(BengaliVoiceCommands.match('থামো'), VoiceIntent.stopSpeaking);
      expect(BengaliVoiceCommands.match('কমান্ড বলো'), VoiceIntent.help);
      expect(BengaliVoiceCommands.match('নতুন আলাপ'), VoiceIntent.newChat);
    });

    test('trailing verbs and politeness do not break matching', () {
      expect(
        BengaliVoiceCommands.match('এটা কী দেখো'),
        VoiceIntent.identifyObject,
      );
      expect(
        BengaliVoiceCommands.match('সামনে কী আছে বলো'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('লেখাটা পড়ো'),
        VoiceIntent.readText,
      );
      expect(
        BengaliVoiceCommands.match('লেখা দেখাও'),
        VoiceIntent.readText,
      );
    });

    test('near-miss commands stay distinct', () {
      // "ভিডিও রেকর্ড" alone still starts; "বন্ধ" variants stop.
      expect(
        BengaliVoiceCommands.match('ভিডিও রেকর্ড'),
        VoiceIntent.startVideo,
      );
      // Plain "বন্ধ করো" (e.g. fan off) must NOT stop the video.
      expect(BengaliVoiceCommands.match('ফ্যান বন্ধ করো'), isNull);
      // "কী লেখা" fragment must not fire on its own conversation.
      expect(BengaliVoiceCommands.match('তোমার নামে কী লেখা'), isNull);
    });
  });
}
