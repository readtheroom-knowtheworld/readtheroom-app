// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Settings screen's notification section: the permission status row across
// the OS permission states, plus the compact toggle rows that replaced the
// section's `SwitchListTile` + indented-time-picker blocks (2026-09-17).
//
// `SettingsScreen` itself cannot be pumped (it touches `Supabase.instance` in
// `initState` and `build` — the same documented gap as `OnboardingScreen`), so
// both state-dependent parts are their own widgets: the header is driven by the
// pure `notificationSettingsUiState`, and each row is a
// `NotificationSettingsTile` the screen configures. The fake "permission
// source" is therefore just the `OsNotificationPermission` value passed in.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/post_answer_prompt_logic.dart';
import 'package:read_the_room/src/widgets/notification_permission_status_row.dart';
import 'package:read_the_room/src/widgets/notification_settings_tile.dart';

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    required OsNotificationPermission osStatus,
    bool isAuthenticated = true,
    VoidCallback? onOpenSettings,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationPermissionStatusRow(
            state: notificationSettingsUiState(
              isAuthenticated: isAuthenticated,
              osStatus: osStatus,
            ),
            onOpenSettings: onOpenSettings,
          ),
        ),
      ),
    );
  }

  final deniedRow = find.byKey(const Key(kNotificationStatusDeniedKey));
  final notDeterminedRow =
      find.byKey(const Key(kNotificationStatusNotDeterminedKey));
  final openSettings = find.byKey(const Key(kNotificationOpenSettingsKey));

  group('granted', () {
    testWidgets('renders nothing — the toggles speak for themselves',
        (tester) async {
      await pumpRow(tester, osStatus: OsNotificationPermission.authorized);
      expect(deniedRow, findsNothing);
      expect(notDeterminedRow, findsNothing);
    });

    testWidgets('provisional is granted too (iOS delivers quietly)',
        (tester) async {
      await pumpRow(tester, osStatus: OsNotificationPermission.provisional);
      expect(deniedRow, findsNothing);
      expect(notDeterminedRow, findsNothing);
    });
  });

  group('OS-denied', () {
    testWidgets('explains that the OS is the blocker, not the app',
        (tester) async {
      await pumpRow(
        tester,
        osStatus: OsNotificationPermission.denied,
        onOpenSettings: () {},
      );
      expect(deniedRow, findsOneWidget);
      expect(notDeterminedRow, findsNothing);
      expect(
        find.textContaining('off in your device Settings'),
        findsOneWidget,
      );
    });

    testWidgets('offers Open Settings and fires the callback', (tester) async {
      var taps = 0;
      await pumpRow(
        tester,
        osStatus: OsNotificationPermission.denied,
        onOpenSettings: () => taps++,
      );
      expect(openSettings, findsOneWidget);
      await tester.tap(openSettings);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('no callback means no button, but the explanation stays',
        (tester) async {
      await pumpRow(tester, osStatus: OsNotificationPermission.denied);
      expect(deniedRow, findsOneWidget);
      expect(openSettings, findsNothing);
    });
  });

  group('not determined', () {
    testWidgets('says a toggle will ask, and offers no Settings button',
        (tester) async {
      await pumpRow(
        tester,
        osStatus: OsNotificationPermission.notDetermined,
        onOpenSettings: () {},
      );
      expect(notDeterminedRow, findsOneWidget);
      expect(deniedRow, findsNothing);
      expect(openSettings, findsNothing);
    });

    testWidgets('an unreadable status renders the same hint, never the denied '
        'banner', (tester) async {
      await pumpRow(tester, osStatus: OsNotificationPermission.unknown);
      expect(notDeterminedRow, findsOneWidget);
      expect(deniedRow, findsNothing);
    });
  });

  group('guest', () {
    testWidgets('says nothing — the toggles are behind the auth dialog',
        (tester) async {
      await pumpRow(
        tester,
        isAuthenticated: false,
        osStatus: OsNotificationPermission.denied,
        onOpenSettings: () {},
      );
      expect(deniedRow, findsNothing);
      expect(notDeterminedRow, findsNothing);
    });
  });

  // ------------------------------------------------- condensed toggle rows
  group('NotificationSettingsTile (condensed section, 2026-09-17)', () {
    Future<void> pumpTile(
      WidgetTester tester, {
      required bool value,
      String? chipLabel,
      ValueChanged<bool>? onChanged,
      VoidCallback? onChipTap,
      bool emphasised = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationSettingsTile(
              id: 'qotd',
              icon: Icons.today,
              title: 'Question of the Day',
              subtitle: 'A nudge when today\'s question lands.',
              value: value,
              chipLabel: chipLabel,
              onChipTap: onChipTap,
              emphasised: emphasised,
              onChanged: onChanged ?? (_) {},
            ),
          ),
        ),
      );
    }

    final toggle = find.byKey(Key(notificationToggleKey('qotd')));
    final chip = find.byKey(Key(notificationChipKey('qotd')));

    testWidgets('is one row: title, one short line, and a switch',
        (tester) async {
      await pumpTile(tester, value: true);
      expect(find.text('Question of the Day'), findsOneWidget);
      expect(find.text('A nudge when today\'s question lands.'), findsOneWidget);
      expect(toggle, findsOneWidget);
      // The old section put the time picker in a second indented ListTile; with
      // no chip supplied there is nothing below the row at all.
      expect(chip, findsNothing);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('reports the switch value and fires onChanged', (tester) async {
      final taps = <bool>[];
      await pumpTile(tester, value: false, onChanged: taps.add);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pump();
      expect(taps, [true]);
    });

    testWidgets('the time picker is an inline chip, not a separate block',
        (tester) async {
      var chipTaps = 0;
      await pumpTile(
        tester,
        value: true,
        chipLabel: '9:00 AM',
        onChipTap: () => chipTaps++,
      );
      expect(chip, findsOneWidget);
      expect(find.text('9:00 AM'), findsOneWidget);
      // The chip sits on the same row as the switch.
      expect(tester.getCenter(chip).dy, tester.getCenter(toggle).dy);
      await tester.tap(chip);
      await tester.pump();
      expect(chipTaps, 1);
    });

    testWidgets('the master row is emphasised but is still a plain switch row',
        (tester) async {
      await pumpTile(tester, value: true, emphasised: true);
      expect(toggle, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // --------------------------------------------------- master toggle state
  group('notificationsMasterEnabled', () {
    test('on while anything can still arrive', () {
      expect(
        notificationsMasterEnabled(
          qotd: false,
          responses: false,
          friendEvents: true,
        ),
        isTrue,
      );
      expect(
        notificationsMasterEnabled(
          qotd: true,
          responses: false,
          friendEvents: false,
        ),
        isTrue,
      );
    });

    test('off only when every category is off', () {
      expect(
        notificationsMasterEnabled(
          qotd: false,
          responses: false,
          friendEvents: false,
        ),
        isFalse,
      );
    });
  });
}
