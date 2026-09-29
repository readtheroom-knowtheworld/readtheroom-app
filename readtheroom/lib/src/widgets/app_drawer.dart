// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/widgets/app_drawer.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../screens/home_screen.dart';
import '../screens/user_screen.dart';
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

  /// Fallback when get_platform_stats() is unavailable.
  ///
  /// It used to count `responses` from the client — seven queries, two of them
  /// pulling every row's country_code just to count distinct countries. Since
  /// the answers read lockdown (2026-09-22) the table is write-only for
  /// clients, and a platform total is exactly the kind of number a server-side
  /// function should compute anyway. There is nothing left to fall back TO, so
  /// the screen simply shows no stats and says so in the log.
  Future<void> _loadDatabaseStatsLegacy() async {
    print('=== PLATFORM STATS unavailable: get_platform_stats() did not answer ===');
    print('There is no client-side fallback: `responses` is write-only for '
        'clients since the answers read lockdown. Check the RPC.');
    if (mounted) {
      setState(() {
        _isLoadingStats = false;
      });
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


  /// The mission line's style. A tagline, not a footnote: title-sized, muted
  /// grey. Upright (italics hurt legibility over several lines) and medium
  /// weight (semi-bold is heavy for a full sentence).
  TextStyle? _missionStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
            height: 1.4,
          );

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // Main navigation content
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate([
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
                  leading: Icon(Icons.rocket_launch_outlined),
                  title: Text('Join the beta'),
                  onTap: () {
                    Navigator.pushNamed(context, '/join_beta');
                  },
                ),
                  ]),
                ),
                // Mission line, centred in the space between the last tile
                // and the stats footer (owner, 2026-09-28). Scrolls with the
                // list on short screens instead of overlapping it.
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 16),
                      // One sentence per line. Two Text widgets rather than a
                      // "\n" in the copy: each line wraps and centres on its
                      // own, the gap belongs to the layout, and MergeSemantics
                      // keeps it one announcement for screen readers.
                      child: MergeSemantics(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Read the Room is a community-driven project.',
                              textAlign: TextAlign.center,
                              style: _missionStyle(context),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'We are making the world smaller, one question '
                              'at a time.',
                              textAlign: TextAlign.center,
                              style: _missionStyle(context),
                            ),
                          ],
                        ),
                      ),
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
