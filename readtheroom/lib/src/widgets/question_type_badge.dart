// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class QuestionTypeBadge extends StatelessWidget {
  final String type;
  final double size;
  final Color? color;

  const QuestionTypeBadge({
    Key? key,
    required this.type,
    this.size = 20.0,
    this.color,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    IconData iconData;

    switch (type.toLowerCase()) {
      case 'approval':
      case 'approval_rating':
        iconData = Icons.thumbs_up_down;
        break;
      case 'multiple_choice':
      case 'multiplechoice':
        iconData = Icons.check_box;
        break;
      case 'text':
        iconData = Icons.text_fields;
        break;
      default:
        iconData = Icons.help_outline;
    }

    return Icon(
      iconData,
      size: size,
      color: color ?? Colors.grey[600],
    );
  }
} 