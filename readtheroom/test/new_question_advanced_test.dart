// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Progressive-disclosure "Advanced options" section on the new-question screen.
//
// The full NewQuestionScreen tree can't be pumped in a unit test: LocationService
// and UserService construct `Supabase.instance.client` in their field
// initializers, so instantiating the providers the screen depends on throws
// without a live backend. Per the design note, the collapsed-header disclosure
// logic — the part that decides whether a non-default advanced option is shown
// while the section is collapsed — is extracted into pure static helpers on
// NewQuestionScreen (advancedOptionsSummary / hasNonDefaultAdvancedOptions) and
// is fully exercised here.
//
// Widget-level gap (documented, not covered): that the section renders as an
// ExpansionTile collapsed by default and that expanding reveals the targeting
// selector + private toggle. These require a pumpable screen (live/mocked
// Supabase) and are verified manually.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/screens/new_question_screen.dart';

void main() {
  group('Defaults are a public World question', () {
    test('globe + public discloses nothing in the collapsed header', () {
      expect(
        NewQuestionScreen.advancedOptionsSummary(
          targeting: 'globe',
          isPrivate: false,
          countryName: 'France',
          cityName: 'Paris',
        ),
        isNull,
      );
      expect(
        NewQuestionScreen.hasNonDefaultAdvancedOptions(
          targeting: 'globe',
          isPrivate: false,
        ),
        isFalse,
      );
    });
  });

  group('Non-default advanced options are reflected in the collapsed header', () {
    test('country targeting names the country', () {
      final summary = NewQuestionScreen.advancedOptionsSummary(
        targeting: 'country',
        isPrivate: false,
        countryName: 'France',
      );
      expect(summary, 'Targeted: France');
      expect(
        NewQuestionScreen.hasNonDefaultAdvancedOptions(
          targeting: 'country',
          isPrivate: false,
        ),
        isTrue,
      );
    });

    test('city targeting names the city', () {
      final summary = NewQuestionScreen.advancedOptionsSummary(
        targeting: 'city',
        isPrivate: false,
        cityName: 'Paris',
      );
      expect(summary, 'Targeted: Paris');
      expect(
        NewQuestionScreen.hasNonDefaultAdvancedOptions(
          targeting: 'city',
          isPrivate: false,
        ),
        isTrue,
      );
    });

    test('private question is disclosed even when collapsed', () {
      final summary = NewQuestionScreen.advancedOptionsSummary(
        targeting: 'globe',
        isPrivate: true,
      );
      expect(summary, 'Private question');
      expect(
        NewQuestionScreen.hasNonDefaultAdvancedOptions(
          targeting: 'globe',
          isPrivate: true,
        ),
        isTrue,
      );
    });

    test('private takes precedence over any targeting selection', () {
      // When private is toggled on, targeting is forced to city upstream, but
      // the header should read as private regardless of the targeting value.
      expect(
        NewQuestionScreen.advancedOptionsSummary(
          targeting: 'city',
          isPrivate: true,
          cityName: 'Paris',
        ),
        'Private question',
      );
    });
  });

  group('Missing location falls back gracefully', () {
    test('country targeting without a country name', () {
      expect(
        NewQuestionScreen.advancedOptionsSummary(
          targeting: 'country',
          isPrivate: false,
        ),
        'Targeted: your country',
      );
    });

    test('city targeting without a city name', () {
      expect(
        NewQuestionScreen.advancedOptionsSummary(
          targeting: 'city',
          isPrivate: false,
        ),
        'Targeted: your city',
      );
    });
  });

  // Topics are now optional: a well-formed question must validate with zero
  // categories. `submissionRequirementErrors` is the pure validation used by
  // both `_canPreview` and `_showPreviewRequirements`, so it fully covers the
  // "no category required" behaviour.
  group('Submission validation treats topics as optional', () {
    test('a valid discussion question with zero topics has no errors', () {
      final errors = NewQuestionScreen.submissionRequirementErrors(
        type: 'text',
        title: 'What should we build next for the community?',
        multipleChoiceOptionCount: 0,
      );
      expect(errors, isEmpty);
    });

    test('a valid multiple-choice question with zero topics has no errors', () {
      final errors = NewQuestionScreen.submissionRequirementErrors(
        type: 'multiple_choice',
        title: 'Which feature matters most to you?',
        multipleChoiceOptionCount: 2,
      );
      expect(errors, isEmpty);
    });

    test('validation never asks the user to add a category/topic', () {
      // Even a fully-empty draft must not surface a topic requirement.
      final errors = NewQuestionScreen.submissionRequirementErrors(
        type: '',
        title: '',
        multipleChoiceOptionCount: 0,
      );
      expect(
        errors.any((e) => e.toLowerCase().contains('categor') ||
            e.toLowerCase().contains('topic')),
        isFalse,
      );
    });

    test('genuine problems are still reported', () {
      final errors = NewQuestionScreen.submissionRequirementErrors(
        type: '',
        title: 'short',
        multipleChoiceOptionCount: 0,
      );
      expect(errors, contains('• Select a question type'));
      expect(errors, contains('• Question must be at least 10 characters long'));
    });

    test('multiple choice still requires at least two options', () {
      final errors = NewQuestionScreen.submissionRequirementErrors(
        type: 'multiple_choice',
        title: 'Which feature matters most to you?',
        multipleChoiceOptionCount: 1,
      );
      expect(errors, contains('• Add at least 2 answer options for multiple choice'));
    });

    test('titles longer than 30 words are rejected', () {
      final longTitle = List.filled(31, 'word').join(' ');
      final errors = NewQuestionScreen.submissionRequirementErrors(
        type: 'text',
        title: longTitle,
        multipleChoiceOptionCount: 0,
      );
      expect(errors.any((e) => e.contains('30 words or less')), isTrue);
    });
  });
}
