// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

enum QuestionType {
  approval,
  multipleChoice,
  text,
}

class Question {
  final String id;
  final String title;
  final String? description;
  final QuestionType type;
  final List<String>? options;
  final bool isNsfw;
  final DateTime timestamp;
  final int votes;

  Question({
    required this.id,
    required this.title,
    this.description,
    required this.type,
    this.options,
    required this.isNsfw,
    required this.timestamp,
    required this.votes,
  });

  factory Question.fromMap(Map<String, dynamic> map) {
    return Question(
      id: map['id'] as String,
      title: map['title'] as String,
      description: map['description'] as String?,
      type: _parseQuestionType(map['type'] as String),
      options: (map['options'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
      isNsfw: map['is_nsfw'] as bool? ?? false,
      timestamp: DateTime.parse(map['timestamp'] as String),
      votes: map['votes'] as int? ?? 0,
    );
  }

  static QuestionType _parseQuestionType(String type) {
    switch (type.toLowerCase()) {
      case 'approval':
        return QuestionType.approval;
      case 'multiplechoice':
        return QuestionType.multipleChoice;
      case 'text':
        return QuestionType.text;
      default:
        throw ArgumentError('Unknown question type: $type');
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'type': type.toString().split('.').last,
      'options': options,
      'is_nsfw': isNsfw,
      'timestamp': timestamp.toIso8601String(),
      'votes': votes,
    };
  }
}
