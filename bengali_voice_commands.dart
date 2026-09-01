import 'voice_intent.dart';

/// Deterministic Bengali command matcher.
///
/// This deliberately avoids asking the generative model to classify control
/// commands. A small, fixed command vocabulary is easier to test and safer
/// for an accessibility workflow.
///
/// Matching strategy (Priority 5):
///  1. Exact equality after normalisation.
///  2. Word-boundary containment, so "সামনে কী আছে দেখো" matches the
///     "সামনে কী আছে" intent — this exact phrase was reported broken.
///  3. Polite prefix / trailing-verb tolerance (দেখো / দেখুন / বলো / করো…).
///  4. A conservative whole-utterance fuzzy pass (Levenshtein ≥ 0.85) that
///     recovers speech-recogniser noise like "সামনে কি আসে" without firing
///     on unrelated conversation.
///  5. Optional wake-word gating (Priority 4): in wake-word mode only
///     utterances containing a wake word (রিউ / সহায়ক / hey assistant…)
///     are considered.
class BengaliVoiceCommands {
  BengaliVoiceCommands._();

  /// Order matters: more specific intents must appear before any intent
  /// whose phrase is a substring of the more specific one.
  static const Map<VoiceIntent, List<String>> _phrases = {
    VoiceIntent.readText: [
      'সামনে কী লেখা আছে',
      'সামনে কি লেখা আছে',
      'সামনে কী লেখা',
      'সামনের লেখা পড়ো',
      'সামনের লেখা পড়ে শোনাও',
      'লেখাটা পড়ে শোনাও',
      'লেখাটা পড়ো',
      'লেখা পড়ে শোনাও',
      'এটা পড়ে শোনাও',
      'এইটা পড়ে শোনাও',
      'এটা কী লেখা',
      'এটাতে কী লেখা',
      'এটাতে কি লেখা',
      'এটায় কী লেখা',
      'কী লেখা আছে',
      'কি লেখা আছে',
      'লেখাটা কী বলে',
      'লেখাটা কি বলে',
      'লেখা দেখাও',
      'লেখা পড়ো',
      'লেখাগুলো পড়ো',
    ],
    VoiceIntent.stopVideo: [
      'ভিডিও রেকর্ড বন্ধ করো',
      'ভিডিও রেকর্ডিং বন্ধ করো',
      'ভিডিও বন্ধ করো',
      'ভিডিওটা বন্ধ করো',
      'রেকর্ডিং বন্ধ করো',
      'রেকর্ড বন্ধ করো',
      'ভিডিও শেষ করো',
      'ভিডিও সেভ করো',
      'ভিডিও থামাও',
    ],
    VoiceIntent.startVideo: [
      'ভিডিও রেকর্ড করো',
      'ভিডিও রেকর্ড শুরু করো',
      'ভিডিও রেকর্ডিং শুরু করো',
      'ভিডিও শুরু করো',
      'রেকর্ডিং শুরু করো',
      'রেকর্ড শুরু করো',
      'ভিডিও রেকর্ড',
      'ভিডিও নাও',
      'ভিডিও চালু করো',
    ],
    VoiceIntent.takePhoto: [
      'ছবি তোলো',
      'ছবি তোলে',
      'ছবি তুলো',
      'ছবি তুলে দাও',
      'ছবি তুলে দেখাও',
      'ছবি নাও',
      'ছবি নিন',
      'একটা ছবি তোলো',
      'একটি ছবি তোলো',
      'একটা ছবি নাও',
      'একটি ছবি নিন',
      'ছবি খুলো',
      'ফটো তোলো',
      'ফটো নাও',
      'একটা ফটো তোলো',
      'ছবিটা তোলো',
      'ছবিটা নাও',
    ],
    VoiceIntent.describeFront: [
      'সামনে কী আছে',
      'সামনে কি আছে',
      'সামনে কী দেখছ',
      'সামনে কি দেখছ',
      'সামনে কী দেখছো',
      'সামনে কি দেখছো',
      'সামনেরটা বলো',
      'সামনের দৃশ্য বলো',
      'সামনে কী আছে দেখো',
      'সামনে কি আছে দেখো',
      'সামনে কী আছে বলো',
      'সামনে কি আছে বলো',
      'সামনে দেখো',
      'সামনেটা দেখো',
      'সামনে কী দেখা যাচ্ছে',
      'সামনে কি দেখা যাচ্ছে',
    ],
    VoiceIntent.describeCurrent: [
      'এদিকে দেখো',
      'এইদিকে দেখো',
      'এখানে কী আছে',
      'এখানে কি আছে',
      'চারপাশে কী আছে',
      'চারপাশে কি আছে',
      'চারদিকে কী আছে',
      'চারদিকে কি আছে',
      'চারপাশটা দেখো',
      'আশেপাশে কী আছে',
      'কী দেখছো',
      'কি দেখছো',
      'কী দেখছ',
      'কি দেখছ',
    ],
    VoiceIntent.describeRight: [
      'ডান পাশে কী আছে',
      'ডান পাশে কি আছে',
      'ডানে কী আছে',
      'ডানে কি আছে',
      'ডান দিকে কী আছে',
      'ডান দিকে কি আছে',
      'ডান দিকটা দেখো',
      'ডান পাশটা দেখো',
    ],
    VoiceIntent.describeLeft: [
      'বাম পাশে কী আছে',
      'বাম পাশে কি আছে',
      'বামে কী আছে',
      'বামে কি আছে',
      'বাম দিকে কী আছে',
      'বাম দিকে কি আছে',
      'বাম দিকটা দেখো',
      'বাম পাশটা দেখো',
    ],
    VoiceIntent.identifyObject: [
      'এটা কী',
      'এটা কি',
      'এইটা কী',
      'এইটা কি',
      'এইটা কিসে',
      'জিনিসটা কী',
      'জিনিসটা কি',
      'ওটা কী',
      'ওটা কি',
      'এটা কিসে',
      'এটা কি জিনিস',
      'এইটা কি জিনিস',
      'এটা চেনো',
      'এটা চিনো',
    ],
    VoiceIntent.repeatLast: [
      'আবার বলো',
      'আরেকবার বলো',
      'পুনরায় বলো',
      'পুনরায় বলো',
      'আবার শোনাও',
    ],
    VoiceIntent.stopSpeaking: [
      'চুপ করো',
      'চুপ',
      'থামো',
      'থাম',
      'বলা বন্ধ করো',
      'কথা বন্ধ করো',
      'ভয়েস বন্ধ করো',
      'আওয়াজ বন্ধ করো',
      // NOTE: plain 'বন্ধ করো' is intentionally NOT here — "ফ্যান বন্ধ করো"
      // (turn the fan off) must not silence the assistant. Stop commands
      // always carry a speech-related noun (বলা/কথা/ভয়েস/আওয়াজ).
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

  /// Wake words (Priority 4). A wake word activates the assistant the same
  /// way "Hey Assistant" activates a phone assistant.
  static const List<String> wakeWords = [
    'রিউ',
    'রিউ ভিশন',
    'রিউউ ভিশন',
    'রিউ ভিশন',
    'সহায়ক',
    'সহায়ক',
    'হে সহায়ক',
    'হেলো সহায়ক',
    'অ্যাসিস্ট্যান্ট',
    'hey assistant',
    'hi assistant',
  ];

  /// Polite prefixes tolerated before any command.
  static const List<String> _prefixes = [
    'একটু ',
    'দয়া করে ',
    'রিউ ',
    'রিউ ভিশন ',
    'রিউউ ',
    'রিউউ ভিশন ',
    'সহায়ক ',
    'হে সহায়ক ',
    'আরে ',
  ];

  /// Trailing verbs tolerated after any command ("…দেখো", "…বলো").
  static const List<String> _trailingVerbs = [
    'দেখো',
    'দেখুন',
    'দেখাও',
    'বলো',
    'বলুন',
    'শোনাও',
    'শোনান',
    'পড়ো',
    'পড়ুন',
    'করো',
    'করুন',
    'করেন',
    'দাও',
    'দিন',
    'নাও',
    'নিন',
    'তো',
  ];

  /// Returns the matched intent, or null when nothing matches.
  ///
  /// [requireWakeWord] enables wake-word gating. [wakePrimed] is true when a
  /// wake word was heard moments ago — commands are then accepted directly.
  static VoiceIntent? match(
    String rawText, {
    bool requireWakeWord = false,
    bool wakePrimed = true,
  }) {
    final normalized = _normalize(rawText);
    if (normalized.isEmpty) return null;

    // Wake-word gating: without a wake word (or an active prime window)
    // nothing is accepted.
    if (requireWakeWord && !wakePrimed) {
      final stripped = stripWakeWord(normalized);
      if (stripped == null) return null;
      if (stripped.isEmpty) return null; // Wake word alone → priming event.
      return _matchText(stripped);
    }

    return _matchText(normalized);
  }

  static VoiceIntent? _matchText(String normalized) {
    final direct = _exactOrContainment(normalized);
    if (direct != null) return direct;

    final fuzzy = _fuzzyMatch(normalized);
    if (fuzzy != null) return fuzzy;
    return null;
  }

  static VoiceIntent? _exactOrContainment(String heard) {
    // Pass 1: exact and prefix/suffix variants.
    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(phrase);
        if (heard == command) return entry.key;
        if (_matchesWithPoliteness(heard, command)) return entry.key;
      }
    }

    // Pass 2: word-boundary containment (handles extra words around the
    // command, e.g. "সামনে কী আছে দেখো" for "সামনে কী আছে").
    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(phrase);
        if (_containsAsWords(heard, command)) return entry.key;
      }
    }

    // Pass 3: trailing-verb tolerance.
    final stripped = _stripTrailingVerbs(heard);
    if (stripped != heard) {
      for (final entry in _phrases.entries) {
        for (final phrase in entry.value) {
          final command = _normalize(phrase);
          if (stripped == command) return entry.key;
          if (_matchesWithPoliteness(stripped, command)) return entry.key;
          if (_containsAsWords(stripped, command)) return entry.key;
        }
      }
    }
    return null;
  }

  static bool _matchesWithPoliteness(String heard, String command) {
    if (heard == command) return true;

    for (final prefix in _prefixes) {
      if (heard == '$prefix$command') return true;
      final withoutPrefix = heard.startsWith(prefix) ? heard.substring(prefix.length) : null;
      if (withoutPrefix != null && withoutPrefix == command) return true;
    }

    for (final suffix in const [' প্লিজ', ' একটু']) {
      if (heard == '$command$suffix') return true;
    }
    return false;
  }

  /// True when [command] appears in [heard] with space (or string edge)
  /// boundaries on both sides — prevents "ভাত খেয়েছ" style false hits and
  /// matches inside longer utterances.
  static bool _containsAsWords(String heard, String command) {
    if (command.isEmpty) return false;
    int index = heard.indexOf(command);
    while (index != -1) {
      final beforeOk = index == 0 || heard[index - 1] == ' ';
      final end = index + command.length;
      final afterOk = end == heard.length || heard[end] == ' ';
      if (beforeOk && afterOk) return true;
      index = heard.indexOf(command, index + 1);
    }
    return false;
  }

  static String _stripTrailingVerbs(String heard) {
    var text = heard.trim();
    var changed = true;
    int strips = 0;
    while (changed && strips < 3) {
      changed = false;
      for (final verb in _trailingVerbs) {
        if (text == verb) return '';
        if (text.endsWith(' $verb')) {
          text = text.substring(0, text.length - verb.length - 1).trim();
          changed = true;
          strips++;
          break;
        }
      }
    }
    return text;
  }

  /// Conservative whole-utterance fuzzy match. Only fires when the lengths
  /// are close and similarity is high, so ordinary conversation never
  /// triggers a command.
  static VoiceIntent? _fuzzyMatch(String heard) {
    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(phrase);
        if ((heard.length - command.length).abs() > 3) continue;
        if (_similarity(heard, command) >= 0.85) {
          return entry.key;
        }
      }
    }
    return null;
  }

  static double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final distance = _levenshtein(a, b);
    return 1.0 - distance / (a.length > b.length ? a.length : b.length);
  }

  static int _levenshtein(String a, String b) {
    final m = a.length, n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;
    final prev = List<int>.generate(n + 1, (i) => i);
    final curr = List<int>.filled(n + 1, 0);
    for (int i = 1; i <= m; i++) {
      curr[0] = i;
      for (int j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = [
          prev[j] + 1,
          curr[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      for (int j = 0; j <= n; j++) {
        prev[j] = curr[j];
      }
    }
    return prev[n];
  }

  /// Normalises raw speech: lowercase, strips zero-width chars, punctuation
  /// and repeated spaces. Also unifies the most common speech-recogniser
  /// spelling variants (কি/কী) so "সামনে কি আছে" and "সামনে কী আছে" are the
  /// same command to the matcher — a frequent source of missed commands.
  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll('\u200c', '')
        .replaceAll('\u200d', '')
        .replaceAll('কি', 'কী')
        .replaceAll(RegExp(r'[\?\!\.,;:।]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Removes the first wake word from a normalised utterance.
  /// Returns the remainder, or null when no wake word is present.
  /// An empty string means "only the wake word was spoken".
  static String? stripWakeWord(String normalizedHeard) {
    final heard = _normalize(normalizedHeard);
    if (heard.isEmpty) return null;

    // Longest wake words first so "রিউ ভিশন" wins over "রিউ".
    final words = [...wakeWords]..sort((a, b) => b.length.compareTo(a.length));
    for (final wake in words) {
      final w = _normalize(wake);
      if (w.isEmpty) continue;
      if (heard == w) return '';
      if (heard.startsWith('$w ')) return heard.substring(w.length + 1).trim();
      if (heard.endsWith(' $w')) return heard.substring(0, heard.length - w.length - 1).trim();
    }
    return null;
  }

  static bool containsWakeWord(String rawText) {
    return stripWakeWord(rawText) != null;
  }

  static List<String> get primaryHelpCommands => const [
    'সামনে কী আছে',
    'এটা কী',
    'এদিকে দেখো',
    'ডান পাশে কী আছে',
    'বাম পাশে কী আছে',
    'লেখাটা পড়ে শোনাও',
    'ছবি তোলো',
    'ভিডিও রেকর্ড করো',
    'ভিডিও বন্ধ করো',
    'আবার বলো',
    'চুপ করো',
    'নতুন আলাপ',
  ];
}
