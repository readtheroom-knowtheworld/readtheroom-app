// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/temporary_category_filter_notifier.dart';
import '../models/category.dart';

class TemporaryCategoryFilterWidget extends StatelessWidget {
  const TemporaryCategoryFilterWidget({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<TemporaryCategoryFilterNotifier>(
      builder: (context, filterNotifier, child) {
        if (!filterNotifier.hasTemporaryCategoryFilter) {
          return SizedBox.shrink();
        }

        final categoryName = filterNotifier.temporaryCategoryFilter!;
        final category = Category.allCategories.firstWhere(
          (c) => c.name == categoryName,
          orElse: () => Category(name: categoryName, isNSFW: false),
        );

        return Dismissible(
          key: Key('temp_category_filter_${category.name}'),
          direction: DismissDirection.horizontal, // Allow both directions
          confirmDismiss: (direction) async {
            // Handle right swipe (start to end) - open drawer
            if (direction == DismissDirection.startToEnd) {
              Scaffold.of(context).openDrawer();
              return false; // Don't dismiss the filter
            }
            
            // Handle left swipe (end to start) - dismiss filter
            filterNotifier.setTemporaryCategoryFilter(null);
            return true; // Allow dismissal
          },
          background: Container(
            // Transparent background for right swipe (opens drawer)
            color: Colors.transparent,
          ),
          secondaryBackground: Container(
            alignment: Alignment.centerRight,
            padding: EdgeInsets.only(right: 20),
            color: Theme.of(context).primaryColor,
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
                colors: category.isNSFW 
                    ? [
                        Colors.red.withOpacity(0.1),
                        Colors.red.withOpacity(0.05),
                      ]
                    : [
                        Theme.of(context).primaryColor.withOpacity(0.1),
                        Theme.of(context).primaryColor.withOpacity(0.05),
                      ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: category.isNSFW 
                    ? Colors.red.withOpacity(0.3)
                    : Theme.of(context).primaryColor.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Padding(
              padding: EdgeInsets.all(0),
              child: Row(
                children: [
                  // Category chip icon
                  Icon(
                    Icons.category,
                    color: category.isNSFW 
                        ? Colors.red
                        : Theme.of(context).colorScheme.onSurface,
                    size: 24,
                  ),
                  SizedBox(width: 8),
                  // Category name
                  Expanded(
                    child: Text(
                      category.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Close button
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      color: category.isNSFW 
                          ? Colors.red
                          : Theme.of(context).primaryColor,
                    ),
                    onPressed: () {
                      filterNotifier.setTemporaryCategoryFilter(null);
                    },
                    tooltip: 'Clear filter',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}