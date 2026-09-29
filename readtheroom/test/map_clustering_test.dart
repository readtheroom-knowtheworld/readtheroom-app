// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the pure-Dart *collision* dot-map clusterer and the bundled
// country-centroid fallback loader. All logic here is network-free and
// deterministic. Cities (and country-centroid fallbacks) are always the
// underlying unit; at a given zoom, two locations merge only when the circles
// actually drawn for them overlap (r(a) + r(b), three fixed radius steps), and
// never across a country boundary. Merging iterates to a fixed point, and the
// partition can still only refine (split) as the user zooms in.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:read_the_room/src/utils/map_clustering.dart';
import 'package:read_the_room/src/utils/country_centroids.dart';

ClusterPoint _p(
  double lat,
  double lng, {
  String country = 'Testland',
  String? countryIso,
  String? admin1,
  LatLng? countryCentroid,
  String? town,
  double? score,
  String? option,
}) =>
    ClusterPoint(
      position: LatLng(lat, lng),
      country: country,
      countryIso: countryIso,
      admin1: admin1,
      countryCentroid: countryCentroid,
      town: town,
      score: score,
      option: option,
    );

/// The partition induced by clustering [pts] at [zoom], as sets of indices into
/// [pts]. Relies on [clusterPoints] preserving member identity.
Set<Set<int>> _partition(List<ClusterPoint> pts, double zoom) {
  final clusters = clusterPoints(pts, zoom);
  final result = <Set<int>>{};
  for (final c in clusters) {
    final members = <int>{};
    for (final m in c.points) {
      members.add(pts.indexWhere((p) => identical(p, m)));
    }
    result.add(members);
  }
  return result;
}

/// Projected separation (logical px) of two equatorial points [dLng] degrees
/// apart at [zoom] — mirrors the clusterer's Web-Mercator projection.
double _separationPx(double dLng, double zoom) =>
    dLng / 360.0 * 256.0 * math.pow(2.0, zoom);

/// True when [fine] is a refinement of [coarse]: every fine block sits wholly
/// inside some coarse block (i.e. clustering never re-merges what it split).
bool _refines(Set<Set<int>> fine, Set<Set<int>> coarse) {
  for (final block in fine) {
    final contained = coarse.any((c) => block.every(c.contains));
    if (!contained) return false;
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('clusterPoints — determinism', () {
    test('same input + zoom produces identical output', () {
      final points = [
        _p(10.0, 10.0, score: 0.5),
        _p(10.0, 12.0, score: -0.5),
        _p(48.85, 2.35, score: 1.0),
        _p(-33.86, 151.2, score: -1.0),
        _p(40.7, -74.0, score: 0.1),
      ];

      final a = clusterPoints(points, 4.0);
      final b = clusterPoints(points, 4.0);

      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].position.latitude, b[i].position.latitude);
        expect(a[i].position.longitude, b[i].position.longitude);
        expect(a[i].count, b[i].count);
      }
    });

    test('output is independent of input order', () {
      final forward = [
        _p(34.0, -118.0, countryIso: 'USA'),
        _p(40.7, -74.0, countryIso: 'USA'),
        _p(48.85, 2.35, countryIso: 'FRA'),
      ];
      final reversed = forward.reversed.toList();

      // Zoomed in enough that all three are separate dots.
      final a = clusterPoints(forward, 6.0);
      final b = clusterPoints(reversed, 6.0);

      expect(a.length, 3);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].position.latitude, closeTo(b[i].position.latitude, 1e-12));
        expect(a[i].position.longitude, closeTo(b[i].position.longitude, 1e-12));
        expect(a[i].count, b[i].count);
      }
    });

    test('empty input yields empty output', () {
      expect(clusterPoints(const [], 1.0), isEmpty);
    });
  });

  group('clusterPoints — collision merging', () {
    test('identical city centroids always collapse into one dot at any zoom', () {
      final points = [
        _p(34.05, -118.25, town: 'LA'),
        _p(34.05, -118.25, town: 'LA'),
        // A far-away distinct city.
        _p(-33.86, 151.2, town: 'Sydney'),
      ];
      // Even fully zoomed in, the two identical-coordinate responses are one
      // leaf and cannot separate.
      final clusters = clusterPoints(points, 12.0);
      expect(clusters.length, 2);
      final la = clusters.firstWhere((c) => c.count == 2);
      expect(la.commonTown, 'LA');
      // Anchored at the shared centroid.
      expect(la.position.latitude, closeTo(34.05, 1e-9));
      expect(la.position.longitude, closeTo(-118.25, 1e-9));
    });

    test('distinct nearby cities merge far out but separate when zoomed in', () {
      final points = [
        _p(34.05, -118.25, town: 'LA'),
        _p(34.10, -118.40, town: 'Burbank'),
      ];
      // Far out: the two overlap → one blob.
      expect(clusterPoints(points, 1.0).length, 1);
      // Zoomed in: distinguishable → two individual city dots.
      expect(clusterPoints(points, 12.0).length, 2);
    });

    test('merged cluster is anchored at the member mean', () {
      final points = [
        _p(34.0, -118.0),
        _p(35.0, -120.0),
      ];
      // Far out enough to merge.
      final clusters = clusterPoints(points, 1.0);
      expect(clusters.length, 1);
      expect(clusters.first.position.latitude, closeTo(34.5, 1e-9));
      expect(clusters.first.position.longitude, closeTo(-119.0, 1e-9));
    });

    test('extra overlap padding groups more aggressively', () {
      final points = [
        _p(34.05, -118.25),
        _p(34.10, -118.40),
      ];
      // At a zoom where the drawn circles clear each other...
      expect(clusterPoints(points, 12.0).length, 2);
      // ...added slack still merges them.
      expect(clusterPoints(points, 12.0, overlapPaddingPx: 100000).length, 1);
    });

    test('dots merge exactly when their drawn circles overlap', () {
      // Two base dots (r = 7 each) sit 100 px apart at zoom 10 in projected
      // space; find the zoom either side of the 14 px overlap threshold.
      const lat = 0.0;
      // Separation in px = (Δlng / 360) * 256 * 2^zoom.
      double separationPx(double dLng, double zoom) =>
          dLng / 360.0 * 256.0 * math.pow(2.0, zoom);

      const dLng = 0.5;
      // Zoom where the pair sits just inside 2 × kDotRadiusBase.
      var overlapZoom = 0.0;
      for (var z = 0.0; z < 20; z += 0.05) {
        if (separationPx(dLng, z) >= 2 * kDotRadiusBase) break;
        overlapZoom = z;
      }
      final pair = [_p(lat, 0), _p(lat, dLng)];

      expect(separationPx(dLng, overlapZoom), lessThan(2 * kDotRadiusBase));
      expect(clusterPoints(pair, overlapZoom).length, 1,
          reason: 'circles overlap → one dot');
      expect(clusterPoints(pair, overlapZoom + 1.0).length, 2,
          reason: 'circles clear each other → two dots');
    });

    test('a big city reaches further than a small one', () {
      // 40 respondents in city A (r = 11) vs 1 in city B (r = 7): the pair
      // merges at a separation where two base-size dots would not.
      const zoom = 5.0;
      const gap = 0.70; // degrees of longitude at the equator
      final separationPx = _separationPx(gap, zoom);
      expect(separationPx, greaterThan(kDotRadiusBase + kDotRadiusBase));
      expect(separationPx, lessThan(kDotRadiusMedium + kDotRadiusBase));

      final small = [_p(0, 0), _p(0, gap)];
      final big = [
        for (var i = 0; i < 40; i++) _p(0, 0),
        _p(0, gap),
      ];
      expect(clusterPoints(small, zoom).length, 2);
      expect(clusterPoints(big, zoom).length, 1);
    });

    test('merging runs to a fixed point: a merged dot can absorb a third', () {
      // A (10) + B (1) merge into 11 → the medium step, and the grown dot then
      // reaches C, which neither A nor B could reach on its own.
      const zoom = 5.0;
      const gap = 0.70;
      expect(_separationPx(gap, zoom),
          greaterThan(kDotRadiusBase + kDotRadiusBase));
      expect(_separationPx(gap, zoom),
          lessThan(kDotRadiusMedium + kDotRadiusBase));

      final points = [
        for (var i = 0; i < 10; i++) _p(0, 0),
        _p(0, 0.02), // B — touching A
        _p(0, gap), // C — out of a base dot's reach
      ];
      // Without B, A stays base-sized and never reaches C.
      final withoutB = [
        for (var i = 0; i < 10; i++) _p(0, 0),
        _p(0, gap),
      ];
      expect(clusterPoints(withoutB, zoom).length, 2);

      final clusters = clusterPoints(points, zoom);
      expect(clusters.length, 1);
      expect(clusters.first.count, 12);
    });
  });

  group('clusterPoints — countries never combine', () {
    test('adjacent cities in different countries stay separate dots', () {
      final points = [
        _p(47.0, 8.0, country: 'Switzerland', countryIso: 'CHE', town: 'A'),
        _p(47.0, 8.0, country: 'Liechtenstein', countryIso: 'LIE', town: 'B'),
      ];
      // Identical coordinates, fully zoomed out — still two dots.
      for (final z in [0.5, 1.0, 4.0, 12.0]) {
        expect(clusterPoints(points, z).length, 2,
            reason: 'countries must never combine (zoom $z)');
      }
    });

    test('overlapping cities merge only when they share a country', () {
      // Detroit and Windsor sit a few km apart across a border.
      const detroit = [42.33, -83.05];
      const windsor = [42.28, -83.02];

      final sameCountry = [
        _p(detroit[0], detroit[1], country: 'United States', countryIso: 'USA'),
        _p(windsor[0], windsor[1], country: 'United States', countryIso: 'USA'),
      ];
      final acrossBorder = [
        _p(detroit[0], detroit[1], country: 'United States', countryIso: 'USA'),
        _p(windsor[0], windsor[1], country: 'Canada', countryIso: 'CAN'),
      ];

      expect(clusterPoints(sameCountry, 6.0).length, 1);
      expect(clusterPoints(acrossBorder, 6.0).length, 2);
    });

    test('the country name partitions when no ISO code is carried', () {
      final points = [
        _p(47.0, 8.0, country: 'Switzerland'),
        _p(47.0, 8.0, country: 'Liechtenstein'),
      ];
      expect(clusterPoints(points, 1.0).length, 2);
    });

    test('countryPartitionKey prefers the ISO code, falls back to the name',
        () {
      expect(countryPartitionKey(_p(0, 0, country: 'Oman', countryIso: 'OMN')),
          'OMN');
      expect(countryPartitionKey(_p(0, 0, country: 'Oman')), 'Oman');
      expect(countryPartitionKey(_p(0, 0, country: 'Oman', countryIso: '')),
          'Oman');
    });
  });

  group('clusterPoints — monotonic split (refinement) across zoom', () {
    test('partition at higher zoom refines the partition at lower zoom', () {
      final points = [
        _p(34.0, -118.0), // A — LA area
        _p(34.5, -118.5), // B — near A
        _p(40.7, -74.0), // C — NY area
        _p(41.0, -74.5), // D — near C
        _p(48.85, 2.35), // E — Paris
        _p(-33.86, 151.2), // F — Sydney
      ];

      const zooms = [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0];
      final partitions = [for (final z in zooms) _partition(points, z)];

      // Each successive (more zoomed-in) partition refines the previous one:
      // two points in different clusters never re-merge as we zoom in.
      for (var i = 1; i < partitions.length; i++) {
        expect(_refines(partitions[i], partitions[i - 1]), isTrue,
            reason: 'zoom ${zooms[i]} must refine zoom ${zooms[i - 1]}');
      }

      // And the split genuinely happens: fewer clusters far out, all six
      // distinct dots when fully zoomed in.
      expect(partitions.first.length, lessThan(partitions.last.length));
      expect(partitions.last.length, 6);
    });

    test('refinement survives mixed radius steps and several countries', () {
      // The property that could plausibly break under overlap-based merging:
      // clusters of different sizes (hence different reach) sitting close to
      // each other. Seeded pseudo-random so a failure is reproducible.
      final rng = math.Random(20260917);
      const countries = ['AAA', 'BBB', 'CCC'];
      final points = <ClusterPoint>[];
      for (var city = 0; city < 18; city++) {
        final lat = rng.nextDouble() * 120 - 60;
        final lng = rng.nextDouble() * 200 - 100;
        final iso = countries[city % countries.length];
        // City sizes spanning all three radius steps.
        final n = [1, 3, 9, 25, 80, 140][city % 6];
        for (var r = 0; r < n; r++) {
          points.add(_p(lat, lng, country: iso, countryIso: iso));
        }
      }

      const zooms = [0.3, 0.6, 1.0, 1.5, 2.0, 3.0, 4.0, 5.5, 7.0, 9.0, 12.0];
      final partitions = [for (final z in zooms) _partition(points, z)];
      for (var i = 1; i < partitions.length; i++) {
        expect(_refines(partitions[i], partitions[i - 1]), isTrue,
            reason: 'zoom ${zooms[i]} must refine zoom ${zooms[i - 1]}');
      }
      expect(partitions.first.length, lessThan(partitions.last.length));
      // Fully zoomed in every city is its own dot.
      expect(partitions.last.length, 18);
    });

    test('a pair that is split stays split at every deeper zoom', () {
      final points = [
        _p(34.05, -118.25),
        _p(34.10, -118.40),
      ];
      var separatedAt = -1.0;
      for (final z in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0]) {
        final n = clusterPoints(points, z).length;
        if (n == 2 && separatedAt < 0) separatedAt = z;
        // Once separated, they must never regroup at a deeper zoom.
        if (separatedAt >= 0) expect(n, 2, reason: 'regrouped at zoom $z');
      }
      expect(separatedAt, greaterThan(0));
    });
  });

  group('DotCluster — aggregation', () {
    test('count and averageScore aggregate approval members', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, score: 1.0),
          _p(0, 0, score: -1.0),
          _p(0, 0, score: 0.0),
        ],
      );
      expect(cluster.count, 3);
      expect(cluster.averageScore, closeTo(0.0, 1e-9));
    });

    test('averageScore ignores null-score (MC) members', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, score: 0.6),
          _p(0, 0, score: 0.2),
          _p(0, 0, option: 'A'), // no score → excluded from the mean
        ],
      );
      expect(cluster.averageScore, closeTo(0.4, 1e-9));
    });

    test('empty cluster averageScore is 0', () {
      const cluster = DotCluster(position: LatLng(0, 0), points: []);
      expect(cluster.averageScore, 0);
    });

    test('optionCounts and countForOption tally MC votes', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, option: 'Red'),
          _p(0, 0, option: 'Red'),
          _p(0, 0, option: 'Blue'),
        ],
      );
      expect(cluster.optionCounts, {'Red': 2, 'Blue': 1});
      expect(cluster.countForOption('Red'), 2);
      expect(cluster.countForOption('Blue'), 1);
      expect(cluster.countForOption('Green'), 0);
    });
  });

  group('DotCluster — top option selection', () {
    test('returns the sole leading option', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, option: 'A'),
          _p(0, 0, option: 'A'),
          _p(0, 0, option: 'B'),
        ],
      );
      expect(cluster.topOption, 'A');
    });

    test('two-way tie resolves to TIE', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, option: 'A'),
          _p(0, 0, option: 'B'),
        ],
      );
      expect(cluster.topOption, 'TIE');
    });

    test('no MC options resolves to TIE', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [_p(0, 0, score: 0.5)],
      );
      expect(cluster.topOption, 'TIE');
    });
  });

  group('approvalBucketIndex — ±0.8 / ±0.3 thresholds', () {
    test('boundary scores map to the lower/inclusive bucket', () {
      expect(approvalBucketIndex(-1.0), 0); // strongly disapprove
      expect(approvalBucketIndex(-0.8), 0); // boundary → still bucket 0
      expect(approvalBucketIndex(-0.79), 1); // disapprove
      expect(approvalBucketIndex(-0.3), 1); // boundary → bucket 1
      expect(approvalBucketIndex(-0.29), 2); // neutral
      expect(approvalBucketIndex(0.0), 2);
      expect(approvalBucketIndex(0.3), 2); // boundary → neutral
      expect(approvalBucketIndex(0.31), 3); // approve
      expect(approvalBucketIndex(0.8), 3); // boundary → approve
      expect(approvalBucketIndex(0.81), 4); // strongly approve
      expect(approvalBucketIndex(1.0), 4);
    });

    test('countForBucket tallies members per sentiment bucket', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, score: -1.0), // bucket 0
          _p(0, 0, score: 0.0), // bucket 2
          _p(0, 0, score: 0.1), // bucket 2
          _p(0, 0, score: 1.0), // bucket 4
        ],
      );
      expect(cluster.countForBucket(0), 1);
      expect(cluster.countForBucket(2), 2);
      expect(cluster.countForBucket(4), 1);
      expect(cluster.countForBucket(1), 0);
    });
  });

  group('clusterRadius — three fixed steps', () {
    test('base size up to and including 10 respondents', () {
      expect(clusterRadius(0), kDotRadiusBase);
      expect(clusterRadius(1), kDotRadiusBase);
      expect(clusterRadius(10), kDotRadiusBase);
    });

    test('steps up above 10, and again above 100', () {
      expect(clusterRadius(11), kDotRadiusMedium);
      expect(clusterRadius(100), kDotRadiusMedium);
      expect(clusterRadius(101), kDotRadiusLarge);
      expect(clusterRadius(100000), kDotRadiusLarge);
    });

    test('there are exactly three sizes, strictly increasing', () {
      final sizes = {
        for (var n = 0; n <= 500; n++) clusterRadius(n),
      };
      expect(sizes.length, 3);
      expect(kDotRadiusBase, lessThan(kDotRadiusMedium));
      expect(kDotRadiusMedium, lessThan(kDotRadiusLarge));
      // Non-decreasing in count, with no other steps in between.
      for (var n = 1; n <= 500; n++) {
        expect(clusterRadius(n), greaterThanOrEqualTo(clusterRadius(n - 1)));
      }
    });

    test('a merged cluster steps by its combined count', () {
      // Six responses in each of two cities that merge → 12 → medium.
      final points = [
        for (var i = 0; i < 6; i++) _p(0, 0),
        for (var i = 0; i < 6; i++) _p(0, 0.01),
      ];
      final clusters = clusterPoints(points, 2.0);
      expect(clusters.length, 1);
      expect(clusters.first.count, 12);
      expect(clusterRadius(clusters.first.count), kDotRadiusMedium);
    });
  });

  group('country-centroid fallback for null city', () {
    test('city-less responses (at a country centroid) still aggregate', () {
      // Responses without a city_id fall back to the country centroid: town is
      // null but they still carry a country + score and must aggregate. Two at
      // the exact same centroid always collapse to one dot.
      final points = [
        _p(21, 57,
            country: 'Oman',
            countryIso: 'OMN',
            town: null,
            countryCentroid: const LatLng(21, 57),
            score: 0.9),
        _p(21, 57,
            country: 'Oman',
            countryIso: 'OMN',
            town: null,
            countryCentroid: const LatLng(21, 57),
            score: 0.5),
      ];
      final clusters = clusterPoints(points, 4.0);
      expect(clusters.length, 1);
      final c = clusters.first;
      expect(c.count, 2);
      expect(c.commonTown, isNull);
      expect(c.commonCountry, 'Oman');
      // Anchored at the shared country centroid.
      expect(c.position.latitude, closeTo(21, 1e-9));
      expect(c.position.longitude, closeTo(57, 1e-9));
    });

    test('a city response and a country-centroid fallback merge far out', () {
      final points = [
        _p(21, 57,
            country: 'Oman',
            countryIso: 'OMN',
            town: null,
            countryCentroid: const LatLng(21, 57),
            score: 0.9),
        _p(23.6, 58.5,
            country: 'Oman',
            countryIso: 'OMN',
            town: 'Muscat',
            countryCentroid: const LatLng(21, 57),
            score: 0.9),
      ];
      // Far out both Oman responses collapse to a single blob at their mean.
      final clusters = clusterPoints(points, 1.0);
      expect(clusters.length, 1);
      final c = clusters.first;
      expect(c.count, 2);
      expect(c.commonTown, isNull); // mixed null/known town
      expect(c.commonCountry, 'Oman');
      expect(c.position.latitude, closeTo((21 + 23.6) / 2, 1e-9));
    });

    test('commonTown is set only when every member shares one town', () {
      final same = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, town: 'Muscat'),
          _p(0, 0, town: 'Muscat'),
        ],
      );
      expect(same.commonTown, 'Muscat');

      final mixed = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, town: 'Muscat'),
          _p(0, 0, town: 'Salalah'),
        ],
      );
      expect(mixed.commonTown, isNull);
    });

    test('commonCountry picks the most frequent country', () {
      final cluster = DotCluster(
        position: const LatLng(0, 0),
        points: [
          _p(0, 0, country: 'Oman'),
          _p(0, 0, country: 'Oman'),
          _p(0, 0, country: 'Qatar'),
        ],
      );
      expect(cluster.commonCountry, 'Oman');
    });
  });

  group('CountryCentroids — asset loader', () {
    test('null / not-loaded lookups never throw', () {
      expect(CountryCentroids.of(null), isNull);
      expect(CountryCentroids.nameOf(null), isNull);
    });

    test('load() populates centroids from the bundled asset', () async {
      await CountryCentroids.load();
      expect(CountryCentroids.isLoaded, isTrue);

      // The asset is declared in pubspec and available to `flutter test`.
      // Aruba (ABW) is the first entry; verify exact centroid + name.
      final aruba = CountryCentroids.of('ABW');
      expect(aruba, isNotNull);
      expect(aruba!.latitude, closeTo(12.5209, 1e-4));
      expect(aruba.longitude, closeTo(-69.9827, 1e-4));
      expect(CountryCentroids.nameOf('ABW'), 'Aruba');

      // Unknown code → null (no crash), and a second load() is a no-op.
      expect(CountryCentroids.of('ZZZ'), isNull);
      await CountryCentroids.load();
      expect(CountryCentroids.isLoaded, isTrue);
    });
  });
}
