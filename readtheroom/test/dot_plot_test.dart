// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Tests for the < 30-respondent dot charts (design doc §4.3): the shared
// threshold, the approval bucket colouring at the ±0.8 / ±0.3 boundaries, and
// the MC dot-row wrapping at ~15 dots per row. The two new widgets are pumped
// directly with synthetic response data.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/dot_plot_threshold.dart';
import 'package:read_the_room/src/utils/results_colors.dart';
import 'package:read_the_room/src/widgets/approval_dot_plot.dart';
import 'package:read_the_room/src/widgets/mc_dot_row.dart';

/// Wraps [child] so it renders with animations disabled (reduced-motion),
/// which pins every dot's scale-in to its final state on the first frame.
Widget _reducedMotion(Widget child) => MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: Scaffold(
        body: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SingleChildScrollView(child: child),
        ),
      ),
    );

Finder _dotFinder() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle,
    );

void main() {
  group('kDotPlotThreshold — mode switch at exactly 30', () {
    test('threshold is 30', () {
      expect(kDotPlotThreshold, 30);
    });

    test('29 respondents use dots, 30 use the histogram/bars', () {
      // The screens switch on `filteredResponses.length < kDotPlotThreshold`.
      expect(29 < kDotPlotThreshold, isTrue); // dots
      expect(30 < kDotPlotThreshold, isFalse); // histogram / bars
      expect(31 < kDotPlotThreshold, isFalse);
    });
  });

  group('approval bucket colouring at ±0.8 / ±0.3 boundaries', () {
    testWidgets('boundary scores map to the expected 5-bucket colour',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(primaryColor: const Color(0xFF00897B)),
          home: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }),
        ),
      );

      Color bucket(double v) => ResultsColors.forApprovalBucket(ctx, v);

      // Lower bound / inclusive-boundary behaviour mirrors the screens'
      // `_binnedResponses` thresholds.
      expect(bucket(-1.0), ResultsColors.stronglyDisapprove(ctx));
      expect(bucket(-0.8), ResultsColors.stronglyDisapprove(ctx)); // boundary
      expect(bucket(-0.79), ResultsColors.disapprove(ctx));
      expect(bucket(-0.3), ResultsColors.disapprove(ctx)); // boundary
      expect(bucket(-0.29), ResultsColors.neutral(ctx));
      expect(bucket(0.0), ResultsColors.neutral(ctx));
      expect(bucket(0.3), ResultsColors.neutral(ctx)); // boundary
      expect(bucket(0.31), ResultsColors.approve(ctx));
      expect(bucket(0.8), ResultsColors.approve(ctx)); // boundary
      expect(bucket(0.81), ResultsColors.stronglyApprove(ctx));
      expect(bucket(1.0), ResultsColors.stronglyApprove(ctx));
    });
  });

  group('ApprovalDotPlot widget', () {
    testWidgets('renders a CustomPaint for a small sample', (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const SizedBox(
          width: 300,
          child: ApprovalDotPlot(
            values: [-1.0, -0.5, -0.3, 0.0, 0.3, 0.6, 1.0],
            average: 0.014,
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(ApprovalDotPlot), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byType(ApprovalDotPlot), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles a single response without error', (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const SizedBox(
          width: 300,
          child: ApprovalDotPlot(values: [0.5], average: 0.5),
        ),
      ));
      await tester.pump();
      expect(find.byType(ApprovalDotPlot), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('McDotRow — one dot per vote, wrapping at ~15/row', () {
    testWidgets('15 votes render 15 dots on a single row', (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const McDotRow(
          label: 'Option A',
          voteCount: 15,
          totalResponses: 20,
          color: Colors.red,
        ),
      ));
      await tester.pump();

      expect(_dotFinder(), findsNWidgets(15));

      final dotRows = tester
          .widgetList<Row>(find.byType(Row))
          .where((r) => r.mainAxisSize == MainAxisSize.min)
          .toList();
      expect(dotRows.length, 1);
    });

    testWidgets('16 votes wrap onto a second row', (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const McDotRow(
          label: 'Option B',
          voteCount: 16,
          totalResponses: 20,
          color: Colors.blue,
        ),
      ));
      await tester.pump();

      expect(_dotFinder(), findsNWidgets(16));

      final dotRows = tester
          .widgetList<Row>(find.byType(Row))
          .where((r) => r.mainAxisSize == MainAxisSize.min)
          .toList();
      expect(dotRows.length, 2);
    });

    testWidgets('31 votes wrap onto three rows', (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const McDotRow(
          label: 'Option C',
          voteCount: 31,
          totalResponses: 40,
          color: Colors.green,
        ),
      ));
      await tester.pump();

      expect(_dotFinder(), findsNWidgets(31));
      final dotRows = tester
          .widgetList<Row>(find.byType(Row))
          .where((r) => r.mainAxisSize == MainAxisSize.min)
          .toList();
      expect(dotRows.length, 3);
    });

    testWidgets('zero votes render no dots and show the percentage label',
        (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const McDotRow(
          label: 'Option D',
          voteCount: 0,
          totalResponses: 10,
          color: Colors.orange,
        ),
      ));
      await tester.pump();

      expect(_dotFinder(), findsNothing);
      expect(find.text('0% (0)'), findsOneWidget);
      expect(find.text('Option D'), findsOneWidget);
    });

    testWidgets('percentage label reflects vote share', (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const McDotRow(
          label: 'Option E',
          voteCount: 5,
          totalResponses: 20,
          color: Colors.purple,
        ),
      ));
      await tester.pump();
      expect(find.text('25% (5)'), findsOneWidget);
    });

    testWidgets('delayMs keeps dots at zero scale until the delay elapses',
        (tester) async {
      // Real animations (no reduced motion): with a long start delay, the
      // dots exist but are still scaled to 0 shortly after mounting.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: McDotRow(
            label: 'Delayed',
            voteCount: 3,
            totalResponses: 10,
            color: Colors.teal,
            delayMs: 1000,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // Only the Transforms wrapping actual dots (MaterialApp chrome has its
      // own unrelated Transforms). Read the X-scale matrix entry directly —
      // getMaxScaleOnAxis would report the untouched Z axis (1.0) even for a
      // zero-scaled dot.
      List<double> dotScales() => tester
          .widgetList<Transform>(find.ancestor(
            of: _dotFinder(),
            matching: find.byType(Transform),
          ))
          .map((t) => t.transform.storage[0])
          .toList();

      expect(dotScales(), everyElement(0.0));

      // After delay + fill, all dots are at full scale.
      await tester.pumpAndSettle();
      expect(dotScales(), everyElement(closeTo(1.0, 0.001)));
    });

    test('fillDurationMs mirrors the internal timing (clamped 300–1600ms)', () {
      expect(McDotRow.fillDurationMs(0), 300);
      expect(McDotRow.fillDurationMs(20), 220 + 20 * 18);
      expect(McDotRow.fillDurationMs(500), 1600);
    });
  });

  group('McResultBar — cascading percentage bar', () {
    testWidgets('grows to its widthFactor after entrance', (tester) async {
      await tester.pumpWidget(_reducedMotion(
        const McResultBar(widthFactor: 0.6, color: Colors.red),
      ));
      await tester.pump();

      final box = tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
      expect(box.widthFactor, closeTo(0.6, 0.001));
    });

    testWidgets('stays at zero width during its start delay', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: McResultBar(
            widthFactor: 0.8,
            color: Colors.blue,
            delayMs: 1000,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      final early = tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
      expect(early.widthFactor, 0.0);

      await tester.pumpAndSettle();
      final settled = tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
      expect(settled.widthFactor, closeTo(0.8, 0.001));
    });
  });
}
