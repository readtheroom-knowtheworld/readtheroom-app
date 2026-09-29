// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The QOTD answered-state inline results view: "Results so far" + the
// distribution (approval beeswarm / percentage bars / MC dot rows) + the
// response dot map.
//
// Extracted from [QotdHeroCard], where it lived as a family of private methods
// (`_buildResultsPreview`, `_buildMap`, `_buildApprovalPreview`,
// `_buildMcPreview`, `_buildTextPreview`, `_distributionBar` and the shimmer).
// The onboarding QOTD slide needs exactly the same view after a guest answers —
// "for answers it should display the results" — and duplicating ~250 lines of
// chart plumbing is how the inline preview and the full results screen start
// disagreeing. The pure aggregation already lives in
// `utils/qotd_results_preview_logic.dart`; this file is the widget half.
//
// The widget owns its own fetch (the hero's original lazy pattern, keyed by
// question id so a midnight rollover re-fetches) because both callers want the
// same three requests. Every failure path collapses to `SizedBox.shrink()`
// rather than an error state: an absent preview is a far better outcome than a
// broken card on the home screen or mid-onboarding.
//
// ## Guests
//
// The onboarding caller runs before the user has an account. Reading the
// responses is fine — `responses` is SELECT-readable without authentication
// (the three results screens already render for guests, complete with their
// "N free views left" guest banner), and none of the three service calls below
// touch `auth.currentUser`. Only the *insert* needs an account, which is why
// the onboarding answer is stashed rather than submitted. The consequence is
// documented at the onboarding call site: the numbers shown are the world's
// current results, which do not yet include the guest's own stashed answer.

import 'package:flutter/material.dart';
import '../models/question_results.dart';
import '../services/results_service.dart';
import 'package:provider/provider.dart';

import '../services/question_service.dart';
import '../utils/approval_labels.dart';
import '../utils/dot_plot_threshold.dart';
import '../utils/qotd_results_preview_logic.dart';
import '../utils/results_colors.dart';
import 'approval_dot_plot.dart';
import 'country_approval_map.dart';
import 'country_multiple_choice_map.dart';
import 'mc_dot_row.dart';

/// Empty-room threshold for the embedded response map (mirrors the v1.4
/// live-window spec §5.2): below this many geo-tagged responses the map is
/// hidden — a lone dot on a blank landmass reads worse than no map.
const int kHeroMapMinResponses = 5;

/// Inline results for a QOTD the viewer has already answered.
///
/// Renders nothing at all until the fetch lands, and nothing ever if it fails
/// or the question has no responses yet — callers can drop this straight into a
/// column without a fallback.
class QotdResultsPreview extends StatefulWidget {
  const QotdResultsPreview({
    Key? key,
    required this.question,
    this.storedAnswer,
    this.refreshNonce = 0,
    this.showMap = true,
    this.ownAnswerChipLabel = 'you',
  }) : super(key: key);

  /// The enriched QOTD map (`id`, `type`, `question_options`, targeting…).
  final Map<String, dynamic> question;

  /// The viewer's own answer as a display string — 'Approve' / 'Neutral' /
  /// 'Disapprove' for approval questions, the option text for multiple choice.
  /// Highlighted in the distribution when it matches a bucket/option.
  final String? storedAnswer;

  /// Bumped by a pull-to-refresh to re-fetch without a question change.
  final int refreshNonce;

  /// Set false to suppress the response dot map (the distribution alone).
  final bool showMap;

  /// Copy of the chip marking the viewer's own row.
  final String ownAnswerChipLabel;

  @override
  State<QotdResultsPreview> createState() => _QotdResultsPreviewState();
}

class _QotdResultsPreviewState extends State<QotdResultsPreview> {
  // Loaded lazily on mount, keyed by question id so a midnight rollover (or a
  // refresh nonce bump) re-fetches.
  String? _loadedForId;
  bool _loading = false;
  bool _failed = false;
    /// Text answers (public content). Empty for approval / multiple choice.
  List<Map<String, dynamic>> _responses = const [];

  /// The server-computed results for approval / multiple choice. Since the
  /// answers read lockdown (2026-09-22) the preview draws these, not rows.
  QuestionResults _results = QuestionResults.emptyFor('', '');

  // Response dot map: lazily probe the geo-tagged rows alongside the preview
  // fetch. We only embed the map (CountryApprovalMap / CountryMultipleChoiceMap,
  // which re-resolve the same rows to plot points) once we know there are
  // enough geographic rows — so on a fetch failure the card simply shows no map
  // rather than the adapters' "No geographic data available" placeholder.
  bool _mapHasGeoData = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoad();
    });
  }

  @override
  void didUpdateWidget(QotdResultsPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pull-to-refresh: forget the loaded id so the preview re-fetches below.
    if (widget.refreshNonce != oldWidget.refreshNonce) _loadedForId = null;
    _maybeLoad();
  }

  String get _questionType =>
      widget.question['type']?.toString().toLowerCase() ?? 'text';

  void _maybeLoad() {
    final id = widget.question['id']?.toString();
    if (id == null || id == _loadedForId) return;
    _loadedForId = id;
    _load(id);
  }

  Future<void> _load(String questionId) async {
        setState(() {
      _loading = true;
      _failed = false;
      _responses = const [];
      _results = QuestionResults.emptyFor(questionId, _questionType);
      _mapHasGeoData = false;
    });

    final questionService = context.read<QuestionService>();
    List<Map<String, dynamic>> responses = const [];
    var results = QuestionResults.emptyFor(questionId, _questionType);
    var failed = false;
    try {
      switch (_questionType) {
        case 'multiplechoice':
        case 'multiple_choice':
        case 'approval_rating':
        case 'approval':
          // Results, never rows. The server counts what the phone used to.
          results = await questionService.fetchQuestionResults(questionId,
              questionType: _questionType);
          break;
        case 'text':
        default:
          responses = await questionService.getTextResponses(questionId);
      }
    } catch (e) {
      debugPrint('QotdResultsPreview: error loading results: $e');
      failed = true;
    }

    if (!mounted || questionId != _loadedForId) return;
    setState(() {
      _loading = false;
      _failed = failed;
      _responses = responses;
      _results = results;
    });

    // After the distribution preview, probe whether there is enough geo-tagged
    // data to embed the map. Best-effort: any failure leaves the map hidden.
    if (!failed && widget.showMap) {
      await _loadMapAvailability(questionId, questionService);
    }
  }

  /// Probe the geo-tagged rows the dot map plots (same source the map adapters
  /// use) to decide whether to embed the map. No-op for text questions or when
  /// the map targeting guard would hide it.
    Future<void> _loadMapAvailability(
      String questionId, QuestionService questionService) async {
    if (!_mapAllowedForType || !_mapTargetingAllows) return;
    int placed = 0;
    try {
      final cells = await ResultsService().fetchMapCells(questionId);
      placed = cells.total; // answers the map can actually place
    } catch (e) {
      debugPrint('QotdResultsPreview: error probing map data: $e');
      return; // Graceful: no map.
    }

    if (!mounted || questionId != _loadedForId) return;
    // Empty-room rule (mirrors the v1.4 live-window spec): below
    // [kHeroMapMinResponses] placed answers a map is a near-blank landmass
    // with a lone dot — worse than no map.
    if (placed >= kHeroMapMinResponses) {
      setState(() => _mapHasGeoData = true);
    }
  }

  /// The dot map exists for approval + multiple-choice, never for text.
  bool get _mapAllowedForType {
    switch (_questionType) {
      case 'multiplechoice':
      case 'multiple_choice':
      case 'approval_rating':
      case 'approval':
        return true;
      default:
        return false;
    }
  }

  /// Mirror the results screens' map guard: no dot map for city-targeted or
  /// private questions. The QOTD is globe-targeted, so this normally passes —
  /// it's here purely so the card never crashes/misrenders if that changes.
  bool get _mapTargetingAllows {
    final targeting =
        widget.question['targeting_type']?.toString().toLowerCase();
    if (targeting == 'city') return false;
    if (widget.question['is_private'] == true) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildDistribution(context),
        if (widget.showMap) _buildMap(context),
      ],
    );
  }

  /// Divider + inline distribution/recent-responses view. On load failure or an
  /// empty result set it collapses to nothing, leaving the surrounding card
  /// intact.
  Widget _buildDistribution(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 20),
        child: QotdResultsPreviewShimmer(),
      );
    }
        if (_failed || _previewCount == 0) {
      // Graceful fallback: no preview at all.
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    Widget chart;
    switch (_questionType) {
      case 'multiplechoice':
      case 'multiple_choice':
        chart = _buildMcPreview(context);
        break;
      case 'approval_rating':
      case 'approval':
        chart = _buildApprovalPreview(context);
        break;
      default:
        chart = _buildTextPreview(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Divider(color: theme.dividerColor.withOpacity(0.4), height: 1),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Results so far',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
                            qotdResponseCountLabel(_previewCount),
              style:
                  theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
        const SizedBox(height: 16),
        chart,
      ],
    );
  }

  /// Inline response dot map, reusing the results-screen adapters
  /// (CountryApprovalMap / CountryMultipleChoiceMap → ResponseDotMap). Rendered
  /// only when: type has a map (approval/MC, never text), targeting allows it,
  /// and the geo-data probe found enough plottable rows. The adapter re-resolves
  /// the same rows into a non-interactive ~300px preview whose single tap opens
  /// the full-screen map.
  Widget _buildMap(BuildContext context) {
    if (!_mapAllowedForType || !_mapTargetingAllows || !_mapHasGeoData) {
      return const SizedBox.shrink();
    }

    final question = widget.question;
    final questionId = question['id']?.toString() ?? '';
    final title = question['prompt']?.toString() ??
        question['title']?.toString() ??
        'No Title';

    Widget map;
    switch (_questionType) {
      case 'multiplechoice':
      case 'multiple_choice':
        map = CountryMultipleChoiceMap(
          key: ValueKey('qotd_mc_map_$questionId'),
                    responsesByCountry: const [],
          questionTitle: title,
          options: _options,
          questionId: questionId,
          embedded: true,
        );
        break;
      default: // approval
        map = CountryApprovalMap(
          key: ValueKey('qotd_approval_map_$questionId'),
                    responsesByCountry: const [],
          questionTitle: title,
          questionId: questionId,
          labels: approvalLabelsFrom(widget.question),
          embedded: true,
        );
    }

    final content = Padding(
      padding: const EdgeInsets.only(top: 16),
      child: map,
    );

    // Fade the map in once its data is ready, consistent with the card's entry
    // motion; jump straight to visible when reduced-motion is requested.
    if (MediaQuery.of(context).disableAnimations) return content;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: content,
    );
  }

    List<String> get _options {
    final fromQuestion =
        ((widget.question['question_options'] as List<dynamic>?) ?? const [])
            .map((o) => o['option_text']?.toString() ?? '')
            .where((o) => o.isNotEmpty)
            .toList();
    if (fromQuestion.isNotEmpty) return fromQuestion;
    // The results carry every option the question defines, in sort order.
    return _results.optionTexts.where((o) => o.isNotEmpty).toList();
  }

  /// How many answers the preview is summarising: text answers for a
  /// discussion question, the results total for everything else.
  int get _previewCount =>
      _questionType == 'text' ? _responses.length : _results.total;

    Widget _buildApprovalPreview(BuildContext context) {
    final total = _results.total;
    final ownBucket = ownApprovalBucket(widget.storedAnswer);

    // Small sample: the shared beeswarm dot plot (matches the results screen).
    if (total < kDotPlotThreshold) {
      return ApprovalDotPlot(
        values: _results.overall.scoreValues,
        average: _results.overall.averageOrZero,
        labels: approvalLabelsFrom(widget.question),
      );
    }

    // Larger sample: compact per-bucket percentage bars.
    final dist = _results.overall.binsByLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final label in kApprovalBucketLabels)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _distributionBar(
              context,
              label: label,
              count: dist[label] ?? 0,
              total: total,
              color: ResultsColors.forApprovalLabel(context, label),
              isOwn: ownBucket != null && ownBucket == label,
            ),
          ),
      ],
    );
  }

    Widget _buildMcPreview(BuildContext context) {
    final options = _options;
    final total = _results.total;
    final counts = _results.overall.optionCountsFor(options);
    final ownAnswer = ownOption(widget.storedAnswer, options);
    final colors = ResultsColors.multipleChoiceColors(context);

    // Ranked: most-answered option first (ties keep the question's option
    // order — sort isn't stable, so tie-break on index). Colors stay bound to
    // the original option index so an option keeps its color across
    // re-rankings. Rows fill in a top-to-bottom cascade, mirroring the MC
    // results screen.
    final ranked = List<int>.generate(options.length, (i) => i)
      ..sort((a, b) {
        final byVotes =
            (counts[options[b]] ?? 0).compareTo(counts[options[a]] ?? 0);
        return byVotes != 0 ? byVotes : a.compareTo(b);
      });

    // Small sample: one dot per vote per option (shared results-screen widget).
    if (total < kDotPlotThreshold) {
      var delayMs = 0;
      final rows = <Widget>[];
      for (final i in ranked) {
        final count = counts[options[i]] ?? 0;
        rows.add(McDotRow(
          key: ValueKey('qotd_mc_dots_${options[i]}'),
          label:
              options[i] + (ownAnswer == options[i] ? '  (your answer)' : ''),
          voteCount: count,
          totalResponses: total,
          color: colors[i % colors.length],
          delayMs: delayMs,
        ));
        delayMs += (McDotRow.fillDurationMs(count) * 0.65).round();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      );
    }

    var delayMs = 0;
    final bars = <Widget>[];
    for (final i in ranked) {
      bars.add(Padding(
        key: ValueKey('qotd_mc_bar_${options[i]}'),
        padding: const EdgeInsets.only(bottom: 10),
        child: _distributionBar(
          context,
          label: options[i],
          count: counts[options[i]] ?? 0,
          total: total,
          color: colors[i % colors.length],
          isOwn: ownAnswer == options[i],
          delayMs: delayMs,
        ),
      ));
      delayMs += (McResultBar.fillDurationMs * 0.6).round();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: bars,
    );
  }

  Widget _buildTextPreview(BuildContext context) {
    final theme = Theme.of(context);
    final display = _responses.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in display)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _textResponseCard(
              context,
              (r['text_response']?.toString() ?? '').trim(),
            ),
          ),
        if (_responses.length > display.length)
          Text(
            'and ${_responses.length - display.length} more',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
              fontStyle: FontStyle.italic,
            ),
          ),
      ],
    );
  }

  Widget _textResponseCard(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor.withOpacity(0.35)),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// A labelled percentage bar (used above the dot-plot threshold). The user's
  /// own bucket/option is emphasised with a bold label + a "you" chip.
  Widget _distributionBar(
    BuildContext context, {
    required String label,
    required int count,
    required int total,
    required Color color,
    required bool isOwn,
    int delayMs = 0,
  }) {
    final theme = Theme.of(context);
    final fraction = total > 0 ? count / total : 0.0;
    final pct = (fraction * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: isOwn ? FontWeight.w700 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isOwn) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  widget.ownAnswerChipLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Text(
              '$pct% ($count)',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: McResultBar(
            widthFactor: fraction.clamp(0.0, 1.0),
            color: color,
            delayMs: delayMs,
            height: 8,
            backgroundColor: Colors.grey.withOpacity(0.15),
            fillRadius: BorderRadius.zero,
          ),
        ),
      ],
    );
  }
}

/// A lightweight three-bar shimmer shown while the answered-state results load.
class QotdResultsPreviewShimmer extends StatefulWidget {
  const QotdResultsPreviewShimmer({Key? key}) : super(key: key);

  @override
  State<QotdResultsPreviewShimmer> createState() =>
      _QotdResultsPreviewShimmerState();
}

class _QotdResultsPreviewShimmerState extends State<QotdResultsPreviewShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: hold a static placeholder rather than pulsing.
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final opacity = 0.08 + 0.10 * _controller.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final width in const [0.8, 0.6, 0.7])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: width,
                    child: Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(opacity),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
