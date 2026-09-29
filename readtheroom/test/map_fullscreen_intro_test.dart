// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Widget tests for the full-screen dot map's "open on your country" intro:
// the map flies in to the viewer's country (and offers a 🌍 World chip back
// out) when one is set, stays on its world fit when none is, and jumps rather
// than animates under reduced motion.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:read_the_room/src/screens/map_fullscreen_screen.dart';
import 'package:read_the_room/src/utils/country_centroids.dart';
import 'package:read_the_room/src/utils/geojson_parser.dart';
import 'package:read_the_room/src/utils/map_clustering.dart';

final _points = <ClusterPoint>[
  const ClusterPoint(
    position: LatLng(23.6, 58.5),
    country: 'Oman',
    countryIso: 'OMN',
    town: 'Muscat',
    score: 0.6,
  ),
  const ClusterPoint(
    position: LatLng(48.85, 2.35),
    country: 'France',
    countryIso: 'FRA',
    town: 'Paris',
    score: -0.2,
  ),
];

Widget _app(Widget child, {bool disableAnimations = false}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: child,
        ),
      ),
    );

/// Warms the bundled basemap + centroid caches with real async I/O, so the
/// screen's own `await`s resolve inside the test's fake-async zone.
Future<void> _warmAssets(WidgetTester tester) => tester.runAsync(() async {
      await GeoJsonParser.loadCountries();
      await CountryCentroids.load();
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await GeoJsonParser.loadCountries();
    await CountryCentroids.load();
  });

  testWidgets('offers the World chip once it has zoomed to your country',
      (tester) async {
    await tester.pumpWidget(_app(MapFullscreenScreen(
      points: _points,
      isApproval: true,
      options: const [],
      questionTitle: 'Test question',
      questionId: 'q1',
      userCountryName: 'Oman',
    )));

    // First frame: still the opening world fit, no chip yet.
    expect(find.text('🌍 World'), findsNothing);

    await _warmAssets(tester);
    await tester.pump(); // country resolved
    await tester.pump(); // post-frame callback starts the fly-in
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'the intro should animate, not jump');

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('🌍 World'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('no country set keeps the opening fit and hides the chip',
      (tester) async {
    await tester.pumpWidget(_app(MapFullscreenScreen(
      points: _points,
      isApproval: true,
      options: const [],
      questionTitle: 'Test question',
      questionId: 'q1',
    )));

    await _warmAssets(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('🌍 World'), findsNothing);
  });

  testWidgets('reduced motion jumps: nothing is left animating', (tester) async {
    await tester.pumpWidget(_app(
      MapFullscreenScreen(
        points: _points,
        isApproval: true,
        options: const [],
        questionTitle: 'Test question',
        questionId: 'q1',
        userCountryName: 'Oman',
      ),
      disableAnimations: true,
    ));

    // Let the async geo load + post-frame intro run, then assert the tree is
    // quiescent immediately — a jump, not a 900 ms fly-in.
    await _warmAssets(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('🌍 World'), findsOneWidget);
  });

  testWidgets('an unknown country name leaves the map on its world fit',
      (tester) async {
    await tester.pumpWidget(_app(MapFullscreenScreen(
      points: _points,
      isApproval: true,
      options: const [],
      questionTitle: 'Test question',
      questionId: 'q1',
      userCountryName: 'Atlantis',
    )));

    await _warmAssets(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('🌍 World'), findsNothing);
  });
}
