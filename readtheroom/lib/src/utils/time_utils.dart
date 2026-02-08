// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/utils/time_utils.dart
String getTimeAgo(String? isoTimestamp) {
  if (isoTimestamp == null || isoTimestamp.isEmpty) {
    return 'Unknown';
  }
  
  DateTime date;
  try {
    date = DateTime.parse(isoTimestamp);
  } catch (e) {
    return 'Invalid date';
  }
  
  Duration diff = DateTime.now().difference(date);
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes}m';
  } else if (diff.inHours < 24) {
    return '${diff.inHours}h';
  } else if (diff.inDays < 30) {
    return '${diff.inDays}d';
  } else if (diff.inDays < 365) {
    int months = (diff.inDays / 30).floor();
    return '${months}mo';
  } else {
    int years = (diff.inDays / 365).floor();
    return '${years}yr';
  }
}

String formatTimestamp(String? timestamp) {
  if (timestamp == null || timestamp.isEmpty) return 'Unknown time';
  
  try {
    final date = DateTime.parse(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  } catch (e) {
    return 'Invalid time';
  }
}
