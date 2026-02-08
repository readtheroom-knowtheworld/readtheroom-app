// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/analytics_service.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';

class GuideScreen extends StatefulWidget {
  const GuideScreen({Key? key}) : super(key: key);

  @override
  _GuideScreenState createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  DateTime? _screenOpenTime;

  @override
  void initState() {
    super.initState();
    _screenOpenTime = DateTime.now();
    
    // Check if user needs onboarding before showing guide
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkOnboardingStatus();
    });
    
    // Track guide screen opened
    AnalyticsService().trackGuideOpened('main_menu');
    Posthog().screen(screenName: 'Guide Screen');
  }

  void _checkOnboardingStatus() async {
    if (!mounted) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final onboardingCompleted = prefs.getBool('onboarding_completed') ?? false;
      
      // If onboarding has been completed, don't trigger it again
      if (onboardingCompleted) {
        return;
      }
      
      final locationService = Provider.of<LocationService>(context, listen: false);
      
      // Check if user is authenticated and has location set
      final isAuthenticated = Supabase.instance.client.auth.currentUser != null;
      final hasLocation = locationService.hasLocation;
      
      // Trigger onboarding if user is not authenticated OR doesn't have location
      if (!isAuthenticated || !hasLocation) {
        // Track that onboarding was triggered from guide
        AnalyticsService().trackEvent('onboarding_triggered_from_guide', {
          'is_authenticated': isAuthenticated,
          'has_location': hasLocation,
          'missing_auth': !isAuthenticated,
          'missing_location': !hasLocation,
          'trigger_reason': !isAuthenticated ? 'not_authenticated' : 'missing_location',
        });
        
        // Navigate to onboarding
        Navigator.pushReplacementNamed(
          context, 
          '/onboarding',
          arguments: 'guide_screen',
        );
      }
    } catch (e) {
      print('Error checking onboarding status: $e');
    }
  }

  @override
  void dispose() {
    if (_screenOpenTime != null) {
      final timeSpent = DateTime.now().difference(_screenOpenTime!);
      AnalyticsService().trackGuideClosed(timeSpent);
    }
    super.dispose();
  }

  Future<void> _launchURL(String url, {String? linkName}) async {
    try {
      // Track external link click
      AnalyticsService().trackEvent('guide_link_clicked', {
        'url': url,
        'link_name': linkName ?? url,
        'source': 'guide_screen',
      });
      
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Could not launch $url';
      }
    } catch (e) {
      print('Error launching URL: $e');
    }
  }

  Future<void> _launchAppStore() async {
    try {
      // Track app store review click
      AnalyticsService().trackEvent('guide_app_store_review_clicked', {
        'source': 'guide_screen',
      });

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

  @override
  Widget build(BuildContext context) {
    return Consumer2<UserService, LocationService>(
      builder: (context, userService, locationService, child) {
        final isAuthenticated = Supabase.instance.client.auth.currentUser != null;
        final hasLocation = locationService.hasLocation;
        final canSkip = isAuthenticated && hasLocation;
        
        return Scaffold(
          appBar: AppBar(
            title: Text('Guide'),
            centerTitle: false,
            actions: canSkip ? [
              TextButton(
                onPressed: () => _skipGuide(),
                child: Text(
                  'Skip',
                  style: TextStyle(
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ] : null,
          ),
      body: Builder(
        builder: (context) => GestureDetector(
          onHorizontalDragEnd: (details) {
            // Check if swipe is from left to right with sufficient velocity
            if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
              Scaffold.of(context).openDrawer();
            }
          },
          child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Welcome heading
              Text(
                'Welcome to Read the Room!',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).primaryColor,
                ),
              ),
              SizedBox(height: 16),
              
              // Onboarding tutorial link
              GestureDetector(
                onTap: () {
                  AnalyticsService().trackEvent('onboarding_tutorial_opened', {
                    'source': 'guide_screen',
                  });
                  Navigator.pushNamed(context, '/onboarding', arguments: 'guide_screen');
                },
                child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).primaryColor.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.school,
                        color: Theme.of(context).primaryColor,
                        size: 24,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Take the Tutorial',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                            Text(
                              'Learn how to use Read the Room with our interactive walkthrough (recommended)',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).primaryColor.withOpacity(0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        color: Theme.of(context).primaryColor,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 24),
              
              // Context and Rules Section
              _buildSection(
                context,
                icon: Icons.waving_hand,
                title: 'Context and Rules',
                children: [
                  Text(
                    'We are a privacy-first and community-driven social app.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Our goal is to provide space for everyone to ask and answer questions freely, to eventually become the world\'s first human bioindicator — Earth\'s vibe check.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 12),
                    Text(
                      'We create real-time maps of how people feel across cities, countries, and the whole world.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.4,
                      ),
                    ),
                  SizedBox(height: 12),
                  RichText(
                    text: TextSpan(
                      style: Theme.of(context).textTheme.bodyMedium,
                      children: [
                        TextSpan(text: 'While here, please follow our '),
                        WidgetSpan(
                          child: GestureDetector(
                            onTap: () => _launchURL('https://readtheroom.site/about/#community-guidelines', linkName: 'community_guidelines'),
                            child: Text(
                              'community guidelines',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        TextSpan(text: ' and '),
                        WidgetSpan(
                          child: GestureDetector(
                            onTap: () => _launchURL('https://readtheroom.site/terms/'),
                            child: Text(
                              'terms of service',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        TextSpan(text: '.'),
                      ],
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Please search for similar questions before posting, tag your questions appropriately, and help us moderate by reporting content violating the guidelines.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                    ),
                  ),
                ],
              ),

              SizedBox(height: 24),

              // Navigation Section
              _buildSection(
                context,
                icon: Icons.navigation,
                title: 'Basics',
                children: [
                  _buildNavigationItem(
                    context,
                    icon: Icons.today,
                    title: 'Question of the Day',
                    description: 'A popular question gets featured so we can all share our thoughts.',
                  ),
                  _buildNavigationItem(
                    context,
                    icon: Icons.create,
                    title: 'Posting Questions',
                    description: 'Choose your audience: Globe, Country, or City. Tag other countries with @countryname in the description.',
                  ),
                ],
              ),

              SizedBox(height: 24),

              // Category Toggles Section
              _buildSection(
                context,
                icon: Icons.tune,
                title: 'Customized Feeds',
                children: [
                  // Categories subsection
                  SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.category,
                        size: 20,
                        color: Theme.of(context).primaryColor,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Topic Filtering',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'You can tailor your feed by toggling different categories on or off — just tap the filter icon to choose the topics you want to see.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 12),
                  _buildCategoryState(
                    context,
                    icon: Icons.tune,
                    state: 'All topics enabled',
                    description: 'Filled icon with a colored background',
                    bgColor: Theme.of(context).primaryColor,
                    iconColor: Colors.white,
                  ),
                  SizedBox(height: 8),
                  _buildCategoryState(
                    context,
                    icon: Icons.tune,
                    state: 'Custom topic selection',
                    description: 'Only the topics you enable will be displayed in the feed.',
                    bgColor: Theme.of(context).primaryColor.withOpacity(0.1),
                    iconColor: Theme.of(context).primaryColor,
                  ),
                  SizedBox(height: 8),
                  _buildCategoryState(
                    context,
                    icon: Icons.tune,
                    state: 'Exploring a single topic',
                    description: 'The topic being explored will be shown in place of the question of the day, the filter can be swiped away to exit back into your normal feed.',
                    bgColor: Colors.grey.withOpacity(0.1),
                    iconColor: Colors.grey,
                  ),
                  
                  SizedBox(height: 24),
                  
                  Row(
                    children: [
                      Icon(
                        Icons.quiz,
                        size: 20,
                        color: Theme.of(context).primaryColor,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Question Types',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Not a fan of effort and nuance in text-response questions? No worries, just filter them out!', 
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                    ),
                  ),
                  
                ],
              ),

              SizedBox(height: 24),

              // Feedback Section
              _buildSection(
                context,
                icon: Icons.feedback,
                title: 'Feedback?',
                children: [
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.menu, size: 16, color: Colors.grey[600]),
                      SizedBox(width: 4),
                      Text(
                        'Sidebar → Feedback.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Here, you can:',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 8),
                  _buildBulletPoint('Submit suggestions for app improvements'),
                  _buildBulletPoint('Vote and comment on suggestions'),
                  _buildBulletPoint('Connect with our development team'),
                  SizedBox(height: 8),
                  Text(
                    'Help us shape the future of Read the Room.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),

              SizedBox(height: 24),

              // Widgets Section
              _buildSection(
                context,
                icon: Icons.widgets_outlined,
                title: 'Home Screen Widgets',
                children: [
                  Text(
                    'Widgets let you engage with Read the Room passively, right from your home screen or lock screen — no notifications needed. They provide a simple way to check in whenever the mood strikes.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Setting up a widget is the best way for you to support the nonprofit platform, after leaving a nice app store review!',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: () => _launchURL('https://readtheroom.site/widgets/', linkName: 'widgets_guide'),
                      icon: Icon(Icons.open_in_new, size: 18),
                      label: Text('Learn how to set up widgets'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).primaryColor,
                        side: BorderSide(color: Theme.of(context).primaryColor),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              SizedBox(height: 24),

              // Social Media Section
              _buildSection(
                context,
                icon: Icons.share,
                title: 'Connect',
                children: [
                  Center(
                    child: Text(
                      'Support us? Toss a follow <3',
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

              SizedBox(height: 32),

              // Footer
              Center(
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/Curio_smiling_trans.png',
                      width: 100,
                      height: 100,
                    ),
                    SizedBox(height: 8),
                    GestureDetector(
                      onTap: () {
                        Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
                      },
                      child: Text(
                        'Ask away!',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.w600,
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
      ),
        );
      },
    );
  }

  Widget _buildSection(BuildContext context, {required IconData icon, required String title, required List<Widget> children}) {
    return Container(
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
                icon,
                color: Theme.of(context).primaryColor,
                size: 24,
              ),
              SizedBox(width: 12),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildNavigationItem(BuildContext context, {required IconData icon, required String title, required String description}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: Theme.of(context).primaryColor,
            size: 18,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 4),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryState(BuildContext context, {required IconData icon, required String state, required String description, required Color bgColor, required Color iconColor}) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: bgColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: iconColor.withOpacity(0.3),
            ),
          ),
          child: Icon(
            icon,
            color: iconColor,
            size: 14,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBulletPoint(String text) {
    return Padding(
      padding: EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSocialIcon(BuildContext context, {required IconData icon, required String url, required Color color}) {
    return GestureDetector(
      onTap: () => _launchURL(url),
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

  Widget _buildSocialLink(BuildContext context, {required IconData icon, required String platform, required String handle, required String url, required Color color}) {
    return GestureDetector(
      onTap: () => _launchURL(url),
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: color.withOpacity(0.3),
          ),
          borderRadius: BorderRadius.circular(8),
          color: color.withOpacity(0.05),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: color,
                size: 18,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    platform,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    handle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.open_in_new,
              size: 16,
              color: Colors.grey[600],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeographicScope(BuildContext context, {required IconData icon, required String title, required String description, required Color color}) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
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
            size: 12,
          ),
        ),
        SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _skipGuide() async {
    try {
      // Mark guide as completed (same logic as onboarding completion)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('guide_completed', true);
      await prefs.setString('guide_completed_at', DateTime.now().toIso8601String());
      
      // Track guide skip event
      AnalyticsService().trackEvent('guide_skipped', {
        'source': 'guide_screen',
        'time_spent_seconds': _screenOpenTime != null 
            ? DateTime.now().difference(_screenOpenTime!).inSeconds 
            : 0,
      });
      
      // Navigate to main feed (home screen)
      Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
    } catch (e) {
      print('Error skipping guide: $e');
    }
  }
}
