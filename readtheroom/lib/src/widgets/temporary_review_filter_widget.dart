// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/temporary_review_filter_notifier.dart';
import '../utils/review_tag_navigation.dart';

class TemporaryReviewFilterWidget extends StatelessWidget {
  const TemporaryReviewFilterWidget({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<TemporaryReviewFilterNotifier>(
      builder: (context, filterNotifier, child) {
        if (!filterNotifier.hasTemporaryReviewFilter) {
          return SizedBox.shrink();
        }

        final tagKey = filterNotifier.temporaryReviewFilter!;
        final tagLabel = ReviewTagNavigation.chipLabels[tagKey] ?? tagKey;
        final primaryColor = Theme.of(context).primaryColor;

        return Dismissible(
          key: Key('temp_review_filter_$tagKey'),
          direction: DismissDirection.horizontal,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              Scaffold.of(context).openDrawer();
              return false;
            }
            filterNotifier.setTemporaryReviewFilter(null);
            return true;
          },
          background: Container(
            color: Colors.transparent,
          ),
          secondaryBackground: Container(
            alignment: Alignment.centerRight,
            padding: EdgeInsets.only(right: 20),
            color: primaryColor,
            child: Icon(
              Icons.close,
              color: Colors.white,
              size: 24,
            ),
          ),
          child: Container(
            margin: EdgeInsets.fromLTRB(16, 4, 16, 12),
            padding: EdgeInsets.all(16),
            constraints: BoxConstraints(minHeight: 100),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primaryColor.withOpacity(0.1),
                  primaryColor.withOpacity(0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: primaryColor.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.star,
                  color: primaryColor,
                  size: 24,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tagLabel,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close,
                    color: primaryColor,
                  ),
                  onPressed: () {
                    filterNotifier.setTemporaryReviewFilter(null);
                  },
                  tooltip: 'Clear filter',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
