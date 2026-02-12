// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/analytics_service.dart';
import '../utils/generation_utils.dart';

/// Bump this constant to trigger a new "What's New?" dialog for a release.
const String whatsNewVersion = '1.2.0-generations';

class WhatsNewDialog extends StatefulWidget {
  const WhatsNewDialog({Key? key}) : super(key: key);

  /// Show the dialog unconditionally (e.g. from settings screen).
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const WhatsNewDialog(),
    );
  }

  /// Check SharedPreferences and show the dialog if this version hasn't been seen.
  static Future<void> checkAndShow(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenVersion = prefs.getString('whats_new_seen_version');

      if (seenVersion == whatsNewVersion) return;

      if (!context.mounted) return;

      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const WhatsNewDialog(),
      );
    } catch (e) {
      print('WhatsNewDialog: Error checking version: $e');
    }
  }

  @override
  State<WhatsNewDialog> createState() => _WhatsNewDialogState();
}

class _WhatsNewDialogState extends State<WhatsNewDialog> with SingleTickerProviderStateMixin {
  String? _selectedGeneration;
  bool _showSelectionHint = false;
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 2718),
    );
    _shimmerAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );
    // Load existing generation if set
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userService = Provider.of<UserService>(context, listen: false);
      if (userService.hasGeneration) {
        setState(() {
          _selectedGeneration = userService.generation;
        });
      }
    });
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  void _triggerShimmer() {
    _shimmerController.reset();
    _shimmerController.forward();
  }

  Future<void> _dismiss(BuildContext context) async {
    // Save generation if selected
    if (_selectedGeneration != null) {
      final userService = Provider.of<UserService>(context, listen: false);
      await userService.setGeneration(_selectedGeneration);
      AnalyticsService().trackEvent('generation_selected', {
        'generation': _selectedGeneration,
        'source': 'whats_new',
      });
    }

    if (context.mounted) {
      Navigator.of(context).pop();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('whats_new_seen_version', whatsNewVersion);
    } catch (e) {
      print('WhatsNewDialog: Error saving seen version: $e');
    }
  }

  Future<void> _launchAppStore() async {
    final url = Platform.isIOS
        ? 'https://apps.apple.com/us/app/read-the-room-know-the-world/id6747105473'
        : 'https://play.google.com/store/apps/details?id=com.readtheroom.app';
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      print('WhatsNewDialog: Error launching app store: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _selectedGeneration != null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectedGeneration == null) {
          setState(() {
            _showSelectionHint = true;
          });
          _triggerShimmer();
        }
      },
      child: AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.auto_awesome,
            color: Theme.of(context).primaryColor,
            size: 28,
          ),
          SizedBox(width: 12),
          Text("What's New?"),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Generation Comparison',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).primaryColor,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Select your generation to see how different generations answer!',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.4,
              ),
            ),
            SizedBox(height: 12),
            AnimatedBuilder(
              animation: _shimmerAnimation,
              builder: (context, child) {
                final shimmerActive = _shimmerController.isAnimating;
                final shimmerValue = _shimmerAnimation.value;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(generations.length, (index) {
                    final gen = generations[index];
                    final isSelected = _selectedGeneration == gen.id;
                    // Each chip lights up as the shimmer passes over its position
                    final chipPosition = index / generations.length;
                    final distance = (shimmerValue - chipPosition).abs();
                    final glow = shimmerActive && distance < 0.4
                        ? ((0.4 - distance) / 0.4).clamp(0.0, 1.0)
                        : 0.0;
                    return Container(
                      decoration: glow > 0
                          ? BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0xFF00BFA5).withOpacity(glow * 0.6),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ],
                            )
                          : null,
                      child: ChoiceChip(
                        label: Text(gen.label),
                        selected: isSelected,
                        showCheckmark: false,
                        onSelected: (selected) {
                          setState(() {
                            _selectedGeneration = selected ? gen.id : null;
                          });
                        },
                        selectedColor: Theme.of(context).primaryColor,
                        backgroundColor: glow > 0
                            ? Color.lerp(
                                Theme.of(context).chipTheme.backgroundColor,
                                Color(0xFF00BFA5).withOpacity(0.15),
                                glow,
                              )
                            : null,
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : null,
                          fontSize: 13,
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
            SizedBox(height: 16),
            Text(
              'Question Ratings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).primaryColor,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Rate questions after viewing results to help surface the best content.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.4,
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Open Source',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).primaryColor,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Read the Room is now open source! Check out the code and contribute on GitHub.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.4,
              ),
            ),
            SizedBox(height: 16),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                  color: Colors.grey[600],
                ),
                children: [
                  TextSpan(text: 'Enjoying RTR? Leave an '),
                  TextSpan(
                    text: 'app store review',
                    style: TextStyle(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    recognizer: TapGestureRecognizer()..onTap = _launchAppStore,
                  ),
                  TextSpan(text: ' <3'),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_showSelectionHint && _selectedGeneration == null)
          Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text(
              'Please select a generation above',
              style: TextStyle(
                color: Colors.orange,
                fontSize: 12,
              ),
            ),
          ),
        ElevatedButton(
          onPressed: _selectedGeneration != null
              ? () => _dismiss(context)
              : () {
                  setState(() {
                    _showSelectionHint = true;
                  });
                  _triggerShimmer();
                },
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF00BFA5),
            foregroundColor: Colors.white,
          ),
          child: Text('Got it'),
        ),
      ],
      ),
    );
  }
}
