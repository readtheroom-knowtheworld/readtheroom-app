// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

class Category {
  final String name;
  final bool isNSFW;

  const Category({
    required this.name,
    this.isNSFW = false,
  });

  static const List<Category> allCategories = [
    // Always first (getOrderedCategoriesByUsage ensures these stay at top)
    Category(name: 'Serious'),
    Category(name: 'Funny'),

    // Ordered by actual usage frequency (most to least used)
    Category(name: 'Society & Culture'),        // 996 questions (18.20%)
    Category(name: 'Self Reflection'),          // 693 questions (12.66%)
    Category(name: 'Lifestyle'),                // 637 questions (11.64%)
    Category(name: 'Health & Wellness'),        // 358 questions (6.54%)
    Category(name: 'Pop Culture & Media'),      // 336 questions (6.14%)
    Category(name: 'Philosophy & Ethics'),      // 244 questions (4.46%)
    Category(name: 'Dating & Relationships'),   // 193 questions (3.53%)
    Category(name: 'Politics'),                 // 183 questions (3.34%)
    Category(name: 'Food & Drink'),             // 158 questions (2.89%)
    Category(name: 'My Community'),             // 156 questions (2.85%)
    Category(name: 'Hypotheticals & What-ifs'), // 142 questions (2.60%)
    Category(name: 'Science & Technology'),     // 116 questions (2.12%)
    Category(name: 'News & Current Events'),    // 112 questions (2.05%)
    Category(name: 'Money & Work'),             // 88 questions (1.61%)
    Category(name: 'Unpopular Opinions', isNSFW: false), // 52 questions (0.95%)
    Category(name: 'Reviews'),                  // 47 questions (0.86%)
    Category(name: 'Travel & Places'),          // 40 questions (0.73%)
    Category(name: 'History'),                  // 37 questions (0.68%)
    Category(name: 'Games & Fandoms'),          // 36 questions (0.66%)
    Category(name: 'Would You Rather?'),        // 36 questions (0.66%)
    Category(name: 'Secrets'),                  // 35 questions (0.64%)
    Category(name: 'Religion & Spirituality'),  // 27 questions (0.49%)
    Category(name: 'Memes'),                    // 24 questions (0.44%)
    Category(name: 'Sports'),                   // 18 questions (0.33%)
    Category(name: 'Conspiracies & Mysteries'), // 15 questions (0.27%)
    Category(name: 'Rate a Billionaire'),       // New category
    Category(name: 'Rate an Organization'),     // New category
  ];

  static const List<String> mainCategories = [
    'General',
    'Thought-Provoking',
    'Personal & Lifestyle',
    'Fun & Lighthearted',
    'Edgier & Unfiltered',
  ];

  static List<Category> getCategoriesByMainCategory(String mainCategory) {
    switch (mainCategory) {
      case 'General':
        return allCategories.where((c) => 
          ['Pop Culture, Media & Memes', 'My Community', 'Politics', 'News & Current Events']
          .contains(c.name)).toList();
      case 'Thought-Provoking':
        return allCategories.where((c) => 
          ['Philosophy & Ethics', 'Society & Culture', 'Science & Technology', 'History', 'Religion & Spirituality', 'Serious']
          .contains(c.name)).toList();
      case 'Personal & Lifestyle':
        return allCategories.where((c) => 
          ['Dating & Relationships', 'Health & Wellness', 'Money & Work', 'Food & Drink', 'Travel & Places', 'Reviews', 'Lifestyle', 'Self Reflection', 'Sports']
          .contains(c.name)).toList();
      case 'Fun & Lighthearted':
        return allCategories.where((c) => 
          ['Would You Rather?', 'Ratings', 'Ranking', 'Hypotheticals & What-ifs', 'Games & Fandoms', 'Conspiracies & Mysteries', 'Secrets', 'Funny', 'Rate a Billionaire', 'Rate an Organization']
          .contains(c.name)).toList();
      case 'Edgier & Unfiltered':
        return allCategories.where((c) => 
          ['Unpopular Opinions']
          .contains(c.name)).toList();
      default:
        return [];
    }
  }

  /// Get categories ordered by static usage statistics
  /// "Serious" and "Funny" always appear first, followed by categories in the order from allCategories (sorted by overall usage frequency)
  static List<Category> getOrderedCategoriesByStaticUsage() {
    // Return categories in the order they appear in allCategories (already sorted by frequency)
    return List.from(allCategories);
  }

  /// Get categories ordered by usage in current feed
  /// "Serious" and "Funny" always appear first, followed by categories ordered by their count in the feed
  /// If feed counts are empty/unavailable, falls back to overall usage order from allCategories
  static List<Category> getOrderedCategoriesByUsage(Map<String, int> categoryCounts) {
    final List<Category> orderedCategories = [];
    
    // First, add "Serious" and "Funny" in that order if they exist
    final serious = allCategories.firstWhere((c) => c.name == 'Serious', orElse: () => Category(name: ''));
    final funny = allCategories.firstWhere((c) => c.name == 'Funny', orElse: () => Category(name: ''));
    
    if (serious.name.isNotEmpty) {
      orderedCategories.add(serious);
    }
    if (funny.name.isNotEmpty) {
      orderedCategories.add(funny);
    }
    
    // Get remaining categories (excluding Serious and Funny)
    final remainingCategories = allCategories.where((c) => 
      c.name != 'Serious' && c.name != 'Funny'
    ).toList();
    
    // Check if we have meaningful feed counts (more than just empty/zero counts)
    final hasValidCounts = categoryCounts.values.any((count) => count > 0);
    
    if (hasValidCounts) {
      // Sort by feed counts (descending), then alphabetically
      remainingCategories.sort((a, b) {
        final countA = categoryCounts[a.name] ?? 0;
        final countB = categoryCounts[b.name] ?? 0;
        
        if (countA != countB) {
          return countB.compareTo(countA);
        }
        
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    } else {
      // Fallback: use the order from allCategories (already sorted by overall usage frequency)
      // The allCategories list is already ordered by usage statistics, so we just maintain that order
      // No additional sorting needed since remainingCategories preserves the allCategories order
    }
    
    // Add the sorted remaining categories
    orderedCategories.addAll(remainingCategories);
    
    return orderedCategories;
  }
} 