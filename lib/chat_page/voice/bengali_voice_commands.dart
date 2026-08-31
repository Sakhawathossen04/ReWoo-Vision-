import 'voice_intent.dart';

/// Deterministic Bengali command matcher.
///
/// This deliberately avoids asking the generative model to classify control
/// commands. A small, fixed command vocabulary is easier to test and safer for
/// an accessibility workflow.
class BengaliVoiceCommands {
  BengaliVoiceCommands._();

  static const Map<VoiceIntent, List<String>> _phrases = {
    VoiceIntent.describeFront: [
      'সামনে কী আছে',
      'সামনে কি আছে',
      'সামনে কী দেখছ',
      'সামনে কি দেখছ',
      'সামনে কী দেখছো',
      'সামনে কি দেখছো',
      'সামনেরটা বলো',
    ],
    VoiceIntent.describeCurrent: [
      'এদিকে দেখো',
      'এইদিকে দেখো',
      'এখানে কী আছে',
      'এখানে কি আছে',
    ],
    VoiceIntent.describeRight: [
      'ডান পাশে কী আছে',
      'ডান পাশে কি আছে',
      'ডানে কী আছে',
      'ডানে কি আছে',
    ],
    VoiceIntent.describeLeft: [
      'বাম পাশে কী আছে',
      'বাম পাশে কি আছে',
      'বামে কী আছে',
      'বামে কি আছে',
    ],
    VoiceIntent.identifyObject: [
      'এটা কী',
      'এটা কি',
      'এইটা কী',
      'এইটা কি',
      'জিনিসটা কী',
      'জিনিসটা কি',
    ],
    VoiceIntent.readText: [
      'লেখাটা পড়ে শোনাও',
      'লেখাটা পড়ে শোনাও',
      'লেখা পড়ে শোনাও',
      'লেখা পড়ে শোনাও',
      'এটা পড়ে শোনাও',
      'এটা পড়ে শোনাও',
      'লেখাটা পড়ো',
      'লেখাটা পড়ো',
    ],
    VoiceIntent.repeatLast: [
      'আবার বলো',
      'আরেকবার বলো',
      'পুনরায় বলো',
      'পুনরায় বলো',
    ],
    VoiceIntent.stopSpeaking: [
      'চুপ করো',
      'থামো',
      'বলা বন্ধ করো',
      'কথা বন্ধ করো',
    ],
    VoiceIntent.help: [
      'কী কী বলতে পারি',
      'কি কি বলতে পারি',
      'কমান্ড বলো',
      'কমান্ডগুলো বলো',
      'সাহায্য করো',
    ],
    VoiceIntent.newChat: [
      'নতুন আলাপ',
      'নতুন চ্যাট',
      'নতুন কথা শুরু করো',
    ],
  };

  static VoiceIntent? match(String rawText) {
    final normalized = _normalize(rawText);
    if (normalized.isEmpty) return null;

    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final normalizedPhrase = _normalize(phrase);
        if (_matchesCommand(normalized, normalizedPhrase)) {
          return entry.key;
        }
      }
    }
    return null;
  }

  static bool _matchesCommand(String heard, String command) {
    if (heard == command) return true;

    // Permit a very small set of polite prefixes/suffixes without turning this
    // into open-ended language understanding. This keeps accidental triggers
    // lower than broad substring matching.
    const prefixes = [
      'একটু ',
      'দয়া করে ',
      'দয়া করে ',
      'রিউ ',
      'রিউ ভিশন ',
      'রিউউ ',
      'রিউউ ভিশন ',
      'সহায়ক ',
      'সহায়ক ',
    ];
    const suffixes = [' প্লিজ', ' একটু'];

    for (final prefix in prefixes) {
      if (heard == '$prefix$command') return true;
    }
    for (final suffix in suffixes) {
      if (heard == '$command$suffix') return true;
    }

    return false;
  }

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll('\u200c', '')
        .replaceAll('\u200d', '')
        .replaceAll(RegExp(r'[\?\!\.,;:।]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<String> get primaryHelpCommands => const [
    'সামনে কী আছে',
    'এটা কী',
    'এদিকে দেখো',
    'ডান পাশে কী আছে',
    'বাম পাশে কী আছে',
    'লেখাটা পড়ে শোনাও',
    'আবার বলো',
    'চুপ করো',
    'নতুন আলাপ',
  ];
}
