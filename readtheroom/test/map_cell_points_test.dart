// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The answers read lockdown (2026-09-22) changed what feeds the dot map: the
// server now sends one CELL per place with a count and a summary, where the
// client used to receive one row per answer. These tests pin the two halves of
// that change:
//
//   * pointsFromCells — one ClusterPoint per cell, carrying the cell's weight;
//   * the weighting itself — a cluster of cells must count, average, bucket and
//     rank exactly as the same answers did when each was its own point.
//
// The second half is the one that matters: if a weighted point and N unweighted
// points ever disagree, the map silently starts lying about crowd size.

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:read_the_room/src/models/question_results.dart';
import 'package:read_the_room/src/utils/map_cell_points.dart';
import 'package:read_the_room/src/utils/map_clustering.dart';

QuestionMapCells _cells(List<Map<String, dynamic>> cells) =>
    QuestionMapCells.fromJson(<String, dynamic>{
      'question_id': 'q1',
      'type': 'approval_rating',
      'options': <dynamic>[],
      'total': cells.fold<int>(0, (a, c) => a + (c['count'] as int)),
      'cells': cells,
    });

Map<String, dynamic> _cityCell({
  required String city,
  required double lat,
  required double lng,
  required int count,
  double? average,
  List<int>? bins,
  Map<String, int>? optionCounts,
  String iso = 'TST',
  String country = 'Testlandia',
}) =>
    <String, dynamic>{
      'kind': 'city',
      'city_id': 'id-$city',
      'city': city,
      'admin1': 'A1',
      'lat': lat,
      'lng': lng,
      'country_code': 'TS',
      'country_iso3': iso,
      'country': country,
      'count': count,
      'average': average,
      'bins': bins ?? <int>[0, 0, 0, 0, 0],
      'option_counts': optionCounts ?? <String, int>{},
    };

void main() {
  group('pointsFromCells', () {
    test('a city cell becomes ONE point carrying the whole cell', () {
      final points = pointsFromCells(
        _cells([
          _cityCell(
            city: 'Testville',
            lat: 10,
            lng: 20,
            count: 6,
            average: 1.0,
            bins: const [0, 0, 0, 0, 6],
          ),
        ]),
        isApproval: true,
      );

      expect(points, hasLength(1));
      final p = points.single;
      expect(p.count, 6);
      expect(p.town, 'Testville');
      expect(p.position, const LatLng(10, 20));
      expect(p.score, 1.0);
      expect(p.bins, [0, 0, 0, 0, 6]);
    });

    test('a one-answer city is still a point — no k threshold on the map', () {
      final points = pointsFromCells(
        _cells([
          _cityCell(
              city: 'Solotown',
              lat: -5,
              lng: 30,
              count: 1,
              average: 0.0,
              bins: const [0, 0, 1, 0, 0]),
        ]),
        isApproval: true,
      );
      expect(points, hasLength(1));
      expect(points.single.count, 1);
    });

    test('a multiple-choice cell carries the option histogram and its leader',
        () {
      final points = pointsFromCells(
        _cells([
          _cityCell(
            city: 'Testville',
            lat: 10,
            lng: 20,
            count: 8,
            optionCounts: const {'Yes': 5, 'No': 3},
          ),
        ]),
        isApproval: false,
      );

      final p = points.single;
      expect(p.option, 'Yes');
      expect(p.optionCounts, {'Yes': 5, 'No': 3});
      expect(p.score, isNull);
      expect(p.effectiveOptionCounts, {'Yes': 5, 'No': 3});
    });

    test('a country cell with no centroid we recognise is dropped, not drawn '
        'at (0, 0)', () {
      final points = pointsFromCells(
        _cells([
          <String, dynamic>{
            'kind': 'country',
            'city_id': null,
            'city': null,
            'admin1': null,
            'lat': null,
            'lng': null,
            'country_code': 'ZZ',
            'country_iso3': 'ZZZ', // not in the bundled centroid table
            'country': 'Nowhereland',
            'count': 3,
            'average': 0.2,
            'bins': [0, 0, 0, 3, 0],
            'option_counts': <String, dynamic>{},
          },
        ]),
        isApproval: true,
      );
      expect(points, isEmpty);
    });

    test('a zero-count cell is skipped', () {
      final points = pointsFromCells(
        _cells([_cityCell(city: 'Ghosttown', lat: 1, lng: 2, count: 0)]),
        isApproval: true,
      );
      expect(points, isEmpty);
    });
  });

  group('weighted points count the same as the answers they stand for', () {
    // Six answers at one city: one weighted point, or six plain ones.
    final weighted = <ClusterPoint>[
      const ClusterPoint(
        position: LatLng(10, 20),
        country: 'Testlandia',
        countryIso: 'TST',
        town: 'Testville',
        count: 6,
        score: 1.0,
        bins: [0, 0, 0, 0, 6],
      ),
    ];
    final plain = <ClusterPoint>[
      for (var i = 0; i < 6; i++)
        const ClusterPoint(
          position: LatLng(10, 20),
          country: 'Testlandia',
          countryIso: 'TST',
          town: 'Testville',
          score: 1.0,
        ),
    ];

    test('cluster count is answers, not members', () {
      final w = clusterPoints(weighted, 3).single;
      final p = clusterPoints(plain, 3).single;
      expect(w.count, 6);
      expect(w.count, p.count);
      expect(w.points, hasLength(1)); // one member standing for six
    });

    test('averageScore is weighted by the answers behind each point', () {
      // Two cities: six answers at +1, two at -1. Mean = (6 - 2) / 8 = 0.5.
      final cells = <ClusterPoint>[
        const ClusterPoint(
          position: LatLng(10, 20),
          country: 'Testlandia',
          countryIso: 'TST',
          count: 6,
          score: 1.0,
          bins: [0, 0, 0, 0, 6],
        ),
        const ClusterPoint(
          position: LatLng(10.0001, 20.0001),
          country: 'Testlandia',
          countryIso: 'TST',
          count: 2,
          score: -1.0,
          bins: [2, 0, 0, 0, 0],
        ),
      ];
      final cluster = clusterPoints(cells, 3).single;
      expect(cluster.count, 8);
      expect(cluster.averageScore, closeTo(0.5, 1e-9));
    });

    test('countForBucket sums the cells\' histograms', () {
      final cluster = clusterPoints(weighted, 3).single;
      expect(cluster.countForBucket(4), 6); // strongly approve
      expect(cluster.countForBucket(0), 0);
      expect(cluster.countForBucket(-1), 0); // out of range is 0, not a crash
      expect(cluster.countForBucket(9), 0);
    });

    test('a point with a score but no histogram still buckets its whole weight',
        () {
      const p = ClusterPoint(
        position: LatLng(10, 20),
        country: 'Testlandia',
        countryIso: 'TST',
        count: 4,
        score: -0.9, // strongly disapprove
      );
      expect(p.effectiveBins, [4, 0, 0, 0, 0]);
      expect(clusterPoints([p], 3).single.countForBucket(0), 4);
    });

    test('option counts and the leader aggregate across cells', () {
      final cells = <ClusterPoint>[
        const ClusterPoint(
          position: LatLng(10, 20),
          country: 'Testlandia',
          countryIso: 'TST',
          count: 5,
          option: 'Yes',
          optionCounts: {'Yes': 4, 'No': 1},
        ),
        const ClusterPoint(
          position: LatLng(10.0001, 20.0001),
          country: 'Testlandia',
          countryIso: 'TST',
          count: 4,
          option: 'No',
          optionCounts: {'No': 4},
        ),
      ];
      final cluster = clusterPoints(cells, 3).single;
      expect(cluster.count, 9);
      expect(cluster.optionCounts, {'Yes': 4, 'No': 5});
      expect(cluster.countForOption('No'), 5);
      expect(cluster.countForOption('Yes'), 4);
      expect(cluster.countForOption('Maybe'), 0);
      expect(cluster.topOption, 'No');
    });

    test('a plain point with an option but no histogram counts once per answer',
        () {
      const p = ClusterPoint(
        position: LatLng(10, 20),
        country: 'Testlandia',
        countryIso: 'TST',
        count: 3,
        option: 'Yes',
      );
      expect(p.effectiveOptionCounts, {'Yes': 3});
      expect(clusterPoints([p], 3).single.countForOption('Yes'), 3);
    });

    test('commonCountry is decided by answers, not by how many cells', () {
      final points = <ClusterPoint>[
        const ClusterPoint(
          position: LatLng(10, 20),
          country: 'Bigland',
          countryIso: 'TST',
          count: 50,
        ),
        const ClusterPoint(
          position: LatLng(10.0001, 20.0001),
          country: 'Smallland',
          countryIso: 'TST',
          count: 1,
        ),
        const ClusterPoint(
          position: LatLng(10.0002, 20.0002),
          country: 'Smallland',
          countryIso: 'TST',
          count: 1,
        ),
      ];
      // Two cells say Smallland, but fifty answers say Bigland.
      expect(clusterPoints(points, 3).single.commonCountry, 'Bigland');
    });

    test('totalResponses counts answers, not points', () {
      final points = <ClusterPoint>[
        const ClusterPoint(
            position: LatLng(10, 20), country: 'A', countryIso: 'AAA', count: 6),
        const ClusterPoint(
            position: LatLng(-33, 151), country: 'B', countryIso: 'BBB', count: 4),
      ];
      expect(points.length, 2);
      expect(totalResponses(points), 10);
      expect(totalResponses(const []), 0);
    });

    test('a heavy cell draws at the radius its answers earn, so it merges like '
        'the crowd it is', () {
      // One point of weight 12 must radius exactly like twelve coincident ones.
      const heavy = ClusterPoint(
        position: LatLng(10, 20),
        country: 'Testlandia',
        countryIso: 'TST',
        count: 12,
      );
      final plainTwelve = <ClusterPoint>[
        for (var i = 0; i < 12; i++)
          const ClusterPoint(
              position: LatLng(10, 20), country: 'Testlandia', countryIso: 'TST'),
      ];
      expect(clusterRadius(clusterPoints([heavy], 3).single.count),
          clusterRadius(clusterPoints(plainTwelve, 3).single.count));
    });
  });
}
