// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../services/analytics_service.dart';
import '../utils/beta_links.dart';
import '../widgets/email_signup_card.dart';

/// "Join the beta" — the drawer's old Feedback screen, reframed.
///
/// Same page from two doors: the app drawer replaced its **Feedback** entry
/// with this, and the Community tab's footer links here under the shared email
/// card. Both doors land on one screen so there is a single place that explains
/// what being a tester gets you.
///
/// Top → bottom: the pitch, the shared [EmailSignupCard], the per-platform
/// enrolment buttons, then **Send feedback** — a private bug-report email and
/// the socials.
///
/// Public suggestions were removed (see
/// `feature-documentation/remove-public-suggestions-2026-09-17.md`): the
/// submission form, the voted list and the suggestion detail screen are gone,
/// and feedback now reaches us by email. `feedback_screen.dart` is gone;
/// `/feedback` still resolves here for anything holding the old route name,
/// and a stale `readtheroom://suggestion/{id}` link lands here too.
///
/// A platform button whose URL is empty is hidden — see `utils/beta_links.dart`.
class JoinBetaScreen extends StatefulWidget {
  const JoinBetaScreen({Key? key, this.source = 'drawer'}) : super(key: key);

  /// Which door the user came through: `drawer` | `community` | `deep_link`.
  /// Reported once per view as `join_beta_viewed`.
  final String source;

  @override
  State<JoinBetaScreen> createState() => _JoinBetaScreenState();
}

class _JoinBetaScreenState extends State<JoinBetaScreen> {
  // Helper function to launch a URL.
  Future<void> _launchURL(String url) async {
    try {
      final Uri uri = Uri.parse(url);

      // For mailto URLs, try with external application mode first
      if (url.startsWith('mailto:')) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return; // Success!
        } catch (e) {
          // Try with platform default
          try {
            await launchUrl(uri, mode: LaunchMode.platformDefault);
            return; // Success!
          } catch (e2) {
            // Fall back to clipboard
            await Clipboard.setData(ClipboardData(text: 'dev@readtheroom.site'));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'No email app found. Email address copied to clipboard: dev@readtheroom.site',
                    style: TextStyle(color: Colors.white),
                  ),
                  duration: Duration(seconds: 4),
                  backgroundColor: Colors.orange,
                ),
              );
            }
            return;
          }
        }
      }

      // For non-mailto URLs, use standard launch
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        throw 'Could not launch $url';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open link. Please email dev@readtheroom.site manually.',
              style: TextStyle(color: Colors.white),
            ),
            duration: Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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
      // Nothing useful to offer if the store will not open.
    }
  }

  @override
  void initState() {
    super.initState();
    AnalyticsService()
        .trackEvent('join_beta_viewed', {'source': widget.source});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join the beta'),
      ),
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          // Check if swipe is from left to right with sufficient velocity
          if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
            Scaffold.of(context).openDrawer();
          }
        },
        child: ListView(
          children: [
            _buildBetaHeader(context),
            _buildFeedbackHeading(context),
            _buildBugReportCard(context),
            _buildConnectCard(context),
            SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Join the beta
  // ---------------------------------------------------------------------------

  /// The pitch, the shared email card and the per-platform enrolment buttons.
  Widget _buildBetaHeader(BuildContext context) {
    final theme = Theme.of(context);
    final buttons = _buildBetaButtons(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Eager for new features? Join the beta.',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Join a tight community that helps shape Read the Room.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.grey,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          const EmailSignupCard(source: 'join_beta'),
          if (buttons.isNotEmpty) ...[
            const SizedBox(height: 16),
            ...buttons,
          ],
        ],
      ),
    );
  }

  /// One button per platform that has a link. A platform whose constant ships
  /// empty is skipped — better than a button that goes nowhere.
  List<Widget> _buildBetaButtons(BuildContext context) {
    final out = <Widget>[];

    void add(String label, IconData icon, String url, String platform) {
      if (!hasBetaLink(url)) return;
      if (out.isNotEmpty) out.add(const SizedBox(height: 8));
      out.add(
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: () => _openBetaLink(url, platform),
            icon: Icon(icon),
            label: Text(label),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      );
    }

    add('Join on TestFlight', Icons.apple, kTestFlightUrl, 'ios');
    add('Join the Play beta', Icons.shop, kPlayBetaUrl, 'android');
    return out;
  }

  Future<void> _openBetaLink(String url, String platform) async {
    AnalyticsService().trackEvent('beta_link_tapped', {'platform': platform});
    await _launchURL(url);
  }

  // ---------------------------------------------------------------------------
  // Send feedback
  // ---------------------------------------------------------------------------

  /// Marks where the beta pitch ends and the feedback section begins.
  Widget _buildFeedbackHeading(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            'Send feedback',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// The private bug-report path: one email address, tap to copy.
  Widget _buildBugReportCard(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(16, 12, 16, 16),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).primaryColor.withOpacity(0.3),
        ),
      ),
      child: Column(
        children: [
          Text(
            'Bugs, ideas and anything else — email us!',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).primaryColor.withOpacity(0.8),
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 8),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: 'dev@readtheroom.site'));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Email copied to clipboard',
                      style: TextStyle(color: Colors.white),
                    ),
                    duration: Duration(seconds: 2),
                    backgroundColor: Colors.teal,
                  ),
                );
              }
            },
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              minimumSize: Size(0, 0),
            ),
            child: Text(
              'dev@readtheroom.site',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).primaryColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Socials plus the app-store rating nudge.
  Widget _buildConnectCard(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(16, 16, 16, 0),
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
              label: Text('Leave a review'),
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
}
