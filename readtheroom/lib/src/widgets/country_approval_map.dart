// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../services/country_service.dart';
import '../services/question_service.dart';
import 'choropleth_map_base.dart';

class CountryApprovalMap extends StatefulWidget {
  final List<Map<String, dynamic>> responsesByCountry;
  final String questionTitle;
  final String? questionId;
  final Function(String?)? onCountryTap;
  final ValueChanged<bool>? onZoomChanged;

  const CountryApprovalMap({
    Key? key,
    required this.responsesByCountry,
    required this.questionTitle,
    this.questionId,
    this.onCountryTap,
    this.onZoomChanged,
  }) : super(key: key);

  @override
  _CountryApprovalMapState createState() => _CountryApprovalMapState();
}

class _CountryApprovalMapState extends State<CountryApprovalMap> {
  List<ApprovalModel> _approvalData = [];
  List<ChoroplethEntry> _choroplethEntries = [];
  bool _isLoading = true;

  MapGranularity _granularity = MapGranularity.country;
  List<MapMarkerEntry> _markers = [];
  List<Map<String, dynamic>>? _cityEnrichedResponses;
  bool _isLoadingCityData = false;

  @override
  void initState() {
    super.initState();
    _prepareApprovalData();
  }

  @override
  void didUpdateWidget(CountryApprovalMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.responsesByCountry != oldWidget.responsesByCountry) {
      _prepareApprovalData();
      // Reset city data on new responses
      _cityEnrichedResponses = null;
      _markers = [];
      _granularity = MapGranularity.country;
    }
  }

  Future<void> _prepareApprovalData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Preload country mappings for better performance
      await CountryService.preloadCountryMappings();

      // Only get countries that have actual responses to avoid loading all countries
      final Set<String> countriesWithResponses = {};
      for (var response in widget.responsesByCountry) {
        final String country = response['country']?.toString() ?? '';
        // Skip responses without valid country data or with problematic countries
        if (country.isNotEmpty &&
            country != 'Unknown' &&
            country != 'null' &&
            !country.toLowerCase().contains('antarctica')) {
          countriesWithResponses.add(country);
        }
      }

      print('🗺️ ApprovalMap: Found ${countriesWithResponses.length} countries with responses from ${widget.responsesByCountry.length} total responses');

      // If no valid countries found, don't proceed with map rendering
      if (countriesWithResponses.isEmpty) {
        if (mounted) {
          setState(() {
            _approvalData = [];
            _choroplethEntries = [];
            _isLoading = false;
          });
        }
        return;
      }

      // Convert the responses by country to our model
      final List<ApprovalModel> approvalData = [];

      // Create a map of country codes to approval values
      final Map<String, double> approvalByCountry = {};
      final Map<String, int> countByCountry = {};

      // Process actual response data and get ISO codes in batches
      final Map<String, String> countryToIsoCache = {};

      // First pass: collect all country names and get their ISO codes
      for (String countryName in countriesWithResponses) {
        final String? isoCode = await CountryService.getIsoCodeForCountry(countryName);
        if (isoCode != null && isoCode.isNotEmpty && isoCode != 'ATA') {
          countryToIsoCache[countryName] = isoCode;
          approvalByCountry[isoCode] = 0.0;
          countByCountry[isoCode] = 0;
        }
      }

      // Second pass: aggregate responses using cached ISO codes
      for (var response in widget.responsesByCountry) {
        final String country = response['country']?.toString() ?? '';
        final double answer = (response['answer'] as double?) ?? 0.0;

        if (country.isNotEmpty && countryToIsoCache.containsKey(country)) {
          final String isoCode = countryToIsoCache[country]!;
          approvalByCountry[isoCode] = (approvalByCountry[isoCode] ?? 0) + answer;
          countByCountry[isoCode] = (countByCountry[isoCode] ?? 0) + 1;
        } else if (country.isNotEmpty) {
          print('⚠️ Country "$country" not found in ISO cache during aggregation');
        }
      }

      // Calculate average approval value for each country with responses
      approvalByCountry.forEach((isoCode, approvalSum) {
        final int total = countByCountry[isoCode] ?? 0;
        if (total > 0) {
          final double averageApproval = approvalSum / total;
          approvalData.add(ApprovalModel(country: isoCode, approvalRate: averageApproval));
        }
      });

      // Build choropleth entries with pre-resolved country names
      final entries = <ChoroplethEntry>[];
      for (final item in approvalData) {
        final countryName =
            await CountryService.getCountryNameFromIso(item.country) ??
                item.country;
        final sentimentLabel = _getSentimentLabel(item.approvalRate);
        entries.add(ChoroplethEntry(
          isoA3: item.country,
          color: _colorForApproval(item.approvalRate),
          tooltip: '$countryName: $sentimentLabel',
        ));
      }

      print('Prepared approval map data for ${approvalData.length} countries');

      if (mounted) {
        setState(() {
          _approvalData = approvalData;
          _choroplethEntries = entries;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error preparing approval data: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  bool get _showToggle =>
      widget.questionId != null && widget.questionId!.isNotEmpty;

  Future<void> _loadCityData() async {
    if (_cityEnrichedResponses != null || _isLoadingCityData) return;
    if (widget.questionId == null || widget.questionId!.isEmpty) return;

    setState(() {
      _isLoadingCityData = true;
    });

    try {
      final data = await QuestionService()
          .getApprovalResponsesWithCityData(widget.questionId!);
      if (mounted) {
        setState(() {
          _cityEnrichedResponses = data;
          _isLoadingCityData = false;
        });
        _buildMarkers(_granularity);
      }
    } catch (e) {
      print('Error loading city data for approval map: $e');
      if (mounted) {
        setState(() {
          _isLoadingCityData = false;
        });
      }
    }
  }

  void _buildMarkers(MapGranularity granularity) {
    if (_cityEnrichedResponses == null || granularity == MapGranularity.country) {
      setState(() {
        _markers = [];
      });
      return;
    }

    final markers = <MapMarkerEntry>[];

    if (granularity == MapGranularity.state) {
      // Group by admin1_code + country_code
      final Map<String, List<Map<String, dynamic>>> stateGroups = {};
      for (final r in _cityEnrichedResponses!) {
        final city = r['cities'];
        if (city == null) continue;
        final admin1 = city['admin1_code']?.toString() ?? '';
        final countryCode = city['country_code']?.toString() ?? '';
        if (admin1.isEmpty) continue;
        final key = '${countryCode}_$admin1';
        stateGroups.putIfAbsent(key, () => []).add(r);
      }

      for (final entry in stateGroups.entries) {
        final responses = entry.value;
        if (responses.length <= 3) continue; // Privacy threshold

        double latSum = 0, lngSum = 0;
        double scoreSum = 0;
        int count = 0;
        String stateName = entry.key;

        for (final r in responses) {
          final city = r['cities'];
          final lat = (city['lat'] as num?)?.toDouble();
          final lng = (city['lng'] as num?)?.toDouble();
          final score = (r['score'] as num?)?.toDouble();
          if (lat == null || lng == null || score == null) continue;
          latSum += lat;
          lngSum += lng;
          scoreSum += score / 100.0; // Convert from -100/100 to -1/1
          count++;
          // Use first city's admin1_code as label
          if (stateName == entry.key) {
            stateName = city['admin1_code']?.toString() ?? entry.key;
          }
        }

        if (count <= 3) continue;
        final avgLat = latSum / count;
        final avgLng = lngSum / count;
        final avgScore = scoreSum / count;
        final sentiment = _getSentimentLabel(avgScore);
        final radius = _scaleRadius(count);

        markers.add(MapMarkerEntry(
          position: LatLng(avgLat, avgLng),
          color: _colorForApproval(avgScore),
          radius: radius,
          tooltip: '$stateName: $sentiment ($count votes)',
        ));
      }
    } else if (granularity == MapGranularity.city) {
      // Group by city_id
      final Map<String, List<Map<String, dynamic>>> cityGroups = {};
      for (final r in _cityEnrichedResponses!) {
        final cityId = r['city_id']?.toString();
        if (cityId == null) continue;
        cityGroups.putIfAbsent(cityId, () => []).add(r);
      }

      for (final entry in cityGroups.entries) {
        final responses = entry.value;
        if (responses.length <= 3) continue; // Privacy threshold

        final firstCity = responses.first['cities'];
        if (firstCity == null) continue;
        final lat = (firstCity['lat'] as num?)?.toDouble();
        final lng = (firstCity['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;

        double scoreSum = 0;
        int count = 0;
        for (final r in responses) {
          final score = (r['score'] as num?)?.toDouble();
          if (score == null) continue;
          scoreSum += score / 100.0;
          count++;
        }

        if (count <= 3) continue;
        final avgScore = scoreSum / count;
        final cityName = firstCity['ascii_name']?.toString() ?? 'Unknown';
        final sentiment = _getSentimentLabel(avgScore);
        final radius = _scaleRadius(count);

        markers.add(MapMarkerEntry(
          position: LatLng(lat, lng),
          color: _colorForApproval(avgScore),
          radius: radius,
          tooltip: '$cityName: $sentiment ($count votes)',
        ));
      }
    }

    setState(() {
      _markers = markers;
    });
  }

  double _scaleRadius(int count) {
    // Scale from 6 to 20 based on count (log scale)
    if (count <= 4) return 6.0;
    final scaled = 6.0 + 14.0 * (count.clamp(4, 200) - 4) / 196.0;
    return scaled.clamp(6.0, 20.0);
  }

  void _onGranularityChanged(MapGranularity granularity) {
    setState(() {
      _granularity = granularity;
    });

    if (granularity != MapGranularity.country) {
      if (_cityEnrichedResponses == null) {
        _loadCityData();
      } else {
        _buildMarkers(granularity);
      }
    } else {
      setState(() {
        _markers = [];
      });
    }
  }

  Color _colorForApproval(double value) {
    if (value <= -0.8) return Colors.red;
    if (value <= -0.3) return Colors.red[300]!;
    if (value <= 0.3) return Colors.grey.shade300;
    if (value <= 0.8) return Colors.lightGreen;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
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
            const SizedBox(height: 8),
            Text(
              'Average Response',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            // TODO: Re-enable granularity toggle when user base grows
            if (false && _showToggle) ...[
              const SizedBox(height: 12),
              // Granularity toggle
              SegmentedButton<MapGranularity>(
                segments: const [
                  ButtonSegment(
                    value: MapGranularity.country,
                    label: Text('Country'),
                    icon: Icon(Icons.public, size: 16),
                  ),
                  ButtonSegment(
                    value: MapGranularity.state,
                    label: Text('State'),
                    icon: Icon(Icons.map, size: 16),
                  ),
                  ButtonSegment(
                    value: MapGranularity.city,
                    label: Text('City'),
                    icon: Icon(Icons.location_city, size: 16),
                  ),
                ],
                selected: {_granularity},
                onSelectionChanged: (selected) {
                  _onGranularityChanged(selected.first);
                },
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(
                    TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _isLoading || _isLoadingCityData
                ? const SizedBox(
                    height: 300,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : widget.responsesByCountry.isEmpty || _approvalData.isEmpty
                    ? const SizedBox(
                        height: 300,
                        child: Center(child: Text('No geographic data available')),
                      )
                    : ChoroplethMapBase(
                        entries: _choroplethEntries,
                        onCountryTap: widget.onCountryTap,
                        markers: _markers,
                        neutralPolygons: _granularity != MapGranularity.country,
                        onZoomChanged: widget.onZoomChanged,
                      ),
            const SizedBox(height: 16),
            // Custom legend with icons
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12.0,
              runSpacing: 8.0,
              children: [
                _getIconForSentiment('Strongly Disapprove'),
                _getIconForSentiment('Disapprove'),
                _getIconForSentiment('Neutral'),
                _getIconForSentiment('Approve'),
                _getIconForSentiment('Strongly Approve'),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Data source: Read the Room',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  String _getSentimentLabel(double value) {
    if (value == -99.0) return 'No Data';
    if (value <= -0.8) return 'Strongly Disapprove';
    if (value <= -0.3) return 'Disapprove';
    if (value <= 0.3) return 'Neutral';
    if (value <= 0.8) return 'Approve';
    return 'Strongly Approve';
  }

  Widget _getIconForSentiment(String sentiment) {
    switch (sentiment) {
      case 'Strongly Disapprove':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.thumb_down, color: Colors.red, size: 16),
            SizedBox(width: 2),
            Icon(Icons.thumb_down, color: Colors.red, size: 16),
          ],
        );
      case 'Disapprove':
        return Icon(Icons.thumb_down, color: Colors.red[300]!, size: 16);
      case 'Neutral':
        return Icon(Icons.sentiment_neutral, color: Colors.grey.shade300, size: 16);
      case 'Approve':
        return Icon(Icons.thumb_up, color: Colors.lightGreen, size: 16);
      case 'Strongly Approve':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.thumb_up, color: Colors.green, size: 16),
            SizedBox(width: 2),
            Icon(Icons.thumb_up, color: Colors.green, size: 16),
          ],
        );
      default:
        return Icon(Icons.sentiment_neutral, color: Colors.grey[300], size: 16);
    }
  }

}

class ApprovalModel {
  final String country;
  final double approvalRate;

  ApprovalModel({
    required this.country,
    required this.approvalRate,
  });
}
