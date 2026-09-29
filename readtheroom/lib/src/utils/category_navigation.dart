// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../models/category.dart';
import '../screens/search_screen.dart';

class CategoryNavigation {
  // Static method to handle category chip clicks
  static void onCategoryChipTap(BuildContext context, String categoryName) {
    // Push the Archive (evolved Search) with the topic filter pre-applied. The
    // Archive shows a dismissible "Topic: <name>" header and filters its
    // Unanswered queue / search results to this category client-side.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          source: 'topic_chip',
          autofocus: false,
          initialCategoryFilter: categoryName,
        ),
      ),
    );
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