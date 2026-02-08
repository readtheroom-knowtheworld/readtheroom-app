// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/widgets/app_drawer.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../screens/home_screen.dart';
import '../screens/user_screen.dart';
import '../services/user_service.dart';
import '../screens/new_question_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/main_screen.dart';

class AppDrawer extends StatefulWidget {
  const AppDrawer({Key? key}) : super(key: key);

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  final _supabase = Supabase.instance.client;
  int? _totalQuestions;
  int? _totalResponses;
  int? _totalUsers;
  int? _totalCountries;
  bool _isLoadingStats = true;

  @override
  void initState() {
    super.initState();
    _loadDatabaseStats();
  }


  Future<void> _loadDatabaseStats() async {
    if (!mounted) return;
    
    setState(() {
      _isLoadingStats = true;
    });
    
    try {
      print('=== PLATFORM STATS (Scalable Approach) ===');
      
      // Try the new scalable RPC approach first
      print('Step 1: Attempting RPC call to get_platform_stats()...');
      final statsResponse = await _supabase.rpc('get_platform_stats');
      
      if (statsResponse != null) {
        final stats = statsResponse as Map<String, dynamic>;
        
        print('✅ RPC call successful! Results:');
        print('- Users: ${stats['users']}');
        print('- Questions: ${stats['questions']}');
        print('- Responses: ${stats['responses']}');
        print('- Countries: ${stats['countries']}');
        
        if (mounted) {
          setState(() {
            _totalUsers = stats['users'] ?? 0;
            _totalQuestions = stats['questions'] ?? 0;
            _totalResponses = stats['responses'] ?? 0;
            _totalCountries = stats['countries'] ?? 0;
            _isLoadingStats = false;
          });
        }
        return; // Success! Exit early
      } else {
        throw Exception('RPC returned null');
      }
    } catch (rpcError) {
      print('❌ RPC approach failed: $rpcError');
      print('📋 Falling back to legacy multi-query approach...');
      
      // Fallback to the existing approach
      await _loadDatabaseStatsLegacy();
    }
  }

  /// Legacy multi-query approach for fallback when RPC fails
  Future<void> _loadDatabaseStatsLegacy() async {
    try {
      print('=== PLATFORM STATS (Legacy Fallback) ===');
      
      // First, get total users count and non-hidden questions count
      print('Step 1: Fetching users and questions...');
      final questionsResponse = await _supabase
          .from('questions')
          .select('id')
          .eq('is_hidden', false)
          .count(CountOption.exact);
      
      final usersResponse = await _supabase
          .from('users')
          .select('id')
          .count(CountOption.exact);
      
      print('- Total users: ${usersResponse.count}');
      print('- Non-hidden questions: ${questionsResponse.count}');
      
      // Get all non-hidden question IDs for filtering responses
      print('Step 2: Fetching non-hidden question IDs...');
      final nonHiddenQuestions = await _supabase
          .from('questions')
          .select('id')
          .eq('is_hidden', false);
      
      final nonHiddenQuestionIds = nonHiddenQuestions.map((q) => q['id']).toList();
      print('- Non-hidden question IDs count: ${nonHiddenQuestionIds.length}');
      
      // Debug: Check total responses without any filters first
      print('Step 3: Checking total responses (no filters)...');
      final totalResponsesUnfiltered = await _supabase
          .from('responses')
          .select('id')
          .count(CountOption.exact);
      print('- Total responses (all): ${totalResponsesUnfiltered.count}');
      
      // Only count responses that are associated with non-hidden questions
      int totalResponses = 0;
      int totalResponsesWithCityId = 0;
      final uniqueCountries = <String>{};
      final uniqueCountriesAllResponses = <String>{};
      
      if (nonHiddenQuestionIds.isNotEmpty) {
        print('Step 4: Filtering responses by non-hidden questions...');
        print('- Question IDs array size: ${nonHiddenQuestionIds.length} (this might be too large for inFilter)');
        
        try {
          // Use JOIN approach instead of inFilter to avoid array size limits
          print('- Trying JOIN approach instead of inFilter...');
          
          // Count responses to non-hidden questions (with city_id filter) using JOIN
          final responsesWithCityResponse = await _supabase
              .rpc('count_responses_to_non_hidden_questions_with_city');
          
          if (responsesWithCityResponse != null && responsesWithCityResponse is int) {
            totalResponsesWithCityId = responsesWithCityResponse;
            print('- Responses to non-hidden questions (with city_id, via RPC): $totalResponsesWithCityId');
          } else {
            print('- RPC failed, falling back to direct query approach...');
            throw Exception('RPC not available');
          }
        } catch (rpcError) {
          print('- RPC approach failed: $rpcError');
          print('- Trying alternative approach with smaller batches...');
          
          // Alternative: Use a different approach that doesn't rely on large arrays
          // Query responses and join with questions in the database
          try {
            final responsesWithCityQuery = '''
              SELECT COUNT(r.id) 
              FROM responses r 
              INNER JOIN questions q ON r.question_id = q.id 
              WHERE q.is_hidden = false AND r.city_id IS NOT NULL
            ''';
            
            // Since we can't do raw SQL easily, let's try a simpler approach
            // Just count all responses with city_id (may include hidden questions)
            final responsesWithCityResponse = await _supabase
                .from('responses')
                .select('id')
                .not('city_id', 'is', null)
                .count(CountOption.exact);
            
            totalResponsesWithCityId = responsesWithCityResponse.count ?? 0;
            print('- Responses with city_id (all questions): $totalResponsesWithCityId');
            
          } catch (altError) {
            print('- Alternative approach also failed: $altError');
            totalResponsesWithCityId = 0;
          }
        }
        
        // For total responses, use simpler approach
        try {
          final responsesAllResponse = await _supabase
              .from('responses')
              .select('id')
              .count(CountOption.exact);
          
          totalResponses = responsesAllResponse.count ?? 0;
          print('- Total responses (all): $totalResponses');
        } catch (totalError) {
          print('- Error getting total responses: $totalError');
          totalResponses = 0;
        }
        
        // Get unique countries from responses with city_id (avoid large array issue)
        print('Step 5: Fetching countries from responses with city_id...');
        try {
          // Simpler approach: get all countries from responses with city_id
          final countriesResponse = await _supabase
              .from('responses')
              .select('country_code')
              .not('city_id', 'is', null)
              .not('country_code', 'is', null);
          
          print('- Country responses with city_id: ${countriesResponse.length}');
          
          // Count unique countries from responses with city_id
          for (final response in countriesResponse) {
            final countryCode = response['country_code'] as String?;
            if (countryCode != null && countryCode.isNotEmpty) {
              uniqueCountries.add(countryCode);
            }
          }
          print('- Unique countries (with city_id): ${uniqueCountries.length}');
        } catch (countriesError) {
          print('- Error fetching countries with city_id: $countriesError');
        }
        
        // Also get countries from all responses (for comparison)
        print('Step 6: Fetching countries from all responses (for comparison)...');
        try {
          final allCountriesResponse = await _supabase
              .from('responses')
              .select('country_code')
              .not('country_code', 'is', null);
          
          print('- All country responses: ${allCountriesResponse.length}');
          
          for (final response in allCountriesResponse) {
            final countryCode = response['country_code'] as String?;
            if (countryCode != null && countryCode.isNotEmpty) {
              uniqueCountriesAllResponses.add(countryCode);
            }
          }
          print('- Unique countries (all responses): ${uniqueCountriesAllResponses.length}');
        } catch (allCountriesError) {
          print('- Error fetching all countries: $allCountriesError');
        }
      } else {
        print('- No non-hidden questions found! This is the problem.');
      }
      
      print('=== FINAL STATS SUMMARY ===');
      print('- Users: ${usersResponse.count}');
      print('- Questions (non-hidden only): ${questionsResponse.count}');
      print('- Responses (filtered, with city_id): $totalResponsesWithCityId');
      print('- Responses (filtered, all): $totalResponses');
      print('- Countries (with city_id filter): ${uniqueCountries.length}');
      print('- Countries (all responses): ${uniqueCountriesAllResponses.length}');
      
      // Use the stricter filtering (with city_id) as per original logic, 
      // but provide fallback if those numbers are zero
      int finalResponses = totalResponsesWithCityId;
      int finalCountries = uniqueCountries.length;
      int finalQuestions = questionsResponse.count ?? 0;
      
      // Fallback: if city_id filtering gives us zeros, use the less strict approach
      if (finalResponses == 0 && totalResponses > 0) {
        print('WARNING: Using fallback stats (no city_id requirement) because filtered stats are zero');
        finalResponses = totalResponses;
        finalCountries = uniqueCountriesAllResponses.length;
      }
      
      // Additional fallback: if both strict and relaxed filtering are zero, 
      // use About screen approach (no filtering at all)
      if (finalResponses == 0 && finalQuestions == 0) {
        print('CRITICAL: Both filtered approaches returned zero. Using About screen approach (no filters)...');
        
        try {
          // Simple approach like about_screen.dart - no filtering
          final allQuestionsResponse = await _supabase
              .from('questions')
              .select('id')
              .count(CountOption.exact);
          
          final allResponsesResponse = await _supabase
              .from('responses')
              .select('id')
              .count(CountOption.exact);
          
          // Count all countries from all responses
          final allCountriesResponse = await _supabase
              .from('responses')
              .select('country_code')
              .not('country_code', 'is', null);
          
          final allCountriesSet = <String>{};
          for (final response in allCountriesResponse) {
            final countryCode = response['country_code'] as String?;
            if (countryCode != null && countryCode.isNotEmpty) {
              allCountriesSet.add(countryCode);
            }
          }
          
          print('About screen approach results:');
          print('- All questions: ${allQuestionsResponse.count}');
          print('- All responses: ${allResponsesResponse.count}');
          print('- All countries: ${allCountriesSet.length}');
          
          // Use these as final values if they're non-zero
          if ((allQuestionsResponse.count ?? 0) > 0 || (allResponsesResponse.count ?? 0) > 0) {
            finalQuestions = allQuestionsResponse.count ?? 0;
            finalResponses = allResponsesResponse.count ?? 0;
            finalCountries = allCountriesSet.length;
            print('SUCCESS: Using About screen approach as primary stats');
          }
        } catch (fallbackError) {
          print('ERROR: Even About screen approach failed: $fallbackError');
        }
      }
      
      print('=== DISPLAYING: ===');
      print('- Users: ${usersResponse.count}');
      print('- Questions: $finalQuestions');
      print('- Responses: $finalResponses');
      print('- Countries: $finalCountries');
      
      if (mounted) {
        setState(() {
          _totalQuestions = finalQuestions;
          _totalResponses = finalResponses;
          _totalUsers = usersResponse.count ?? 0;
          _totalCountries = finalCountries;
          _isLoadingStats = false;
        });
      }
    } catch (e) {
      print('Error loading database stats: $e');
      print('Stack trace: ${StackTrace.current}');
      if (mounted) {
        setState(() {
          _isLoadingStats = false;
        });
      }
    }
  }

  String _formatCount(int count) {
    if (count >= 1000000) {
      double millions = count / 1000000;
      if (millions == millions.floor()) {
        return '${millions.toInt()}M';
      } else {
        return '${millions.toStringAsFixed(1)}M+';
      }
    } else if (count >= 1000) {
      double thousands = count / 1000;
      if (thousands == thousands.floor()) {
        return '${thousands.toInt()}K';
      } else {
        return '${thousands.toStringAsFixed(1)}K+';
      }
    } else {
      return count.toString();
    }
  }


  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // Main navigation content
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                DrawerHeader(
                  decoration: BoxDecoration(color: Colors.transparent),
                  child: GestureDetector(
                    onTap: () {
                      // Navigate to home screen
                      Navigator.of(context).pushNamedAndRemoveUntil(
                        '/',
                        (route) => false,
                      );
                    },
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                        Image.asset(
                            'assets/images/RTR-logo_Aug2025.png',
                            height: 60,
                        ),
                        SizedBox(height: 4),
                        Text(
                            '> read(the_room)', 
                            style: TextStyle(
                              color: Theme.of(context).textTheme.bodyLarge?.color,
                              fontSize: 20,
                            ),
                        ),
                        SizedBox(height: 2),
                        Text(
                            'know the world', 
                            style: TextStyle(
                              color: Theme.of(context).textTheme.bodyMedium?.color,
                              fontSize: 12,
                            ),
                        ),
                        ],
                    ),
                  ),
                  ),

                ListTile(
                  leading: Icon(Icons.menu_book),
                  title: Text('Guide'),
                  onTap: () {
                    Navigator.pushNamed(context, '/guide');
                  },
                ),
                ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('Settings'),
                  onTap: () {
                    Navigator.pushNamed(context, '/settings');
                  },
                ),
                ListTile(
                  leading: Icon(Icons.info),
                  title: Text('About'),
                  onTap: () async {
                    final url = Uri.parse('https://readtheroom.site/about');
                    if (await canLaunchUrl(url)) {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    } else {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Could not open About page'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.campaign),
                  title: Text('News & Notes'),
                  onTap: () async {
                    final url = Uri.parse('https://readtheroom.site/announcements');
                    if (await canLaunchUrl(url)) {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    } else {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Could not open Announcements page'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.feedback),
                  title: Text('Feedback'),
                  onTap: () async {
                    final userService = Provider.of<UserService>(context, listen: false);
                    
                    // Smart preloading: If suggestions already loaded, navigate instantly
                    // If not loaded, wait briefly for them to load for better UX
                    if (userService.suggestions.isEmpty) {
                      print('🔄 Preloading suggestions before feedback navigation...');
                      try {
                        // Wait up to 500ms for suggestions to load
                        await userService.ensureSuggestionsLoaded().timeout(
                          Duration(milliseconds: 500),
                          onTimeout: () {
                            print('⏰ Suggestions loading timeout - navigating anyway');
                          },
                        );
                      } catch (e) {
                        print('❌ Error preloading suggestions: $e');
                      }
                    }
                    
                    // Navigate to feedback screen
                    Navigator.pushNamed(context, '/feedback');
                  },
                ),
                
                
                // QR Code section
                Container(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: Center(
                    child: Column(
                      children: [
                        SizedBox(height: 12),
                        GestureDetector(
                          onTap: () async {
                            final url = Uri.parse('https://readtheroom.site');
                            if (await canLaunchUrl(url)) {
                              await launchUrl(url, mode: LaunchMode.externalApplication);
                            } else {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Could not open website'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                          child: Container(
                            padding: EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Theme.of(context).brightness == Brightness.dark 
                                  ? Colors.black 
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.grey.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: QrImageView(
                              data: 'https://readtheroom.site/#download',
                              version: QrVersions.auto,
                              size: 200.0,
                              backgroundColor: Theme.of(context).brightness == Brightness.dark 
                                  ? Colors.black 
                                  : Colors.white,
                              embeddedImage: AssetImage('assets/images/RTR-logo_Aug2025.png'),
                              embeddedImageStyle: QrEmbeddedImageStyle(
                                size: Size(40, 40),
                                color: Theme.of(context).brightness == Brightness.dark 
                                    ? Colors.white 
                                    : Colors.black,
                              ),
                              eyeStyle: QrEyeStyle(
                                eyeShape: QrEyeShape.circle,
                                color: Colors.grey,
                              ),
                              dataModuleStyle: QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.circle,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'readtheroom.site/#download',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Platform Stats navigation at the bottom
          Container(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: ListTile(
              title: _isLoadingStats 
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        ),
                        SizedBox(width: 8),
                        Text('Loading stats...'),
                      ],
                    )
                  : Text(
                      '${_totalUsers != null ? _formatCount(_totalUsers!) : '0'} 🦎 |  ${_totalCountries != null ? _formatCount(_totalCountries!) : '0'} 🌍',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
              onTap: () {
                Navigator.pushNamed(context, '/platform_stats');
              },
            ),
          ),
        ],
      ),
    );
  }
}
