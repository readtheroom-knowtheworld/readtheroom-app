// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class SharingPreferenceSelector extends StatelessWidget {
  final String selectedPreference;
  final ValueChanged<String> onPreferenceChanged;
  final bool showTitle;
  final bool expanded;

  const SharingPreferenceSelector({
    Key? key,
    required this.selectedPreference,
    required this.onPreferenceChanged,
    this.showTitle = true,
    this.expanded = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle) ...[
          Text(
            'Response Sharing',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Choose how your responses are shared to this room',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
            ),
          ),
          SizedBox(height: 12),
        ],
        
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey[300]!),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              RadioListTile<String>(
                title: Row(
                  children: [
                    Icon(Icons.auto_awesome, color: Colors.green, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Auto-share'),
                          Text(
                            '(recommended)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                subtitle: Text(
                  'Your responses will be auto-shared anonymously to this room.',
                  style: TextStyle(fontSize: 13),
                ),
                value: 'auto_share_all',
                groupValue: selectedPreference,
                onChanged: (value) => onPreferenceChanged(value!),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
              
              Divider(height: 1, indent: 16, endIndent: 16),
              
              RadioListTile<String>(
                title: Row(
                  children: [
                    Icon(Icons.touch_app, color: Colors.orange, size: 20),
                    SizedBox(width: 8),
                    Text('Manual sharing'),
                  ],
                ),
                subtitle: Text(
                  'You\'ll get notifications in the Activity page to share each response individually. '
		  'This increases device storage use.',
                  style: TextStyle(fontSize: 13),
                ),
                value: 'manual',
                groupValue: selectedPreference,
                onChanged: (value) => onPreferenceChanged(value!),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
            ],
          ),
        ),
        
        if (expanded) ...[
          SizedBox(height: 12),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange[700], size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You can change this setting at anytime. '
                    'Your responses are always anonymous and are only displayed when >5 others have responded.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.orange[700],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
