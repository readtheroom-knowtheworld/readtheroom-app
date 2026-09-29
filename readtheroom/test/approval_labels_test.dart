// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// WP-B: approval slider end labels read out of question_options, defaulting
// per-end so every pre-existing approval question renders unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/approval_labels.dart';

Map<String, dynamic> _question(Object? options) => {
      'id': 'q1',
      'type': 'approval_rating',
      if (options != null) 'question_options': options,
    };

void main() {
  group('approvalLabelsFrom — fallbacks', () {
    test('null question → defaults', () {
      expect(approvalLabelsFrom(null), ApprovalLabels.defaults);
    });

    test('no question_options key → defaults (every legacy question)', () {
      expect(approvalLabelsFrom(_question(null)), ApprovalLabels.defaults);
    });

    test('empty list → defaults (the seeded QOTD bank)', () {
      expect(approvalLabelsFrom(_question(const [])), ApprovalLabels.defaults);
    });

    test('non-list junk → defaults', () {
      expect(approvalLabelsFrom(_question('nonsense')), ApprovalLabels.defaults);
    });

    test('defaults are "Disapprove" / "Approve"', () {
      expect(ApprovalLabels.defaults.low, 'Disapprove');
      expect(ApprovalLabels.defaults.high, 'Approve');
      expect(ApprovalLabels.defaults.isDefault, isTrue);
    });
  });

  group('approvalLabelsFrom — authored labels', () {
    test('sort_order 0 is the low end, 1 the high end', () {
      final labels = approvalLabelsFrom(_question([
        {'option_text': 'Too cold', 'sort_order': 0},
        {'option_text': 'Too hot', 'sort_order': 1},
      ]));
      expect(labels.low, 'Too cold');
      expect(labels.high, 'Too hot');
      expect(labels.isDefault, isFalse);
    });

    test('row order in the list does not matter', () {
      final labels = approvalLabelsFrom(_question([
        {'option_text': 'Too hot', 'sort_order': 1},
        {'option_text': 'Too cold', 'sort_order': 0},
      ]));
      expect(labels.low, 'Too cold');
      expect(labels.high, 'Too hot');
    });

    test('only one end authored → the other falls back', () {
      final labels = approvalLabelsFrom(_question([
        {'option_text': 'Hate it', 'sort_order': 0},
      ]));
      expect(labels.low, 'Hate it');
      expect(labels.high, kDefaultApprovalHighLabel);
    });

    test('rows without sort_order are read positionally', () {
      final labels = approvalLabelsFrom(_question([
        {'option_text': 'Nope'},
        {'option_text': 'Yep'},
      ]));
      expect(labels.low, 'Nope');
      expect(labels.high, 'Yep');
    });

    test('string sort_order values still parse', () {
      final labels = approvalLabelsFrom(_question([
        {'option_text': 'Nope', 'sort_order': '0'},
        {'option_text': 'Yep', 'sort_order': '1'},
      ]));
      expect(labels.low, 'Nope');
      expect(labels.high, 'Yep');
    });

    test('blank / whitespace rows fall back instead of rendering empty', () {
      final labels = approvalLabelsFrom(_question([
        {'option_text': '   ', 'sort_order': 0},
        {'option_text': '', 'sort_order': 1},
      ]));
      expect(labels, ApprovalLabels.defaults);
    });

    test('labels are trimmed and clamped to the authoring limit', () {
      final long = 'x' * 40;
      final labels = approvalLabelsFrom(_question([
        {'option_text': '  padded  ', 'sort_order': 0},
        {'option_text': long, 'sort_order': 1},
      ]));
      expect(labels.low, 'padded');
      expect(labels.high.length, kApprovalLabelMaxLength);
    });

    test('extra option rows (sort_order ≥ 2) are ignored', () {
      final labels = approvalLabelsFrom(_question([
        {'option_text': 'Low', 'sort_order': 0},
        {'option_text': 'High', 'sort_order': 1},
        {'option_text': 'Stray', 'sort_order': 2},
      ]));
      expect(labels.low, 'Low');
      expect(labels.high, 'High');
    });

    test('non-map rows are skipped', () {
      final labels = approvalLabelsFrom(_question([
        'garbage',
        {'option_text': 'High', 'sort_order': 1},
      ]));
      expect(labels.low, kDefaultApprovalLowLabel);
      expect(labels.high, 'High');
    });
  });

  group('normalizeApprovalLabel', () {
    test('null / blank → fallback', () {
      expect(normalizeApprovalLabel(null, fallback: 'F'), 'F');
      expect(normalizeApprovalLabel('', fallback: 'F'), 'F');
      expect(normalizeApprovalLabel('  \n ', fallback: 'F'), 'F');
    });

    test('trims and clamps', () {
      expect(normalizeApprovalLabel(' ok ', fallback: 'F'), 'ok');
      expect(
        normalizeApprovalLabel('a' * 25, fallback: 'F').length,
        kApprovalLabelMaxLength,
      );
    });

    test('the authoring limit is 20 characters', () {
      expect(kApprovalLabelMaxLength, 20);
    });
  });
}
