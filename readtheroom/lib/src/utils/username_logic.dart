// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure handle logic for the chameleon identity (WP-C1).
///
/// Validation and generation live here — with no Flutter, Supabase or
/// SharedPreferences dependency — so they are unit-testable and so the client
/// rule is literally the same regex the `set_username()` RPC enforces
/// (`supabase/migrations/user_profiles.sql`). The client check is advisory;
/// the server is the authority (networks-update-design §5.1).
library;

import 'dart:math';

/// Handle rule from networks-update-design §5.1: 3–20 chars, lowercase
/// alphanumerics and underscores, no leading underscore.
final RegExp kUsernamePattern = RegExp(r'^[a-z0-9][a-z0-9_]{2,19}$');

const int kUsernameMinLength = 3;
const int kUsernameMaxLength = 20;

/// Why a candidate handle is unacceptable. `null` (see [usernameFormatError])
/// means the format is fine — uniqueness, the server profanity list and the
/// 7-day cooldown are only knowable server-side.
enum UsernameFormatError {
  empty,
  tooShort,
  tooLong,
  leadingUnderscore,
  invalidCharacters,
}

/// Human-readable, inline-validation copy for [UsernameFormatError].
String usernameFormatErrorMessage(UsernameFormatError error) {
  switch (error) {
    case UsernameFormatError.empty:
      return 'Pick a name for your chameleon.';
    case UsernameFormatError.tooShort:
      return 'At least $kUsernameMinLength characters.';
    case UsernameFormatError.tooLong:
      return 'At most $kUsernameMaxLength characters.';
    case UsernameFormatError.leadingUnderscore:
      return "Can't start with an underscore.";
    case UsernameFormatError.invalidCharacters:
      return 'Lowercase letters, numbers and underscores only.';
  }
}

/// `true` when [username] satisfies the §5.1 charset/length rule exactly.
///
/// Does **not** normalise: callers show users what they typed and normalise
/// with [normalizeUsername] before submitting.
bool isValidUsername(String? username) {
  if (username == null) return false;
  return kUsernamePattern.hasMatch(username);
}

/// Lowercases and trims a typed handle into the form the RPC expects.
String normalizeUsername(String raw) => raw.trim().toLowerCase();

/// Classifies why [raw] fails the format rule, or returns `null` if it passes.
/// Ordered most-specific-first so the inline hint is the useful one.
UsernameFormatError? usernameFormatError(String raw) {
  final value = normalizeUsername(raw);
  if (value.isEmpty) return UsernameFormatError.empty;
  if (value.startsWith('_')) return UsernameFormatError.leadingUnderscore;
  if (value.length < kUsernameMinLength) return UsernameFormatError.tooShort;
  if (value.length > kUsernameMaxLength) return UsernameFormatError.tooLong;
  if (!kUsernamePattern.hasMatch(value)) {
    return UsernameFormatError.invalidCharacters;
  }
  return null;
}

/// Adjective vocabulary for generated suggestions.
///
/// Lifted from the per-question randomized comment names in
/// `comment_service.dart` (the `adjective + chameleon + number` pattern named in
/// DBarchitecture.md's `question_comment_usernames` notes), minus the entries
/// that cannot survive the handle charset (hyphenated species names), so every
/// generated suggestion is valid by construction.
const List<String> kHandleAdjectives = <String>[
  'absurd', 'antsy', 'anxious', 'awkward', 'baroque', 'based', 'blushing',
  'boisterous', 'bold', 'cheeky', 'chill', 'clumsy', 'cool', 'cranky',
  'curious', 'dreamy', 'dusky', 'envious', 'erratic', 'feral', 'fizzy',
  'flaky', 'flirty', 'foggy', 'funky', 'ghostly', 'giddy', 'goofy',
  'grumpy', 'haunted', 'hyper', 'indignant', 'lazy', 'liminal', 'loopy',
  'lurking', 'moody', 'naive', 'nebulous', 'oblivious', 'pensive', 'quirky',
  'rattled', 'reckless', 'salty', 'sassy', 'serious', 'shadowed', 'shy',
  'skittish', 'sleepy', 'slinky', 'smirking', 'snappy', 'snarky', 'sneaky',
  'soggy', 'spicy', 'talkative', 'thirsty', 'timid', 'twinkly', 'unbothered',
  'unhinged', 'unkempt', 'unruly', 'wacky', 'whimsical', 'wiggly', 'willowy',
  'wistful', 'witty', 'yappy', 'zany', 'zesty', 'zonked',
  // chameleon species, handle-safe spellings only
  'panther', 'jacksons', 'parsons', 'mellers', 'oustalets', 'veiled',
  'carpet', 'dwarf', 'tiger',
];

/// Chameleon-flavoured nouns the suggestions pair with the adjective.
const List<String> kHandleNouns = <String>[
  'chameleon',
  'cham',
  'gecko',
  'lizard',
  'curio',
  'camo',
  'scale',
  'tail',
];

/// Builds one `adjective_noun` + numeric-suffix handle, guaranteed to satisfy
/// [isValidUsername].
///
/// The numeric suffix is what keeps the namespace usable without exposing a
/// "is this taken?" probe endpoint (§5.1 forbids browse/enumeration): on a
/// `taken` error the UI simply offers fresh suggestions.
String generateUsername(Random random) {
  final adjective = kHandleAdjectives[random.nextInt(kHandleAdjectives.length)];
  final noun = kHandleNouns[random.nextInt(kHandleNouns.length)];
  final number = random.nextInt(99) + 1; // 1-99

  var candidate = '${adjective}_$noun$number';
  if (candidate.length > kUsernameMaxLength) {
    // Trim the adjective rather than the distinguishing suffix.
    final suffix = '_$noun$number';
    final room = kUsernameMaxLength - suffix.length;
    candidate = adjective.substring(0, room.clamp(1, adjective.length)) + suffix;
  }
  return candidate;
}

/// Generates [count] distinct, format-valid handle suggestions.
///
/// [isAllowed] is the profanity gate — decision D4 requires suggestions to be
/// profanity-checked too, not just typed input. It is injected rather than
/// imported so this file stays pure (ProfileService passes
/// `ProfanityFilterService`).
List<String> generateUsernameSuggestions(
  int count, {
  Random? random,
  bool Function(String candidate)? isAllowed,
}) {
  final rng = random ?? Random();
  final allow = isAllowed ?? (_) => true;
  final out = <String>{};

  // Bounded attempts: a pathological `isAllowed` must never spin forever.
  final maxAttempts = count * 40 + 40;
  for (var attempt = 0; attempt < maxAttempts && out.length < count; attempt++) {
    final candidate = generateUsername(rng);
    if (!isValidUsername(candidate)) continue;
    if (!allow(candidate)) continue;
    out.add(candidate);
  }
  return out.toList();
}

/// Personalised contribution thanks (backlog item 7).
///
/// Falls back to the pre-existing copy whenever no handle is set, so nothing
/// regresses for users who skip the profile step.
/// [exclaim] matches the streak-celebration overlay's punctuation.
/// [breakAfterComma] puts the handle on its own line (the home card: a handle
/// always starts line two, rather than wrapping wherever its length dictates).
String thanksForContributingText(
  String? username, {
  bool exclaim = false,
  bool breakAfterComma = false,
}) {
  const base = 'Thanks for contributing today';
  final handle = username?.trim();
  final suffix = exclaim ? '!' : '';
  if (handle == null || handle.isEmpty) return '$base$suffix';
  return '$base,${breakAfterComma ? '\n' : ' '}$handle$suffix';
}
