// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Approval-question end labels (WP-B, list item 1).
//
// An approval question's slider runs from -1 (the "low" end) to +1 (the "high"
// end). The asker can now name those ends; the labels live in the two
// `question_options` rows the table comment already reserves for "approval
// rating display labels" (DBarchitecture.md), by convention:
//
//   sort_order 0 → low / disapprove end
//   sort_order 1 → high / approve end
//
// No migration is needed, and questions with no option rows — every approval
// question asked before this feature, plus the whole seeded QOTD bank — fall
// back to the defaults and render exactly as they always did.
//
// Pure: no Flutter, no Supabase, directly unit testable.

/// Default label for the low (-1) end of the approval slider.
const String kDefaultApprovalLowLabel = 'Disapprove';

/// Default label for the high (+1) end of the approval slider.
const String kDefaultApprovalHighLabel = 'Approve';

/// Authoring limit for a custom end label.
const int kApprovalLabelMaxLength = 20;

/// The two end labels of an approval question's slider.
class ApprovalLabels {
  /// Label for the low (-1, thumbs-down) end.
  final String low;

  /// Label for the high (+1, thumbs-up) end.
  final String high;

  const ApprovalLabels({required this.low, required this.high});

  /// The untouched defaults ("Disapprove" / "Approve").
  static const ApprovalLabels defaults = ApprovalLabels(
    low: kDefaultApprovalLowLabel,
    high: kDefaultApprovalHighLabel,
  );

  /// Whether both labels are still the defaults (nothing worth persisting
  /// beyond them, and nothing worth showing differently).
  bool get isDefault =>
      low == kDefaultApprovalLowLabel && high == kDefaultApprovalHighLabel;

  @override
  bool operator ==(Object other) =>
      other is ApprovalLabels && other.low == low && other.high == high;

  @override
  int get hashCode => Object.hash(low, high);

  @override
  String toString() => 'ApprovalLabels($low → $high)';
}

/// Trim + clamp one authored label, falling back to [fallback] when blank.
String normalizeApprovalLabel(String? raw, {required String fallback}) {
  final trimmed = (raw ?? '').trim();
  if (trimmed.isEmpty) return fallback;
  return trimmed.length > kApprovalLabelMaxLength
      ? trimmed.substring(0, kApprovalLabelMaxLength)
      : trimmed;
}

/// Extract the approval end labels from an enriched question map, defaulting
/// each end independently when its row is missing or blank.
///
/// Accepts whatever the feed/question queries hand back: `question_options` may
/// be absent, empty, or a list of maps with `option_text` and (usually)
/// `sort_order`. Rows without a usable `sort_order` are read positionally, so a
/// legacy pair inserted without the column still resolves low-then-high.
ApprovalLabels approvalLabelsFrom(Map<String, dynamic>? question) {
  final raw = question?['question_options'];
  if (raw is! List || raw.isEmpty) return ApprovalLabels.defaults;

  final byOrder = <int, String>{};
  for (var i = 0; i < raw.length; i++) {
    final row = raw[i];
    if (row is! Map) continue;
    final text = row['option_text']?.toString();
    if (text == null || text.trim().isEmpty) continue;

    final order = row['sort_order'];
    final index = order is num ? order.toInt() : int.tryParse('$order') ?? i;
    // First row wins for a given end (duplicate sort_order shouldn't happen).
    byOrder.putIfAbsent(index, () => text);
  }

  return ApprovalLabels(
    low: normalizeApprovalLabel(byOrder[0], fallback: kDefaultApprovalLowLabel),
    high:
        normalizeApprovalLabel(byOrder[1], fallback: kDefaultApprovalHighLabel),
  );
}
