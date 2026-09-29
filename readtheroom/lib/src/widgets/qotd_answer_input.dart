// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-type answer input for the Question of the Day, extracted verbatim from
// the proven inputs in the former QOTD overlay so the new QOTD-first home
// (`qotd_hero_card`, Phase 2) uses one shared implementation.
//
// API contract (Phase 2 depends on this exactly):
//   QotdAnswerInput(question: <map>, onChanged: (QotdAnswerValue v) {...})
//     - Owns its own state: slider value / selected option / text controller.
//     - Fires `onChanged` with a fresh [QotdAnswerValue] on every edit AND once
//       immediately after first layout (so the parent gets an initial value).
//     - The parent reads `value.canSubmit` to gate its submit button and
//       `value.submitValue` for the value to send to the response API.
//     - Optional `onCommit` (WP-A tap-to-submit) fires when the user makes a
//       *deliberate, complete* gesture for the type: tapping a multiple-choice
//       option, or releasing the approval slider (decision D7). Text questions
//       never fire it — they keep the manual submit button. It always fires
//       after the matching `onChanged`.
//   Theme-aware; no Supabase / Provider dependency.

import 'package:flutter/material.dart';
import '../utils/approval_labels.dart';
import 'approval_end_labels_row.dart';
import 'approval_slider.dart';

/// Immutable snapshot of the current answer for a QOTD, emitted via
/// [QotdAnswerInput.onChanged]. The parent uses [canSubmit] to gate submission
/// and [submitValue] for the raw value handed to the response API.
class QotdAnswerValue {
  /// Normalized question type (lowercase), as resolved from the question map.
  final String questionType;

  /// Approval slider position in [-1.0, 1.0] (approval questions only).
  final double sliderValue;

  /// Selected multiple-choice option text, or null (multiple-choice only).
  final String? selectedOption;

  /// Free-text answer (text questions only), not yet trimmed.
  final String text;

  const QotdAnswerValue({
    required this.questionType,
    this.sliderValue = 0.0,
    this.selectedOption,
    this.text = '',
  });

  /// Whether the current answer is submittable for this question type.
  /// Mirrors the overlay's original `_canSubmit` logic (approval always
  /// submittable; MC requires a selection; text requires non-empty).
  bool get canSubmit {
    switch (questionType) {
      case 'approval_rating':
      case 'approval':
        return true;
      case 'multiplechoice':
      case 'multiple_choice':
        return selectedOption != null;
      case 'text':
        return text.trim().isNotEmpty;
      default:
        return false;
    }
  }

  /// The value to hand to the response-submit API for this question type:
  /// a `double` for approval, the selected option `String` for MC, or the
  /// trimmed `String` for text.
  dynamic get submitValue {
    switch (questionType) {
      case 'approval_rating':
      case 'approval':
        return sliderValue;
      case 'multiplechoice':
      case 'multiple_choice':
        return selectedOption;
      case 'text':
        return text.trim();
      default:
        return null;
    }
  }
}

class QotdAnswerInput extends StatefulWidget {
  final Map<String, dynamic> question;

  /// Called on every edit, and once after first layout with the initial value.
  final ValueChanged<QotdAnswerValue> onChanged;

  /// Called when the user completes a one-gesture answer for this type — an MC
  /// option tap or an approval-slider release. Never fired for text questions.
  final ValueChanged<QotdAnswerValue>? onCommit;

  const QotdAnswerInput({
    Key? key,
    required this.question,
    required this.onChanged,
    this.onCommit,
  }) : super(key: key);

  @override
  State<QotdAnswerInput> createState() => _QotdAnswerInputState();
}

class _QotdAnswerInputState extends State<QotdAnswerInput> {
  double _sliderValue = 0.0;
  String? _selectedOption;
  final TextEditingController _textController = TextEditingController();

  String get _questionType {
    return widget.question['type']?.toString().toLowerCase() ?? 'text';
  }

  @override
  void initState() {
    super.initState();
    // Emit an initial value so the parent can gate its submit button before any
    // interaction (approval questions are submittable from the start).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notify();
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  QotdAnswerValue get _currentValue => QotdAnswerValue(
        questionType: _questionType,
        sliderValue: _sliderValue,
        selectedOption: _selectedOption,
        text: _textController.text,
      );

  void _notify() {
    widget.onChanged(_currentValue);
  }

  /// Emit the change then the commit, so the parent's cached value is current
  /// before it acts on the commit.
  void _notifyAndCommit() {
    final value = _currentValue;
    widget.onChanged(value);
    widget.onCommit?.call(value);
  }

  Widget _buildAnswerInput() {
    switch (_questionType) {
      case 'approval_rating':
      case 'approval':
        return _buildApprovalInput();
      case 'multiplechoice':
      case 'multiple_choice':
        return _buildMultipleChoiceInput();
      case 'text':
        return _buildTextInput();
      default:
        return _buildTextInput();
    }
  }

  Widget _buildApprovalInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Drag the slider to respond',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).dividerColor,
            ),
          ),
          child: Column(
            children: [
              ApprovalEndLabelsRow(
                labels: approvalLabelsFrom(widget.question),
              ),
              const SizedBox(height: 8),
              ApprovalSlider(
                initialValue: 0.0,
                onChanged: (value) {
                  setState(() => _sliderValue = value);
                  _notify();
                },
                onChangeEnd: (value) {
                  setState(() => _sliderValue = value);
                  _notifyAndCommit();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMultipleChoiceInput() {
    final options = widget.question['question_options'] as List<dynamic>? ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Select your answer',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 16),
        ...options.map((option) {
          final optionText = option['option_text']?.toString() ?? '';
          final isSelected = _selectedOption == optionText;
          final theme = Theme.of(context);

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: isSelected
                  ? theme.primaryColor.withOpacity(0.12)
                  : theme.cardColor,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: () {
                  setState(() => _selectedOption = optionText);
                  _notifyAndCommit();
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? theme.primaryColor
                          : Colors.grey.withOpacity(0.3),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isSelected ? theme.primaryColor : Colors.grey,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          optionText,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            color: isSelected
                                ? theme.primaryColor
                                : theme.textTheme.bodyLarge?.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ],
    );
  }

  Widget _buildTextInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Type your answer',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _textController,
          maxLines: 5,
          minLines: 3,
          decoration: InputDecoration(
            hintText: 'Share your thoughts...',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: Theme.of(context).primaryColor,
                width: 2,
              ),
            ),
          ),
          onChanged: (_) {
            setState(() {});
            _notify();
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildAnswerInput();
  }
}
