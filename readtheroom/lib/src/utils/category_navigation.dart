// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/category.dart';
import '../services/temporary_category_filter_notifier.dart';

class CategoryNavigation {
  // Static method to handle category chip clicks
  static void onCategoryChipTap(BuildContext context, String categoryName) {
    // Set the temporary category filter
    final filterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
    filterNotifier.setTemporaryCategoryFilter(categoryName);
    
    // Navigate back to home screen without destroying it
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  // Method to create a clickable category chip
  static Widget buildClickableCategoryChip(
    BuildContext context,
    String categoryName, {
    double fontSize = 12,
    EdgeInsetsGeometry? padding,
  }) {
    final category = Category.allCategories.firstWhere(
      (c) => c.name == categoryName,
      orElse: () => Category(name: categoryName, isNSFW: false),
    );

    return GestureDetector(
      onTap: () => onCategoryChipTap(context, categoryName),
      child: Chip(
        label: Text(
          category.name,
          style: TextStyle(fontSize: fontSize),
        ),
        backgroundColor: category.isNSFW 
            ? Colors.red.withOpacity(0.1)
            : Theme.of(context).primaryColor.withOpacity(0.1),
        padding: padding,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
} 