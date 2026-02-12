// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../services/congratulations_service.dart';

class CongratulationsCurioScreen extends StatefulWidget {
  final AchievementType achievementType;
  final CongratulationsService congratulationsService;

  const CongratulationsCurioScreen({
    Key? key,
    required this.achievementType,
    required this.congratulationsService,
  }) : super(key: key);

  @override
  _CongratulationsCurioScreenState createState() => _CongratulationsCurioScreenState();

  static Future<void> show(
    BuildContext context,
    AchievementType achievementType,
    CongratulationsService congratulationsService,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CongratulationsCurioScreen(
          achievementType: achievementType,
          congratulationsService: congratulationsService,
        ),
        fullscreenDialog: true,
      ),
    );
  }
}

class _CongratulationsCurioScreenState extends State<CongratulationsCurioScreen> {
  bool _isLaunchingAppStore = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                // Close button at top right
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                    ),
                  ),
                ),

                const SizedBox(height: 20), // Add some top spacing
                
                // Curio Image
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.8, end: 1.0),
                  duration: const Duration(milliseconds: 800),
                  builder: (context, scale, child) {
                    return Transform.scale(
                      scale: scale,
                      child: Image.asset(
                        Theme.of(context).brightness == Brightness.dark
                            ? 'assets/images/Curio_smiling_trans.png'
                            : 'assets/images/Curio_smiling.jpeg',
                        height: 200,
                        width: 200,
                      ),
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Achievement Title
                Text(
                  widget.congratulationsService.getAchievementTitle(widget.achievementType),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 16),

                // Achievement Message
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text(
                    widget.congratulationsService.getAchievementMessage(widget.achievementType),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 32),

                // App Store Review Button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _isLaunchingAppStore ? null : _launchAppStore,
                    icon: _isLaunchingAppStore 
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Icon(Icons.star_rate),
                    label: Text(_isLaunchingAppStore ? 'Opening App Store...' : 'Please rate us on the app store <3'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // "Psst!" text - outside the Connect border
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

                const SizedBox(height: 24),

                // Social Media Section - Connect (with border like guide screen)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Section header with icon and title
                      Row(
                        children: [
                          Icon(
                            Icons.share,
                            size: 20,
                            color: Theme.of(context).primaryColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Connect',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Social media content
                      Center(
                        child: Text(
                          'Support us? Toss a follow <3',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            height: 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
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
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // "Not now..." button at bottom
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Not now...',
                      style: TextStyle(
                        color: Theme.of(context).primaryColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24), // Bottom padding for scroll
              ],
            ),
          ),
        ),
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
          color: color.withValues(alpha: 0.1),
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: 0.3),
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

  Future<void> _launchURL(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Could not launch $url';
      }
    } catch (e) {
      print('Error launching social media URL: $e');
    }
  }

  Future<void> _launchAppStore() async {
    if (_isLaunchingAppStore) return;
    
    setState(() {
      _isLaunchingAppStore = true;
    });

    try {
      final url = widget.congratulationsService.getAppStoreUrl();
      
      // Mark that user clicked the app store review link
      await widget.congratulationsService.markAppStoreReviewClicked();
      
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // Log error for debugging - consider user-facing error handling
      print('Error launching app store URL: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLaunchingAppStore = false;
        });
      }
    }
  }

}
