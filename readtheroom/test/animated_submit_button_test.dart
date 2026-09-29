// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// WP-A: AnimatedSubmitButton can be fired programmatically so the tap-to-submit
// gestures (MC option tap, approval slider release) reuse the one animation
// instead of duplicating it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/widgets/animated_submit_button.dart';

void main() {
  group('AnimatedSubmitButtonController', () {
    testWidgets('trigger() runs the same onPressed as a tap', (tester) async {
      final controller = AnimatedSubmitButtonController();
      var presses = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AnimatedSubmitButton(
            controller: controller,
            onPressed: () => presses++,
            isLoading: false,
          ),
        ),
      ));

      await tester.tap(find.byType(ElevatedButton));
      expect(presses, 1);

      controller.trigger();
      await tester.pumpAndSettle();
      expect(presses, 2);

      controller.dispose();
    });

    testWidgets('trigger() is ignored while loading', (tester) async {
      final controller = AnimatedSubmitButtonController();
      var presses = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AnimatedSubmitButton(
            controller: controller,
            onPressed: () => presses++,
            isLoading: true,
          ),
        ),
      ));

      expect(controller.canTrigger, isFalse);
      controller.trigger();
      await tester.pump();
      expect(presses, 0);

      controller.dispose();
    });

    testWidgets('trigger() is ignored when disabled', (tester) async {
      final controller = AnimatedSubmitButtonController();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AnimatedSubmitButton(
            controller: controller,
            onPressed: null,
            isLoading: false,
          ),
        ),
      ));

      expect(controller.canTrigger, isFalse);
      controller.trigger(); // must not throw
      await tester.pump();

      controller.dispose();
    });

    testWidgets('trigger() after the button is gone is a no-op',
        (tester) async {
      final controller = AnimatedSubmitButtonController();
      var presses = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AnimatedSubmitButton(
            controller: controller,
            onPressed: () => presses++,
            isLoading: false,
          ),
        ),
      ));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

      expect(controller.canTrigger, isFalse);
      controller.trigger();
      await tester.pump();
      expect(presses, 0);

      controller.dispose();
    });

    testWidgets('the loading state still shows the progress animation',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AnimatedSubmitButton(onPressed: null, isLoading: true),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
    });
  });
}
