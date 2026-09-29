// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The typed shape of everything the results surfaces draw.
//
// Since the answers read lockdown (2026-09-22) the client never sees an answer
// row for a multiple-choice or approval question. It asks the database for
// RESULTS — counts, averages, histograms — computed by SECURITY DEFINER
// functions, and these classes are the Dart side of that contract. Text answers
// are the one exception: they are public content, and arrive one per answer
// with the hour they were given and nothing else.
//
// The JSON contracts live in scripts/responses_lockdown_01_results_rpcs.sql and
// are documented in feature-documentation/responses-lockdown-2026-09-22.md.

import 'dart:math' as math;

/// Histogram labels in the order the results screens draw them (approve first).
/// [ResultsBreakdown.bins] is in the OPPOSITE order — index 0 is strongly
/// disapprove — because that is the order the map's bucket colours use
/// (`approvalBucketIndex` in map_clustering.dart). [ResultsBreakdown.binsByLabel]
/// is the bridge.
const List<String> kResultsBinLabels = <String>[
  'Strongly Approve',
  'Approve',
  'Neutral',
  'Disapprove',
  'Strongly Disapprove',
];

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

double? _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

String? _asString(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

/// One question option, as the question defines it (not as it was voted for).
class ResultOption {
  final String id;
  final String text;
  final int sortOrder;

  const ResultOption({
    required this.id,
    required this.text,
    required this.sortOrder,
  });

  factory ResultOption.fromJson(Map<String, dynamic> json) => ResultOption(
        id: json['id']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
        sortOrder: _asInt(json['sort_order']),
      );
}

/// The summary of one slice of a question's answers: the whole question, one
/// country, one city, one generation, or one map cell.
///
/// [average] is already normalised to -1..1 (the server divides the stored
/// -100..100 score by 100) and is null when nothing in the slice is scored.
/// [optionCounts] carries every option of the question, zeros included, for
/// whole-question and facet breakdowns; map cells carry only options with
/// votes.
class ResultsBreakdown {
  final int count;
  final double? average;

  /// Five counts, index 0 = strongly disapprove … 4 = strongly approve.
  final List<int> bins;

  /// The slice's raw -100..100 scores, SORTED ASCENDING, for the small-sample
  /// beeswarm. Empty above 40 answers — by then the screen draws [bins].
  ///
  /// A sorted multiset: it carries no ordering, no time, no place and no
  /// generation. It is the histogram at full resolution, not a list of answers.
  final List<int> scores;

  /// Option text → votes.
  final Map<String, int> optionCounts;

  const ResultsBreakdown({
    required this.count,
    required this.average,
    required this.bins,
    required this.optionCounts,
    this.scores = const <int>[],
  });

  static const ResultsBreakdown empty = ResultsBreakdown(
    count: 0,
    average: null,
    bins: <int>[0, 0, 0, 0, 0],
    optionCounts: <String, int>{},
  );

  factory ResultsBreakdown.fromJson(Map<String, dynamic> json) {
    final rawBins = json['bins'];
    final bins = List<int>.filled(5, 0);
    if (rawBins is List) {
      for (var i = 0; i < math.min(5, rawBins.length); i++) {
        bins[i] = _asInt(rawBins[i]);
      }
    }
    final counts = <String, int>{};
    final rawCounts = json['option_counts'];
    if (rawCounts is Map) {
      rawCounts.forEach((k, v) => counts[k.toString()] = _asInt(v));
    }
    final rawScores = json['scores'];
    return ResultsBreakdown(
      count: _asInt(json['count']),
      average: _asDouble(json['average']),
      bins: bins,
      optionCounts: counts,
      scores: rawScores is List
          ? rawScores.map(_asInt).toList(growable: false)
          : const <int>[],
    );
  }

  bool get isEmpty => count == 0;

  /// The average the screens display, which treats "nothing scored" as 0 —
  /// the behaviour of the old `filteredResponses`-derived getter.
  double get averageOrZero => average ?? 0.0;

  /// The histogram keyed by display label, approve first — the shape the
  /// results screens and the QOTD preview chart consume.
  Map<String, int> get binsByLabel => <String, int>{
        'Strongly Approve': bins[4],
        'Approve': bins[3],
        'Neutral': bins[2],
        'Disapprove': bins[1],
        'Strongly Disapprove': bins[0],
      };

  /// The beeswarm's values, normalised to -1..1 like everything else the
  /// approval screen works in. Empty when the slice is too big for a beeswarm.
  List<double> get scoreValues =>
      scores.map((s) => s / 100.0).toList(growable: false);

  /// Option counts restricted to [options] and in that order, so a chart keeps
  /// the question's own option ordering and still shows unvoted options.
  Map<String, int> optionCountsFor(List<String> options) =>
      <String, int>{for (final o in options) o: optionCounts[o] ?? 0};

  /// The most-chosen option, or 'TIE' when two or more share the maximum.
  /// Matches DotCluster.topOption so the map and the charts never disagree.
  String get topOption {
    final voted = optionCounts.entries.where((e) => e.value > 0).toList();
    if (voted.isEmpty) return 'TIE';
    final maxCount = voted.map((e) => e.value).reduce(math.max);
    final leaders = voted.where((e) => e.value == maxCount).toList();
    return leaders.length > 1 ? 'TIE' : leaders.first.key;
  }
}

/// A country slice. [country] is the display name; answers whose country could
/// not be resolved arrive under the name 'Unknown'.
class CountryResults {
  final String country;
  final String? countryCode;
  final ResultsBreakdown breakdown;

  const CountryResults({
    required this.country,
    required this.countryCode,
    required this.breakdown,
  });

  factory CountryResults.fromJson(Map<String, dynamic> json) => CountryResults(
        country: json['country']?.toString() ?? 'Unknown',
        countryCode: _asString(json['country_code']),
        breakdown: ResultsBreakdown.fromJson(json),
      );
}

/// A city slice. Answers with no city are absent from the city facet.
class CityResults {
  final String city;
  final String country;
  final String? countryCode;
  final ResultsBreakdown breakdown;

  const CityResults({
    required this.city,
    required this.country,
    required this.countryCode,
    required this.breakdown,
  });

  factory CityResults.fromJson(Map<String, dynamic> json) => CityResults(
        city: json['city']?.toString() ?? '',
        country: json['country']?.toString() ?? 'Unknown',
        countryCode: _asString(json['country_code']),
        breakdown: ResultsBreakdown.fromJson(json),
      );
}

/// A generation slice. Only groups of five or more respondents are ever sent —
/// smaller ones are counted in [QuestionResults.generationSuppressedCount] and
/// are not in this list at all.
class GenerationResults {
  final String generation;
  final ResultsBreakdown breakdown;

  const GenerationResults({
    required this.generation,
    required this.breakdown,
  });

  factory GenerationResults.fromJson(Map<String, dynamic> json) =>
      GenerationResults(
        generation: json['generation']?.toString() ?? '',
        breakdown: ResultsBreakdown.fromJson(json),
      );
}

/// Everything the results screens need for one question.
///
/// The facets are independent views of the same population, never a joint
/// distribution: there is deliberately no city-by-generation cross-tab, because
/// that tuple is the re-identification risk the lockdown exists to remove.
class QuestionResults {
  final String questionId;
  final String type;

  /// Every answer row for the question.
  final int total;

  /// The type-aware valid count: multiple choice counts answers whose option
  /// belongs to this question, approval counts scored answers, anything else
  /// counts everything.
  final int answered;

  final int textCount;
  final int commentCount;
  final List<ResultOption> options;
  final ResultsBreakdown overall;
  final List<CountryResults> byCountry;
  final List<CityResults> byCity;
  final List<GenerationResults> byGeneration;

  /// How many generation groups were withheld for being under five, and how
  /// many answers sit inside them.
  final int generationSuppressedGroups;
  final int generationSuppressedCount;

  QuestionResults({
    required this.questionId,
    required this.type,
    required this.total,
    required this.answered,
    required this.textCount,
    required this.commentCount,
    required this.options,
    required this.overall,
    required this.byCountry,
    required this.byCity,
    required this.byGeneration,
    required this.generationSuppressedGroups,
    required this.generationSuppressedCount,
  });

  factory QuestionResults.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) build) {
      final raw = json[key];
      if (raw is! List) return <T>[];
      return raw
          .whereType<Map>()
          .map((e) => build(Map<String, dynamic>.from(e)))
          .toList();
    }

    final overallRaw = json['overall'];
    return QuestionResults(
      questionId: json['question_id']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      total: _asInt(json['total']),
      answered: _asInt(json['answered']),
      textCount: _asInt(json['text_count']),
      commentCount: _asInt(json['comment_count']),
      options: list('options', ResultOption.fromJson)
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
      overall: overallRaw is Map
          ? ResultsBreakdown.fromJson(Map<String, dynamic>.from(overallRaw))
          : ResultsBreakdown.empty,
      byCountry: list('by_country', CountryResults.fromJson),
      byCity: list('by_city', CityResults.fromJson),
      byGeneration: list('by_generation', GenerationResults.fromJson),
      generationSuppressedGroups: _asInt(json['generation_suppressed_groups']),
      generationSuppressedCount: _asInt(json['generation_suppressed_count']),
    );
  }

  /// An empty result for a question nothing is known about yet — every screen
  /// renders its "no answers" state from this without a null check.
  static QuestionResults emptyFor(String questionId, String type) =>
      QuestionResults(
        questionId: questionId,
        type: type,
        total: 0,
        answered: 0,
        textCount: 0,
        commentCount: 0,
        options: const <ResultOption>[],
        overall: ResultsBreakdown.empty,
        byCountry: const <CountryResults>[],
        byCity: const <CityResults>[],
        byGeneration: const <GenerationResults>[],
        generationSuppressedGroups: 0,
        generationSuppressedCount: 0,
      );

  bool get isEmpty => total == 0;

  List<String> get optionTexts =>
      options.map((o) => o.text).toList(growable: false);

  /// Countries that contributed at least one answer, excluding the 'Unknown'
  /// bucket — the list the country filter button is gated on.
  List<String> get countriesWithResponses => byCountry
      .map((c) => c.country)
      .where((c) => c.isNotEmpty && c != 'Unknown')
      .toList();

  ResultsBreakdown? forCountry(String country) {
    for (final c in byCountry) {
      if (c.country == country) return c.breakdown;
    }
    return null;
  }

  ResultsBreakdown? forCity(String city) {
    for (final c in byCity) {
      if (c.city == city) return c.breakdown;
    }
    return null;
  }

  ResultsBreakdown? forGeneration(String generation) {
    for (final g in byGeneration) {
      if (g.generation == generation) return g.breakdown;
    }
    return null;
  }

  /// Resolve the results screens' single filter token to a slice.
  ///
  /// The token is null for "everyone", `Gen:<id>` for a generation, `City:<n>`
  /// for a city, and a bare country display name otherwise — the same encoding
  /// the screens have always used. An unknown token resolves to an empty
  /// slice, never to the global one, so a filter for a group that has since
  /// been suppressed shows nothing rather than silently showing everybody.
  ///
  /// One token is deliberately NOT resolved here: `Network` ("My Network")
  /// names the viewer's own friends-and-friends-of-friends slice, which comes
  /// from a different RPC and never from this object. The results screens
  /// resolve it through `resolveResultsFilter` in utils/network_breakdown.dart.
  ResultsBreakdown breakdownForFilter(String? filter) {
    if (filter == null || filter.isEmpty) return overall;
    if (filter.startsWith('Gen:')) {
      return forGeneration(filter.substring(4)) ?? ResultsBreakdown.empty;
    }
    if (filter.startsWith('City:')) {
      return forCity(filter.substring(5)) ?? ResultsBreakdown.empty;
    }
    return forCountry(filter) ?? ResultsBreakdown.empty;
  }

  /// `{country: {'total': n}}` — the shape CountryFilterDialog consumes.
  Map<String, Map<String, dynamic>> get countryResponseData => <String, Map<String, dynamic>>{
        for (final c in byCountry)
          if (c.country != 'Unknown') c.country: <String, dynamic>{'total': c.breakdown.count},
      };

  /// `{country: average}` in -1..1, for the country comparison rows.
  Map<String, double> get countryAverages => <String, double>{
        for (final c in byCountry)
          if (c.breakdown.average != null) c.country: c.breakdown.average!,
      };

  /// Countries ordered by how many answers they contributed, descending.
  List<String> get countriesByVolume =>
      byCountry.map((c) => c.country).toList(growable: false);

  /// `{generation: {'total': n}}`, already k-suppressed by the server.
  Map<String, Map<String, dynamic>> get generationResponseData =>
      <String, Map<String, dynamic>>{
        for (final g in byGeneration)
          g.generation: <String, dynamic>{'total': g.breakdown.count},
      };

  Map<String, double> get generationAverages => <String, double>{
        for (final g in byGeneration)
          if (g.breakdown.average != null) g.generation: g.breakdown.average!,
      };

  /// `{generation: most popular option text}` for the MC filter dialog.
  Map<String, String> get generationMostPopular => <String, String>{
        for (final g in byGeneration) g.generation: g.breakdown.topOption,
      };
}

/// One dot's worth of map data: a place and what it answered.
///
/// A cell exists from a single answer (owner decision 2026-09-22) — the city
/// dot is the product — but it is never a row per answer. [lat]/[lng] are null
/// for a `country` cell, which the client draws on its own bundled centroid.
class MapCell {
  /// 'city' or 'country'.
  final String kind;
  final String? cityId;
  final String? city;
  final String? admin1;
  final double? lat;
  final double? lng;
  final String? countryCode;
  final String? countryIso3;
  final String country;
  final int count;

  /// Approval average in -1..1, null when the cell holds no scored answer.
  final double? average;

  /// Five counts, index 0 = strongly disapprove.
  final List<int> bins;

  /// Option text → votes, for multiple choice. Only options with votes.
  final Map<String, int> optionCounts;

  const MapCell({
    required this.kind,
    required this.cityId,
    required this.city,
    required this.admin1,
    required this.lat,
    required this.lng,
    required this.countryCode,
    required this.countryIso3,
    required this.country,
    required this.count,
    required this.average,
    required this.bins,
    required this.optionCounts,
  });

  factory MapCell.fromJson(Map<String, dynamic> json) {
    final breakdown = ResultsBreakdown.fromJson(json);
    return MapCell(
      kind: json['kind']?.toString() ?? 'city',
      cityId: _asString(json['city_id']),
      city: _asString(json['city']),
      admin1: _asString(json['admin1']),
      lat: _asDouble(json['lat']),
      lng: _asDouble(json['lng']),
      countryCode: _asString(json['country_code']),
      countryIso3: _asString(json['country_iso3']),
      country: json['country']?.toString() ?? 'Unknown',
      count: breakdown.count,
      average: breakdown.average,
      bins: breakdown.bins,
      optionCounts: breakdown.optionCounts,
    );
  }

  bool get isCity => kind == 'city' && lat != null && lng != null;

  /// The option this cell is coloured by, or 'TIE'.
  String get topOption => ResultsBreakdown(
        count: count,
        average: average,
        bins: bins,
        optionCounts: optionCounts,
      ).topOption;
}

/// The map payload for one question.
class QuestionMapCells {
  final String questionId;
  final String type;
  final List<ResultOption> options;
  final int total;
  final List<MapCell> cells;

  const QuestionMapCells({
    required this.questionId,
    required this.type,
    required this.options,
    required this.total,
    required this.cells,
  });

  static const QuestionMapCells empty = QuestionMapCells(
    questionId: '',
    type: '',
    options: <ResultOption>[],
    total: 0,
    cells: <MapCell>[],
  );

  factory QuestionMapCells.fromJson(Map<String, dynamic> json) {
    final rawCells = json['cells'];
    final rawOptions = json['options'];
    return QuestionMapCells(
      questionId: json['question_id']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      options: rawOptions is List
          ? (rawOptions
              .whereType<Map>()
              .map((e) => ResultOption.fromJson(Map<String, dynamic>.from(e)))
              .toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
          : const <ResultOption>[],
      total: _asInt(json['total']),
      cells: rawCells is List
          ? rawCells
              .whereType<Map>()
              .map((e) => MapCell.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const <MapCell>[],
    );
  }

  List<String> get optionTexts =>
      options.map((o) => o.text).toList(growable: false);
}

/// One public text answer: the words, the country, and the HOUR it was given.
/// There is no exact timestamp, no city and no generation — by design.
class TextAnswer {
  final String id;
  final String text;
  final String country;
  final String? countryCode;
  final DateTime? answeredHour;

  const TextAnswer({
    required this.id,
    required this.text,
    required this.country,
    required this.countryCode,
    required this.answeredHour,
  });

  factory TextAnswer.fromJson(Map<String, dynamic> json) => TextAnswer(
        id: json['id']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
        country: json['country']?.toString() ?? 'Unknown',
        countryCode: _asString(json['country_code']),
        answeredHour: DateTime.tryParse(json['answered_hour']?.toString() ?? ''),
      );

  /// The legacy row shape the discussion screen's list still reads. `created_at`
  /// is the HOUR, never the second — the field name is kept so the widget tree
  /// did not have to be rewritten around a rename.
  Map<String, dynamic> toRow() => <String, dynamic>{
        'id': id,
        'text_response': text,
        'country': country,
        'created_at': answeredHour?.toIso8601String(),
      };
}

/// One page of text answers. Paging is hour-aligned server-side, so [nextBefore]
/// can be passed back with no risk of skipping or repeating an answer.
class TextAnswerPage {
  final String questionId;
  final int total;
  final List<TextAnswer> answers;
  final DateTime? nextBefore;
  final bool hasMore;

  const TextAnswerPage({
    required this.questionId,
    required this.total,
    required this.answers,
    required this.nextBefore,
    required this.hasMore,
  });

  static const TextAnswerPage empty = TextAnswerPage(
    questionId: '',
    total: 0,
    answers: <TextAnswer>[],
    nextBefore: null,
    hasMore: false,
  );

  factory TextAnswerPage.fromJson(Map<String, dynamic> json) {
    final raw = json['answers'];
    return TextAnswerPage(
      questionId: json['question_id']?.toString() ?? '',
      total: _asInt(json['total']),
      answers: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => TextAnswer.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const <TextAnswer>[],
      nextBefore: DateTime.tryParse(json['next_before']?.toString() ?? ''),
      hasMore: json['has_more'] == true,
    );
  }

  List<Map<String, dynamic>> toRows() =>
      answers.map((a) => a.toRow()).toList(growable: false);
}

/// The four counts every "N answered" label is built from.
class QuestionCounts {
  final int total;
  final int answered;
  final int text;
  final int last24h;

  const QuestionCounts({
    required this.total,
    required this.answered,
    required this.text,
    required this.last24h,
  });

  static const QuestionCounts zero =
      QuestionCounts(total: 0, answered: 0, text: 0, last24h: 0);

  factory QuestionCounts.fromJson(Map<String, dynamic> json) => QuestionCounts(
        total: _asInt(json['total']),
        answered: _asInt(json['answered']),
        text: _asInt(json['text']),
        last24h: _asInt(json['last_24h']),
      );
}
