// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/question_service.dart';
import '../services/user_service.dart';
import '../utils/friend_chat_logic.dart';
import 'question_type_badge.dart';

/// "Forward a question" mini-picker (networks-update-design §5.4).
///
/// Opens over the chat overlay and returns the chosen question id, or null on
/// dismissal. Two states:
///
/// * **idle** — today's QOTD first, then the questions the viewer has answered
///   (`UserService.answeredQuestions`, newest first). Those are the two lists
///   that need no network round trip, and between them they are what someone
///   actually wants to send: the thing everyone is answering today, and the
///   thing they just had an opinion about.
/// * **searching** — `QuestionService.searchQuestionsForAutocomplete`, the same
///   query path the Archive/search screen and the comment composer use, behind
///   the same 300 ms debounce and 3-character gate.
///
/// Filtering, de-duplication and the hidden-question guard are
/// [filterForwardCandidates] in `friend_chat_logic.dart`, so they are
/// unit-tested rather than tangled into the widget.
class ForwardQuestionPicker {
  const ForwardQuestionPicker._();

  /// Returns the picked question's id, or null.
  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ForwardQuestionPickerSheet(),
    );
  }
}

class _ForwardQuestionPickerSheet extends StatefulWidget {
  const _ForwardQuestionPickerSheet();

  @override
  State<_ForwardQuestionPickerSheet> createState() =>
      _ForwardQuestionPickerSheetState();
}

class _ForwardQuestionPickerSheetState
    extends State<_ForwardQuestionPickerSheet> {
  static const Duration _debounceDelay = Duration(milliseconds: 300);
  static const int _minQueryLength = 3;

  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  List<Map<String, dynamic>> _recent = const [];
  List<Map<String, dynamic>> _results = const [];
  String _query = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRecent());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _loadRecent() {
    if (!mounted) return;
    final userService = context.read<UserService>();
    final questionService = context.read<QuestionService>();

    // The QOTD goes first because it is the one question the recipient is
    // most likely to have an opinion about today.
    final qotd = questionService.questionOfTheDay;
    final candidates = <Map<String, dynamic>>[
      if (qotd != null) qotd,
      ...userService.answeredQuestions.reversed,
    ];

    setState(() {
      _recent = filterForwardCandidates(candidates);
    });
  }

  void _onQueryChanged(String raw) {
    _debounce?.cancel();
    final query = raw.trim();
    if (query.length < _minQueryLength) {
      setState(() {
        _query = query;
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() {
      _query = query;
      _searching = true;
    });
    _debounce = Timer(_debounceDelay, () => _search(query));
  }

  Future<void> _search(String query) async {
    final questionService = context.read<QuestionService>();
    final userService = context.read<UserService>();
    try {
      final raw = await questionService.searchQuestionsForAutocomplete(
        query,
        limit: kForwardPickerLimit,
        includeNSFW: userService.showNSFWContent,
        excludePrivate: true,
      );
      if (!mounted || _query != query) return;
      setState(() {
        _results = filterForwardCandidates(raw, query: '');
        _searching = false;
      });
    } catch (e) {
      debugPrint('ForwardQuestionPicker search failed: $e');
      if (!mounted) return;
      setState(() {
        _results = const [];
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSearch = _query.length >= _minQueryLength;
    final rows = isSearch ? _results : _recent;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            _dragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Send a question',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: Colors.grey[600]),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                onChanged: _onQueryChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search questions…',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildList(theme, rows, isSearch)),
          ],
        ),
      ),
    );
  }

  Widget _dragHandle() => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 12, bottom: 8),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[400],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _buildList(
    ThemeData theme,
    List<Map<String, dynamic>> rows,
    bool isSearch,
  ) {
    if (_searching && rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Center(
          child: Text(
            isSearch
                ? 'Nothing matched that.'
                : "Answer a question and it'll show up here to send on.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              isSearch ? 'Results' : 'Recent',
              style: theme.textTheme.labelLarge?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        final question = rows[index - 1];
        return ListTile(
          leading: QuestionTypeBadge(
            type: (question['type'] ?? '').toString(),
            color: theme.primaryColor,
          ),
          title: Text(
            (question['prompt'] ?? '').toString(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () =>
              Navigator.of(context).pop((question['id'] ?? '').toString()),
        );
      },
    );
  }
}
