// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Widget-level tests for the dot painter shared by the inline preview and the
// full-screen map: dots are drawn at the three fixed radius steps, highlighting
// resizes to the highlighted answer's count, and the preview's "fit to data"
// camera still frames the data.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:read_the_room/src/utils/map_clustering.dart';
import 'package:read_the_room/src/widgets/response_dot_map.dart';

ClusterPoint _p({double? score, String? option}) => ClusterPoint(
      position: const LatLng(0, 0),
      country: 'Testland',
      countryIso: 'TST',
      score: score,
      option: option,
    );

DotCluster _cluster(int count, {String? option, double score = 0.5}) =>
    DotCluster(
      position: const LatLng(0, 0),
      points: [
        for (var i = 0; i < count; i++)
          option == null ? _p(score: score) : _p(option: option),
      ],
    );

/// Grabs a BuildContext so the theme-dependent painter can run.
Future<BuildContext> _context(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (context) {
      captured = context;
      return const SizedBox.shrink();
    }),
  ));
  return captured;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dots are drawn at the three fixed radius steps', (tester) async {
    final context = await _context(tester);
    final markers = buildDotMarkers(
      context,
      clusters: [_cluster(5), _cluster(50), _cluster(500)],
      isApproval: true,
      options: const [],
    );

    expect(markers.map((m) => m.width).toList(), [
      kDotRadiusBase * 2,
      kDotRadiusMedium * 2,
      kDotRadiusLarge * 2,
    ]);
    for (final m in markers) {
      expect(m.height, m.width);
    }
  });

  testWidgets('a highlighted answer resizes the dot to its own count',
      (tester) async {
    final context = await _context(tester);
    // 50 responses in the cluster, only 4 of them chose "Red".
    final cluster = DotCluster(
      position: const LatLng(0, 0),
      points: [
        for (var i = 0; i < 4; i++) _p(option: 'Red'),
        for (var i = 0; i < 46; i++) _p(option: 'Blue'),
      ],
    );

    final plain = buildDotMarkers(context,
        clusters: [cluster], isApproval: false, options: const ['Red', 'Blue']);
    expect(plain.single.width, kDotRadiusMedium * 2); // 50 → medium

    final highlighted = buildDotMarkers(context,
        clusters: [cluster],
        isApproval: false,
        options: const ['Red', 'Blue'],
        highlightOption: 'Red');
    expect(highlighted.single.width, kDotRadiusBase * 2); // 4 → base
  });

  testWidgets('a cluster without the highlighted answer keeps its own size',
      (tester) async {
    final context = await _context(tester);
    final markers = buildDotMarkers(context,
        clusters: [_cluster(500, option: 'Blue')],
        isApproval: false,
        options: const ['Red', 'Blue'],
        highlightOption: 'Red');
    expect(markers.single.width, kDotRadiusLarge * 2);
  });

  group('fitDotCamera — the preview still frames its data', () {
    test('no points falls back to a world-ish camera', () {
      final cam = fitDotCamera(const [], 400, 300);
      expect(cam.zoom, 0.6);
      expect(cam.center.latitude, 20);
    });

    test('a single city is capped at maxZoom, not street level', () {
      final cam = fitDotCamera([
        const ClusterPoint(
            position: LatLng(23.6, 58.5), country: 'Oman', countryIso: 'OMN'),
      ], 400, 300);
      expect(cam.zoom, 6.0);
      expect(cam.center.latitude, closeTo(23.6, 1e-6));
      expect(cam.center.longitude, closeTo(58.5, 1e-6));
    });

    test('globe-spanning data zooms out and centres between the extremes', () {
      final cam = fitDotCamera([
        const ClusterPoint(
            position: LatLng(-33.86, 151.2), country: 'A', countryIso: 'AAA'),
        const ClusterPoint(
            position: LatLng(48.85, -2.35), country: 'B', countryIso: 'BBB'),
      ], 400, 300);
      expect(cam.zoom, lessThan(2.0));
      expect(cam.center.longitude, closeTo((151.2 - 2.35) / 2, 1e-6));
    });

    test('the preview clusters at exactly the camera zoom it renders', () {
      final points = [
        const ClusterPoint(
            position: LatLng(23.6, 58.5),
            country: 'Oman',
            countryIso: 'OMN',
            town: 'Muscat'),
        const ClusterPoint(
            position: LatLng(23.61, 58.51),
            country: 'Oman',
            countryIso: 'OMN',
            town: 'Seeb'),
      ];
      final cam = fitDotCamera(points, 400, 300);
      // The preview clusters at its own fitted zoom, under the same overlap
      // rules the full-screen map applies — two neighbouring cities read as
      // one dot here, and split once the viewer zooms past it.
      final atPreview = clusterPoints(points, cam.zoom);
      expect(atPreview.length, 1);
      expect(atPreview.first.count, 2);
      expect(clusterPoints(points, cam.zoom + 6).length, 2);
    });
  });
}
