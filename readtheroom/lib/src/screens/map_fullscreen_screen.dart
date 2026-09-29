// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../utils/map_camera_logic.dart';
import '../utils/map_clustering.dart';
import '../utils/country_centroids.dart';
import '../utils/geojson_parser.dart';
import '../data/countries_data.dart';
import '../services/analytics_service.dart';
import '../services/location_service.dart';
import '../widgets/response_dot_map.dart';

/// Full-screen, fully interactive dot map pushed from the inline results
/// preview. Supports pan/zoom with re-clustering on move-end, legend-chip
/// answer highlighting ("Carmen's feature"), dot tooltips, and a long-press /
/// popup affordance to filter results to a tapped country.
///
/// On open the map shows the world fit for one frame and then animates in to
/// frame the viewer's own country ("you first"), even when that country holds
/// no responses — the 🌍 World chip animates back out again. With
/// `MediaQuery.disableAnimations` set, the intro jumps instead of animating.
class MapFullscreenScreen extends StatefulWidget {
  final List<ClusterPoint> points;
  final bool isApproval;
  final List<String> options;
  final String questionTitle;
  final String questionId;

  /// Applies a location filter on the results screen, then this screen pops:
  /// `'City:<name>'` from a city dot's "Filter to here", or an ISO_A3 code
  /// from a country long-press. Null (maps opened from the home QOTD hero)
  /// hides every filter affordance — results screens are the only place a
  /// filter can land.
  final void Function(String?)? onCountryTap;

  /// Overrides the viewer's country for the zoom-in intro. Null (the norm)
  /// reads it from [LocationService]; exists so tests can drive the intro
  /// without a provider.
  final String? userCountryName;

  const MapFullscreenScreen({
    Key? key,
    required this.points,
    required this.isApproval,
    required this.options,
    required this.questionTitle,
    required this.questionId,
    this.onCountryTap,
    this.userCountryName,
  }) : super(key: key);

  @override
  State<MapFullscreenScreen> createState() => _MapFullscreenScreenState();
}

class _MapFullscreenScreenState extends State<MapFullscreenScreen>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();

  /// Duration of the open-to-your-country fly-in and of the World chip's
  /// fly-out. Long enough to read as travel, short enough not to block.
  static const Duration _flyDuration = Duration(milliseconds: 900);

  List<DotCluster> _clusters = const [];
  double _zoom = 1.0;
  List<GeoCountry>? _geo;

  String? _highlightOption;
  int? _highlightBucket;
  DotCluster? _tooltip;

  late final AnimationController _flyController;
  late final Animation<double> _flyCurve;
  LatLng? _flyFromCenter;
  double _flyFromZoom = 0;
  CameraTarget? _flyTarget;

  /// Camera framing the viewer's own country, resolved once on open. Null when
  /// no country is set (or it cannot be placed) — then the map simply keeps
  /// its opening fit and shows no World chip.
  CameraTarget? _homeCountryTarget;
  bool _mapReady = false;
  bool _introDone = false;

  String get _questionType => widget.isApproval ? 'approval' : 'multiple_choice';

  @override
  void initState() {
    super.initState();
    AnalyticsService()
        .trackEvent('map_fullscreen_opened', {'question_type': _questionType});
    _flyController =
        AnimationController(vsync: this, duration: _flyDuration);
    _flyCurve = CurvedAnimation(
        parent: _flyController, curve: Curves.easeInOutCubic);
    _flyController.addListener(_onFlyTick);
    _flyController.addStatusListener(_onFlyStatus);
    _clusters = clusterPoints(widget.points, _zoom);
    _loadGeo();
  }

  @override
  void dispose() {
    _flyController.dispose();
    super.dispose();
  }

  Future<void> _loadGeo() async {
    final geo = await GeoJsonParser.loadCountries();
    // Cheap no-op when an adapter already loaded it; needed for the country
    // centroid fallback when the map is opened some other way.
    await CountryCentroids.load();
    if (!mounted) return;
    _resolveHomeCountry(geo);
    setState(() => _geo = geo);
    _maybeStartIntro();
  }

  // ---------------------------------------------------------------------
  // "You first": frame the viewer's own country on open.
  // ---------------------------------------------------------------------

  /// Reads the viewer's selected country and turns it into a camera target.
  ///
  /// The ISO code is resolved locally (no network): from the response points
  /// first — they already carry the app's own country name *and* its ISO code
  /// — then the bundled country table, then the GeoJSON names. Bounds come
  /// from the country's polygon; the bundled centroid is the fallback.
  void _resolveHomeCountry(List<GeoCountry> geo) {
    final name = widget.userCountryName ?? _selectedCountryName();
    if (name == null || name.trim().isEmpty) return;

    final iso = _isoForUserCountry(name, geo);
    if (iso == null) return;

    GeoCountry? country;
    for (final c in geo) {
      if (c.isoA3 == iso) {
        country = c;
        break;
      }
    }
    final bounds = country == null
        ? null
        : boundsForRings([for (final part in country.parts) part.outerRing]);
    final centroid = CountryCentroids.of(iso) ?? bounds?.center;
    if (centroid == null) return;

    final size = MediaQuery.of(context).size;
    _homeCountryTarget = cameraForCountry(
      centroid: centroid,
      bounds: bounds,
      width: size.width,
      height: size.height,
    );
  }

  String? _selectedCountryName() {
    try {
      return Provider.of<LocationService>(context, listen: false)
          .selectedCountry;
    } catch (_) {
      // No provider above this route (tests, or a detached push) — the map
      // just keeps its opening fit.
      return null;
    }
  }

  String? _isoForUserCountry(String name, List<GeoCountry> geo) {
    final normalized = normalizeCountryName(name);
    for (final p in widget.points) {
      final iso = p.countryIso;
      if (iso != null &&
          iso.isNotEmpty &&
          normalizeCountryName(p.country) == normalized) {
        return iso;
      }
    }
    final fromTable = CountriesData.countryIsoMap[name];
    if (fromTable != null) return fromTable;
    return isoForCountryName(
        name, {for (final c in geo) c.isoA3: c.name});
  }

  /// Runs the intro once the map is laid out and the country is resolved:
  /// one frame of the opening world fit, then the fly-in.
  void _maybeStartIntro() {
    if (_introDone || !_mapReady || !mounted) return;
    final target = _homeCountryTarget;
    if (target == null) return;
    _introDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _flyTo(target);
    });
  }

  /// Animates the camera to [target] (or jumps, under reduced motion).
  void _flyTo(CameraTarget target) {
    if (!mounted) return;
    if (MediaQuery.of(context).disableAnimations) {
      _mapController.move(target.center, target.zoom);
      _recluster(target.zoom);
      return;
    }
    final camera = _mapController.camera;
    _flyFromCenter = camera.center;
    _flyFromZoom = camera.zoom;
    _flyTarget = target;
    _flyController
      ..reset()
      ..forward();
  }

  void _onFlyTick() {
    final from = _flyFromCenter;
    final target = _flyTarget;
    if (from == null || target == null) return;
    final t = _flyCurve.value;
    // Interpolate latitude in projected space so the pan reads as a straight
    // line on screen rather than easing oddly near the poles.
    final lat = yNormToLat(_lerp(
        latToYNorm(from.latitude), latToYNorm(target.center.latitude), t));
    final lng = _lerp(from.longitude, target.center.longitude, t);
    _mapController.move(
        LatLng(lat, lng), _lerp(_flyFromZoom, target.zoom, t));
  }

  void _onFlyStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      final target = _flyTarget;
      if (target != null && mounted) _recluster(target.zoom);
    }
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// The map's opening framing — the whole world. The 🌍 World chip flies back
  /// out to exactly this, so the country zoom is always one tap from undone.
  void _flyToWorld() {
    final size = MediaQuery.of(context).size;
    const world =
        GeoBounds(minLat: -55, minLng: -170, maxLat: 78, maxLng: 179);
    AnalyticsService()
        .trackEvent('map_world_view', {'question_type': _questionType});
    _flyTo(cameraForBounds(
      world,
      size.width,
      size.height,
      padding: 24,
      minZoom: 0.3,
      maxZoom: 6,
    ));
  }

  void _recluster(double zoom) {
    setState(() {
      _zoom = zoom;
      _clusters = clusterPoints(widget.points, zoom);
    });
  }

  void _onMapEvent(MapEvent event) {
    if (event is MapEventMoveEnd ||
        event is MapEventFlingAnimationEnd ||
        event is MapEventDoubleTapZoomEnd ||
        event is MapEventScrollWheelZoom) {
      final z = event.camera.zoom;
      if ((z - _zoom).abs() > 0.01) {
        _recluster(z);
      }
    }
  }

  void _onClusterTap(DotCluster cluster) {
    setState(() => _tooltip = cluster);
    final target = (_zoom + 1.5).clamp(0.3, 15.0);
    _mapController.move(cluster.position, target.toDouble());
  }

  void _toggleOption(String option) {
    setState(() {
      _highlightBucket = null;
      if (_highlightOption == option) {
        _highlightOption = null;
      } else {
        _highlightOption = option;
        AnalyticsService().trackEvent(
            'map_option_highlighted', {'question_type': _questionType});
      }
    });
  }

  void _toggleBucket(int bucket) {
    setState(() {
      _highlightOption = null;
      if (_highlightBucket == bucket) {
        _highlightBucket = null;
      } else {
        _highlightBucket = bucket;
        AnalyticsService().trackEvent(
            'map_option_highlighted', {'question_type': _questionType});
      }
    });
  }

  void _clearHighlight() {
    setState(() {
      _highlightOption = null;
      _highlightBucket = null;
    });
  }

  bool get _canFilter => widget.onCountryTap != null;

  void _filterToCountryAt(LatLng point) {
    if (!_canFilter) return;
    final geo = _geo;
    if (geo == null) return;
    final iso = GeoJsonParser.hitTest(point, geo);
    if (iso != null) {
      AnalyticsService().trackEvent('map_country_tapped');
      widget.onCountryTap?.call(iso);
      Navigator.of(context).pop();
    }
  }

  /// "Filter to here" on a dot: filter to the dot's city when the cluster
  /// resolves to one town (country filtering already lives in the results
  /// screen's filter button); mixed / country-centroid clusters fall back to
  /// the country under the anchor.
  void _filterToCluster(DotCluster cluster) {
    if (!_canFilter) return;
    final town = cluster.commonTown;
    if (town != null) {
      AnalyticsService().trackEvent('map_city_filtered');
      widget.onCountryTap?.call('City:$town');
      Navigator.of(context).pop();
      return;
    }
    _filterToCountryAt(cluster.position);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: dotMapBackground(context),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: kWorldBounds,
                padding: const EdgeInsets.all(24),
              ),
              minZoom: 0.3,
              maxZoom: 15,
              backgroundColor: dotMapBackground(context),
              onMapReady: () {
                _mapReady = true;
                _recluster(_mapController.camera.zoom);
                _maybeStartIntro();
              },
              onMapEvent: _onMapEvent,
              onTap: (_, __) {
                if (_tooltip != null) setState(() => _tooltip = null);
              },
              onLongPress:
                  _canFilter ? (_, point) => _filterToCountryAt(point) : null,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              if (_geo != null)
                PolygonLayer(
                  polygons: buildBasemapPolygons(context, _geo!),
                  polygonCulling: true,
                ),
              MarkerLayer(
                markers: buildDotMarkers(
                  context,
                  clusters: _clusters,
                  isApproval: widget.isApproval,
                  options: widget.options,
                  highlightOption: _highlightOption,
                  highlightBucket: _highlightBucket,
                  onTap: _onClusterTap,
                  // Clusters were built at _zoom; their enlarged tap targets
                  // are sized for it too.
                  hitZoom: _zoom,
                ),
              ),
            ],
          ),

          // Close + World chip on the first line; the full prompt, centred in
          // its own pill, on the line beneath (owner, 2026-09-22).
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            right: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Row(
                  children: [
                    _circleButton(
                      icon: Icons.close,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    // Undo the open-on-my-country zoom.
                    if (_homeCountryTarget != null) _worldChip(),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    widget.questionTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),

          // Tooltip popup.
          if (_tooltip != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 96,
              child: _buildTooltipCard(_tooltip!),
            ),

          // Legend chips.
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 12,
            child: _buildLegendChips(),
          ),
        ],
      ),
    );
  }

  /// "🌍 World" — flies back out to the whole-world framing the map opened on.
  Widget _worldChip() {
    return GestureDetector(
      onTap: _flyToWorld,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          '🌍 World',
          style: TextStyle(
              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _buildTooltipCard(DotCluster cluster) {
    final place = cluster.commonTown != null
        ? '${cluster.commonTown}, ${cluster.commonCountry}'
        : cluster.commonCountry;
    final detail = widget.isApproval
        ? _sentimentLabel(cluster.averageScore)
        : cluster.topOption;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(place,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 2),
            Text(
              '${cluster.count} response${cluster.count == 1 ? '' : 's'} · $detail',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            if (_canFilter) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _filterToCluster(cluster),
                  icon: const Icon(Icons.filter_alt, size: 16),
                  label: const Text('Filter to here'),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 0)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLegendChips() {
    final chips = <Widget>[];
    if (widget.isApproval) {
      for (var i = 0; i < kApprovalBucketLabels.length; i++) {
        final selected = _highlightBucket == i;
        chips.add(_legendChip(
          label: kApprovalBucketLabels[i],
          color: approvalBucketColor(context, i),
          selected: selected,
          onTap: () => _toggleBucket(i),
        ));
      }
    } else {
      for (var i = 0; i < widget.options.length; i++) {
        final opt = widget.options[i];
        chips.add(_legendChip(
          label: opt,
          color: optionColor(context, opt, widget.options),
          selected: _highlightOption == opt,
          onTap: () => _toggleOption(opt),
        ));
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (_highlightOption != null || _highlightBucket != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: const Icon(Icons.clear, size: 16),
                label: const Text('Clear'),
                onPressed: _clearHighlight,
              ),
            ),
          ...chips,
        ],
      ),
    );
  }

  Widget _legendChip({
    required String label,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        avatar: CircleAvatar(backgroundColor: color, radius: 7),
        label: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  String _sentimentLabel(double value) {
    if (value <= -0.8) return 'Strongly Disapprove';
    if (value <= -0.3) return 'Disapprove';
    if (value <= 0.3) return 'Neutral';
    if (value <= 0.8) return 'Approve';
    return 'Strongly Approve';
  }
}
