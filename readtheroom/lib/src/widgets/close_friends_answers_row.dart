// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Close-friend answers row — design doc §5.5B.
//
// Lists, by @handle, how each *reciprocal* close friend answered a question,
// with a coloured chip per answer drawn from the shared results palette
// (ResultsColors). This is the one place individual answers are shown, and only
// under the three-way consent gate described in §9 P-2 (reciprocity + the
// global share toggle + the ability to unfriend). The explanatory copy states
// the reciprocity requirement honestly, per the spec.
//
// Takes a plain list of [CloseFriendAnswer] — the shape
// `get_close_friend_answers(question_id)` returns, and the shape the demo
// dataset fabricates. Picks and slider positions only: a text answer's BODY is
// never shared, with anyone, ever (owner decision D-1), so a text question
// produces no rows here at all.
//
// Never written to disk (privacy rule P-2).

import 'package:flutter/material.dart';
import '../models/network_graph.dart';
import '../utils/results_colors.dart';

class CloseFriendsAnswersRow extends StatelessWidget {
  final List<CloseFriendAnswer> answers;

  const CloseFriendsAnswersRow({Key? key, required this.answers})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.04) : primary.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary.withOpacity(0.18)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_rounded, size: 18, color: primary),
              const SizedBox(width: 8),
              Text(
                'Close friends',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "Close friends can see each other's answers.",
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.grey,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < answers.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _buildAnswerRow(context, answers[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildAnswerRow(BuildContext context, CloseFriendAnswer answer) {
    final theme = Theme.of(context);
    final chipColor = _colorFor(context, answer);

    return Row(
      children: [
        // Avatar dab: coloured initial for the handle.
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.dividerColor.withOpacity(0.25),
          ),
          alignment: Alignment.center,
          child: Text(
            _initial(answer.handle),
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            answer.handle,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _answerChip(context, answer.answerLabel, chipColor),
      ],
    );
  }

  Widget _answerChip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Color _colorFor(BuildContext context, CloseFriendAnswer answer) {
    switch (answer.kind) {
      case NetworkAnswerKind.approval:
        return ResultsColors.forApprovalBucket(
            context, answer.approvalValue ?? 0);
      case NetworkAnswerKind.multipleChoice:
        return ResultsColors.forOptionIndex(context, answer.optionIndex ?? 0);
    }
  }

  String _initial(String handle) {
    final cleaned = handle.replaceFirst('@', '');
    return cleaned.isEmpty ? '?' : cleaned[0].toUpperCase();
  }
}
