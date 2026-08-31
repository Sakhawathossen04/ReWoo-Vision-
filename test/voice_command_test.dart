import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_chat/chat_page/voice/bengali_voice_commands.dart';
import 'package:gemma_chat/chat_page/voice/voice_intent.dart';

void main() {
  group('BengaliVoiceCommands', () {
    test('matches core fixed commands', () {
      expect(
        BengaliVoiceCommands.match('সামনে কী আছে?'),
        VoiceIntent.describeFront,
      );
      expect(BengaliVoiceCommands.match('এটা কী'), VoiceIntent.identifyObject);
      expect(
        BengaliVoiceCommands.match('লেখাটা পড়ে শোনাও'),
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
    });

    test('allows a small polite prefix', () {
      expect(
        BengaliVoiceCommands.match('একটু সামনে কী আছে'),
        VoiceIntent.describeFront,
      );
      expect(
        BengaliVoiceCommands.match('দয়া করে এটা কী'),
        VoiceIntent.identifyObject,
      );
    });

    test('does not activate on unrelated conversation', () {
      expect(BengaliVoiceCommands.match('আজকে বাজারে যাব'), isNull);
      expect(BengaliVoiceCommands.match('ভাত খেয়েছ'), isNull);
      expect(BengaliVoiceCommands.match('দরজাটা বন্ধ করো'), isNull);
    });
  });
}
