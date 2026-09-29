// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression guard for the Phase 1 Rooms UI removal (design doc §4.6). The
// rooms "My Network" filter, the rooms response-forwarding hook, and the rooms
// screens/services must stay gone. These are compile/source-level guarantees:
// the dialogs are heavyweight stateful widgets that need a full response
// dataset to pump, so we assert the removed identifiers are absent from source
// and that the deleted files no longer exist (both stable and network-free).

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'expected $path to exist');
  return file.readAsStringSync();
}

void main() {
  // The ROOMS "My Network" — a per-person list of what the people in your
  // rooms answered — stays gone. The row the dialogs carry since 2026-09-22 is
  // a different thing with the same name: the k-anonymous network aggregate
  // from `get_network_results`, which is counts only and never names anyone
  // (feature-documentation/my-network-filter-2026-09-22.md).
  group('the rooms-era "My Network" filter stays removed', () {
    for (final path in <String>[
      'lib/src/widgets/country_filter_dialog.dart',
      'lib/src/widgets/country_comparison_dialog.dart',
    ]) {
      test('$path reaches no rooms code', () {
        final source = _read(path);
        expect(source, isNot(contains('getMyNetworkResponses')));
        expect(source, isNot(contains('RoomService')));
        expect(source, isNot(contains('room_')));
      });
    }

    test('the dialogs only ever draw the aggregate slice', () {
      // A `ResultsBreakdown` is counts, averages and histograms — there is no
      // shape here that could carry a person.
      for (final path in <String>[
        'lib/src/widgets/country_filter_dialog.dart',
        'lib/src/widgets/country_comparison_dialog.dart',
      ]) {
        expect(_read(path), contains('ResultsBreakdown? networkBreakdown'));
      }
    });
  });

  group('question_service.dart has no rooms coupling', () {
    late String source;
    setUpAll(() => source = _read('lib/src/services/question_service.dart'));

    test('no getMyNetworkResponses network filter', () {
      expect(source, isNot(contains('getMyNetworkResponses')));
    });

    test('no room-sharing service hook on the response submission path', () {
      expect(source, isNot(contains('_roomSharingService')));
      expect(source, isNot(contains('RoomSharingService')));
    });
  });

  group('rooms screens/services/widgets are deleted', () {
    final deleted = <String>[
      'lib/src/screens/create_room_screen.dart',
      'lib/src/screens/join_room_screen.dart',
      'lib/src/screens/room_details_screen.dart',
      'lib/src/screens/room_settings_screen.dart',
      'lib/src/services/room_service.dart',
      'lib/src/services/room_event_service.dart',
      'lib/src/services/room_sharing_service.dart',
      'lib/src/services/activity_service.dart',
      'lib/src/widgets/my_rooms_section.dart',
    ];

    for (final path in deleted) {
      test('$path no longer exists', () {
        expect(File(path).existsSync(), isFalse);
      });
    }
  });
}
