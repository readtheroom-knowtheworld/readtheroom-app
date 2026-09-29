// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../services/country_service.dart';
import '../services/results_service.dart';
import '../utils/country_centroids.dart';
import '../utils/map_cell_points.dart';
import '../utils/map_clustering.dart';
import 'response_dot_map.dart';

/// Multiple-choice results map — a thin adapter over [ResponseDotMap].
///
/// With a question id it draws the server's map CELLS: one dot per city (or per
/// country, for answers with no city), each weighted by the answers it holds.
/// Without one it falls back to the per-country summary it was handed, one dot
/// per country. Since the answers read lockdown it never sees an answer row.
class CountryMultipleChoiceMap extends StatefulWidget {
  final List<Map<String, dynamic>> responsesByCountry;
  final String questionTitle;
  final List<String> options;
  final String questionId;
  final Function(String?)? onCountryTap;

  /// Bare full-width map + legend, no Card/title chrome (QOTD hero embed).
  final bool embedded;

  /// Passed through to [ResponseDotMap.footer].
  final Widget? footer;

  const CountryMultipleChoiceMap({
    Key? key,
    required this.responsesByCountry,
    required this.questionTitle,
    required this.options,
    required this.questionId,
    this.onCountryTap,
    this.embedded = false,
    this.footer,
  }) : super(key: key);

  @override
  State<CountryMultipleChoiceMap> createState() =>
      _CountryMultipleChoiceMapState();
}

class _CountryMultipleChoiceMapState extends State<CountryMultipleChoiceMap> {
  List<ClusterPoint> _points = const [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _buildPoints();
  }

  @override
  void didUpdateWidget(CountryMultipleChoiceMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.responsesByCountry != oldWidget.responsesByCountry ||
        widget.options != oldWidget.options ||
        widget.questionId != oldWidget.questionId) {
      _buildPoints();
    }
  }

  Future<void> _buildPoints() async {
    if (mounted) setState(() => _isLoading = true);
    await CountryCentroids.load();

    List<ClusterPoint> points;
    if (widget.questionId.isNotEmpty) {
      final cells = await ResultsService().fetchMapCells(widget.questionId);
      points = pointsFromCells(cells, isApproval: false);
    } else {
      points = await _pointsFromCountryResponses();
    }

    if (mounted) {
      setState(() {
        _points = points;
        _isLoading = false;
      });
    }
  }

  Future<List<ClusterPoint>> _pointsFromCountryResponses() async {
    await CountryService.preloadCountryMappings();
    final points = <ClusterPoint>[];
    for (final r in widget.responsesByCountry) {
      final name = r['country']?.toString();
      final option = r['answer']?.toString();
      if (name == null || name.isEmpty || name == 'Unknown' ||
          option == null || option.isEmpty) {
        continue;
      }
      final iso = await CountryService.getIsoCodeForCountry(name);
      final centroid = CountryCentroids.of(iso);
      if (centroid != null) {
        points.add(ClusterPoint(
          position: centroid,
          country: name,
          countryIso: iso,
          countryCentroid: centroid,
          option: option,
        ));
      }
    }
    return points;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      const loading = SizedBox(
        height: 340,
        child: Center(child: CircularProgressIndicator()),
      );
      return widget.embedded ? loading : const Card(child: loading);
    }
    if (_points.isEmpty) {
      if (widget.embedded) return const SizedBox.shrink();
      return const Card(
        child: SizedBox(
          height: 200,
          child: Center(child: Text('No geographic data available')),
        ),
      );
    }
    return ResponseDotMap(
      points: _points,
      isApproval: false,
      options: widget.options,
      questionTitle: widget.questionTitle,
      questionId: widget.questionId,
      onCountryTap: widget.onCountryTap,
      embedded: widget.embedded,
      footer: widget.footer,
    );
  }
}
