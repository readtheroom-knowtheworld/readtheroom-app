// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../services/country_service.dart';
import '../services/question_service.dart';
import 'choropleth_map_base.dart';

class CountryMultipleChoiceMap extends StatefulWidget {
  final List<Map<String, dynamic>> responsesByCountry;
  final String questionTitle;
  final List<String> options;
  final String questionId;
  final Function(String?)? onCountryTap;
  final ValueChanged<bool>? onZoomChanged;

  const CountryMultipleChoiceMap({
    Key? key,
    required this.responsesByCountry,
    required this.questionTitle,
    required this.options,
    required this.questionId,
    this.onCountryTap,
    this.onZoomChanged,
  }) : super(key: key);

  @override
  _CountryMultipleChoiceMapState createState() =>
      _CountryMultipleChoiceMapState();
}

class _CountryMultipleChoiceMapState extends State<CountryMultipleChoiceMap> {
  List<MultipleChoiceModel> _multipleChoiceData = [];
  List<ChoroplethEntry> _choroplethEntries = [];
  bool _isLoading = true;

  MapGranularity _granularity = MapGranularity.country;
  List<MapMarkerEntry> _markers = [];
  List<Map<String, dynamic>>? _cityEnrichedResponses;
  bool _isLoadingCityData = false;

  // Define colors for options
  final List<Color> _optionColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.indigo,
  ];

  @override
  void initState() {
    super.initState();
    _prepareMultipleChoiceData();
  }

  @override
  void didUpdateWidget(CountryMultipleChoiceMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.responsesByCountry != oldWidget.responsesByCountry ||
        widget.options != oldWidget.options) {
      _prepareMultipleChoiceData();
      // Reset city data on new responses
      _cityEnrichedResponses = null;
      _markers = [];
      _granularity = MapGranularity.country;
    }
  }

  Future<void> _prepareMultipleChoiceData() async {
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

      print('🗺️ MultipleChoiceMap: Found ${countriesWithResponses.length} countries with responses from ${widget.responsesByCountry.length} total responses');

      // If no valid countries found, don't proceed with map rendering
      if (countriesWithResponses.isEmpty) {
        if (mounted) {
          setState(() {
            _multipleChoiceData = [];
            _choroplethEntries = [];
            _isLoading = false;
          });
        }
        return;
      }

      // Convert the responses by country to our model
      final List<MultipleChoiceModel> multipleChoiceData = [];

      // Create a map of country codes to choice counts
      final Map<String, Map<String, int>> countByCountry = {};

      // Get ISO codes in batches for countries with responses
      final Map<String, String> countryToIsoCache = {};

      // First pass: collect all country names and get their ISO codes
      for (String countryName in countriesWithResponses) {
        final String? isoCode =
            await CountryService.getIsoCodeForCountry(countryName);
        if (isoCode != null && isoCode.isNotEmpty && isoCode != 'ATA') {
          countryToIsoCache[countryName] = isoCode;
          countByCountry[isoCode] = {};
        }
      }

      // Second pass: aggregate responses using cached ISO codes
      for (var response in widget.responsesByCountry) {
        final String country = response['country']?.toString() ?? '';
        final String answer = response['answer']?.toString() ?? '';

        if (country.isNotEmpty &&
            answer.isNotEmpty &&
            countryToIsoCache.containsKey(country)) {
          final String isoCode = countryToIsoCache[country]!;
          if (!countByCountry[isoCode]!.containsKey(answer)) {
            countByCountry[isoCode]![answer] = 0;
          }
          countByCountry[isoCode]![answer] =
              (countByCountry[isoCode]![answer] ?? 0) + 1;
        } else if (country.isNotEmpty) {
          print('⚠️ Country "$country" not found in ISO cache during aggregation');
        }
      }

      // Calculate most popular choice for each country with responses
      countByCountry.forEach((isoCode, choices) {
        if (choices.isEmpty) {
          return;
        } else {
          // Find the most popular choice
          String mostPopularChoice = choices.entries
              .reduce((a, b) => a.value > b.value ? a : b)
              .key;

          // Check for ties
          final maxCount = choices[mostPopularChoice]!;
          final tiedChoices = choices.entries
              .where((entry) => entry.value == maxCount)
              .map((entry) => entry.key)
              .toList();

          if (tiedChoices.length > 1) {
            multipleChoiceData
                .add(MultipleChoiceModel(country: isoCode, choice: 'TIE'));
          } else {
            multipleChoiceData.add(
                MultipleChoiceModel(country: isoCode, choice: mostPopularChoice));
          }
        }
      });

      // Build choropleth entries with pre-resolved country names
      final entries = <ChoroplethEntry>[];
      for (final item in multipleChoiceData) {
        final countryName =
            await CountryService.getCountryNameFromIso(item.country) ??
                item.country;
        String choiceText;
        if (item.choice == 'NO_DATA') {
          choiceText = 'No responses';
        } else if (item.choice == 'TIE') {
          choiceText = 'Tied responses';
        } else {
          choiceText = item.choice;
        }
        entries.add(ChoroplethEntry(
          isoA3: item.country,
          color: _colorForChoice(item.choice),
          tooltip: '$countryName: $choiceText',
        ));
      }

      print('Prepared multiple choice map data for ${multipleChoiceData.length} countries');

      if (mounted) {
        setState(() {
          _multipleChoiceData = multipleChoiceData;
          _choroplethEntries = entries;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error preparing multiple choice data: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadCityData() async {
    if (_cityEnrichedResponses != null || _isLoadingCityData) return;

    setState(() {
      _isLoadingCityData = true;
    });

    try {
      final data = await QuestionService()
          .getMultipleChoiceResponsesWithCityData(widget.questionId);
      if (mounted) {
        setState(() {
          _cityEnrichedResponses = data;
          _isLoadingCityData = false;
        });
        _buildMarkers(_granularity);
      }
    } catch (e) {
      print('Error loading city data for MC map: $e');
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
        int locCount = 0;
        final Map<String, int> optionCounts = {};
        String stateName = entry.key;

        for (final r in responses) {
          final city = r['cities'];
          final lat = (city['lat'] as num?)?.toDouble();
          final lng = (city['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            latSum += lat;
            lngSum += lng;
            locCount++;
          }
          final optionText = r['question_options']?['option_text']?.toString();
          if (optionText != null) {
            optionCounts[optionText] = (optionCounts[optionText] ?? 0) + 1;
          }
          if (stateName == entry.key) {
            stateName = city['admin1_code']?.toString() ?? entry.key;
          }
        }

        if (locCount == 0 || optionCounts.isEmpty) continue;
        final avgLat = latSum / locCount;
        final avgLng = lngSum / locCount;
        final topOption = optionCounts.entries
            .reduce((a, b) => a.value > b.value ? a : b);
        final totalVotes = optionCounts.values.fold(0, (a, b) => a + b);
        final radius = _scaleRadius(totalVotes);

        markers.add(MapMarkerEntry(
          position: LatLng(avgLat, avgLng),
          color: _colorForChoice(topOption.key),
          radius: radius,
          tooltip: '$stateName: ${topOption.key} ($totalVotes votes)',
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

        final Map<String, int> optionCounts = {};
        for (final r in responses) {
          final optionText = r['question_options']?['option_text']?.toString();
          if (optionText != null) {
            optionCounts[optionText] = (optionCounts[optionText] ?? 0) + 1;
          }
        }

        if (optionCounts.isEmpty) continue;
        final cityName = firstCity['ascii_name']?.toString() ?? 'Unknown';
        final topOption = optionCounts.entries
            .reduce((a, b) => a.value > b.value ? a : b);
        final totalVotes = optionCounts.values.fold(0, (a, b) => a + b);
        final radius = _scaleRadius(totalVotes);

        markers.add(MapMarkerEntry(
          position: LatLng(lat, lng),
          color: _colorForChoice(topOption.key),
          radius: radius,
          tooltip: '$cityName: ${topOption.key} ($totalVotes votes)',
        ));
      }
    }

    setState(() {
      _markers = markers;
    });
  }

  double _scaleRadius(int count) {
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

  Color _colorForChoice(String choice) {
    if (choice == 'TIE') return Colors.grey[400]!;
    if (choice == 'NO_DATA') return Colors.transparent;
    final index = widget.options.indexOf(choice);
    if (index >= 0) return _optionColors[index % _optionColors.length];
    return Colors.grey[400]!;
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
              'Top Choice',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            // TODO: Re-enable granularity toggle when user base grows
            if (false) ...[
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
                : widget.responsesByCountry.isEmpty || _multipleChoiceData.isEmpty
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
            // Custom legend with option colors
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16.0,
              runSpacing: 8.0,
              children: [
                ...widget.options.asMap().entries.map((entry) {
                  final index = entry.key;
                  final option = entry.value;
                  final color = _optionColors[index % _optionColors.length];
                  return _buildOptionLegendItem(option, color);
                }),
                _buildTieLegendItem(),
                _buildNoDataLegendItem(),
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

  Widget _buildOptionLegendItem(String option, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: 4),
        Flexible(
          child: Text(
            option,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
    );
  }

  Widget _buildTieLegendItem() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.grey[400],
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: 4),
        Text(
          'Tie',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildNoDataLegendItem() {
    final noDataColor = Theme.of(context).brightness == Brightness.dark
        ? Theme.of(context).colorScheme.surface
        : Colors.white;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: noDataColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey[300]!, width: 0.5),
          ),
        ),
        SizedBox(width: 4),
        Text(
          'No data',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }
}

class MultipleChoiceModel {
  final String country;
  final String choice;

  MultipleChoiceModel({
    required this.country,
    required this.choice,
  });
}
