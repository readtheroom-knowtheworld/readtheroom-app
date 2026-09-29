// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../models/question_results.dart';
import '../utils/generation_utils.dart';
import '../utils/network_breakdown.dart';

class CountryFilterDialog extends StatefulWidget {
  final Map<String, Map<String, dynamic>> countryResponses;
  final String? currentSelectedCountry;
  final Function(String?) onCountrySelected;
  final String questionTitle;
  final String questionId;
  final String questionType; // 'approval', 'multiple_choice', 'text'
  final Map<String, double>? countryAverages; // Only for approval questions
  final List<String>? questionOptions; // Only for multiple choice questions
  final Map<String, String?>? countryMostPopular; // Only for multiple choice questions
  final Map<String, Map<String, dynamic>>? generationResponses; // Generation response data
  final Map<String, double>? generationAverages; // Only for approval questions
  final Map<String, String?>? generationMostPopular; // Only for multiple choice questions

  /// The viewer's own network as a slice, or null when there is none to offer —
  /// the row is drawn ONLY when this is non-null, so a gated or undeployed
  /// network leaves the dialog exactly as it was before the feature existed.
  final ResultsBreakdown? networkBreakdown;

  /// The remainder the server withheld from the network count, which turns the
  /// row's count into "N+" just like the aggregate card.
  final int networkHidden;

  const CountryFilterDialog({
    Key? key,
    required this.countryResponses,
    required this.currentSelectedCountry,
    required this.onCountrySelected,
    required this.questionTitle,
    required this.questionId,
    this.questionType = 'text',
    this.countryAverages,
    this.questionOptions,
    this.countryMostPopular,
    this.generationResponses,
    this.generationAverages,
    this.generationMostPopular,
    this.networkBreakdown,
    this.networkHidden = 0,
  }) : super(key: key);

  static Future<String?> show({
    required BuildContext context,
    required Map<String, Map<String, dynamic>> countryResponses,
    required String? currentSelectedCountry,
    required String questionTitle,
    required String questionId,
    String questionType = 'text',
    Map<String, double>? countryAverages,
    List<String>? questionOptions,
    Map<String, String?>? countryMostPopular,
    Map<String, Map<String, dynamic>>? generationResponses,
    Map<String, double>? generationAverages,
    Map<String, String?>? generationMostPopular,
    ResultsBreakdown? networkBreakdown,
    int networkHidden = 0,
  }) {
    return showDialog<String?>(
      context: context,
      builder: (context) => CountryFilterDialog(
        countryResponses: countryResponses,
        currentSelectedCountry: currentSelectedCountry,
        questionTitle: questionTitle,
        questionId: questionId,
        questionType: questionType,
        countryAverages: countryAverages,
        questionOptions: questionOptions,
        countryMostPopular: countryMostPopular,
        generationResponses: generationResponses,
        generationAverages: generationAverages,
        generationMostPopular: generationMostPopular,
        networkBreakdown: networkBreakdown,
        networkHidden: networkHidden,
        onCountrySelected: (country) => Navigator.of(context).pop(country),
      ),
    );
  }

  @override
  State<CountryFilterDialog> createState() => _CountryFilterDialogState();
}

class _CountryFilterDialogState extends State<CountryFilterDialog> {
  String _searchQuery = '';
  late List<MapEntry<String, Map<String, dynamic>>> _sortedCountries;

  @override
  void initState() {
    super.initState();
    _sortedCountries = widget.countryResponses.entries.toList()
      ..sort((a, b) {
        final aTotal = a.value['total'] as int? ?? 0;
        final bTotal = b.value['total'] as int? ?? 0;
        return bTotal.compareTo(aTotal); // Sort by response count, descending
      });
  }

  // Color mapping for approval questions (matches approval results screen)
  Color _getColorForValue(double value) {
    // Normalize the value from -1 to 1 range to 0 to 1 range
    final normalizedValue = (value + 1) / 2;

    if (normalizedValue < 0.2) {
      return Colors.red;
    } else if (normalizedValue < 0.4) {
      return Colors.red[300]!;
    } else if (normalizedValue < 0.6) {
      return Colors.grey.shade300;
    } else if (normalizedValue < 0.8) {
      return Colors.lightGreen;
    } else {
      return Colors.green;
    }
  }

  // Color mapping for multiple choice questions (matches multiple choice results screen)
  Color getColorForOption(String? option) {
    // Return grey for ties or null values
    if (option == null || option == 'TIE') {
      return Colors.grey[400]!;
    }

    final colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
    ];

    // Find the index of this option in the list of options
    if (widget.questionOptions != null) {
      final index = widget.questionOptions!.indexOf(option);
      if (index != -1) {
        return colors[index % colors.length];
      }
    }

    // If option not found, use a default color
    return Colors.grey[400]!;
  }

  Color _getCountryColor(String countryName, int responseCount) {
    // Handle World option specially
    if (countryName == 'World') {
      return _getGlobalColor(responseCount);
    }

    // My Network — coloured by what the network said, exactly like a country
    // row: the approval average, or the most-popular option.
    if (isNetworkFilter(countryName)) {
      final network = widget.networkBreakdown;
      if (network != null) {
        if (widget.questionType == 'approval' && network.average != null) {
          return _getColorForValue(network.average!);
        }
        if (widget.questionType == 'multiple_choice') {
          final top = network.topOption;
          return getColorForOption(top == 'TIE' ? null : top);
        }
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
        return getColorForOption(mostPopular);
      }
      return Theme.of(context).primaryColor;
    }

    // For approval questions, use the average approval rating color
    if (widget.questionType == 'approval' && widget.countryAverages != null) {
      final average = widget.countryAverages![countryName];
      if (average != null) {
        return _getColorForValue(average);
      }
    }

    // For multiple choice questions, use the most popular option color
    if (widget.questionType == 'multiple_choice' && widget.countryMostPopular != null) {
      final mostPopular = widget.countryMostPopular![countryName];
      return getColorForOption(mostPopular);
    }

    // For text questions or other question types, use response count based color with higher threshold
    final threshold = widget.questionType == 'text' ? 5 : 3;
    return responseCount > threshold
        ? Theme.of(context).primaryColor
        : Colors.grey[400]!;
  }

  Color _getGlobalColor(int totalResponses) {
    // For approval questions, calculate the global average and use its color
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

    // For multiple choice questions, calculate global most popular option
    if (widget.questionType == 'multiple_choice' && widget.countryMostPopular != null && widget.questionOptions != null) {
      // Count total votes for each option across all countries
      final globalOptionCounts = <String, int>{};
      for (var option in widget.questionOptions!) {
        globalOptionCounts[option] = 0;
      }

      widget.countryMostPopular!.forEach((country, mostPopular) {
        if (mostPopular != null && widget.countryResponses[country] != null) {
          final countryResponseCount = widget.countryResponses[country]!['total'] as int? ?? 0;
          globalOptionCounts[mostPopular] = (globalOptionCounts[mostPopular] ?? 0) + countryResponseCount;
        }
      });

      if (globalOptionCounts.isNotEmpty) {
        // Find the globally most popular option
        final maxCount = globalOptionCounts.values.reduce((a, b) => a > b ? a : b);
        final mostPopularGlobally = globalOptionCounts.entries
            .where((entry) => entry.value == maxCount)
            .map((entry) => entry.key)
            .first;

        return getColorForOption(mostPopularGlobally);
      }
    }

    // For text questions or other question types, use response count based color with higher threshold
    final threshold = widget.questionType == 'text' ? 5 : 3;
    return totalResponses > threshold
        ? Theme.of(context).primaryColor
        : Colors.grey[400]!;
  }

  @override
  Widget build(BuildContext context) {
    final totalResponsesGlobal = _sortedCountries.fold<int>(0, (sum, entry) {
      return sum + (entry.value['total'] as int? ?? 0);
    });

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Filter Results'),
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
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Global option
            _buildCountryOption(
              context: context,
              countryName: 'World',
              subtitle: 'All responses ($totalResponsesGlobal)',
              isSelected: widget.currentSelectedCountry == null,
              responseCount: totalResponsesGlobal,
              onTap: () => widget.onCountrySelected(null),
            ),

            // My Network, under World — only when the server gave us one.
            if (widget.networkBreakdown != null)
              _buildCountryOption(
                context: context,
                countryName: kNetworkFilter,
                displayName: kNetworkFilterLabel,
                leading: Icons.hub_rounded,
                subtitle:
                    '${networkCountLabel(widget.networkBreakdown!.count, widget.networkHidden)} answers · $kNetworkFilterSubtitle',
                isSelected: isNetworkFilter(widget.currentSelectedCountry),
                responseCount: widget.networkBreakdown!.count,
                onTap: () => widget.onCountrySelected(kNetworkFilter),
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
                  // Generations section
                  ..._buildGenerationsSection(totalResponsesGlobal),

                  // Countries heading
                  if (_sortedCountries.isNotEmpty)
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
    required BuildContext context,
    required String countryName,
    required String subtitle,
    required bool isSelected,
    required int responseCount,
    required VoidCallback onTap,
    String? displayName,
    IconData? leading,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: _getCountryColor(countryName, responseCount),
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
                    displayName ??
                        (countryName.startsWith('Gen:') ? getGenerationLabel(countryName.substring(4)) : countryName),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: isSelected
                          ? Theme.of(context).primaryColor
                          : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).primaryColor,
                size: 20,
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

        return _buildCountryOption(
          context: context,
          countryName: filterKey,
          subtitle: '$percentage% ($total responses)',
          isSelected: widget.currentSelectedCountry == filterKey,
          responseCount: total,
          onTap: () => widget.onCountrySelected(filterKey),
        );
      }),
    ];
  }

  List<Widget> _buildTopCountriesList(int totalResponsesGlobal) {
    // Filter countries by search query
    final filteredCountries = _searchQuery.isEmpty
        ? _sortedCountries
        : _sortedCountries.where((entry) {
            return entry.key.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();

    // Take top 5 countries
    final topCountries = filteredCountries.take(5).toList();

    return topCountries.map((entry) {
      final countryName = entry.key;
      final data = entry.value;
      final total = data['total'] as int? ?? 0;
      final percentage = totalResponsesGlobal > 0 ? (total / totalResponsesGlobal * 100).round() : 0;

      return _buildCountryOption(
        context: context,
        countryName: countryName,
        subtitle: '$percentage% ($total responses)',
        isSelected: widget.currentSelectedCountry == countryName,
        responseCount: total,
        onTap: () => widget.onCountrySelected(countryName),
      );
    }).toList();
  }
}
