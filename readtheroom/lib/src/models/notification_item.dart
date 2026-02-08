// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

class NotificationItem {
  final String id;
  final String title;
  final String body;
  final String type; // 'comment', 'vote_activity', 'qotd', 'system'
  final DateTime timestamp;
  final String? questionId;
  final String? suggestionId;
  final bool isViewed;
  final bool isDismissed;
  final Map<String, dynamic>? metadata;

  NotificationItem({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.timestamp,
    this.questionId,
    this.suggestionId,
    this.isViewed = false,
    this.isDismissed = false,
    this.metadata,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    return NotificationItem(
      id: json['id'],
      title: json['title'],
      body: json['body'],
      type: json['type'],
      timestamp: DateTime.parse(json['timestamp']),
      questionId: json['question_id'],
      suggestionId: json['suggestion_id'],
      isViewed: json['is_viewed'] ?? false,
      isDismissed: json['is_dismissed'] ?? false,
      metadata: json['metadata'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'body': body,
      'type': type,
      'timestamp': timestamp.toIso8601String(),
      'question_id': questionId,
      'suggestion_id': suggestionId,
      'is_viewed': isViewed,
      'is_dismissed': isDismissed,
      'metadata': metadata,
    };
  }

  NotificationItem copyWith({
    String? id,
    String? title,
    String? body,
    String? type,
    DateTime? timestamp,
    String? questionId,
    String? suggestionId,
    bool? isViewed,
    bool? isDismissed,
    Map<String, dynamic>? metadata,
  }) {
    return NotificationItem(
      id: id ?? this.id,
      title: title ?? this.title,
      body: body ?? this.body,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      questionId: questionId ?? this.questionId,
      suggestionId: suggestionId ?? this.suggestionId,
      isViewed: isViewed ?? this.isViewed,
      isDismissed: isDismissed ?? this.isDismissed,
      metadata: metadata ?? this.metadata,
    );
  }

  bool get isToday {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final itemDate = DateTime(timestamp.year, timestamp.month, timestamp.day);
    return itemDate == today;
  }

  String get displayType {
    switch (type) {
      case 'comment':
        return '💬';
      case 'vote_activity':
        return '🦎';
      case 'qotd':
        return '📆';
      case 'system':
        return '🔔';
      default:
        return '📱';
    }
  }
}