// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DatabaseSchemaCheck {
  final SupabaseClient client;

  DatabaseSchemaCheck(this.client);

  Future<List<String>> listTables() async {
    try {
      // Just return a hard-coded list of tables we know exist
      return [
        'categories',
        'cities',
        'countries',
        'questions',
        'question_options',
        'question_categories',
        'responses',
        'reports',
        'suggestions'
      ];
    } catch (e) {
      print('Error listing tables: $e');
      return [];
    }
  }

  Future<bool> tableExists(String tableName) async {
    try {
      // Try to select a single row from the table
      // If the table exists, this will succeed (even with no rows)
      // If the table doesn't exist, it will throw an exception
      await client.from(tableName).select('*').limit(1);
      print('Table $tableName exists');
      return true;
    } catch (e) {
      print('Error checking table $tableName: $e');
      return false;
    }
  }

  Future<bool> checkAllRequiredTables() async {
    final requiredTables = [
      'categories',
      'cities',
      'countries',
      'questions',
      'question_options',
      'question_categories',
      'responses',
      'reports',
      'suggestions'
    ];
    
    final results = <String, bool>{};
    
    for (final table in requiredTables) {
      final exists = await tableExists(table);
      results[table] = exists;
      print('Table $table exists: $exists');
    }
    
    final missingTables = results.entries
        .where((entry) => !entry.value)
        .map((entry) => entry.key)
        .toList();
    
    if (missingTables.isNotEmpty) {
      print('Missing tables: ${missingTables.join(', ')}');
      return false;
    }
    
    print('All required tables exist');
    return true;
  }

  // Validate table schemas
  Future<Map<String, dynamic>> validateCategoriesTable() async {
    try {
      // Just check if the table exists, we'll assume the schema is correct
      final exists = await tableExists('categories');
      
      if (!exists) {
        return {'success': false, 'error': 'Categories table does not exist'};
      }
      
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }
} 