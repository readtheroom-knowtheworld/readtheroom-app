// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dart:async';

import '../services/analytics_service.dart';
import '../utils/haptic_utils.dart';

/// Email capture — "Stay up to date and support Read the Room".
///
/// Lifted verbatim out of `community_screen.dart` when the Join-the-beta screen
/// needed the same card, so the two cannot drift: one implementation, one
/// `subscribe_email` call, one persisted flag.
///
/// **The one-time thank-you.** Signing up swaps the form for a thank-you row
/// *for that session only*; the persisted flag then hides the card entirely on
/// every later visit. The flag is shared across both surfaces on purpose — once
/// you are on the list, neither place should ask again — and it keeps the
/// original `community_email_submitted` key so nobody who already signed up is
/// asked a second time.
class EmailSignupCard extends StatefulWidget {
  const EmailSignupCard({Key? key, required this.source}) : super(key: key);

  /// `p_source` on the RPC: which surface the address came from
  /// (`community_tab` | `join_beta`).
  final String source;

  /// SharedPreferences flag. Shared by every surface — see the class doc.
  static const String submittedKey = 'community_email_submitted';

  @override
  State<EmailSignupCard> createState() => _EmailSignupCardState();
}

class _EmailSignupCardState extends State<EmailSignupCard> {
  static final RegExp _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  final TextEditingController _emailController = TextEditingController();

  /// The placeholder address disappears while the field has focus.
  final FocusNode _emailFocus = FocusNode();
  bool _emailSubmitted = false;

  /// True only for the session in which the user signed up: the card thanks
  /// them once, then disappears for good on the next visit/launch (the
  /// persisted flag hides it entirely).
  bool _emailJustSubmitted = false;
  bool _submitting = false;
  String? _emailError;

  @override
  void initState() {
    super.initState();
    _emailFocus.addListener(_onEmailFocusChanged);
    _loadSubmitted();
  }

  void _onEmailFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _emailFocus.removeListener(_onEmailFocusChanged);
    _emailFocus.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _loadSubmitted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _emailSubmitted = prefs.getBool(EmailSignupCard.submittedKey) ?? false;
      });
    } catch (_) {
      // Non-fatal; the form simply shows again.
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    if (!_emailShape.hasMatch(email)) {
      setState(() => _emailError = 'Please enter a valid email address');
      return;
    }

    AppHaptics.lightImpact();
    setState(() {
      _emailError = null;
      _submitting = true;
    });

    var success = false;
    try {
      final result = await Supabase.instance.client.rpc(
        'subscribe_email',
        params: {'p_email': email, 'p_source': widget.source},
      );
      success = result is Map && result['success'] == true;
      if (!success) {
        AnalyticsService()
            .trackRpcFailed('subscribe_email', reason: 'refused');
      }
    } catch (_) {
      success = false;
      AnalyticsService()
          .trackRpcFailed('subscribe_email', reason: 'exception');
    }
    // P1-7: the card had no analytics at all, so the beta waitlist's
    // conversion was invisible. The address itself never travels — only
    // whether it worked, and which surface asked.
    unawaited(AnalyticsService().trackEvent('email_signup_submitted', {
      'source': widget.source,
      'success': success,
    }));

    if (!mounted) return;
    setState(() {
      _submitting = false;
      _emailSubmitted = success;
      _emailJustSubmitted = success;
    });

    if (success) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(EmailSignupCard.submittedKey, true);
      } catch (_) {
        // Non-fatal; worst case the form reappears next session.
      }
    }

    if (!mounted) return;
    _snack(
      success
          ? "You're on the list — thanks for supporting Read the Room 🦎"
          : "Couldn't save your email — please try again.",
      error: !success,
    );
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: error ? Colors.orange : Theme.of(context).primaryColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;

    // Already on the list from a previous session: nothing to show. The
    // thank-you state below appears only right after signing up.
    if (_emailSubmitted && !_emailJustSubmitted) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? Colors.white.withOpacity(0.04)
            : primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: primary.withOpacity(0.25),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: _emailSubmitted
          ? Row(
              children: [
                Icon(Icons.check_circle_rounded, color: primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "You're on the list — thanks for supporting "
                    "Read the Room 🦎",
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.mail_outline_rounded, color: primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Keep in touch',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Share an email, stay up to date and support '
                  'RTR.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _emailController,
                        focusNode: _emailFocus,
                        enabled: !_submitting,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        onChanged: (_) {
                          if (_emailError != null) {
                            setState(() => _emailError = null);
                          }
                        },
                        decoration: InputDecoration(
                          hintText: _emailFocus.hasFocus
                              ? null
                              : 'karma@chameleon.com',
                          hintStyle: TextStyle(color: Colors.grey[500]),
                          errorText: _emailError,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: _submitting ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Sign up'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
