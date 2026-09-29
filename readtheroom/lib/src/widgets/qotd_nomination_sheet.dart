// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Asker's Pick (Phase 3b): a lightweight, skip-able post-submit step offering
// the asker a say in an upcoming Question of the Day. One tap nominates a
// candidate; a prominent Skip continues the flow. All rules are enforced
// server-side by the `nominate_qotd` RPC — this sheet never blocks the user's
// success moment: fetch/rule failures surface a friendly message and continue.

import 'package:flutter/material.dart';
import '../services/nomination_result.dart';

/// What the asker did on the pick step — reported back to the caller so it can
/// fire the `qotd_nomination` analytics event.
enum QotdNominationAction { picked, skipped }

class QotdNominationOutcome {
  final QotdNominationAction action;
  final int candidatesShown;
  const QotdNominationOutcome(this.action, this.candidatesShown);
}

class QotdNominationSheet extends StatefulWidget {
  /// Candidate questions (already fetched + filtered). Each map has at least
  /// `id`, `prompt`, and `votes`/`vote_count`.
  final List<Map<String, dynamic>> candidates;

  /// Performs the nomination (typically `QuestionService.nominateQotd`).
  final Future<NominationResult> Function(String questionId) onNominate;

  /// Headline override; null keeps "Help pick tomorrow's question!".
  final String? title;

  const QotdNominationSheet({
    Key? key,
    required this.candidates,
    required this.onNominate,
    this.title,
  }) : super(key: key);

  /// Presents the pick step as a modal bottom sheet. Resolves to the asker's
  /// [QotdNominationOutcome] once they pick or skip (or dismiss).
  static Future<QotdNominationOutcome> show(
    BuildContext context, {
    required List<Map<String, dynamic>> candidates,
    required Future<NominationResult> Function(String questionId) onNominate,
    String? title,
  }) async {
    final result = await showModalBottomSheet<QotdNominationOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => QotdNominationSheet(
        candidates: candidates,
        onNominate: onNominate,
        title: title,
      ),
    );
    // A dismissal (drag/tap-outside) counts as a skip.
    return result ??
        QotdNominationOutcome(QotdNominationAction.skipped, candidates.length);
  }

  @override
  State<QotdNominationSheet> createState() => _QotdNominationSheetState();
}

class _QotdNominationSheetState extends State<QotdNominationSheet> {
  String? _pendingId; // id currently being nominated
  bool _done = false; // guards against double-taps after a pick

  Future<void> _onPick(Map<String, dynamic> question) async {
    if (_done || _pendingId != null) return;
    final id = question['id']?.toString();
    if (id == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);

    setState(() => _pendingId = id);

    NominationResult result;
    try {
      result = await widget.onNominate(id);
    } catch (_) {
      result = NominationResult.fail(NominationError.unknown);
    }

    if (!mounted) return;
    _done = true;

    Navigator.of(context).pop(
      QotdNominationOutcome(
        QotdNominationAction.picked,
        widget.candidates.length,
      ),
    );

    // Success or a friendly rule message — either way the flow continues.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: theme.primaryColor,
      ),
    );
  }

  void _onSkip() {
    if (_pendingId != null) return;
    Navigator.of(context).pop(
      QotdNominationOutcome(
        QotdNominationAction.skipped,
        widget.candidates.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.dividerColor.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              widget.title ?? "Help pick tomorrow's question!",
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.primaryColor,
              ),
            ),
            const SizedBox(height: 16),
            ...widget.candidates.map(_buildCandidateTile),
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: _pendingId != null ? null : _onSkip,
                child: Text(
                  'Skip',
                  style: TextStyle(
                    color: theme.primaryColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCandidateTile(Map<String, dynamic> question) {
    final theme = Theme.of(context);
    final id = question['id']?.toString();
    final prompt = (question['prompt'] ?? '').toString();
    final votes = (question['votes'] ?? question['vote_count'] ?? 0);
    final isPending = _pendingId != null && _pendingId == id;
    final anyPending = _pendingId != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: anyPending ? null : () => _onPick(question),
          child: Opacity(
            opacity: anyPending && !isPending ? 0.5 : 1.0,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prompt,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.how_to_vote_outlined,
                              size: 14,
                              color: theme.textTheme.bodySmall?.color
                                  ?.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$votes ${votes == 1 ? 'answer' : 'answers'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.textTheme.bodySmall?.color
                                    ?.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  isPending
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              theme.primaryColor,
                            ),
                          ),
                        )
                      : Icon(
                          Icons.add_circle_outline,
                          color: theme.primaryColor,
                        ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
