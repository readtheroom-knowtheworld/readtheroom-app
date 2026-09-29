// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure badge catalog for the "Camo Collection" on the Me screen.
//
// Before 2026-09-28 the grid and the "N badges collected" counter were two
// separate code paths that drifted apart: the counter still counted retired
// room badges, hidden lizzy badges and per-device SharedPreferences flags the
// grid never showed. Now [buildBadgeSections] is the single source of truth:
// the grid renders its sections and [countCollectedBadges] sums the very same
// list, so the two cannot disagree.
//
// No I/O, no Flutter imports. The Me screen gathers a [BadgeStats] snapshot
// (local state + a cached server fetch) and hands it here.

/// The day city/country-targeted question badges stopped being awarded.
/// Questions created on or after this date no longer earn the legacy
/// "Local Community" badges; ones earned before it are kept.
final DateTime kLocalBadgesRetiredAt = DateTime.utc(2026, 9, 29);

/// Account-age cut-offs for the tester badges.
final DateTime kAlphaTesterCutoff = DateTime(2025, 7, 21);
final DateTime kBetaTesterCutoff = DateTime(2025, 9, 1);

/// Friend-count tiers (owner request 2026-09-28).
const List<int> kFriendTiers = [5, 10, 25, 50, 100];

/// SharedPreferences flag names (without the `achievement_` prefix) that
/// permanently unlock a badge once set. Older builds wrote these; they are
/// still honoured so nobody loses a badge they already earned.
class BadgeFlags {
  static const alphaTester = 'alpha_tester';
  static const betaTester = 'beta_tester';
  static const birthdayBuddy = 'birthday_buddy';
  static const qotdStar = 'qotd_star';
  static const firstLizzy = 'first_lizzy';
  static const dragonLizzy = 'dragon_lizzy';
  static const dinoLizzy = 'dino_lizzy';
  static const popcornTime = 'popcorn_time';
  static const plantingSeed = 'planting_seed';
  static const communityBuilding = 'community_building';
  static const localLegend = 'local_legend';
  static const globalSeed = 'global_seed';
  static const globalCommunity = 'global_community';
}

/// Everything the catalog needs to decide what is unlocked.
class BadgeStats {
  const BadgeStats({
    this.isSignedIn = false,
    this.postedCount = 0,
    this.answeredCount = 0,
    this.popularQuestionCount = 0,
    this.viralQuestionCount = 0,
    this.qotdCount = 0,
    this.accountCreatedAt,
    this.postedInNovember = false,
    this.qotdNotificationsOn = false,
    this.friendCount = 0,
    this.commentCount = 0,
    this.maxLizziesOnOneComment = 0,
    this.popcornQuestionCount = 0,
    this.reactionsGiven = 0,
    this.reactionsReceived = 0,
    this.legacyCityQuestions = 0,
    this.legacyCountryQuestions = 0,
    this.legacyUniqueCities = 0,
    this.earnedFlags = const <String>{},
  });

  final bool isSignedIn;
  final int postedCount;

  /// Answered questions, filtered the same way as the "Answered" list.
  final int answeredCount;

  /// Posted questions with 100–499 responses.
  final int popularQuestionCount;

  /// Posted questions with 500+ responses.
  final int viralQuestionCount;

  final int qotdCount;
  final DateTime? accountCreatedAt;
  final bool postedInNovember;
  final bool qotdNotificationsOn;

  /// Accepted friends. The loader passes the high-water mark, so unfriending
  /// someone never takes a badge back.
  final int friendCount;

  /// Visible comments the user has posted (high-water mark).
  final int commentCount;

  /// The most 🦎 lizzies any single comment of the user's has received.
  final int maxLizziesOnOneComment;

  /// Posted questions that received 5+ comments.
  final int popcornQuestionCount;

  /// Emoji reactions the user has left on questions (high-water mark).
  final int reactionsGiven;

  /// Emoji reactions left on the user's own questions (high-water mark).
  final int reactionsReceived;

  /// City/country-targeted questions posted before [kLocalBadgesRetiredAt].
  final int legacyCityQuestions;
  final int legacyCountryQuestions;
  final int legacyUniqueCities;

  /// Sticky unlock flags, see [BadgeFlags].
  final Set<String> earnedFlags;

  bool has(String flag) => earnedFlags.contains(flag);
}

/// One chip in the grid.
class BadgeView {
  const BadgeView({
    required this.id,
    required this.emoji,
    required this.title,
    required this.description,
    required this.unlocked,
    this.progress,
    this.stack,
    this.weight = 1,
  });

  final String id;
  final String emoji;
  final String title;
  final String description;
  final bool unlocked;

  /// Dialog footer: a celebration line when unlocked, the next step when not.
  final String? progress;

  /// Shown as an "xN" overlay when greater than 1.
  final int? stack;

  /// How many badges this chip adds to the collected total when unlocked.
  /// Repeatable badges (Popular, Viral, QOTD Star, Popcorn Time) count once
  /// per time they were earned; everything else counts once.
  final int weight;
}

class BadgeSection {
  const BadgeSection(this.title, this.badges);
  final String title;
  final List<BadgeView> badges;
}

/// The total shown under "Camo Collection". Sums exactly the chips the grid
/// renders, so the number always matches what the user can see.
int countCollectedBadges(List<BadgeSection> sections) {
  var total = 0;
  for (final section in sections) {
    for (final badge in section.badges) {
      if (badge.unlocked) total += badge.weight;
    }
  }
  return total;
}

class _Tier {
  const _Tier(this.threshold, this.emoji, this.title, this.description);
  final int threshold;
  final String emoji;
  final String title;
  final String description;
}

/// A progressive ladder: every earned tier is shown (and counts), followed by
/// the next tier as a locked goal. Once the top tier is earned there is no
/// goal left to show.
List<BadgeView> _ladder({
  required String idPrefix,
  required int value,
  required List<_Tier> tiers,
  required String Function(int threshold) goal,
  required String Function(int value) current,
}) {
  final out = <BadgeView>[];
  for (final tier in tiers) {
    final id = '${idPrefix}_${tier.threshold}';
    if (value >= tier.threshold) {
      out.add(BadgeView(
        id: id,
        emoji: tier.emoji,
        title: tier.title,
        description: tier.description,
        unlocked: true,
        progress: current(value),
      ));
    } else {
      final soFar = value > 0 ? ' ($value so far)' : '';
      out.add(BadgeView(
        id: id,
        emoji: tier.emoji,
        title: tier.title,
        description: tier.description,
        unlocked: false,
        progress: '${goal(tier.threshold)}$soFar',
      ));
      break; // only the next goal, never the whole ladder
    }
  }
  return out;
}

String _plural(int n, String one, [String? many]) =>
    n == 1 ? '$n $one' : '$n ${many ?? '${one}s'}';

/// A badge that can be earned more than once. Weight follows the count.
BadgeView _repeatable({
  required String id,
  required String emoji,
  required String title,
  required String description,
  required int count,
  required String lockedHint,
  String Function(int count)? unlockedProgress,
}) {
  if (count <= 0) {
    return BadgeView(
      id: id,
      emoji: emoji,
      title: title,
      description: description,
      unlocked: false,
      progress: lockedHint,
    );
  }
  return BadgeView(
    id: id,
    emoji: emoji,
    title: title,
    description: description,
    unlocked: true,
    progress: unlockedProgress != null
        ? unlockedProgress(count)
        : (count == 1 ? 'Achievement unlocked!' : 'Achieved $count times'),
    stack: count,
    weight: count,
  );
}

/// Unlocked chips first, then locked goals (the Dec 2025 ordering rule).
BadgeSection _section(String title, List<BadgeView> badges) {
  final unlocked = badges.where((b) => b.unlocked).toList();
  final locked = badges.where((b) => !b.unlocked).toList();
  return BadgeSection(title, [...unlocked, ...locked]);
}

List<BadgeSection> buildBadgeSections(BadgeStats s) {
  final sections = <BadgeSection>[
    _section('Question Hunter', _questionBadges(s)),
    if (s.isSignedIn) _section('Friends', _friendBadges(s)),
    _section('Comments', _commentBadges(s)),
    _section('Reactions', _reactionBadges(s)),
    _section('RTR Community', _communityBadges(s)),
  ];
  final legacy = _legacyLocalBadges(s);
  if (legacy.isNotEmpty) sections.add(BadgeSection('Legacy', legacy));
  return sections.where((section) => section.badges.isNotEmpty).toList();
}

List<BadgeView> _questionBadges(BadgeStats s) {
  final out = <BadgeView>[];

  // Posting is a single badge with a posts overlay; it counts once, otherwise
  // every post would be a badge.
  out.add(s.postedCount > 0
      ? BadgeView(
          id: 'not_a_lurker',
          emoji: '❓',
          title: 'Not a lurker!',
          description: 'Posted a question',
          unlocked: true,
          progress: 'Total posted: ${_plural(s.postedCount, 'question')}',
          stack: s.postedCount > 1 ? s.postedCount : null,
        )
      : const BadgeView(
          id: 'not_a_lurker',
          emoji: '❓',
          title: 'Not a lurker!',
          description: 'Posted a question',
          unlocked: false,
          progress: 'Post your first question to unlock',
        ));

  out.addAll(_ladder(
    idPrefix: 'answered',
    value: s.answeredCount,
    tiers: const [
      _Tier(10, '10✅', 'Getting Started', 'Answered 10+ questions'),
      _Tier(100, '💯✅', 'Century Club', 'Answered 100+ questions'),
      _Tier(1000, '✅🏆', 'Answer Champion', 'Answered 1000+ questions'),
    ],
    goal: (t) => 'Answer $t questions to unlock',
    current: (v) => 'Current: ${_plural(v, 'answer')}',
  ));

  out.add(_repeatable(
    id: 'popular_question',
    emoji: '🎤',
    title: 'Popular Question',
    description: 'Your question reached 100+ responses',
    count: s.popularQuestionCount,
    lockedHint: 'Get 100+ responses on a question',
  ));
  out.add(_repeatable(
    id: 'viral_question',
    emoji: '🧿',
    title: 'Viral Question',
    description: 'Your question reached 500+ responses',
    count: s.viralQuestionCount,
    lockedHint: 'Get 500+ responses on a question',
  ));

  // QOTD Star: the flag keeps it unlocked if the history fetch fails.
  final qotd = s.qotdCount > 0 ? s.qotdCount : (s.has(BadgeFlags.qotdStar) ? 1 : 0);
  out.add(_repeatable(
    id: 'qotd_star',
    emoji: '📅⭐',
    title: 'QOTD Star',
    description: 'Your post became Question of the Day',
    count: qotd,
    lockedHint: 'Get your question featured as QOTD',
    unlockedProgress: (n) =>
        n == 1 ? 'You have had 1 QOTD' : 'You have had $n QOTDs',
  ));

  return out;
}

List<BadgeView> _friendBadges(BadgeStats s) => _ladder(
      idPrefix: 'friends',
      value: s.friendCount,
      tiers: const [
        _Tier(5, '🤝', 'Small Circle', 'Added 5 friends'),
        _Tier(10, '👯', 'Squad Goals', 'Added 10 friends'),
        _Tier(25, '🎉', 'Party Starter', 'Added 25 friends'),
        _Tier(50, '🏟️', 'Full House', 'Added 50 friends'),
        _Tier(100, '🦋', 'Social Butterfly', 'Added 100 friends'),
      ],
      goal: (t) => 'Add $t friends to unlock',
      current: (v) => 'Friends: $v',
    );

List<BadgeView> _commentBadges(BadgeStats s) {
  final out = <BadgeView>[];
  out.addAll(_ladder(
    idPrefix: 'comments',
    value: s.commentCount,
    tiers: const [
      _Tier(1, '💬', 'First Words', 'Posted a comment'),
      _Tier(10, '🗣️', 'Chatterbox', 'Posted 10+ comments'),
      _Tier(50, '🎙️', 'Town Crier', 'Posted 50+ comments'),
      _Tier(100, '🏛️', 'Debate Club', 'Posted 100+ comments'),
    ],
    goal: (t) => t == 1
        ? 'Post a comment to unlock'
        : 'Post $t comments to unlock',
    current: (v) => 'Comments posted: $v',
  ));

  // Lizzy ladder on the best single comment. Old sticky flags act as floors.
  var lizzies = s.maxLizziesOnOneComment;
  if (s.has(BadgeFlags.dinoLizzy) && lizzies < 50) lizzies = 50;
  if (s.has(BadgeFlags.dragonLizzy) && lizzies < 10) lizzies = 10;
  if (s.has(BadgeFlags.firstLizzy) && lizzies < 1) lizzies = 1;
  // Only offer lizzy goals once the user has commented at all.
  if (s.commentCount > 0 || lizzies > 0) {
    out.addAll(_ladder(
      idPrefix: 'lizzies',
      value: lizzies,
      tiers: const [
        _Tier(1, '🦎💬', 'First Lizzy', 'Your comment got a lizzy'),
        _Tier(10, '🦎🐉', 'Dragon Lizzy', 'A comment of yours got 10+ lizzies'),
        _Tier(50, '🦎🦕', 'Dino Lizzy', 'A comment of yours got 50+ lizzies'),
      ],
      goal: (t) => t == 1
          ? 'Get a lizzy on one of your comments'
          : 'Get $t lizzies on one comment',
      current: (v) => 'Best comment: ${_plural(v, 'lizzy', 'lizzies')}',
    ));
  }

  var popcorn = s.popcornQuestionCount;
  if (popcorn == 0 && s.has(BadgeFlags.popcornTime)) popcorn = 1;
  out.add(_repeatable(
    id: 'popcorn_time',
    emoji: '🍿',
    title: 'Popcorn Time!',
    description: 'Your question received 5+ comments',
    count: popcorn,
    lockedHint: 'Get 5+ comments on a question',
  ));
  return out;
}

List<BadgeView> _reactionBadges(BadgeStats s) {
  final out = <BadgeView>[];
  out.addAll(_ladder(
    idPrefix: 'reactions_given',
    value: s.reactionsGiven,
    tiers: const [
      _Tier(1, '😮', 'First React', 'Reacted to a question'),
      _Tier(25, '🎭', 'Expressive', 'Left 25+ reactions'),
      _Tier(100, '🌈', 'Emoji Artist', 'Left 100+ reactions'),
      _Tier(500, '🎆', 'Reaction Machine', 'Left 500+ reactions'),
    ],
    goal: (t) => t == 1
        ? 'React to a question to unlock'
        : 'Leave $t reactions to unlock',
    current: (v) => 'Reactions left: $v',
  ));
  // Reactions received only make sense once the user has posted.
  if (s.postedCount > 0 || s.reactionsReceived > 0) {
    out.addAll(_ladder(
      idPrefix: 'reactions_received',
      value: s.reactionsReceived,
      tiers: const [
        _Tier(10, '👏', 'Crowd Pleaser', 'Your questions got 10+ reactions'),
        _Tier(100, '🙌', 'Standing Ovation', 'Your questions got 100+ reactions'),
      ],
      goal: (t) => 'Get $t reactions on your questions',
      current: (v) => 'Reactions on your questions: $v',
    ));
  }
  return out;
}

List<BadgeView> _communityBadges(BadgeStats s) {
  final out = <BadgeView>[];
  final created = s.accountCreatedAt;

  if (created != null) {
    out.add(BadgeView(
      id: 'hatchling',
      emoji: '🐣',
      title: 'Hatchling',
      description:
          'Authenticated as human on ${created.day}/${created.month}/${created.year}',
      unlocked: true,
      progress: 'Achievement unlocked!',
    ));
  }

  // Tester badges only ever appear once earned; there is no goal to chase.
  final alpha = s.has(BadgeFlags.alphaTester) ||
      (created != null && created.isBefore(kAlphaTesterCutoff));
  if (alpha) {
    out.add(const BadgeView(
      id: 'alpha_tester',
      emoji: '🧪🐣',
      title: 'Alpha Tester',
      description: 'User created before July 21 2025',
      unlocked: true,
      progress: 'Achievement unlocked!',
    ));
  }
  final beta = s.has(BadgeFlags.betaTester) ||
      (created != null && created.isBefore(kBetaTesterCutoff));
  if (beta) {
    out.add(const BadgeView(
      id: 'beta_tester',
      emoji: '🐝🔧',
      title: 'Beta Tester',
      description: 'User created before Sept 1 2025',
      unlocked: true,
      progress: 'Achievement unlocked!',
    ));
  }

  final birthday = s.postedInNovember || s.has(BadgeFlags.birthdayBuddy);
  out.add(BadgeView(
    id: 'birthday_buddy',
    emoji: '🎂',
    title: 'Birthday Buddy',
    description: "Posted a question during RTR's birthday month",
    unlocked: birthday,
    progress: birthday ? 'Achievement unlocked!' : 'Post a question in November',
  ));

  out.add(BadgeView(
    id: 'call_me_beep_me',
    emoji: '🦎📡',
    title: 'Call me, beep me',
    description: 'Enabled notifications for new Questions of the Day',
    unlocked: s.qotdNotificationsOn,
    progress: s.qotdNotificationsOn
        ? 'Achievement unlocked!'
        : 'Turn on Question of the Day notifications in Settings',
  ));
  return out;
}

/// Retired city/country badges: earned ones stay, nothing new is offered.
List<BadgeView> _legacyLocalBadges(BadgeStats s) {
  BadgeView earned(String id, String emoji, String title, String description) =>
      BadgeView(
        id: id,
        emoji: emoji,
        title: title,
        description: description,
        unlocked: true,
        progress: 'Legacy badge, no longer awarded',
      );

  return [
    if (s.has(BadgeFlags.plantingSeed) || s.legacyCityQuestions > 0)
      earned('planting_seed', '🏠', 'Asking My Neighbours',
          'Posted a city-targeted question'),
    if (s.has(BadgeFlags.communityBuilding) || s.legacyCityQuestions >= 5)
      earned('community_building', '🏘️', 'Community Building',
          'Posted 5+ city-targeted questions'),
    if (s.has(BadgeFlags.localLegend) || s.legacyUniqueCities >= 3)
      earned('local_legend', '🏆', 'Local Legend',
          'Posted questions in 3+ different cities'),
    if (s.has(BadgeFlags.globalSeed) || s.legacyCountryQuestions > 0)
      earned('global_seed', '🗺️', 'Global Seed',
          'Posted a country-targeted question'),
    if (s.has(BadgeFlags.globalCommunity) || s.legacyCountryQuestions >= 5)
      earned('global_community', '🇺🇳', 'Global Community',
          'Posted 5+ country-targeted questions'),
  ];
}
