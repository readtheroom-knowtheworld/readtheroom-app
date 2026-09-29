// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/screens/platform_stats_screen.dart
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class PlatformStatsScreen extends StatefulWidget {
  const PlatformStatsScreen({Key? key}) : super(key: key);

  @override
  State<PlatformStatsScreen> createState() => _PlatformStatsScreenState();
}

class _PlatformStatsScreenState extends State<PlatformStatsScreen> {
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

  Widget _buildStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
    VoidCallback? onTap,
  }) {
    Widget cardContent = Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark 
              ? Colors.white.withOpacity(0.3)
              : Colors.grey.withOpacity(0.3),
          width: 1.0,
        ),
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: color,
              size: 24,
            ),
          ),
          SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 6),
          _isLoadingStats
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                )
              : Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    value,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
        ],
      ),
    );

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        child: cardContent,
      );
    }
    
    return cardContent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Platform Stats'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _loadDatabaseStats,
        child: SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Read the Room Statistics',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'The goal is to have representation from all ~200 countries.\n\nHelp us get there by inviting your friends and family from around the world!',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              SizedBox(height: 32),
              
              // Stats Grid
              GridView.count(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.95,
                children: [
                  _buildStatCard(
                    icon: Icons.person,
                    title: 'Users 🦎',
                    value: _totalUsers != null ? _formatCount(_totalUsers!) : '0',
                    color: Theme.of(context).primaryColor, // Primary color
                  ),
                  _buildStatCard(
                    icon: Icons.public,
                    title: 'Countries 🌍',
                    value: _totalCountries != null ? _formatCount(_totalCountries!) : '0',
                    color: Color(0xff55c5b4), // Teal,
                    onTap: () async {
                      final url = Uri.parse('https://readtheroom.site/maps');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url, mode: LaunchMode.externalApplication);
                      } else {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Could not open maps page'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                  ),
                  _buildStatCard(
                    icon: Icons.quiz,
                    title: 'Questions',
                    value: _totalQuestions != null ? _formatCount(_totalQuestions!) : '0',
                    color: Color(0xffff9847), // Orange
                  ),
                  _buildStatCard(
                    icon: Icons.people,
                    title: 'Responses',
                    value: _totalResponses != null ? _formatCount(_totalResponses!) : '0',
                    color: Colors.red, // Red
                  ),
                ],
              ),
              
              SizedBox(height: 32),
              
              // Additional Info
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark 
                      ? Colors.grey[800]
                      : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 20,
                          color: Colors.grey[600],
                        ),
                        SizedBox(width: 8),
                        Text(
                          'About These Stats',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),
                    Text(
                      'These statistics are updated in real-time and represent the global Read the Room community that is actively posting or answering questions. ',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              
              SizedBox(height: 32),
              
              // Social Media Section
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).dividerColor.withOpacity(0.3),
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.share,
                          color: Theme.of(context).primaryColor,
                          size: 24,
                        ),
                        SizedBox(width: 12),
                        Text(
                          'Connect',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    Center(
                      child: Text(
                        'Support the project? Toss a follow!',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildSocialIcon(
                          context,
                          icon: FontAwesomeIcons.instagram,
                          url: 'https://instagram.com/readtheroom.site',
                          color: Color(0xFFE4405F),
                        ),
                        _buildSocialIcon(
                          context,
                          icon: FontAwesomeIcons.bluesky,
                          url: 'https://bsky.app/profile/read-theroom.bsky.social',
                          color: Color(0xFF0085ff),
                        ),
                        _buildSocialIcon(
                          context,
                          icon: FontAwesomeIcons.linkedin,
                          url: 'https://www.linkedin.com/company/read-the-room-know-the-world',
                          color: Color(0xFF0077B5),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: () => _launchAppStore(),
                        icon: Icon(Icons.star_rate),
                        label: Text('Leave a review?'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    Center(
                      child: RichText(
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).brightness == Brightness.dark 
                                ? Colors.white 
                                : Colors.black,
                          ),
                          children: [
                            TextSpan(text: 'Psst! Positive app store reviews really help us out '),
                            WidgetSpan(
                              child: Icon(
                                Icons.favorite,
                                size: 14,
                                color: Theme.of(context).brightness == Brightness.dark 
                                    ? Colors.white 
                                    : Colors.black,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _launchAppStore() async {
    try {
      final url = Platform.isIOS
          ? 'https://apps.apple.com/us/app/read-the-room-know-the-world/id6747105473'
          : 'https://play.google.com/store/apps/details?id=com.readtheroom.app';

      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Could not launch $url';
      }
    } catch (e) {
      print('Error launching App Store: $e');
    }
  }

  Widget _buildSocialIcon(BuildContext context, {required IconData icon, required String url, required Color color}) {
    return GestureDetector(
      onTap: () async {
        final Uri uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not open link'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withOpacity(0.3),
          ),
        ),
        child: Icon(
          icon,
          color: color,
          size: 20,
        ),
      ),
    );
  }
}
