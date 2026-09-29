// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../screens/friend_scanner_screen.dart';
import '../utils/main_tab_requests.dart';
import '../services/analytics_service.dart';
import '../services/friend_service.dart';
import '../services/profile_service.dart';
import '../utils/friend_logic.dart';
import '../utils/haptic_utils.dart';
import 'chameleon_avatar.dart';

/// "My QR" — the code a friend scans to add you instantly (§5.2).
///
/// The QR encodes `https://readtheroom.site/friend/{token}`, a rotating 24 h
/// token from `create_friend_qr_token()`, **not** a raw user id: a screenshot
/// of this dialog stops working within a day. Any camera app can scan it and
/// will deep-link into the app via the existing app-link setup.
class FriendQrDialog extends StatefulWidget {
  /// How "My stats" reaches the Me tab. Optional: the action is always
  /// shown, and openers that pass nothing fall back to [MainTabRequests].
  final VoidCallback? onSeeProfile;

  const FriendQrDialog({Key? key, this.onSeeProfile}) : super(key: key);

  /// [surface] distinguishes the two entry points (`header` — the app-bar
  /// avatar chip — from `community`), so the social funnel can tell which one
  /// actually gets codes shown.
  static Future<void> show(
    BuildContext context, {
    VoidCallback? onSeeProfile,
    String surface = 'community',
  }) {
    // Vocabulary: [kQrSurfaces]. Six values had appeared with none declared
    // (review 2026-09-22 §4.2); anything off-vocabulary is now reported as
    // `unknown` rather than silently splitting a breakdown.
    AnalyticsService().trackEvent('qr_shown', {
      'surface': kQrSurfaces.contains(surface) ? surface : 'unknown',
    });
    return showDialog<void>(
      context: context,
      builder: (_) => FriendQrDialog(onSeeProfile: onSeeProfile),
    );
  }

  @override
  State<FriendQrDialog> createState() => _FriendQrDialogState();
}

class _FriendQrDialogState extends State<FriendQrDialog> {
  String? _token;
  bool _loading = true;
  bool _failed = false;

  /// While the code is on screen, reload the friend list every few seconds.
  /// The scan happens on the other phone, so this is how this one finds out:
  /// `FriendService` spots the new pair and `MainScreen` shows the
  /// "You're friends now" dialog. A push does the same when it arrives first;
  /// the service announces each friend once either way. Cheap and bounded —
  /// it stops the moment the dialog closes.
  Timer? _poll;
  static const Duration kFriendPollInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // A fresh token every time the dialog opens. The RPC rotates rather than
    // reusing, so a code shown yesterday cannot be scanned today.
    WidgetsBinding.instance.addPostFrameCallback((_) => _mintToken());
    _poll = Timer.periodic(kFriendPollInterval, (_) {
      if (!mounted) return;
      context.read<FriendService>().refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _mintToken() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final friends = context.read<FriendService>();
    final result = await friends.createQrToken();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = result == null;
      _token = result?.token;
    });
  }


  /// Swap the dialog for the scanner. Everything that outlives the dialog is
  /// captured BEFORE the pop — this State's context is dead afterwards.
  Future<void> _scanInstead() async {
    AppHaptics.lightImpact();
    final navigator = Navigator.of(context);
    final friends = context.read<FriendService>();
    navigator.pop();
    final added = await FriendScannerScreen.push(navigator.context);
    if (added == true) friends.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final profile = context.watch<ProfileService>();
    final handle = profile.username;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Identity above the code, so a scanner can see who they are adding.
          ChameleonAvatar(avatarId: profile.avatarId, size: 56),
          const SizedBox(height: 10),
          Text(
            (handle ?? '').isEmpty ? 'My friend code' : '@$handle',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          _buildCode(context),
          const SizedBox(height: 12),
          Text(
            _failed
                ? "Couldn't create a code. Check your connection and try again."
                : 'Have a friend scan this to add you instantly.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.grey,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          // Every opener gets the same two actions, side by side: "My stats" (the
          // Me tab), and the other half of adding a friend — scanning THEIR
          // code. No Regenerate: a fresh code is minted each time the dialog
          // opens, so reopening it IS regenerating. Openers without their own
          // profile callback (Community, the identity card, the circle card) go
          // through the shared tab-request channel. Two equal halves of the row;
          // the labels scale down rather than overflow on a very narrow screen.
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    if (widget.onSeeProfile != null) {
                      widget.onSeeProfile!();
                    } else {
                      MainTabRequests.instance.goTo(MainTab.me);
                    }
                  },
                  icon: const Icon(Icons.person_outline, size: 16),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('My stats'),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primary,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scanInstead,
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Scan QR'),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primary,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _buildCode(BuildContext context) {
    const double size = 200;
    if (_loading) {
      return const SizedBox(
        width: size,
        height: size,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final token = _token;
    if (token == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(Icons.qr_code_2_rounded,
              size: 72, color: Colors.grey.withOpacity(0.5)),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // The code is always rendered dark-on-white regardless of theme:
        // an inverted QR is unreliable for many scanner apps.
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      // Tight box on purpose: AlertDialog measures its content with
      // IntrinsicWidth, and QrImageView is built on a LayoutBuilder, which
      // cannot report intrinsics — without a fixed size the whole dialog
      // fails to lay out (blank QR on device).
      child: SizedBox(
        width: size,
        height: size,
        child: QrImageView(
          data: friendLinkForToken(token),
          version: QrVersions.auto,
          size: size,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        ),
      ),
    );
  }
}
