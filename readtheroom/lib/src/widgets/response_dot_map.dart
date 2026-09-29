// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../utils/map_camera_logic.dart';
import '../utils/map_clustering.dart';
import '../utils/map_hit_targets.dart';
import '../utils/geojson_parser.dart';
import '../utils/results_colors.dart';
import '../screens/map_fullscreen_screen.dart';
import '../utils/approval_labels.dart';
import 'approval_spectrum_legend.dart';

/// World bounds used to fit the full-screen map when data spans the globe.
final LatLngBounds kWorldBounds = LatLngBounds(
  const LatLng(-55, -170),
  const LatLng(78, 179),
);

/// Ocean / empty background colour under the dot map basemap.
/// Dark mode follows the Dark Matter basemap convention: a near-black,
/// desaturated ocean (faint cool cast, not pure black) so the only saturated
/// colour on screen is the response data itself.
Color dotMapBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF10161A)
        : const Color(0xFFC3D8E3);

/// Muted landmass fill for the offline basemap. Dark mode keeps land only a
/// couple of steps lighter than the ocean — enough to read coastlines, low
/// enough in contrast and saturation that dots stay the unambiguous figure.
Color _basemapLand(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF222B30)
        : const Color(0xFFF8F6F1);

/// Country outline for the basemap — a hairline seam between land and land,
/// kept close to the land value so borders whisper rather than compete.
Color _basemapBorder(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF3A474E)
        : const Color(0xFFBCC7CD);

/// Builds subtle, theme-aware country polygons for the offline basemap.
///
/// Reuses [GeoJsonParser]'s parsed (and cached) country geometry — no tile
/// server. Both the inline preview and the full-screen map render this under
/// their [MarkerLayer].
List<Polygon> buildBasemapPolygons(BuildContext context, List<GeoCountry> geo) {
  final land = _basemapLand(context);
  final border = _basemapBorder(context);
  final polygons = <Polygon>[];
  for (final country in geo) {
    for (final part in country.parts) {
      polygons.add(Polygon(
        points: part.outerRing,
        holePointsList: part.holes.isNotEmpty ? part.holes : null,
        color: land,
        borderColor: border,
        borderStrokeWidth: 0.5,
        isFilled: true,
      ));
    }
  }
  return polygons;
}

/// A framing (center + zoom) for the inline preview, derived from the data.
/// Alias of the shared [CameraTarget] so the preview and the full-screen map
/// speak the same camera vocabulary.
typedef DotMapCamera = CameraTarget;

/// Computes a camera that fits every [points] anchor into a [width]×[height]
/// box (logical px) with [padding], clamped to [minZoom, maxZoom]. A tight
/// cluster of 1–2 cities is capped at [maxZoom] (never street level); only
/// globe-spanning data reaches [minZoom]. Deterministic — the inline preview
/// clusters at exactly this zoom.
DotMapCamera fitDotCamera(
  List<ClusterPoint> points,
  double width,
  double height, {
  double padding = 24.0,
  double minZoom = 0.4,
  double maxZoom = 6.0,
  double tileSize = 256.0,
}) {
  final bounds = GeoBounds.ofPositions(points.map((p) => p.position));
  if (bounds == null) {
    return const DotMapCamera(LatLng(20, 0), 0.6);
  }
  return cameraForBounds(
    bounds,
    width,
    height,
    padding: padding,
    minZoom: minZoom,
    maxZoom: maxZoom,
    tileSize: tileSize,
  );
}

/// Colour of a cluster given the question type.
Color clusterColor(
  BuildContext context, {
  required bool isApproval,
  required DotCluster cluster,
  required List<String> options,
}) {
  if (isApproval) {
    return ResultsColors.forApprovalBucket(context, cluster.averageScore);
  }
  return optionColor(context, cluster.topOption, options);
}

/// Colour for a specific MC option ('TIE' → neutral grey).
Color optionColor(BuildContext context, String option, List<String> options) {
  if (option == 'TIE') return Colors.grey.shade500;
  final i = options.indexOf(option);
  if (i >= 0) return ResultsColors.forOptionIndex(context, i);
  return Colors.grey.shade500;
}

/// Approval sentiment bucket colour by index 0..4.
Color approvalBucketColor(BuildContext context, int bucketIndex) {
  final colors = ResultsColors.approvalBinColors(context);
  return colors[bucketIndex.clamp(0, colors.length - 1)];
}

const List<String> kApprovalBucketLabels = [
  'Strongly Disapprove',
  'Disapprove',
  'Neutral',
  'Approve',
  'Strongly Approve',
];

/// Builds the flutter_map [Marker]s for a set of clusters.
///
/// When [highlightOption] (MC) or [highlightBucket] (approval) is set, clusters
/// that contain the highlighted answer recolour and resize to that answer's
/// count; clusters without it fade to 20% opacity.
///
/// [hitZoom] is the zoom [clusters] were computed at. When it and [onTap] are
/// given, each dot's tap target is enlarged beyond the visible dot without
/// overlapping its neighbours' (the visible dot size is unchanged).
List<Marker> buildDotMarkers(
  BuildContext context, {
  required List<DotCluster> clusters,
  required bool isApproval,
  required List<String> options,
  String? highlightOption,
  int? highlightBucket,
  void Function(DotCluster cluster)? onTap,
  double? hitZoom,
}) {
  // Dot rims: in dark mode a solid ocean-toned rim gives every dot the same
  // crisp halo whether it sits on land or water (a translucent black rim
  // shifted hue depending on what was underneath).
  final borderColor = Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF10161A)
      : Colors.white;
  final colors = <Color>[];
  final opacities = <double>[];
  final radii = <double>[];

  for (final cluster in clusters) {
    final bool highlighting = highlightOption != null || highlightBucket != null;
    int displayCount = cluster.count;
    Color color;
    double opacity = 1.0;

    if (highlighting) {
      final matchCount = highlightOption != null
          ? cluster.countForOption(highlightOption)
          : cluster.countForBucket(highlightBucket!);
      if (matchCount > 0) {
        displayCount = matchCount;
        color = highlightOption != null
            ? optionColor(context, highlightOption, options)
            : approvalBucketColor(context, highlightBucket!);
      } else {
        opacity = 0.2;
        color = clusterColor(
            context, isApproval: isApproval, cluster: cluster, options: options);
      }
    } else {
      color = clusterColor(
          context, isApproval: isApproval, cluster: cluster, options: options);
    }

    // Dots never carry count labels — the tap tooltip communicates the count.
    // Radius still reflects displayCount so highlighted answers resize.
    colors.add(color);
    opacities.add(opacity);
    radii.add(clusterRadius(displayCount));
  }

  // Tap targets: when the dots are tappable and the zoom is known, each dot's
  // hit circle reaches past its rim (toward a 44 px target) but stops where a
  // neighbour's would begin — see [dotHitRadii]. Otherwise hit = visible dot.
  final hitRadii = (onTap != null && hitZoom != null)
      ? dotHitRadii(
          [for (final c in clusters) projectToWorldPixels(c.position, hitZoom)],
          radii,
        )
      : radii;

  final markers = <Marker>[];
  for (var i = 0; i < clusters.length; i++) {
    final cluster = clusters[i];
    final size = radii[i] * 2;
    final hitSize = hitRadii[i] * 2;

    markers.add(Marker(
      point: cluster.position,
      width: hitSize,
      height: hitSize,
      alignment: Alignment.center,
      // ClipOval with Clip.none paints nothing extra but hit-tests as a
      // circle, so the (square) marker box never steals a neighbour's tap.
      child: ClipOval(
        clipBehavior: Clip.none,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap == null ? null : () => onTap(cluster),
          child: Center(
            child: Opacity(
              opacity: opacities[i],
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: colors[i],
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor, width: 1.5),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
  }
  return markers;
}

/// Non-interactive ~300px preview of the response dot map. A single tap
/// anywhere opens the full-screen interactive map.
class ResponseDotMap extends StatefulWidget {
  final List<ClusterPoint> points;
  final bool isApproval;
  final List<String> options;
  final String questionTitle;
  final String questionId;

  /// Called when the user filters from the full-screen map: `'City:<name>'`
  /// for a city dot, an ISO_A3 code for a country long-press, or null to
  /// clear. When null, the full-screen map hides its filter affordances
  /// entirely (e.g. maps opened from the home QOTD hero).
  final void Function(String?)? onCountryTap;

  /// Embedded form (QOTD hero card): just the map + legend at full width —
  /// no Card, question title, subtitle or data-source line (the host card
  /// already provides that context).
  final bool embedded;

  /// Drawn inside the card under the credit line (results pages put the
  /// reactions row here, owner 2026-09-22). Ignored when [embedded].
  final Widget? footer;

  /// Approval only: the question's end labels on the legend's spectrum.
  final ApprovalLabels approvalLabels;

  const ResponseDotMap({
    Key? key,
    required this.points,
    required this.isApproval,
    required this.options,
    required this.questionTitle,
    required this.questionId,
    this.onCountryTap,
    this.embedded = false,
    this.footer,
    this.approvalLabels = ApprovalLabels.defaults,
  }) : super(key: key);

  @override
  State<ResponseDotMap> createState() => _ResponseDotMapState();
}

class _ResponseDotMapState extends State<ResponseDotMap> {
  static const double _previewHeight = 300;

  List<GeoCountry>? _geo;

  @override
  void initState() {
    super.initState();
    _loadGeo();
  }

  Future<void> _loadGeo() async {
    final geo = await GeoJsonParser.loadCountries();
    if (mounted) setState(() => _geo = geo);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildMapPreview(context),
          const SizedBox(height: 12),
          _buildLegend(context),
        ],
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.questionTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white
                    : Colors.black,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            _buildMapPreview(context),
            const SizedBox(height: 12),
            _buildLegend(context),
            const SizedBox(height: 12),
            // Credit line: © + the name reads as a credit at a glance, where
            // "Data source:" needed a sentence (owner, 2026-09-22).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.copyright, size: 13, color: Colors.grey),
                SizedBox(width: 4),
                Text(
                  'Read the Room',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            if (widget.footer != null) ...[
              const SizedBox(height: 8),
              // Full width so a right-aligned footer (the reactions row) can
              // actually hug the right edge inside this centred column.
              SizedBox(width: double.infinity, child: widget.footer),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMapPreview(BuildContext context) {
    return ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: GestureDetector(
                // Opaque: the map below sits in an IgnorePointer, so with the
                // default deferToChild only the "Explore" chip was hit-testable
                // and taps on the map body did nothing. Tap-only, so vertical
                // drags still go to the parent scroll view.
                behavior: HitTestBehavior.opaque,
                onTap: () => _openFullscreen(context),
                child: Stack(
                  children: [
                    IgnorePointer(
                      child: SizedBox(
                        height: _previewHeight,
                        width: double.infinity,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth.isFinite
                                ? constraints.maxWidth
                                : MediaQuery.of(context).size.width;
                            final camera = fitDotCamera(
                              widget.points,
                              width,
                              _previewHeight,
                            );
                            final clusters =
                                clusterPoints(widget.points, camera.zoom);
                            return FlutterMap(
                              options: MapOptions(
                                initialCenter: camera.center,
                                initialZoom: camera.zoom,
                                minZoom: 0.3,
                                maxZoom: 15,
                                backgroundColor: dotMapBackground(context),
                                interactionOptions: const InteractionOptions(
                                  flags: InteractiveFlag.none,
                                ),
                              ),
                              children: [
                                if (_geo != null)
                                  PolygonLayer(
                                    polygons:
                                        buildBasemapPolygons(context, _geo!),
                                    polygonCulling: true,
                                  ),
                                MarkerLayer(
                                  markers: buildDotMarkers(
                                    context,
                                    clusters: clusters,
                                    isApproval: widget.isApproval,
                                    options: widget.options,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    // Tap-to-explore affordance, carrying the response count.
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.open_in_full,
                                color: Colors.white, size: 14),
                            const SizedBox(width: 6),
                            Text(
                                totalResponses(widget.points) == 1
                                    ? 'Explore 1 response'
                                    : 'Explore ${totalResponses(widget.points)} responses',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
    );
  }

  Widget _buildLegend(BuildContext context) {
    if (widget.isApproval) {
      return ApprovalSpectrumLegend(
        labels: widget.approvalLabels,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: [
        for (var i = 0; i < widget.options.length; i++)
          _legendDot(
              context, widget.options[i], ResultsColors.forOptionIndex(context, i)),
        _legendDot(context, 'Tie', Colors.grey.shade500),
      ],
    );
  }

  Widget _legendDot(BuildContext context, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
    );
  }

  void _openFullscreen(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MapFullscreenScreen(
        points: widget.points,
        isApproval: widget.isApproval,
        options: widget.options,
        questionTitle: widget.questionTitle,
        questionId: widget.questionId,
        onCountryTap: widget.onCountryTap,
      ),
    ));
  }
}
