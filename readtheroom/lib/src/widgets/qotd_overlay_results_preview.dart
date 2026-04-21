// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/question_service.dart';
import '../services/country_service.dart';
import 'choropleth_map_base.dart';

class QotdOverlayResultsPreview extends StatefulWidget {
  final Map<String, dynamic> question;
  final VoidCallback? onSeeMore;
  final ValueChanged<bool>? onMapAvailable;

  const QotdOverlayResultsPreview({
    Key? key,
    required this.question,
    this.onSeeMore,
    this.onMapAvailable,
  }) : super(key: key);

  @override
  State<QotdOverlayResultsPreview> createState() => _QotdOverlayResultsPreviewState();
}

class _QotdOverlayResultsPreviewState extends State<QotdOverlayResultsPreview> {
  final _supabase = Supabase.instance.client;
  bool _isLoading = true;

  // Raw individual responses for distribution calculation
  List<Map<String, dynamic>> _rawResponses = [];
  // Choropleth entries for the blurred map
  List<ChoroplethEntry> _mapEntries = [];

  String get _questionType {
    return widget.question['type']?.toString().toLowerCase() ?? 'text';
  }

  @override
  void initState() {
    super.initState();
    _loadResponses();
  }

  Future<void> _loadResponses() async {
    final questionId = widget.question['id'].toString();

    try {
      switch (_questionType) {
        case 'approval_rating':
        case 'approval':
          await _loadApprovalData(questionId);
          break;
        case 'multiplechoice':
        case 'multiple_choice':
          await _loadMultipleChoiceData(questionId);
          break;
        case 'text':
          await _loadTextData(questionId);
          break;
        default:
          await _loadTextData(questionId);
      }
    } catch (e) {
      print('QotdOverlayResultsPreview: Error loading responses: $e');
    }

    if (mounted) {
      setState(() => _isLoading = false);
      widget.onMapAvailable?.call(_mapEntries.isNotEmpty);
    }
  }

  Future<void> _loadApprovalData(String questionId) async {
    final rawResponse = await _supabase
        .from('responses')
        .select('score')
        .eq('question_id', questionId)
        .not('score', 'is', null);

    _rawResponses = List<Map<String, dynamic>>.from(rawResponse);

    // Build map entries from aggregated by-country data
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final mapResponses = await questionService.getCachedResponses(questionId, _questionType);
    _mapEntries = await _buildApprovalMapEntries(mapResponses);
  }

  Future<List<ChoroplethEntry>> _buildApprovalMapEntries(
      List<Map<String, dynamic>> responses) async {
    await CountryService.preloadCountryMappings();
    final entries = <ChoroplethEntry>[];

    for (final r in responses) {
      final country = r['country']?.toString() ?? '';
      final answer = (r['answer'] as num?)?.toDouble() ?? 0.0;
      if (country.isEmpty || country == 'Unknown') continue;

      final isoCode = await CountryService.getIsoCodeForCountry(country);
      if (isoCode == null || isoCode.isEmpty || isoCode == 'ATA') continue;

      entries.add(ChoroplethEntry(
        isoA3: isoCode,
        color: _colorForApproval(answer),
        tooltip: '',
      ));
    }
    return entries;
  }

  Color _colorForApproval(double value) {
    if (value <= -0.8) return Colors.red;
    if (value <= -0.3) return Colors.red[300]!;
    if (value <= 0.3) return Colors.grey.shade300;
    if (value <= 0.8) return Colors.lightGreen;
    return Colors.green;
  }

  Future<void> _loadMultipleChoiceData(String questionId) async {
    final rawResponse = await _supabase
        .from('responses')
        .select('option_id, question_options!inner(option_text)')
        .eq('question_id', questionId)
        .not('option_id', 'is', null);

    _rawResponses = List<Map<String, dynamic>>.from(rawResponse);

    // Build map entries from aggregated by-country data
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final mapResponses = await questionService.getCachedResponses(questionId, _questionType);
    final options = (widget.question['question_options'] as List<dynamic>? ?? [])
        .map((o) => o['option_text']?.toString() ?? '')
        .toList();
    _mapEntries = await _buildMCMapEntries(mapResponses, options);
  }

  Future<List<ChoroplethEntry>> _buildMCMapEntries(
      List<Map<String, dynamic>> responses, List<String> options) async {
    await CountryService.preloadCountryMappings();

    final optionColors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
    ];

    final entries = <ChoroplethEntry>[];
    for (final r in responses) {
      final country = r['country']?.toString() ?? '';
      final answer = r['answer']?.toString() ?? '';
      if (country.isEmpty || country == 'Unknown') continue;

      final isoCode = await CountryService.getIsoCodeForCountry(country);
      if (isoCode == null || isoCode.isEmpty || isoCode == 'ATA') continue;

      final optionIndex = options.indexOf(answer);
      final color = optionIndex >= 0
          ? optionColors[optionIndex % optionColors.length]
          : Colors.grey;

      entries.add(ChoroplethEntry(
        isoA3: isoCode,
        color: color,
        tooltip: '',
      ));
    }
    return entries;
  }

  Future<void> _loadTextData(String questionId) async {
    final questionService = Provider.of<QuestionService>(context, listen: false);
    _rawResponses = await questionService.getCachedResponses(questionId, _questionType);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_rawResponses.isEmpty) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            'No responses yet',
            style: TextStyle(color: Colors.grey[600], fontSize: 16),
          ),
        ),
      );
    }

    switch (_questionType) {
      case 'approval_rating':
      case 'approval':
        return _buildApprovalPreview();
      case 'multiplechoice':
      case 'multiple_choice':
        return _buildMultipleChoicePreview();
      case 'text':
        return _buildTextPreview();
      default:
        return _buildTextPreview();
    }
  }

  Widget _buildApprovalPreview() {
    final distribution = _calculateApprovalDistribution();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Results',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        ...distribution.entries.map((entry) {
          final total = _rawResponses.length;
          final fraction = total > 0 ? entry.value / total : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildDistributionBar(entry.key, fraction, entry.value),
          );
        }),
        // Blurred map commented out — "View map" button navigates to full results instead
        // if (_mapEntries.isNotEmpty) ...[
        //   const SizedBox(height: 20),
        //   _buildBlurredMap(),
        // ],
      ],
    );
  }

  Map<String, int> _calculateApprovalDistribution() {
    final dist = <String, int>{
      'Strongly Approve': 0,
      'Approve': 0,
      'Neutral': 0,
      'Disapprove': 0,
      'Strongly Disapprove': 0,
    };

    for (final r in _rawResponses) {
      final score = (r['score'] as num?)?.toDouble() ?? 0;
      // Raw scores are stored as -100 to 100 integers
      final normalized = score / 100.0;
      if (normalized > 0.8) {
        dist['Strongly Approve'] = dist['Strongly Approve']! + 1;
      } else if (normalized > 0.3) {
        dist['Approve'] = dist['Approve']! + 1;
      } else if (normalized >= -0.3) {
        dist['Neutral'] = dist['Neutral']! + 1;
      } else if (normalized >= -0.8) {
        dist['Disapprove'] = dist['Disapprove']! + 1;
      } else {
        dist['Strongly Disapprove'] = dist['Strongly Disapprove']! + 1;
      }
    }
    return dist;
  }

  Widget _buildDistributionBar(String label, double fraction, int count) {
    final color = _getBarColor(label);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13)),
            Text(
              '$count (${(fraction * 100).toStringAsFixed(0)}%)',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            backgroundColor: Colors.grey.withOpacity(0.15),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Color _getBarColor(String label) {
    switch (label) {
      case 'Strongly Approve':
        return Colors.green[700]!;
      case 'Approve':
        return Colors.green[300]!;
      case 'Neutral':
        return Colors.grey;
      case 'Disapprove':
        return Colors.red[300]!;
      case 'Strongly Disapprove':
        return Colors.red[700]!;
      default:
        return Colors.grey;
    }
  }

  Widget _buildMultipleChoicePreview() {
    final theme = Theme.of(context);
    final options = (widget.question['question_options'] as List<dynamic>? ?? [])
        .map((o) => o['option_text']?.toString() ?? '')
        .toList();

    // Count from raw responses
    final optionCounts = <String, int>{};
    for (final option in options) {
      optionCounts[option] = 0;
    }
    for (final r in _rawResponses) {
      final optionText = r['question_options']?['option_text']?.toString();
      if (optionText != null && optionCounts.containsKey(optionText)) {
        optionCounts[optionText] = optionCounts[optionText]! + 1;
      }
    }

    final total = _rawResponses.length;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Results',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        ...options.asMap().entries.map((entry) {
          final idx = entry.key;
          final option = entry.value;
          final count = optionCounts[option] ?? 0;
          final fraction = total > 0 ? count / total : 0.0;
          final color = colors[idx % colors.length];

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        option,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '$count (${(fraction * 100).toStringAsFixed(0)}%)',
                      style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 8,
                    backgroundColor: Colors.grey.withOpacity(0.15),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ],
            ),
          );
        }),
        // Blurred map commented out — "View map" button navigates to full results instead
        // if (_mapEntries.isNotEmpty) ...[
        //   const SizedBox(height: 20),
        //   _buildBlurredMap(),
        // ],
      ],
    );
  }

  Widget _buildTextPreview() {
    final theme = Theme.of(context);
    final displayResponses = _rawResponses.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Results',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${_rawResponses.length} responses',
          style: TextStyle(color: Colors.grey[600], fontSize: 14),
        ),
        const SizedBox(height: 16),
        ...displayResponses.map((r) {
          final text = r['text_response']?.toString() ?? '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.grey.withOpacity(0.2),
                ),
              ),
              child: Text(
                text,
                style: const TextStyle(fontSize: 14, height: 1.4),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        }),
        if (_rawResponses.length > 5)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'and ${_rawResponses.length - 5} more...',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBlurredMap() {
    return GestureDetector(
      onTap: widget.onSeeMore,
      child: SizedBox(
        height: 200,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              // Blurred map with colored countries
              Positioned.fill(
                child: IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                    child: ChoroplethMapBase(
                      entries: _mapEntries,
                    ),
                  ),
                ),
              ),
              // "Tap to see full results" overlay
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.15),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.map_outlined, color: Colors.white, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Tap to explore',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
