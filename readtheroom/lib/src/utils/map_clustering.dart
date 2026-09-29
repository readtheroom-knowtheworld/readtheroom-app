// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// A single placed response feeding the dot map.
///
/// Every response resolves to exactly one [position]: a city centroid when a
/// `city_id` is known, otherwise the bundled country centroid. City centroid
/// is the maximum resolution (privacy note P-3) — points are never at precise
/// coordinates.
///
/// [admin1] and [countryCentroid] are carried for tooltips and the city-less
/// country-centroid fallback the adapters perform. [countryIso] (falling back
/// to [country]) additionally partitions the clusterer: dots from different
/// countries never combine, however close they draw — within a country the
/// clusterer groups purely by on-screen overlap (see [clusterPoints]).
class ClusterPoint {
  final LatLng position;

  /// Town / city name, or null when the point falls back to a country centroid.
  final String? town;

  /// Country display name (always known).
  final String country;

  /// ISO_A3 country code, when known.
  final String? countryIso;

  /// Admin1 (state / province) code from the `cities` join, when known. Kept
  /// for context/debugging; no longer drives clustering.
  final String? admin1;

  /// The country's representative centroid — the position used for responses
  /// that have no city (privacy fallback). Null when unknown.
  final LatLng? countryCentroid;

  /// Approval score in [-1, 1], for approval questions. Null for MC.
  final double? score;

  /// Chosen option text, for multiple-choice questions. Null for approval.
  final String? option;

  /// How many answers this point stands for.
  ///
  /// Since the answers read lockdown (2026-09-22) the map is fed CELLS, not
  /// answers: the server sends one entry per city (or per country, for answers
  /// with no city) with the number of answers it holds. A cell of six is one
  /// point with `count: 6`, drawn as a single dot at the radius six earns —
  /// which is exactly what six coincident points used to draw.
  ///
  /// Defaults to 1 so a point that really is one answer needs to say nothing.
  final int count;

  /// Approval histogram for this point, index 0 = strongly disapprove … 4 =
  /// strongly approve. Null when the point carries a single [score] instead.
  final List<int>? bins;

  /// Per-option vote counts for this point. Null when the point carries a
  /// single [option] instead.
  final Map<String, int>? optionCounts;

  const ClusterPoint({
    required this.position,
    required this.country,
    this.town,
    this.countryIso,
    this.admin1,
    this.countryCentroid,
    this.score,
    this.option,
    this.count = 1,
    this.bins,
    this.optionCounts,
  });

  /// This point's votes per option, however it was built: from [optionCounts]
  /// when it is a cell, from [option] x [count] when it is a plain point.
  Map<String, int> get effectiveOptionCounts {
    final counts = optionCounts;
    if (counts != null) return counts;
    final o = option;
    if (o == null || o.isEmpty) return const <String, int>{};
    return <String, int>{o: count};
  }

  /// This point's approval histogram, however it was built.
  List<int> get effectiveBins {
    final b = bins;
    if (b != null && b.length == 5) return b;
    final s = score;
    final out = List<int>.filled(5, 0);
    if (s != null) out[approvalBucketIndex(s)] = count;
    return out;
  }
}

/// The result of collision-clustering a set of [ClusterPoint]s at a zoom.
class DotCluster {
  /// Cluster anchor — the mean position of all member points, so a cluster
  /// that splits on zoom-in leaves children near where the parent sat.
  final LatLng position;
  final List<ClusterPoint> points;

  const DotCluster({
    required this.position,
    required this.points,
  });

  /// Answers in this cluster — the sum of its members' weights, not the number
  /// of members. A cell of six answers is one member worth six.
  int get count {
    var total = 0;
    for (final p in points) {
      total += p.count;
    }
    return total;
  }

  /// Average approval score across members (approval questions), weighted by
  /// how many answers each member stands for.
  double get averageScore {
    if (points.isEmpty) return 0;
    var sum = 0.0;
    var n = 0;
    for (final p in points) {
      if (p.score != null) {
        sum += p.score! * p.count;
        n += p.count;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  /// Vote counts per MC option within this cluster.
  Map<String, int> get optionCounts {
    final counts = <String, int>{};
    for (final p in points) {
      p.effectiveOptionCounts.forEach((option, n) {
        if (option.isNotEmpty) counts[option] = (counts[option] ?? 0) + n;
      });
    }
    return counts;
  }

  /// Top MC option, or 'TIE' when two or more options share the maximum.
  String get topOption {
    final counts = optionCounts;
    if (counts.isEmpty) return 'TIE';
    final maxCount = counts.values.reduce(math.max);
    final leaders =
        counts.entries.where((e) => e.value == maxCount).map((e) => e.key);
    return leaders.length > 1 ? 'TIE' : leaders.first;
  }

  /// Number of answers that chose [option] (used for legend highlighting).
  int countForOption(String option) => optionCounts[option] ?? 0;

  /// Number of answers whose approval score falls in sentiment [bucketIndex]
  /// (0 = strongly disapprove … 4 = strongly approve).
  int countForBucket(int bucketIndex) {
    if (bucketIndex < 0 || bucketIndex > 4) return 0;
    var total = 0;
    for (final p in points) {
      total += p.effectiveBins[bucketIndex];
    }
    return total;
  }

  /// Shared town name if every member resolves to the same town, else null.
  String? get commonTown {
    String? town;
    for (final p in points) {
      if (p.town == null) return null;
      town ??= p.town;
      if (p.town != town) return null;
    }
    return town;
  }

  /// Most common country name among members, weighted by answers.
  String get commonCountry {
    final counts = <String, int>{};
    for (final p in points) {
      counts[p.country] = (counts[p.country] ?? 0) + p.count;
    }
    if (counts.isEmpty) return '';
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}

/// Answers represented by a set of points — the sum of their weights, which is
/// what the map's "Explore N responses" affordance means. Not `points.length`:
/// one point can stand for a whole city.
int totalResponses(List<ClusterPoint> points) {
  var total = 0;
  for (final p in points) {
    total += p.count;
  }
  return total;
}

/// Approval sentiment bucket index for a score in [-1, 1] using the shared
/// ±0.8 / ±0.3 thresholds (mirrors `ResultsColors.forApprovalBucket`).
/// 0 = strongly disapprove, 1 = disapprove, 2 = neutral, 3 = approve,
/// 4 = strongly approve.
int approvalBucketIndex(double score) {
  if (score <= -0.8) return 0;
  if (score <= -0.3) return 1;
  if (score <= 0.3) return 2;
  if (score <= 0.8) return 3;
  return 4;
}

/// Deterministic, pure-Dart *collision* clusterer for the response dot map.
///
/// Cities (and country-centroid fallbacks) are always the underlying unit. Two
/// dots merge **only when the circles actually drawn for them overlap** at the
/// current [zoom] — projected separation below `r(a) + r(b)` (+ any
/// [overlapPaddingPx] slack), with `r` the three-step [clusterRadius] of each
/// side's respondent count. There is no fixed linkage distance: a dot the
/// viewer can see as separate stays separate.
///
/// **Countries never combine.** Leaves are partitioned by country before any
/// union is considered, so two cities either side of a border stay two dots
/// however close they sit on screen.
///
/// Merging runs to a **fixed point**: a merged cluster is drawn at its total
/// count's radius, so it may now overlap a third dot that the parts did not.
/// Each pass recomputes component radii from a snapshot of the partition and
/// applies every qualifying union, so the result never depends on iteration
/// order. Single-linkage: components collide when their *closest* members do.
///
/// ### Monotonic refinement still holds
/// The partition at a deeper zoom is always a refinement of the partition at a
/// shallower one — a cluster only ever splits as you zoom in, never regroups.
/// Proof sketch: pixel separation is strictly increasing in zoom while radii
/// depend only on counts, which do not change with zoom. Induct over the
/// closure passes at the deeper zoom z′: suppose every union so far sits
/// inside a block of the (fixed-point) partition P(z). A new union joins
/// components C₁, C₂ with `minDist_{z′}(C₁,C₂) < r(|C₁|) + r(|C₂|)`. At z the
/// separation is smaller and the enclosing P(z) blocks are supersets, whose
/// radii are ≥ (radius is non-decreasing in count) — so if C₁ and C₂ sat in
/// different P(z) blocks those blocks would themselves have collided,
/// contradicting P(z) being a fixed point. Hence C₁ and C₂ share a P(z) block,
/// and the refinement holds. (Property-tested in `map_clustering_test.dart`.)
///
/// Membership depends solely on the fixed pairwise geometry, the counts and
/// the zoom — not on input order — so identical input + zoom always yields
/// identical output. Output is stably sorted by anchor. Call on
/// `MapEventMoveEnd`, not per frame.
List<DotCluster> clusterPoints(
  List<ClusterPoint> points,
  double zoom, {
  double overlapPaddingPx = 0.0,
  double tileSize = 256.0,
}) {
  if (points.isEmpty) return const [];

  // 1. Collapse responses that share an exact location *within one country*
  //    into leaf nodes. A city centroid is the maximum resolution (privacy
  //    P-3); identical coordinates (same city, or the same country-centroid
  //    fallback) always collide.
  final leafIndex = <String, int>{};
  final leaves = <List<ClusterPoint>>[];
  final leafCountry = <String>[];
  for (final p in points) {
    final country = countryPartitionKey(p);
    final key = '$country|${_posKey(p.position)}';
    final idx = leafIndex.putIfAbsent(key, () {
      leaves.add(<ClusterPoint>[]);
      leafCountry.add(country);
      return leaves.length - 1;
    });
    leaves[idx].add(p);
  }

  final n = leaves.length;

  // 2. Project each leaf to Web-Mercator pixel space at this zoom.
  final worldSize = tileSize * math.pow(2.0, zoom);
  final xs = List<double>.filled(n, 0);
  final ys = List<double>.filled(n, 0);
  final counts = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final pos = leaves[i].first.position;
    xs[i] = _lngToX(pos.longitude, worldSize);
    ys[i] = _latToY(pos.latitude, worldSize);
    // Answers, not members: a cell counts for everyone it holds, so a big city
    // draws at a big radius and merges like the crowd it is.
    var weight = 0;
    for (final p in leaves[i]) {
      weight += p.count;
    }
    counts[i] = weight;
  }

  // 3. Overlap-only single linkage, iterated to a fixed point. Each pass reads
  //    the partition as it stood at the pass's start, so the set of unions a
  //    pass performs is independent of the order they are applied in.
  final uf = _UnionFind(n);
  while (true) {
    final roots = List<int>.generate(n, uf.find);
    final rootCount = <int, int>{};
    for (var i = 0; i < n; i++) {
      rootCount[roots[i]] = (rootCount[roots[i]] ?? 0) + counts[i];
    }
    final radius = <int, double>{
      for (final entry in rootCount.entries)
        entry.key: clusterRadius(entry.value),
    };

    var merged = false;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        if (roots[i] == roots[j]) continue;
        // Different countries never combine, however close they draw.
        if (leafCountry[i] != leafCountry[j]) continue;
        final reach =
            radius[roots[i]]! + radius[roots[j]]! + overlapPaddingPx;
        final dx = xs[i] - xs[j];
        final dy = ys[i] - ys[j];
        if (dx * dx + dy * dy < reach * reach) {
          uf.union(i, j);
          merged = true;
        }
      }
    }
    if (!merged) break;
  }

  // 4. Gather members by connected-component root.
  final byRoot = <int, List<ClusterPoint>>{};
  for (var i = 0; i < n; i++) {
    byRoot.putIfAbsent(uf.find(i), () => <ClusterPoint>[]).addAll(leaves[i]);
  }

  final clusters = <DotCluster>[
    for (final members in byRoot.values)
      DotCluster(position: _mean(members), points: members),
  ];
  clusters.sort(_byAnchor);
  return clusters;
}

/// The key that keeps one country's dots away from another's: the ISO_A3 code
/// when the response carries one, else the country display name. Responses
/// with neither share the single "unknown" partition.
String countryPartitionKey(ClusterPoint p) {
  final iso = p.countryIso;
  if (iso != null && iso.isNotEmpty) return iso;
  return p.country;
}

/// Location key at fixed precision (~11 m): responses at the same city centroid
/// (or the same country-centroid fallback) always collide into one leaf.
String _posKey(LatLng p) =>
    '${p.latitude.toStringAsFixed(4)}_${p.longitude.toStringAsFixed(4)}';

LatLng _mean(List<ClusterPoint> members) {
  var latSum = 0.0;
  var lngSum = 0.0;
  for (final m in members) {
    latSum += m.position.latitude;
    lngSum += m.position.longitude;
  }
  return LatLng(latSum / members.length, lngSum / members.length);
}

/// Stable ordering by anchor latitude, then longitude, then count — keeps
/// output deterministic across runs regardless of input order.
int _byAnchor(DotCluster a, DotCluster b) {
  final dLat = a.position.latitude.compareTo(b.position.latitude);
  if (dLat != 0) return dLat;
  final dLng = a.position.longitude.compareTo(b.position.longitude);
  if (dLng != 0) return dLng;
  return a.count.compareTo(b.count);
}

/// Respondent count above which a city's dot steps up to [kDotRadiusMedium].
const int kDotMediumThreshold = 10;

/// Respondent count above which a city's dot steps up to [kDotRadiusLarge].
const int kDotLargeThreshold = 100;

/// Dot radius (logical px) for a city with at most [kDotMediumThreshold]
/// respondents — the baseline dot, and the size most dots on the map are.
const double kDotRadiusBase = 7.0;

/// Dot radius for 11–100 respondents in one city.
const double kDotRadiusMedium = 11.0;

/// Dot radius for more than 100 respondents in one city.
const double kDotRadiusLarge = 16.0;

/// Marker radius in logical pixels: three fixed steps, not a continuous curve.
///
/// A dot grows only when a city passes 10 respondents, and again when it
/// passes 100 — so size reads as a category ("a lot of people here") rather
/// than a number nobody can estimate from an unlabelled circle. A merged
/// cluster steps by its combined count.
double clusterRadius(int count) {
  if (count > kDotLargeThreshold) return kDotRadiusLarge;
  if (count > kDotMediumThreshold) return kDotRadiusMedium;
  return kDotRadiusBase;
}

/// Web-Mercator world-pixel position of [position] at [zoom] — the same
/// projection [clusterPoints] measures overlap in. Differences between two
/// results are on-screen distances in logical px (the map does not rotate).
math.Point<double> projectToWorldPixels(
  LatLng position,
  double zoom, {
  double tileSize = 256.0,
}) {
  final worldSize = tileSize * math.pow(2.0, zoom);
  return math.Point<double>(
    _lngToX(position.longitude, worldSize),
    _latToY(position.latitude, worldSize),
  );
}

double _lngToX(double lng, double worldSize) =>
    (lng + 180.0) / 360.0 * worldSize;

double _latToY(double lat, double worldSize) {
  final s = math.sin(lat * math.pi / 180.0).clamp(-0.9999, 0.9999).toDouble();
  final y = 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
  return y * worldSize;
}

/// Minimal deterministic union-find (disjoint-set) with path compression. The
/// resulting partition is independent of the order in which unions are applied.
class _UnionFind {
  final List<int> _parent;

  _UnionFind(int n) : _parent = List<int>.generate(n, (i) => i);

  int find(int x) {
    var root = x;
    while (_parent[root] != root) {
      root = _parent[root];
    }
    // Path compression.
    while (_parent[x] != root) {
      final next = _parent[x];
      _parent[x] = root;
      x = next;
    }
    return root;
  }

  void union(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra == rb) return;
    // Attach the higher-index root under the lower for a canonical result.
    if (ra < rb) {
      _parent[rb] = ra;
    } else {
      _parent[ra] = rb;
    }
  }
}
