// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Turn the server's map CELLS into the [ClusterPoint]s the dot map draws.
//
// Before the answers read lockdown (2026-09-22) each answer was its own point,
// and the clusterer collapsed the ones sharing a city centroid back into a
// single dot. The server now does that collapsing — it sends one cell per city
// (and one per country for answers with no city) with the count and the
// summary — so this adapter produces ONE point per cell, carrying the cell's
// weight. The dot the viewer sees is unchanged; what crosses the network is not.

import 'package:latlong2/latlong.dart';

import '../models/question_results.dart';
import 'country_centroids.dart';
import 'map_clustering.dart';

/// One point per cell. City cells sit at the city centroid (max resolution,
/// privacy note P-3); country cells sit on the bundled country centroid, and
/// are dropped when we have no centroid for that country.
///
/// [CountryCentroids.load] must have been awaited by the caller.
List<ClusterPoint> pointsFromCells(
  QuestionMapCells cells, {
  required bool isApproval,
}) {
  final points = <ClusterPoint>[];
  for (final cell in cells.cells) {
    if (cell.count <= 0) continue;

    final centroid = CountryCentroids.of(cell.countryIso3);
    final countryName = cell.country.isNotEmpty && cell.country != 'Unknown'
        ? cell.country
        : (CountryCentroids.nameOf(cell.countryIso3) ?? cell.country);

    if (cell.isCity) {
      points.add(ClusterPoint(
        position: LatLng(cell.lat!, cell.lng!),
        town: cell.city,
        country: countryName,
        countryIso: cell.countryIso3,
        admin1: cell.admin1,
        countryCentroid: centroid,
        count: cell.count,
        score: isApproval ? cell.average : null,
        bins: isApproval ? cell.bins : null,
        optionCounts: isApproval ? null : cell.optionCounts,
        option: isApproval ? null : cell.topOption,
      ));
      continue;
    }

    if (centroid == null) continue;
    points.add(ClusterPoint(
      position: centroid,
      country: countryName,
      countryIso: cell.countryIso3,
      countryCentroid: centroid,
      count: cell.count,
      score: isApproval ? cell.average : null,
      bins: isApproval ? cell.bins : null,
      optionCounts: isApproval ? null : cell.optionCounts,
      option: isApproval ? null : cell.topOption,
    ));
  }
  return points;
}
