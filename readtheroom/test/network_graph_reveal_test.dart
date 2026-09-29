import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/demo_network_data.dart';
import 'package:read_the_room/src/widgets/network_graph_preview.dart';

void main() {
  testWidgets('every node is fully opaque once the reveal has finished',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NetworkGraphPreview(
            data: buildDemoNetworkGraph(kDemoNetworkQuestions.first)),
      ),
    ));
    await tester.pumpAndSettle();
    final painter = tester
        .widget<CustomPaint>(find.descendant(
          of: find.byType(NetworkGraphPreview),
          matching: find.byType(CustomPaint),
        ).first)
        .painter as dynamic;
    // Exercise the painter's reveal for the latest possible start.
    expect(painter.progress, 1.0);
    expect(painter.revealForTest(0.9), 1.0);
    expect(painter.revealForTest(0.0), 1.0);
  });
}
