// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/approval_labels.dart';
import 'package:read_the_room/src/widgets/approval_dot_plot.dart';
import 'package:read_the_room/src/widgets/approval_spectrum_legend.dart';

Widget _host(Widget child, {double width = 360}) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: child)),
      ),
    );

void main() {
  const custom = ApprovalLabels(low: 'Way too cold', high: 'Way too hot');

  testWidgets('defaults to Disapprove / Approve', (tester) async {
    await tester.pumpWidget(_host(const ApprovalSpectrumLegend()));
    expect(find.text('Disapprove'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('shows the question\'s own end labels, no thumbs',
      (tester) async {
    await tester.pumpWidget(_host(const ApprovalSpectrumLegend(labels: custom)));
    expect(find.text('Way too cold'), findsOneWidget);
    expect(find.text('Way too hot'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up), findsNothing);
    expect(find.byIcon(Icons.thumb_down), findsNothing);
  });

  testWidgets('20-character labels fit a narrow phone without overflow',
      (tester) async {
    const long = ApprovalLabels(
        low: 'Abcdefghijklmnopqrst', high: 'Abcdefghijklmnopqrsz');
    await tester
        .pumpWidget(_host(const ApprovalSpectrumLegend(labels: long), width: 280));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dot plot carries the spectrum with the question labels',
      (tester) async {
    await tester.pumpWidget(_host(const ApprovalDotPlot(
      values: [-1, -0.5, 0, 0.4, 1],
      average: -0.02,
      labels: custom,
    )));
    await tester.pumpAndSettle();
    expect(find.byType(ApprovalSpectrumLegend), findsOneWidget);
    expect(find.text('Way too cold'), findsOneWidget);
    expect(find.text('Way too hot'), findsOneWidget);
  });
}
