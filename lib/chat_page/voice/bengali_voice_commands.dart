import 'voice_intent.dart';

/// Deterministic Bengali command matcher.
///
/// There are two different matching layers in this class:
///
/// 1. [matchTriggerCommand]
///    Strict trigger matcher for the 5 commands that can activate the
///    assistant directly.
///
/// 2. [match]
///    Existing general-purpose command matcher used by the rest of the app.
///
/// IMPORTANT:
/// The five trigger commands themselves work as the wake phrase.
/// The user does NOT need to say "Hey ReWoo" first.
///
/// Example:
///   User: "সামনে কী আছে দেখো"
///   -> Assistant wakes
///   -> describeFront task runs
///
/// Normal conversation does not activate the assistant unless it exactly
/// matches one of the configured trigger commands.
class BengaliVoiceCommands {
  BengaliVoiceCommands._();

  // ===========================================================================
  // DIRECT WAKE + TASK TRIGGERS
  // ===========================================================================

  /// These are the ONLY 5 commands that should directly activate
  /// the assistant from trigger-listening mode.
  ///
  /// Bengali ASR frequently alternates between "কী" and "কি", therefore
  /// both common forms are accepted where appropriate.
  ///
  /// Keep this list intentionally small and strict to prevent accidental
  /// activation from normal conversation.
  static const Map<VoiceIntent, List<String>> triggerCommands = {
    VoiceIntent.describeFront: [
      'সামনে কী আছে দেখো',
      'সামনে কি আছে দেখো',
    ],

    VoiceIntent.identifyObject: [
      'এটা কী',
      'এটা কি',
    ],

    VoiceIntent.readText: [
      'লেখাটা পড়ে শোনাও',
      'লেখা পড়ে শোনাও',
    ],

    VoiceIntent.describeRight: [
      'ডান পাশে কী আছে',
      'ডান পাশে কি আছে',
    ],

    VoiceIntent.describeLeft: [
      'বাম পাশে কী আছে',
      'বাম পাশে কি আছে',
    ],
  };

  /// Matches ONLY one of the five direct trigger commands.
  ///
  /// This intentionally uses exact matching after normalisation.
  ///
  /// It does NOT:
  /// - fuzzy match
  /// - match partial sentences
  /// - accept unrelated commands
  /// - require "Hey ReWoo"
  ///
  /// Examples:
  ///
  /// "সামনে কী আছে দেখো"
  /// -> VoiceIntent.describeFront
  ///
  /// "আজকে সামনে অনেক মানুষ আছে"
  /// -> null
  ///
  /// "ছবি তোলো"
  /// -> null
  ///
  /// "রিউ সামনে কী আছে দেখো"
  /// -> null
  ///
  /// This strict behaviour is intentional for wake-trigger safety.
  static VoiceIntent? matchTriggerCommand(String rawText) {
    final heard = _normalize(rawText);

    if (heard.isEmpty) {
      return null;
    }

    for (final entry in triggerCommands.entries) {
      for (final phrase in entry.value) {
        if (heard == _normalize(phrase)) {
          return entry.key;
        }
      }
    }

    return null;
  }

  /// Convenience helper when only a true/false trigger result is needed.
  static bool isTriggerCommand(String rawText) {
    return matchTriggerCommand(rawText) != null;
  }

  /// Human-readable primary version of the five trigger commands.
  ///
  /// Useful for:
  /// - onboarding
  /// - help UI
  /// - spoken assistant instructions
  /// - debug screen
  static List<String> get triggerHelpCommands =>
      triggerCommands.values
          .map((phrases) => phrases.first)
          .toList(growable: false);

  // ===========================================================================
  // EXISTING GENERAL COMMAND MATCHER
  // ===========================================================================

  /// Order matters: more specific intents must appear before any intent
  /// whose phrase is a substring of the more specific one.
  ///
  /// This list is intentionally broader than [triggerCommands].
  ///
  /// These commands can still be useful internally after the assistant
  /// has already been activated, but they should NOT be used to wake the
  /// assistant from trigger-listening mode.
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
      'কী লেখা আছে',
      'কি লেখা আছে',
      'লেখাটা কী বলে',
      'লেখা দেখাও',
    ],

    VoiceIntent.stopVideo: [
      'ভিডিও রেকর্ড বন্ধ করো',
      'ভিডিও রেকর্ডিং বন্ধ করো',
      'ভিডিও বন্ধ করো',
      'রেকর্ডিং বন্ধ করো',
      'ভিডিও শেষ করো',
      'ভিডিও সেভ করো',
    ],

    VoiceIntent.startVideo: [
      'ভিডিও রেকর্ড করো',
      'ভিডিও রেকর্ড শুরু করো',
      'ভিডিও রেকর্ডিং শুরু করো',
      'ভিডিও শুরু করো',
      'রেকর্ডিং শুরু করো',
      'ভিডিও রেকর্ড',
    ],

    VoiceIntent.takePhoto: [
      'ছবি তোলো',
      'ছবি তোলে',
      'ছবি তুলো',
      'ছবি তুলে দাও',
      'ছবি তুলে দেখাও',
      'ছবি নাও',
      'একটা ছবি তোলো',
      'একটি ছবি তোলো',
      'ছবি খুলো',
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
    ],

    VoiceIntent.describeCurrent: [
      'এদিকে দেখো',
      'এইদিকে দেখো',
      'এখানে কী আছে',
      'এখানে কি আছে',
      'চারপাশে কী আছে',
    ],

    VoiceIntent.describeRight: [
      'ডান পাশে কী আছে',
      'ডান পাশে কি আছে',
      'ডানে কী আছে',
      'ডানে কি আছে',
      'ডান দিকে কী আছে',
    ],

    VoiceIntent.describeLeft: [
      'বাম পাশে কী আছে',
      'বাম পাশে কি আছে',
      'বামে কী আছে',
      'বামে কি আছে',
      'বাম দিকে কী আছে',
    ],

    VoiceIntent.identifyObject: [
      'এটা কী',
      'এটা কি',
      'এইটা কী',
      'এইটা কি',
      'জিনিসটা কী',
      'জিনিসটা কি',
      'ওটা কী',
      'ওটা কি',
    ],

    VoiceIntent.repeatLast: [
      'আবার বলো',
      'আরেকবার বলো',
      'পুনরায় বলো',
      'আবার শোনাও',
    ],

    VoiceIntent.stopSpeaking: [
      'চুপ করো',
      'চুপ',
      'থামো',
      'বলা বন্ধ করো',
      'কথা বন্ধ করো',
      'ভয়েস বন্ধ করো',
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

  // ===========================================================================
  // OPTIONAL LEGACY WAKE WORD SUPPORT
  // ===========================================================================

  /// Existing wake-word vocabulary.
  ///
  /// Kept for backward compatibility because other parts of the application
  /// may still reference these methods.
  ///
  /// The new five-command trigger flow does NOT need these wake words.
  static const List<String> wakeWords = [
    'রিউ',
    'রিউ ভিশন',
    'রিউউ ভিশন',
    'সহায়ক',
    'হে সহায়ক',
    'হেলো সহায়ক',
    'অ্যাসিস্ট্যান্ট',
    'hey assistant',
    'hi assistant',
  ];

  /// Polite prefixes tolerated by the general command matcher.
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

  /// Trailing verbs tolerated by the general matcher.
  static const List<String> _trailingVerbs = [
    'দেখো',
    'দেখুন',
    'দেখাও',
    'বলো',
    'বলুন',
    'শোনাও',
    'পড়ো',
    'পড়ুন',
    'করো',
    'করুন',
    'দাও',
    'দিন',
    'তো',
  ];

  // ===========================================================================
  // GENERAL MATCHER
  // ===========================================================================

  /// Returns a general matched intent, or null when nothing matches.
  ///
  /// [requireWakeWord] enables the old wake-word gating behaviour.
  ///
  /// [wakePrimed] means a wake word was already heard shortly before this
  /// command.
  ///
  /// NOTE:
  /// Trigger-listening mode should call [matchTriggerCommand] instead of this
  /// method.
  static VoiceIntent? match(
    String rawText, {
    bool requireWakeWord = false,
    bool wakePrimed = true,
  }) {
    final normalized = _normalize(rawText);

    if (normalized.isEmpty) {
      return null;
    }

    // Legacy wake-word gating.
    if (requireWakeWord && !wakePrimed) {
      final stripped = stripWakeWord(normalized);

      if (stripped == null) {
        return null;
      }

      // Wake word alone = priming event, not a task command.
      if (stripped.isEmpty) {
        return null;
      }

      return _matchText(stripped);
    }

    return _matchText(normalized);
  }

  static VoiceIntent? _matchText(String normalized) {
    final direct = _exactOrContainment(normalized);

    if (direct != null) {
      return direct;
    }

    final fuzzy = _fuzzyMatch(normalized);

    if (fuzzy != null) {
      return fuzzy;
    }

    return null;
  }

  // ===========================================================================
  // EXACT / CONTAINMENT MATCHING
  // ===========================================================================

  static VoiceIntent? _exactOrContainment(String heard) {
    // Pass 1:
    // Exact and polite prefix/suffix variants.
    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(phrase);

        if (heard == command) {
          return entry.key;
        }

        if (_matchesWithPoliteness(heard, command)) {
          return entry.key;
        }
      }
    }

    // Pass 2:
    // Word-boundary containment.
    //
    // Example:
    // "সামনে কী আছে দেখো"
    // can match
    // "সামনে কী আছে"
    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(phrase);

        if (_containsAsWords(heard, command)) {
          return entry.key;
        }
      }
    }

    // Pass 3:
    // Trailing verb tolerance.
    final stripped = _stripTrailingVerbs(heard);

    if (stripped != heard) {
      for (final entry in _phrases.entries) {
        for (final phrase in entry.value) {
          final command = _normalize(phrase);

          if (stripped == command) {
            return entry.key;
          }

          if (_matchesWithPoliteness(stripped, command)) {
            return entry.key;
          }

          if (_containsAsWords(stripped, command)) {
            return entry.key;
          }
        }
      }
    }

    return null;
  }

  static bool _matchesWithPoliteness(
    String heard,
    String command,
  ) {
    if (heard == command) {
      return true;
    }

    for (final prefix in _prefixes) {
      if (heard == '$prefix$command') {
        return true;
      }

      final withoutPrefix =
          heard.startsWith(prefix)
              ? heard.substring(prefix.length)
              : null;

      if (withoutPrefix != null && withoutPrefix == command) {
        return true;
      }
    }

    for (final suffix in const [
      ' প্লিজ',
      ' একটু',
    ]) {
      if (heard == '$command$suffix') {
        return true;
      }
    }

    return false;
  }

  /// Returns true when [command] appears inside [heard] with word boundaries.
  ///
  /// This belongs only to the broad/general matcher.
  ///
  /// [matchTriggerCommand] deliberately does NOT use containment because
  /// direct wake triggers should remain strict.
  static bool _containsAsWords(
    String heard,
    String command,
  ) {
    if (command.isEmpty) {
      return false;
    }

    int index = heard.indexOf(command);

    while (index != -1) {
      final beforeOk =
          index == 0 || heard[index - 1] == ' ';

      final end = index + command.length;

      final afterOk =
          end == heard.length || heard[end] == ' ';

      if (beforeOk && afterOk) {
        return true;
      }

      index = heard.indexOf(
        command,
        index + 1,
      );
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
        if (text == verb) {
          return '';
        }

        if (text.endsWith(' $verb')) {
          text = text
              .substring(
                0,
                text.length - verb.length - 1,
              )
              .trim();

          changed = true;
          strips++;

          break;
        }
      }
    }

    return text;
  }

  // ===========================================================================
  // FUZZY MATCHING
  // ===========================================================================

  /// Conservative fuzzy matching for the broad/general command matcher.
  ///
  /// IMPORTANT:
  /// The five direct trigger commands DO NOT use fuzzy matching.
  ///
  /// This prevents random conversation from accidentally waking the
  /// assistant.
  static VoiceIntent? _fuzzyMatch(String heard) {
    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(phrase);

        if ((heard.length - command.length).abs() > 3) {
          continue;
        }

        if (_similarity(heard, command) >= 0.85) {
          return entry.key;
        }
      }
    }

    return null;
  }

  static double _similarity(
    String a,
    String b,
  ) {
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }

    final distance = _levenshtein(a, b);

    final maxLength =
        a.length > b.length ? a.length : b.length;

    return 1.0 - (distance / maxLength);
  }

  static int _levenshtein(
    String a,
    String b,
  ) {
    final m = a.length;
    final n = b.length;

    if (m == 0) {
      return n;
    }

    if (n == 0) {
      return m;
    }

    final prev = List<int>.generate(
      n + 1,
      (i) => i,
    );

    final curr = List<int>.filled(
      n + 1,
      0,
    );

    for (int i = 1; i <= m; i++) {
      curr[0] = i;

      for (int j = 1; j <= n; j++) {
        final cost =
            a.codeUnitAt(i - 1) ==
                    b.codeUnitAt(j - 1)
                ? 0
                : 1;

        final deletion = prev[j] + 1;
        final insertion = curr[j - 1] + 1;
        final substitution = prev[j - 1] + cost;

        var best = deletion;

        if (insertion < best) {
          best = insertion;
        }

        if (substitution < best) {
          best = substitution;
        }

        curr[j] = best;
      }

      for (int j = 0; j <= n; j++) {
        prev[j] = curr[j];
      }
    }

    return prev[n];
  }

  // ===========================================================================
  // NORMALISATION
  // ===========================================================================

  /// Normalises speech-recognition output.
  ///
  /// Handles:
  /// - upper/lowercase English
  /// - zero-width characters
  /// - punctuation
  /// - repeated spaces
  ///
  /// It deliberately does NOT convert "কি" to "কী".
  /// Both variants are explicitly listed in [triggerCommands].
  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll('\u200c', '')
        .replaceAll('\u200d', '')
        .replaceAll(
          RegExp(r'[\?\!\.,;:।]+'),
          ' ',
        )
        .replaceAll(
          RegExp(r'\s+'),
          ' ',
        )
        .trim();
  }

  // ===========================================================================
  // LEGACY WAKE-WORD HELPERS
  // ===========================================================================

  /// Removes the first recognised legacy wake word.
  ///
  /// Returns:
  ///
  /// null
  ///   -> no wake word
  ///
  /// ''
  ///   -> only wake word was spoken
  ///
  /// non-empty String
  ///   -> text after/before the wake word
  static String? stripWakeWord(String normalizedHeard) {
    final heard = _normalize(normalizedHeard);

    if (heard.isEmpty) {
      return null;
    }

    // Longest wake words first so "রিউ ভিশন" wins over "রিউ".
    final words = [...wakeWords]
      ..sort(
        (a, b) => b.length.compareTo(a.length),
      );

    for (final wake in words) {
      final w = _normalize(wake);

      if (w.isEmpty) {
        continue;
      }

      if (heard == w) {
        return '';
      }

      if (heard.startsWith('$w ')) {
        return heard
            .substring(w.length + 1)
            .trim();
      }

      if (heard.endsWith(' $w')) {
        return heard
            .substring(
              0,
              heard.length - w.length - 1,
            )
            .trim();
      }
    }

    return null;
  }

  static bool containsWakeWord(String rawText) {
    return stripWakeWord(rawText) != null;
  }

  // ===========================================================================
  // HELP COMMANDS
  // ===========================================================================

  /// Existing full command help list.
  ///
  /// Keep this for compatibility with any existing screen that displays all
  /// supported commands.
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
