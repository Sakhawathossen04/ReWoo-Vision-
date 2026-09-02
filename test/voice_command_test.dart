import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_chat/chat_page/voice/bengali_voice_commands.dart';
import 'package:gemma_chat/chat_page/voice/voice_intent.dart';

void main() {
  group(
    'BengaliVoiceCommands.matchTriggerCommand — valid triggers',
    () {
      test('matches the five primary trigger commands', () {
        expect(
          BengaliVoiceCommands.matchTriggerCommand(
            'সামনে কী আছে দেখো',
          ),
          VoiceIntent.describeFront,
        );

        expect(
          BengaliVoiceCommands.matchTriggerCommand(
            'এটা কী',
          ),
          VoiceIntent.identifyObject,
        );

        expect(
          BengaliVoiceCommands.matchTriggerCommand(
            'লেখাটা পড়ে শোনাও',
          ),
          VoiceIntent.readText,
        );

        expect(
          BengaliVoiceCommands.matchTriggerCommand(
            'ডান পাশে কী আছে',
          ),
          VoiceIntent.describeRight,
        );

        expect(
          BengaliVoiceCommands.matchTriggerCommand(
            'বাম পাশে কী আছে',
          ),
          VoiceIntent.describeLeft,
        );
      });

      test(
        'accepts configured recognition aliases',
        () {
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'সামনে কি আছে দেখো',
            ),
            VoiceIntent.describeFront,
          );

          // Short front-command alias.
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'সামনে দেখো',
            ),
            VoiceIntent.describeFront,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'এটা কি',
            ),
            VoiceIntent.identifyObject,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'লেখা পড়ে শোনাও',
            ),
            VoiceIntent.readText,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'ডান পাশে কি আছে',
            ),
            VoiceIntent.describeRight,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'বাম পাশে কি আছে',
            ),
            VoiceIntent.describeLeft,
          );
        },
      );

      test(
        'normalizes harmless punctuation and whitespace',
        () {
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              '  সামনে কী আছে দেখো?  ',
            ),
            VoiceIntent.describeFront,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              ' সামনে দেখো! ',
            ),
            VoiceIntent.describeFront,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'এটা কী!',
            ),
            VoiceIntent.identifyObject,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'ডান পাশে   কী আছে।',
            ),
            VoiceIntent.describeRight,
          );
        },
      );

      test(
        'isTriggerCommand agrees with strict matcher',
        () {
          expect(
            BengaliVoiceCommands.isTriggerCommand(
              'সামনে কী আছে দেখো',
            ),
            isTrue,
          );

          expect(
            BengaliVoiceCommands.isTriggerCommand(
              'সামনে দেখো',
            ),
            isTrue,
          );

          expect(
            BengaliVoiceCommands.isTriggerCommand(
              'ছবি তোলো',
            ),
            isFalse,
          );
        },
      );
    },
  );

  group(
    'BengaliVoiceCommands.matchTriggerCommand — rejects old commands',
    () {
      test(
        'old broad commands do not wake the assistant',
        () {
          final oldCommands = <String>[
            'সামনে কী আছে',
            'সামনে কি আছে',
            'এটা পড়ে শোনাও',
            'এইটা পড়ে শোনাও',
            'সামনে কী লেখা আছে',
            'সামনে কি লেখা আছে',
            'এদিকে দেখো',
            'ডানে কী আছে',
            'বামে কী আছে',
            'ছবি তোলো',
            'ছবি তুলে দাও',
            'ভিডিও রেকর্ড করো',
            'ভিডিও বন্ধ করো',
            'আবার বলো',
            'চুপ করো',
            'থামো',
            'কমান্ড বলো',
            'নতুন আলাপ',
          ];

          for (final phrase in oldCommands) {
            expect(
              BengaliVoiceCommands.matchTriggerCommand(
                phrase,
              ),
              isNull,
              reason:
                  '"$phrase" must not activate strict trigger mode',
            );
          }
        },
      );
    },
  );

  group(
    'BengaliVoiceCommands.matchTriggerCommand — rejects wake words',
    () {
      test(
        'wake word alone is not a trigger',
        () {
          final wakeWords = <String>[
            'রিউ',
            'রিউ ভিশন',
            'সহায়ক',
            'হে সহায়ক',
            'অ্যাসিস্ট্যান্ট',
            'hey assistant',
          ];

          for (final phrase in wakeWords) {
            expect(
              BengaliVoiceCommands.matchTriggerCommand(
                phrase,
              ),
              isNull,
            );
          }
        },
      );

      test(
        'wake word plus valid command is still rejected',
        () {
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'রিউ সামনে কী আছে দেখো',
            ),
            isNull,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'রিউ সামনে দেখো',
            ),
            isNull,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'সহায়ক এটা কী',
            ),
            isNull,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'রিউ ভিশন লেখাটা পড়ে শোনাও',
            ),
            isNull,
          );
        },
      );
    },
  );

  group(
    'BengaliVoiceCommands.matchTriggerCommand — rejects normal conversation',
    () {
      test(
        'unrelated speech returns null',
        () {
          final conversation = <String>[
            'আজকে বাজারে যাব',
            'ভাত খেয়েছ',
            'দরজাটা বন্ধ করো',
            'আজ আবহাওয়া খুব সুন্দর',
            'আমার সামনে অনেক মানুষ দাঁড়িয়ে আছে',
            'এটা খুব সুন্দর',
            'ডান পাশে আমার বন্ধু আছে',
            'বাম পাশে একটা দোকান আছে',
          ];

          for (final phrase in conversation) {
            expect(
              BengaliVoiceCommands.matchTriggerCommand(
                phrase,
              ),
              isNull,
            );
          }
        },
      );
    },
  );

  group(
    'BengaliVoiceCommands.matchTriggerCommand — rejects fuzzy phrases',
    () {
      test(
        'recognizer near-misses are not accepted',
        () {
          final fuzzyPhrases = <String>[
            'সামনে কি আসে দেখো',
            'সামনে কী আছে বলো',
            'সামনে কি আছে দেখাও',
            'এটা কি দেখাও',
            'এটা কী দেখো',
            'লেখাটা পড়ে দাও',
            'ডান দিকে কী আছে',
            'বাম দিকে কী আছে',
          ];

          for (final phrase in fuzzyPhrases) {
            expect(
              BengaliVoiceCommands.matchTriggerCommand(
                phrase,
              ),
              isNull,
              reason:
                  '"$phrase" must not fuzzy-match a direct trigger',
            );
          }
        },
      );
    },
  );

  group(
    'BengaliVoiceCommands.matchTriggerCommand — partial sentence safety',
    () {
      test(
        'valid trigger embedded in a longer sentence returns null',
        () {
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'সামনে কী আছে দেখো তারপর আমাকে বলো',
            ),
            isNull,
          );

          // Short alias must still remain exact-only.
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'সামনে দেখো তারপর আমাকে বলো',
            ),
            isNull,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'লেখাটা পড়ে শোনাও তারপর বন্ধ করো',
            ),
            isNull,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'ডান পাশে কী আছে আমি জানতে চাই',
            ),
            isNull,
          );

          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'বাম পাশে কী আছে সেটা বলো',
            ),
            isNull,
          );
        },
      );

      test(
        '"এটা কী সুন্দর জিনিস" must NOT trigger identifyObject',
        () {
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'এটা কী সুন্দর জিনিস',
            ),
            isNull,
          );
        },
      );

      test(
        '"এটা কি সুন্দর জিনিস" must also remain null',
        () {
          expect(
            BengaliVoiceCommands.matchTriggerCommand(
              'এটা কি সুন্দর জিনিস',
            ),
            isNull,
          );
        },
      );
    },
  );

  group(
    'BengaliVoiceCommands trigger configuration',
    () {
      test(
        'contains exactly five trigger intents',
        () {
          expect(
            BengaliVoiceCommands.triggerCommands.length,
            5,
          );

          expect(
            BengaliVoiceCommands.triggerCommands.keys.toSet(),
            equals({
              VoiceIntent.describeFront,
              VoiceIntent.identifyObject,
              VoiceIntent.readText,
              VoiceIntent.describeRight,
              VoiceIntent.describeLeft,
            }),
          );

          // Alias is part of the FRONT family, not a sixth intent.
          expect(
            BengaliVoiceCommands.triggerCommands[
              VoiceIntent.describeFront
            ],
            contains(
              'সামনে দেখো',
            ),
          );
        },
      );

      test(
        'help list exposes exactly five primary phrases',
        () {
          expect(
            BengaliVoiceCommands.triggerHelpCommands,
            equals([
              'সামনে কী আছে দেখো',
              'এটা কী',
              'লেখাটা পড়ে শোনাও',
              'ডান পাশে কী আছে',
              'বাম পাশে কী আছে',
            ]),
          );
        },
      );
    },
  );
}
