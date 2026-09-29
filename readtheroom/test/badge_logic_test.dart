// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Camo Collection badge catalog (2026-09-28 audit): one catalog feeds both the
// grid and the "N badges collected" counter.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/badge_logic.dart';

BadgeSection? _section(List<BadgeSection> sections, String title) {
  for (final s in sections) {
    if (s.title == title) return s;
  }
  return null;
}

List<String> _ids(BadgeSection? section, {bool? unlocked}) => (section?.badges ?? [])
    .where((b) => unlocked == null || b.unlocked == unlocked)
    .map((b) => b.id)
    .toList();

void main() {
  group('counter', () {
    test('counts exactly the unlocked chips, with repeatable weights', () {
      final sections = buildBadgeSections(const BadgeStats(
        isSignedIn: true,
        postedCount: 7, // Not a lurker counts once despite the x7 overlay
        answeredCount: 150, // Getting Started + Century Club
        popularQuestionCount: 2, // weight 2
        qotdCount: 3, // weight 3
        friendCount: 12, // 5 + 10
        commentCount: 1, // First Words
        qotdNotificationsOn: true, // Call me, beep me
      ));
      var manual = 0;
      for (final s in sections) {
        for (final b in s.badges) {
          if (b.unlocked) manual += b.weight;
        }
      }
      expect(countCollectedBadges(sections), manual);
      expect(countCollectedBadges(sections), 1 + 2 + 2 + 3 + 2 + 1 + 1);
    });

    test('a brand-new guest has nothing collected', () {
      expect(countCollectedBadges(buildBadgeSections(const BadgeStats())), 0);
    });

    test('retired room flags are not part of the catalog at all', () {
      final sections = buildBadgeSections(const BadgeStats(
        isSignedIn: true,
        earnedFlags: {'youre_invited', 'room_founder', 'turned_the_key', 'networker'},
      ));
      expect(countCollectedBadges(sections), 0);
    });
  });

  group('friends', () {
    test('tiers are 5/10/25/50/100', () {
      expect(kFriendTiers, [5, 10, 25, 50, 100]);
    });

    test('shows every earned tier plus the next goal', () {
      final friends = _section(
          buildBadgeSections(const BadgeStats(isSignedIn: true, friendCount: 27)),
          'Friends');
      expect(_ids(friends, unlocked: true), ['friends_5', 'friends_10', 'friends_25']);
      expect(_ids(friends, unlocked: false), ['friends_50']);
      expect(friends!.badges.last.progress, 'Add 50 friends to unlock (27 so far)');
    });

    test('no goal left once 100 friends is reached', () {
      final friends = _section(
          buildBadgeSections(const BadgeStats(isSignedIn: true, friendCount: 140)),
          'Friends');
      expect(_ids(friends, unlocked: false), isEmpty);
      expect(_ids(friends, unlocked: true).length, 5);
    });

    test('with no friends yet the first goal omits the zero', () {
      final friends =
          _section(buildBadgeSections(const BadgeStats(isSignedIn: true)), 'Friends');
      expect(friends!.badges.single.progress, 'Add 5 friends to unlock');
    });

    test('hidden for guests, who cannot add friends', () {
      expect(_section(buildBadgeSections(const BadgeStats()), 'Friends'), isNull);
    });
  });

  group('comments and reactions', () {
    test('comment ladder and lizzy goals appear after the first comment', () {
      final comments = _section(
          buildBadgeSections(const BadgeStats(commentCount: 12, maxLizziesOnOneComment: 3)),
          'Comments');
      expect(_ids(comments, unlocked: true),
          ['comments_1', 'comments_10', 'lizzies_1']);
      expect(_ids(comments, unlocked: false),
          ['comments_50', 'lizzies_10', 'popcorn_time']);
    });

    test('no lizzy goal before the user has ever commented', () {
      final comments = _section(buildBadgeSections(const BadgeStats()), 'Comments');
      expect(_ids(comments), ['comments_1', 'popcorn_time']);
    });

    test('old lizzy flags still count as earned', () {
      final comments = _section(
          buildBadgeSections(const BadgeStats(earnedFlags: {BadgeFlags.dragonLizzy})),
          'Comments');
      expect(_ids(comments, unlocked: true), ['lizzies_1', 'lizzies_10']);
    });

    test('popcorn time stacks per question', () {
      final popcorn = _section(
              buildBadgeSections(const BadgeStats(popcornQuestionCount: 4)), 'Comments')!
          .badges
          .firstWhere((b) => b.id == 'popcorn_time');
      expect(popcorn.unlocked, isTrue);
      expect(popcorn.weight, 4);
      expect(popcorn.stack, 4);
    });

    test('reactions given ladder, received only once the user has posted', () {
      final none = _section(buildBadgeSections(const BadgeStats()), 'Reactions');
      expect(_ids(none), ['reactions_given_1']);

      final some = _section(
          buildBadgeSections(const BadgeStats(
              postedCount: 1, reactionsGiven: 30, reactionsReceived: 12)),
          'Reactions');
      expect(_ids(some, unlocked: true),
          ['reactions_given_1', 'reactions_given_25', 'reactions_received_10']);
      expect(_ids(some, unlocked: false),
          ['reactions_given_100', 'reactions_received_100']);
    });
  });

  group('legacy city/country badges', () {
    test('never offered as goals', () {
      expect(_section(buildBadgeSections(const BadgeStats(isSignedIn: true)), 'Legacy'),
          isNull);
    });

    test('earned ones are kept in a Legacy section and still count', () {
      final sections = buildBadgeSections(const BadgeStats(
        legacyCityQuestions: 6,
        legacyUniqueCities: 1,
        earnedFlags: {BadgeFlags.globalSeed},
      ));
      final legacy = _section(sections, 'Legacy');
      expect(_ids(legacy), ['planting_seed', 'community_building', 'global_seed']);
      expect(legacy!.badges.every((b) => b.unlocked), isTrue);
      expect(sections.last.title, 'Legacy');
    });
  });

  group('community', () {
    test('Call me, beep me follows the QOTD notification toggle', () {
      BadgeView beep(bool on) => _section(
              buildBadgeSections(BadgeStats(qotdNotificationsOn: on)), 'RTR Community')!
          .badges
          .firstWhere((b) => b.id == 'call_me_beep_me');
      expect(beep(true).unlocked, isTrue);
      expect(beep(false).unlocked, isFalse);
    });

    test('tester badges come from the account creation date', () {
      final ids = _ids(
          _section(
              buildBadgeSections(BadgeStats(accountCreatedAt: DateTime(2025, 8, 10))),
              'RTR Community'),
          unlocked: true);
      expect(ids, containsAll(['hatchling', 'beta_tester']));
      expect(ids, isNot(contains('alpha_tester')));
    });
  });

  group('question hunter', () {
    test('answer ladder keeps lower tiers and shows the next goal', () {
      final qh = _section(
          buildBadgeSections(const BadgeStats(answeredCount: 120)), 'Question Hunter');
      expect(_ids(qh, unlocked: true), containsAll(['answered_10', 'answered_100']));
      expect(_ids(qh, unlocked: false), contains('answered_1000'));
    });

    test('QOTD Star falls back to its flag when the history is unavailable', () {
      final qotd = _section(
              buildBadgeSections(const BadgeStats(earnedFlags: {BadgeFlags.qotdStar})),
              'Question Hunter')!
          .badges
          .firstWhere((b) => b.id == 'qotd_star');
      expect(qotd.unlocked, isTrue);
      expect(qotd.weight, 1);
    });

    test('unlocked chips come before locked ones', () {
      final qh = _section(
          buildBadgeSections(const BadgeStats(viralQuestionCount: 1)), 'Question Hunter')!;
      final firstLocked = qh.badges.indexWhere((b) => !b.unlocked);
      expect(qh.badges.skip(firstLocked).every((b) => !b.unlocked), isTrue);
      expect(qh.badges.first.id, 'viral_question');
    });
  });
}
