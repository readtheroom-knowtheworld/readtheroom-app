// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../utils/geojson_parser.dart';

/// Granularity level for the map visualization.
enum MapGranularity { country, state, city }

/// Data for coloring a single country on the choropleth map.
class ChoroplethEntry {
  final String isoA3;
  final Color color;
  final String tooltip;

  ChoroplethEntry(
      {required this.isoA3, required this.color, required this.tooltip});
}

/// Data for a circle marker on the map (used for state/city views).
class MapMarkerEntry {
  final LatLng position;
  final Color color;
  final double radius; // 6–20, scaled by response count
  final String tooltip;

  MapMarkerEntry({
    required this.position,
    required this.color,
    required this.radius,
    required this.tooltip,
  });
}

/// Shared choropleth map renderer using flutter_map with PolygonLayer.
/// Both CountryApprovalMap and CountryMultipleChoiceMap delegate to this widget.
class ChoroplethMapBase extends StatefulWidget {
  final List<ChoroplethEntry> entries;
  final Color defaultColor;
  final Function(String?)? onCountryTap;
  final List<MapMarkerEntry> markers;
  final bool neutralPolygons;

  const ChoroplethMapBase({
    Key? key,
    required this.entries,
    this.defaultColor = Colors.white,
    this.onCountryTap,
    this.markers = const [],
    this.neutralPolygons = false,
  }) : super(key: key);

  @override
  State<ChoroplethMapBase> createState() => _ChoroplethMapBaseState();
}

class _ChoroplethMapBaseState extends State<ChoroplethMapBase> {
  List<GeoCountry>? _geoCountries;
  bool _isLoading = true;
  List<Polygon>? _polygonCache;
  bool _lastNeutralPolygons = false;

  // Tooltip state
  String? _tooltipText;
  Offset? _tooltipLocalOffset;
  final GlobalKey _mapKey = GlobalKey();

  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _loadGeoData();
  }

  @override
  void didUpdateWidget(ChoroplethMapBase oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entries != oldWidget.entries ||
        widget.neutralPolygons != oldWidget.neutralPolygons) {
      _polygonCache = null;
    }
  }

  Future<void> _loadGeoData() async {
    final countries = await GeoJsonParser.loadCountries();
    if (mounted) {
      setState(() {
        _geoCountries = countries;
        _isLoading = false;
      });
    }
  }

  List<Polygon> _buildPolygons(BuildContext context) {
    if (_polygonCache != null &&
        _lastNeutralPolygons == widget.neutralPolygons) {
      return _polygonCache!;
    }
    if (_geoCountries == null) return [];

    final colorMap = <String, Color>{};
    for (final entry in widget.entries) {
      colorMap[entry.isoA3] = entry.color;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultFill =
        isDark ? Theme.of(context).colorScheme.surface : widget.defaultColor;
    final borderColor = isDark ? Colors.white54 : Colors.grey[400]!;

    final polygons = <Polygon>[];
    for (final country in _geoCountries!) {
      final Color fillColor;
      if (widget.neutralPolygons) {
        fillColor = defaultFill;
      } else {
        fillColor = colorMap[country.isoA3] ?? defaultFill;
      }
      for (final part in country.parts) {
        polygons.add(Polygon(
          points: part.outerRing,
          holePointsList: part.holes.isNotEmpty ? part.holes : null,
          color: fillColor,
          borderColor: borderColor,
          borderStrokeWidth: 0.5,
          isFilled: true,
        ));
      }
    }

    _polygonCache = polygons;
    _lastNeutralPolygons = widget.neutralPolygons;
    return polygons;
  }

  void _onTap(TapPosition tapPosition, LatLng point) {
    if (_geoCountries == null) return;

    // Check if tap is near a marker first
    if (widget.markers.isNotEmpty) {
      final tappedMarker = _findNearestMarker(point);
      if (tappedMarker != null) {
        final RenderBox? renderBox =
            _mapKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox != null) {
          final localOffset = renderBox.globalToLocal(tapPosition.global);
          setState(() {
            _tooltipText = tappedMarker.tooltip;
            _tooltipLocalOffset = localOffset;
          });
        }
        return;
      }
    }

    final isoCode = GeoJsonParser.hitTest(point, _geoCountries!);

    if (isoCode != null) {
      final entry =
          widget.entries.where((e) => e.isoA3 == isoCode).firstOrNull;
      if (entry != null && !widget.neutralPolygons) {
        // Convert global tap position to local coordinates within the map
        final RenderBox? renderBox =
            _mapKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox != null) {
          final localOffset = renderBox.globalToLocal(tapPosition.global);
          setState(() {
            _tooltipText = entry.tooltip;
            _tooltipLocalOffset = localOffset;
          });
        }
      } else {
        _dismissTooltip();
      }
    } else {
      _dismissTooltip();
    }

    widget.onCountryTap?.call(isoCode);
  }

  /// Find the nearest marker within a reasonable tap distance.
  MapMarkerEntry? _findNearestMarker(LatLng tapPoint) {
    const double tapThresholdDegrees = 3.0; // ~3 degrees tolerance
    MapMarkerEntry? closest;
    double closestDist = double.infinity;

    for (final marker in widget.markers) {
      final dLat = tapPoint.latitude - marker.position.latitude;
      final dLng = tapPoint.longitude - marker.position.longitude;
      final dist = math.sqrt(dLat * dLat + dLng * dLng);
      if (dist < tapThresholdDegrees && dist < closestDist) {
        closestDist = dist;
        closest = marker;
      }
    }
    return closest;
  }

  void _dismissTooltip() {
    if (_tooltipText != null) {
      setState(() {
        _tooltipText = null;
        _tooltipLocalOffset = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SizedBox(
      height: 300,
      key: _mapKey,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds(
                  const LatLng(-38, -165), // South of New Zealand
                  const LatLng(73, 180),   // NZ at far right edge
                ),
              ),
              minZoom: 0.3,
              maxZoom: 15.0,
              backgroundColor: Colors.transparent,
              onTap: _onTap,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              PolygonLayer(
                polygons: _buildPolygons(context),
                polygonCulling: true,
              ),
              if (widget.markers.isNotEmpty)
                CircleLayer(
                  circles: widget.markers
                      .map((m) => CircleMarker(
                            point: m.position,
                            radius: m.radius,
                            color: m.color.withValues(alpha: 0.75),
                            borderColor: Colors.white,
                            borderStrokeWidth: 1.5,
                          ))
                      .toList(),
                ),
            ],
          ),
          // Tooltip overlay
          if (_tooltipText != null && _tooltipLocalOffset != null)
            Positioned(
              left: (_tooltipLocalOffset!.dx - 60).clamp(0.0, double.infinity),
              top: (_tooltipLocalOffset!.dy - 44).clamp(0.0, double.infinity),
              child: IgnorePointer(
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(6),
                  color: Colors.grey[800],
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border:
                          Border.all(color: Colors.white54, width: 1),
                    ),
                    child: Text(
                      _tooltipText!,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
