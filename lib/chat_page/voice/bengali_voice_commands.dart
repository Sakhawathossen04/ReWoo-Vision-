import 'voice_intent.dart';

/// Deterministic Bengali command matcher.
///
/// Two separate matching layers exist:
///
/// 1. [matchTriggerCommand]
///    Strict matcher used by SpeechService while waiting for one of the
///    five direct activation command families.
///
/// 2. [match]
///    Broader legacy/general-purpose matcher retained for existing UI and
///    compatibility code.
///
/// IMPORTANT:
///
/// The five direct trigger command families themselves act as both:
///
/// wake phrase + task command
///
/// No separate "Hey ReWoo" phrase is required.
class BengaliVoiceCommands {
  BengaliVoiceCommands._();

  // ===========================================================================
  // STRICT FIVE-COMMAND-FAMILY TRIGGER MODE
  // ===========================================================================

  /// These are the ONLY five command families that may directly activate
  /// the assistant from waiting/listening mode.
  ///
  /// Bengali speech recognition frequently alternates between "কী" and "কি",
  /// therefore both forms are explicitly accepted where required.
  ///
  /// FRONT also accepts the short exact alias:
  ///
  /// "সামনে দেখো"
  ///
  /// Exact matching is still preserved.
  static const Map<VoiceIntent, List<String>> triggerCommands = {
    // -------------------------------------------------------------------------
    // 1. FRONT
    // -------------------------------------------------------------------------

    VoiceIntent.describeFront: [
      'সামনে কী আছে দেখো',
      'সামনে কি আছে দেখো',
      'সামনে দেখো',
    ],

    // -------------------------------------------------------------------------
    // 2. IDENTIFY OBJECT
    // -------------------------------------------------------------------------

    VoiceIntent.identifyObject: [
      'এটা কী',
      'এটা কি',
    ],

    // -------------------------------------------------------------------------
    // 3. READ TEXT
    // -------------------------------------------------------------------------

    VoiceIntent.readText: [
      'লেখাটা পড়ে শোনাও',
      'লেখা পড়ে শোনাও',
    ],

    // -------------------------------------------------------------------------
    // 4. RIGHT
    // -------------------------------------------------------------------------

    VoiceIntent.describeRight: [
      'ডান পাশে কী আছে',
      'ডান পাশে কি আছে',
    ],

    // -------------------------------------------------------------------------
    // 5. LEFT
    // -------------------------------------------------------------------------

    VoiceIntent.describeLeft: [
      'বাম পাশে কী আছে',
      'বাম পাশে কি আছে',
    ],
  };

  /// Matches ONLY the five direct trigger command families.
  ///
  /// Matching is exact after harmless text normalization.
  ///
  /// This matcher deliberately does NOT use:
  ///
  /// - fuzzy matching
  /// - substring matching
  /// - containment matching
  /// - wake-word stripping
  /// - polite prefixes
  /// - general command vocabulary
  ///
  /// Examples:
  ///
  /// "সামনে কী আছে দেখো"
  /// -> describeFront
  ///
  /// "সামনে কী আছে দেখো?"
  /// -> describeFront
  ///
  /// "সামনে দেখো"
  /// -> describeFront
  ///
  /// "সামনে দেখো!"
  /// -> describeFront
  ///
  /// "এটা কী"
  /// -> identifyObject
  ///
  /// "এটা কী সুন্দর জিনিস"
  /// -> null
  ///
  /// "সামনে দেখো তারপর বলো"
  /// -> null
  ///
  /// "রিউ সামনে দেখো"
  /// -> null
  ///
  /// "ছবি তোলো"
  /// -> null
  static VoiceIntent? matchTriggerCommand(
    String rawText,
  ) {
    final heard = _normalize(
      rawText,
    );

    if (heard.isEmpty) {
      return null;
    }

    for (final entry in triggerCommands.entries) {
      for (final phrase in entry.value) {
        final expected = _normalize(
          phrase,
        );

        if (heard == expected) {
          return entry.key;
        }
      }
    }

    return null;
  }

  /// True only when [rawText] exactly matches one of the direct trigger
  /// commands after normalization.
  static bool isTriggerCommand(
    String rawText,
  ) {
    return matchTriggerCommand(
          rawText,
        ) !=
        null;
  }

  /// Primary human-readable five trigger phrases.
  ///
  /// The first phrase of each family is intentionally used as the help phrase.
  ///
  /// Therefore adding "সামনে দেখো" as an alias does NOT create a sixth
  /// help command.
  ///
  /// Use this for:
  ///
  /// - startup TTS
  /// - trigger-mode help
  /// - onboarding
  /// - tests
  static List<String> get triggerHelpCommands =>
      triggerCommands.values
          .map(
            (phrases) => phrases.first,
          )
          .toList(
            growable: false,
          );

  // ===========================================================================
  // GENERAL / LEGACY COMMAND MATCHER
  // ===========================================================================

  /// Broader command vocabulary retained for existing app compatibility.
  ///
  /// IMPORTANT:
  ///
  /// SpeechService trigger-listening mode must NOT use this map.
  ///
  /// It must use [matchTriggerCommand].
  static const Map<VoiceIntent, List<String>> _phrases = {
    // -------------------------------------------------------------------------
    // READ TEXT
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // STOP VIDEO
    // -------------------------------------------------------------------------

    VoiceIntent.stopVideo: [
      'ভিডিও রেকর্ড বন্ধ করো',
      'ভিডিও রেকর্ডিং বন্ধ করো',
      'ভিডিও বন্ধ করো',
      'রেকর্ডিং বন্ধ করো',
      'ভিডিও শেষ করো',
      'ভিডিও সেভ করো',
    ],

    // -------------------------------------------------------------------------
    // START VIDEO
    // -------------------------------------------------------------------------

    VoiceIntent.startVideo: [
      'ভিডিও রেকর্ড করো',
      'ভিডিও রেকর্ড শুরু করো',
      'ভিডিও রেকর্ডিং শুরু করো',
      'ভিডিও শুরু করো',
      'রেকর্ডিং শুরু করো',
      'ভিডিও রেকর্ড',
    ],

    // -------------------------------------------------------------------------
    // PHOTO
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // FRONT
    // -------------------------------------------------------------------------

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

      // Short direct/legacy-friendly alias.
      'সামনে দেখো',
    ],

    // -------------------------------------------------------------------------
    // CURRENT / SURROUNDINGS
    // -------------------------------------------------------------------------

    VoiceIntent.describeCurrent: [
      'এদিকে দেখো',
      'এইদিকে দেখো',
      'এখানে কী আছে',
      'এখানে কি আছে',
      'চারপাশে কী আছে',
    ],

    // -------------------------------------------------------------------------
    // RIGHT
    // -------------------------------------------------------------------------

    VoiceIntent.describeRight: [
      'ডান পাশে কী আছে',
      'ডান পাশে কি আছে',
      'ডানে কী আছে',
      'ডানে কি আছে',
      'ডান দিকে কী আছে',
    ],

    // -------------------------------------------------------------------------
    // LEFT
    // -------------------------------------------------------------------------

    VoiceIntent.describeLeft: [
      'বাম পাশে কী আছে',
      'বাম পাশে কি আছে',
      'বামে কী আছে',
      'বামে কি আছে',
      'বাম দিকে কী আছে',
    ],

    // -------------------------------------------------------------------------
    // IDENTIFY
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // REPEAT
    // -------------------------------------------------------------------------

    VoiceIntent.repeatLast: [
      'আবার বলো',
      'আরেকবার বলো',
      'পুনরায় বলো',
      'আবার শোনাও',
    ],

    // -------------------------------------------------------------------------
    // STOP SPEAKING
    // -------------------------------------------------------------------------

    VoiceIntent.stopSpeaking: [
      'চুপ করো',
      'চুপ',
      'থামো',
      'বলা বন্ধ করো',
      'কথা বন্ধ করো',
      'ভয়েস বন্ধ করো',
    ],

    // -------------------------------------------------------------------------
    // HELP
    // -------------------------------------------------------------------------

    VoiceIntent.help: [
      'কী কী বলতে পারি',
      'কি কি বলতে পারি',
      'কমান্ড বলো',
      'কমান্ডগুলো বলো',
      'সাহায্য করো',
    ],

    // -------------------------------------------------------------------------
    // NEW CHAT
    // -------------------------------------------------------------------------

    VoiceIntent.newChat: [
      'নতুন আলাপ',
      'নতুন চ্যাট',
      'নতুন কথা শুরু করো',
    ],
  };

  // ===========================================================================
  // LEGACY WAKE WORDS
  // ===========================================================================

  /// Retained only for backward compatibility.
  ///
  /// These DO NOT participate in strict five-command trigger mode.
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

  // ===========================================================================
  // GENERAL MATCHER POLITENESS
  // ===========================================================================

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
  // GENERAL MATCH
  // ===========================================================================

  /// General-purpose legacy command matcher.
  ///
  /// Trigger-listening mode must use [matchTriggerCommand] instead.
  static VoiceIntent? match(
    String rawText, {
    bool requireWakeWord = false,
    bool wakePrimed = true,
  }) {
    final normalized = _normalize(
      rawText,
    );

    if (normalized.isEmpty) {
      return null;
    }

    // -------------------------------------------------------------------------
    // OPTIONAL LEGACY WAKE-WORD GATE
    // -------------------------------------------------------------------------

    if (requireWakeWord &&
        !wakePrimed) {
      final stripped = stripWakeWord(
        normalized,
      );

      if (stripped == null) {
        return null;
      }

      // Wake word alone is only a priming event.
      if (stripped.isEmpty) {
        return null;
      }

      return _matchText(
        stripped,
      );
    }

    return _matchText(
      normalized,
    );
  }

  static VoiceIntent? _matchText(
    String normalized,
  ) {
    final direct = _exactOrContainment(
      normalized,
    );

    if (direct != null) {
      return direct;
    }

    return _fuzzyMatch(
      normalized,
    );
  }

  // ===========================================================================
  // GENERAL EXACT / CONTAINMENT MATCHING
  // ===========================================================================

  static VoiceIntent? _exactOrContainment(
    String heard,
  ) {
    // -------------------------------------------------------------------------
    // PASS 1
    // Exact + polite variants.
    // -------------------------------------------------------------------------

    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(
          phrase,
        );

        if (heard == command) {
          return entry.key;
        }

        if (_matchesWithPoliteness(
          heard,
          command,
        )) {
          return entry.key;
        }
      }
    }

    // -------------------------------------------------------------------------
    // PASS 2
    // Word-boundary containment.
    //
    // GENERAL MATCHER ONLY.
    // -------------------------------------------------------------------------

    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(
          phrase,
        );

        if (_containsAsWords(
          heard,
          command,
        )) {
          return entry.key;
        }
      }
    }

    // -------------------------------------------------------------------------
    // PASS 3
    // Trailing verb tolerance.
    // -------------------------------------------------------------------------

    final stripped = _stripTrailingVerbs(
      heard,
    );

    if (stripped != heard) {
      for (final entry in _phrases.entries) {
        for (final phrase in entry.value) {
          final command = _normalize(
            phrase,
          );

          if (stripped == command) {
            return entry.key;
          }

          if (_matchesWithPoliteness(
            stripped,
            command,
          )) {
            return entry.key;
          }

          if (_containsAsWords(
            stripped,
            command,
          )) {
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
      if (heard ==
          '$prefix$command') {
        return true;
      }

      if (heard.startsWith(
        prefix,
      )) {
        final withoutPrefix = heard
            .substring(
              prefix.length,
            )
            .trim();

        if (withoutPrefix == command) {
          return true;
        }
      }
    }

    for (final suffix in const [
      ' প্লিজ',
      ' একটু',
    ]) {
      if (heard ==
          '$command$suffix') {
        return true;
      }
    }

    return false;
  }

  static bool _containsAsWords(
    String heard,
    String command,
  ) {
    if (command.isEmpty) {
      return false;
    }

    var index = heard.indexOf(
      command,
    );

    while (index != -1) {
      final beforeOk =
          index == 0 ||
          heard[index - 1] == ' ';

      final end =
          index +
          command.length;

      final afterOk =
          end == heard.length ||
          heard[end] == ' ';

      if (beforeOk &&
          afterOk) {
        return true;
      }

      index = heard.indexOf(
        command,
        index + 1,
      );
    }

    return false;
  }

  // ===========================================================================
  // TRAILING VERBS
  // ===========================================================================

  static String _stripTrailingVerbs(
    String heard,
  ) {
    var text = heard.trim();

    var changed = true;

    var strips = 0;

    while (changed &&
        strips < 3) {
      changed = false;

      for (final verb in _trailingVerbs) {
        if (text == verb) {
          return '';
        }

        if (text.endsWith(
          ' $verb',
        )) {
          text = text
              .substring(
                0,
                text.length -
                    verb.length -
                    1,
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
  // GENERAL FUZZY MATCHER
  // ===========================================================================

  /// Conservative fuzzy matcher.
  ///
  /// IMPORTANT:
  ///
  /// Strict direct trigger mode NEVER calls this method.
  static VoiceIntent? _fuzzyMatch(
    String heard,
  ) {
    for (final entry in _phrases.entries) {
      for (final phrase in entry.value) {
        final command = _normalize(
          phrase,
        );

        if ((heard.length -
                    command.length)
                .abs() >
            3) {
          continue;
        }

        if (_similarity(
              heard,
              command,
            ) >=
            0.85) {
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
    if (a.isEmpty ||
        b.isEmpty) {
      return 0;
    }

    final distance = _levenshtein(
      a,
      b,
    );

    final maxLength =
        a.length > b.length
            ? a.length
            : b.length;

    return 1.0 -
        (distance /
            maxLength);
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

    final previous =
        List<int>.generate(
      n + 1,
      (index) => index,
    );

    final current =
        List<int>.filled(
      n + 1,
      0,
    );

    for (var i = 1;
        i <= m;
        i++) {
      current[0] = i;

      for (var j = 1;
          j <= n;
          j++) {
        final cost =
            a.codeUnitAt(
                      i - 1,
                    ) ==
                    b.codeUnitAt(
                      j - 1,
                    )
                ? 0
                : 1;

        final deletion =
            previous[j] + 1;

        final insertion =
            current[j - 1] + 1;

        final substitution =
            previous[j - 1] +
            cost;

        var best = deletion;

        if (insertion < best) {
          best = insertion;
        }

        if (substitution < best) {
          best = substitution;
        }

        current[j] = best;
      }

      for (var j = 0;
          j <= n;
          j++) {
        previous[j] =
            current[j];
      }
    }

    return previous[n];
  }

  // ===========================================================================
  // NORMALIZATION
  // ===========================================================================

  /// Normalizes speech recognition text without making fuzzy semantic changes.
  ///
  /// Handles:
  ///
  /// - English lowercase
  /// - zero-width characters
  /// - Bengali/English punctuation
  /// - repeated whitespace
  ///
  /// It deliberately does NOT convert:
  ///
  /// "কি" <-> "কী"
  ///
  /// because both variants are explicitly configured.
  static String _normalize(
    String text,
  ) {
    return text
        .toLowerCase()
        .replaceAll(
          '\u200c',
          '',
        )
        .replaceAll(
          '\u200d',
          '',
        )
        .replaceAll(
          RegExp(
            r'[\?\!\.,;:।]+',
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\s+',
          ),
          ' ',
        )
        .trim();
  }

  // ===========================================================================
  // LEGACY WAKE-WORD HELPERS
  // ===========================================================================

  /// Removes one legacy wake word.
  ///
  /// Returns:
  ///
  /// null
  /// -> no wake word found
  ///
  /// ''
  /// -> only wake word spoken
  ///
  /// non-empty string
  /// -> remaining utterance
  static String? stripWakeWord(
    String rawText,
  ) {
    final heard = _normalize(
      rawText,
    );

    if (heard.isEmpty) {
      return null;
    }

    // Longest phrase first:
    //
    // "রিউ ভিশন" must win before "রিউ".
    final sortedWakeWords =
        [...wakeWords]
          ..sort(
            (
              a,
              b,
            ) =>
                b.length.compareTo(
              a.length,
            ),
          );

    for (final wake in sortedWakeWords) {
      final normalizedWake = _normalize(
        wake,
      );

      if (normalizedWake.isEmpty) {
        continue;
      }

      if (heard ==
          normalizedWake) {
        return '';
      }

      if (heard.startsWith(
        '$normalizedWake ',
      )) {
        return heard
            .substring(
              normalizedWake.length +
                  1,
            )
            .trim();
      }

      if (heard.endsWith(
        ' $normalizedWake',
      )) {
        return heard
            .substring(
              0,
              heard.length -
                  normalizedWake.length -
                  1,
            )
            .trim();
      }
    }

    return null;
  }

  static bool containsWakeWord(
    String rawText,
  ) {
    return stripWakeWord(
          rawText,
        ) !=
        null;
  }

  // ===========================================================================
  // LEGACY / SETTINGS HELP LIST
  // ===========================================================================

  /// Existing broader help list.
  ///
  /// Keep this property because these existing files currently reference it:
  ///
  /// lib/settings_page.dart
  /// lib/chat_page/services/chat_helpers.dart
  ///
  /// Trigger-mode UI should use [triggerHelpCommands] when only the five
  /// activation phrases should be displayed.
  static List<String> get primaryHelpCommands =>
      const [
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
