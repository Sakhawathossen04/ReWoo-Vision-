// ===========================================================================
// DIRECT FIVE-COMMAND TRIGGER MODE
// ===========================================================================

/// These are the ONLY commands that can activate the assistant while it is
/// waiting in trigger-listening mode.
///
/// The command itself acts as both:
///
/// wake phrase + task command
///
/// There is NO separate "Hey ReWoo" requirement.
static const Map<VoiceIntent, List<String>> triggerCommands = {
  // -------------------------------------------------------------------------
  // 1. Describe what is in front
  // -------------------------------------------------------------------------
  VoiceIntent.describeFront: [
    'সামনে কী আছে দেখো',
    'সামনে কি আছে দেখো',
  ],

  // -------------------------------------------------------------------------
  // 2. Identify an object
  // -------------------------------------------------------------------------
  VoiceIntent.identifyObject: [
    'এটা কী',
    'এটা কি',
  ],

  // -------------------------------------------------------------------------
  // 3. Read visible text
  // -------------------------------------------------------------------------
  VoiceIntent.readText: [
    'লেখাটা পড়ে শোনাও',
    'লেখা পড়ে শোনাও',
  ],

  // -------------------------------------------------------------------------
  // 4. Describe the right side
  // -------------------------------------------------------------------------
  VoiceIntent.describeRight: [
    'ডান পাশে কী আছে',
    'ডান পাশে কি আছে',
  ],

  // -------------------------------------------------------------------------
  // 5. Describe the left side
  // -------------------------------------------------------------------------
  VoiceIntent.describeLeft: [
    'বাম পাশে কী আছে',
    'বাম পাশে কি আছে',
  ],
};

/// Matches ONLY one of the five direct trigger commands.
///
/// IMPORTANT:
///
/// This matcher deliberately does NOT use:
///
/// - fuzzy matching
/// - substring matching
/// - containment matching
/// - old wake words
/// - polite-prefix expansion
/// - general command vocabulary
///
/// This helps prevent normal conversation from accidentally activating
/// the assistant.
///
/// Examples:
///
/// "সামনে কী আছে দেখো"
/// -> describeFront
///
/// "সামনে কি আছে দেখো?"
/// -> describeFront
///
/// "আজ সামনে কী আছে দেখো তো"
/// -> null
///
/// "রিউ সামনে কী আছে দেখো"
/// -> null
///
/// "ছবি তোলো"
/// -> null
///
/// "ভিডিও রেকর্ড করো"
/// -> null
///
/// "নতুন আলাপ"
/// -> null
static VoiceIntent? matchTriggerCommand(
  String rawText,
) {
  final heard = _normalize(rawText);

  if (heard.isEmpty) {
    return null;
  }

  for (final entry in triggerCommands.entries) {
    for (final phrase in entry.value) {
      final expected = _normalize(phrase);

      if (heard == expected) {
        return entry.key;
      }
    }
  }

  return null;
}

/// Simple true/false helper.
static bool isTriggerCommand(
  String rawText,
) {
  return matchTriggerCommand(rawText) != null;
}

/// Primary human-readable version of the five trigger commands.
///
/// Useful for:
///
/// onboarding
/// startup TTS
/// help UI
/// tests
static List<String> get triggerHelpCommands =>
    triggerCommands.values
        .map(
          (phrases) => phrases.first,
        )
        .toList(
          growable: false,
        );
