// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../models/question_results.dart';
import '../utils/generation_utils.dart';
import '../utils/network_breakdown.dart';
import '../utils/results_colors.dart';

class CountryComparisonDialog extends StatefulWidget {
  final Map<String, Map<String, dynamic>> countryResponses;
  final Function(String, String) onCompare;
  final String questionTitle;
  final String questionId;
  final String questionType;
  final Map<String, double>? countryAverages;
  final Map<String, Map<String, dynamic>>? generationResponses;
  final Map<String, double>? generationAverages;
  final Map<String, String?>? generationMostPopular;

  /// The viewer's own network as a slice, or null when there is none to offer.
  /// Only when it is non-null can "My Network" be either side of a comparison.
  final ResultsBreakdown? networkBreakdown;

  /// The remainder the server withheld, which makes the row's count "N+".
  final int networkHidden;

  const CountryComparisonDialog({
    Key? key,
    required this.countryResponses,
    required this.onCompare,
    required this.questionTitle,
    required this.questionId,
    required this.questionType,
    this.countryAverages,
    this.generationResponses,
    this.generationAverages,
    this.generationMostPopular,
    this.networkBreakdown,
    this.networkHidden = 0,
  }) : super(key: key);

  static Future<List<String>?> show({
    required BuildContext context,
    required Map<String, Map<String, dynamic>> countryResponses,
    required String questionTitle,
    required String questionId,
    required String questionType,
    Map<String, double>? countryAverages,
    Map<String, Map<String, dynamic>>? generationResponses,
    Map<String, double>? generationAverages,
    Map<String, String?>? generationMostPopular,
    ResultsBreakdown? networkBreakdown,
    int networkHidden = 0,
  }) {
    return showDialog<List<String>?>(
      context: context,
      builder: (context) => CountryComparisonDialog(
        countryResponses: countryResponses,
        questionTitle: questionTitle,
        questionId: questionId,
        questionType: questionType,
        countryAverages: countryAverages,
        generationResponses: generationResponses,
        generationAverages: generationAverages,
        generationMostPopular: generationMostPopular,
        networkBreakdown: networkBreakdown,
        networkHidden: networkHidden,
        onCompare: (country1, country2) {
          Navigator.of(context).pop([country1, country2]);
        },
      ),
    );
  }

  @override
  State<CountryComparisonDialog> createState() => _CountryComparisonDialogState();
}

class _CountryComparisonDialogState extends State<CountryComparisonDialog> {
  String? _selectedCountry1;
  String? _selectedCountry2;
  String _searchQuery = '';
  late List<String> _sortedCountries;

  @override
  void initState() {
    super.initState();
    _sortedCountries = widget.countryResponses.entries
        .map((e) => e.key)
        .toList()
      ..sort((a, b) {
        final aTotal = widget.countryResponses[a]?['total'] as int? ?? 0;
        final bTotal = widget.countryResponses[b]?['total'] as int? ?? 0;
        return bTotal.compareTo(aTotal);
      });

    // Add "World" as an option for comparison
    _sortedCountries.insert(0, 'World');
  }

  // Get display name for selected country/generation
  String _getDisplayName(String? selection) {
    if (selection == null) return 'Select';
    if (selection == 'World') return 'World';
    if (isNetworkFilter(selection)) return kNetworkFilterLabel;
    if (selection.startsWith('Gen:')) {
      final genId = selection.substring(4);
      return getGenerationLabel(genId);
    }
    return selection; // Regular country name
  }

  Color _getColorForValue(double value) =>
      ResultsColors.forApprovalValue(context, value);

  Color _getCountryColor(String countryName) {
    // My Network — coloured by what the network said, like any other side.
    if (isNetworkFilter(countryName)) {
      final network = widget.networkBreakdown;
      if (network != null &&
          widget.questionType == 'approval' &&
          network.average != null) {
        return _getColorForValue(network.average!);
      }
      return Theme.of(context).primaryColor;
    }

    // Handle Generation filter - match country color behavior
    if (countryName.startsWith('Gen:')) {
      final genId = countryName.substring(4);
      if (widget.questionType == 'approval' && widget.generationAverages != null) {
        final average = widget.generationAverages![genId];
        if (average != null) return _getColorForValue(average);
      }
      if (widget.questionType == 'multiple_choice' && widget.generationMostPopular != null) {
        final mostPopular = widget.generationMostPopular![genId];
        if (mostPopular != null) {
          // Use same color logic as countries - find option index
          final colors = ResultsColors.multipleChoiceColors(context);
          return colors[mostPopular.hashCode % colors.length];
        }
      }
      return Theme.of(context).primaryColor;
    }

    // Handle World option specially
    if (countryName == 'World') {
      final totalResponsesGlobal = widget.countryResponses.values.fold<int>(0,
        (sum, data) => sum + (data['total'] as int? ?? 0));

      if (widget.questionType == 'approval' && widget.countryAverages != null) {
        // Calculate weighted global average from country averages
        double totalWeightedValue = 0;
        int totalResponsesFromAverages = 0;

        widget.countryAverages!.forEach((country, average) {
          final countryResponseCount = widget.countryResponses[country]?['total'] as int? ?? 0;
          totalWeightedValue += average * countryResponseCount;
          totalResponsesFromAverages += countryResponseCount;
        });

        if (totalResponsesFromAverages > 0) {
          final globalAverage = totalWeightedValue / totalResponsesFromAverages;
          return _getColorForValue(globalAverage);
        }
      }

      return totalResponsesGlobal > 3
          ? Theme.of(context).primaryColor
          : Colors.grey[400]!;
    }

    if (widget.questionType == 'approval' && widget.countryAverages != null) {
      final average = widget.countryAverages![countryName];
      if (average != null) {
        return _getColorForValue(average);
      }
    }

    final responseCount = widget.countryResponses[countryName]?['total'] as int? ?? 0;
    return responseCount > 3
        ? Theme.of(context).primaryColor
        : Colors.grey[400]!;
  }

  // Get colors that will be used in the comparison plot
  Color _getComparisonColor(bool isCountry1) {
    if (isCountry1) {
      // Country 1 color based on theme (matches approval_results_screen logic)
      return Theme.of(context).brightness == Brightness.light
          ? Theme.of(context).primaryColor
          : Color(0xFF55C5B4);
    } else {
      // Country 2 color
      return Color(0xFFFF6569);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalResponsesGlobal = widget.countryResponses.values.fold<int>(0,
      (sum, data) => sum + (data['total'] as int? ?? 0));

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Compare'),
          SizedBox(height: 4),
          Text(
            widget.questionTitle.length > 50
                ? '${widget.questionTitle.substring(0, 50)}...'
                : widget.questionTitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
      content: Container(
        width: double.maxFinite,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Selected options display
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).primaryColor.withOpacity(0.2),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'Selection 1',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          _getDisplayName(_selectedCountry1),
                          style: TextStyle(
                            fontWeight: _selectedCountry1 != null ? FontWeight.bold : null,
                            color: _selectedCountry1 != null
                                ? _getComparisonColor(true)
                                : Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.compare_arrows,
                    color: Theme.of(context).primaryColor,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'Selection 2',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          _getDisplayName(_selectedCountry2),
                          style: TextStyle(
                            fontWeight: _selectedCountry2 != null ? FontWeight.bold : null,
                            color: _selectedCountry2 != null
                                ? _getComparisonColor(false)
                                : Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: 16),

            // World option (always visible at top)
            _buildCountryOption(
              countryName: 'World',
              responseCount: totalResponsesGlobal,
              percentage: 100,
              subtitle: 'All responses ($totalResponsesGlobal)',
            ),

            // Divider between fixed options and searchable content
            Divider(),

            SizedBox(height: 8),

            // Search bar for countries
            if (_sortedCountries.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    contentPadding: EdgeInsets.symmetric(vertical: 8.0),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                ),
              ),
              SizedBox(height: 12),
            ],

            // Scrollable list: Generations + Countries
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // My Network, first in the list and directly under World —
                  // only when the server gave us a slice. It lives inside the
                  // scroll area rather than next to World because everything
                  // above the list here is fixed height, and a short screen has
                  // no room left for another fixed row.
                  if (widget.networkBreakdown != null)
                    _buildCountryOption(
                      countryName: kNetworkFilter,
                      displayName: kNetworkFilterLabel,
                      leading: Icons.hub_rounded,
                      responseCount: widget.networkBreakdown!.count,
                      percentage: 0,
                      subtitle:
                          '${networkCountLabel(widget.networkBreakdown!.count, widget.networkHidden)} answers · $kNetworkFilterSubtitle',
                    ),

                  // Generations section
                  ..._buildGenerationsSection(totalResponsesGlobal),

                  // Countries heading
                  if (_sortedCountries.where((c) => c != 'World').isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(left: 8, top: 8, bottom: 4),
                      child: Text(
                        'Countries',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.grey[500],
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),

                  // Top 5 countries
                  ..._buildTopCountriesList(totalResponsesGlobal),
                ],
              ),
            ),

            SizedBox(height: 16),

            // Compare button
            Center(
              child: ElevatedButton(
                onPressed: (_selectedCountry1 != null && _selectedCountry2 != null)
                    ? () {
                        widget.onCompare(_selectedCountry1!, _selectedCountry2!);
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: Text(
                  'Compare',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildCountryOption({
    required String countryName,
    required int responseCount,
    required int percentage,
    required String subtitle,
    bool isEnabled = true,
    String? displayName,
    IconData? leading,
    VoidCallback? onTapOverride,
  }) {
    final isSelected = _selectedCountry1 == countryName || _selectedCountry2 == countryName;
    final isCountry1 = _selectedCountry1 == countryName;
    final effectiveDisplayName = displayName ?? countryName;

    return InkWell(
      onTap: onTapOverride ?? (isEnabled ? () {
        setState(() {
          if (_selectedCountry1 == countryName) {
            _selectedCountry1 = null;
          } else if (_selectedCountry2 == countryName) {
            _selectedCountry2 = null;
          } else if (_selectedCountry1 == null) {
            _selectedCountry1 = countryName;
          } else if (_selectedCountry2 == null) {
            _selectedCountry2 = countryName;
          } else {
            // Replace the first selection
            _selectedCountry1 = countryName;
          }
        });
      } : null),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected && isEnabled
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: isEnabled
                  ? _getCountryColor(countryName)
                  : Colors.grey[400]!,
                shape: BoxShape.circle,
              ),
              child: leading == null
                  ? null
                  : Icon(leading, size: 12, color: Colors.white),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    effectiveDisplayName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: isEnabled
                        ? (isSelected
                            ? Theme.of(context).primaryColor
                            : null)
                        : Colors.grey[500],
                      fontWeight: isSelected && isEnabled ? FontWeight.bold : null,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isEnabled ? Colors.grey[600] : Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected && isEnabled)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isCountry1 ? '1' : '2',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildGenerationsSection(int totalResponsesGlobal) {
    if (widget.generationResponses == null || widget.generationResponses!.isEmpty) {
      return [];
    }

    var genEntries = widget.generationResponses!.entries
        .where((e) => (e.value['total'] as int? ?? 0) > 5)
        .toList()
      ..sort((a, b) {
        final aTotal = a.value['total'] as int? ?? 0;
        final bTotal = b.value['total'] as int? ?? 0;
        return bTotal.compareTo(aTotal);
      });

    if (_searchQuery.isNotEmpty) {
      genEntries = genEntries.where((e) {
        final label = getGenerationLabel(e.key);
        return label.toLowerCase().contains(_searchQuery.toLowerCase());
      }).toList();
    }

    if (genEntries.isEmpty) return [];

    return [
      Padding(
        padding: EdgeInsets.only(left: 8, top: 8, bottom: 4),
        child: Text(
          'Generations',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.grey[500],
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      ...genEntries.map((entry) {
        final genId = entry.key;
        final data = entry.value;
        final total = data['total'] as int? ?? 0;
        final percentage = totalResponsesGlobal > 0 ? (total / totalResponsesGlobal * 100).round() : 0;
        final filterKey = 'Gen:$genId';
        final label = getGenerationLabel(genId);

        return _buildCountryOption(
          countryName: filterKey,
          responseCount: total,
          percentage: percentage,
          subtitle: '$percentage% ($total responses)',
          displayName: label,
        );
      }),
    ];
  }

  List<Widget> _buildTopCountriesList(int totalResponsesGlobal) {
    // Get countries excluding World
    final countriesWithoutWorld = _sortedCountries.where((country) => country != 'World').toList();

    // Filter countries by search query
    final filteredCountries = _searchQuery.isEmpty
        ? countriesWithoutWorld
        : countriesWithoutWorld.where((country) {
            return country.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();

    // Take top 5 countries
    final topCountries = filteredCountries.take(5).toList();

    return topCountries.map((country) {
      final data = widget.countryResponses[country];
      final total = data?['total'] as int? ?? 0;
      final percentage = totalResponsesGlobal > 0 ? (total / totalResponsesGlobal * 100).round() : 0;

      return _buildCountryOption(
        countryName: country,
        responseCount: total,
        percentage: percentage,
        subtitle: '$percentage% ($total responses)',
      );
    }).toList();
  }
}
