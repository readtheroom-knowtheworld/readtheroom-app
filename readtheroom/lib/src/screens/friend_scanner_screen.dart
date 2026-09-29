// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../services/analytics_service.dart';
import '../services/friend_service.dart';
import '../utils/friend_logic.dart';
import '../utils/haptic_utils.dart';
import '../widgets/chameleon_avatar.dart';

/// In-app friend-QR scanner (§5.2 add flow 2).
///
/// Parses `https://readtheroom.site/friend/{token}` (and the custom-scheme and
/// bare-token variants — see [parseFriendToken]) and redeems it through
/// `add_friend_via_qr`, which creates an **instantly accepted** pair: both
/// parties were physically present, so consent is implied.
///
/// Pops with `true` when a friend was added, so the caller can refresh.
class FriendScannerScreen extends StatefulWidget {
  const FriendScannerScreen({Key? key}) : super(key: key);

  static Future<bool?> push(BuildContext context) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const FriendScannerScreen()),
    );
  }

  @override
  State<FriendScannerScreen> createState() => _FriendScannerScreenState();
}

class _FriendScannerScreenState extends State<FriendScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  /// Guards against the detector firing again while an RPC is in flight or a
  /// result is on screen — `noDuplicates` only dedupes identical payloads.
  bool _handling = false;

  /// Non-null once a friend has been added: the success state replaces the
  /// camera rather than popping instantly, so the scanner can see who it got.
  Friend? _added;
  bool _alreadyFriends = false;

  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || _added != null) return;

    String? token;
    for (final barcode in capture.barcodes) {
      token = parseFriendToken(barcode.rawValue);
      if (token != null) break;
    }

    if (token == null) {
      // A QR that is not one of ours. Show the hint but keep scanning — the
      // user is probably still pointing at the wrong thing.
      _showInlineError("That's not a Read the Room friend code.");
      AnalyticsService()
          .trackEvent('qr_scanned', const {'result': 'not_a_friend_code'});
      return;
    }

    setState(() {
      _handling = true;
      _errorMessage = null;
    });
    AppHaptics.lightImpact();

    // Resolved before the first await: reading a provider off a BuildContext
    // after an async gap is exactly the bug use_build_context_synchronously
    // exists to catch.
    final friends = context.read<FriendService>();

    await _controller.stop();
    final result = await friends.addFriendViaQr(token);
    if (!mounted) return;

    if (result.success) {
      // The same buzz the scanned phone gets from NewFriendDialog.
      AppHaptics.mediumImpact();
      AnalyticsService().trackEvent('qr_scanned', {
        'result': result.alreadyFriends ? 'already_friends' : 'added',
      });
      setState(() {
        _handling = false;
        _added = result.friend;
        _alreadyFriends = result.alreadyFriends;
      });
      return;
    }

    AnalyticsService()
        .trackEvent('qr_scanned', {'result': _resultLabel(result.error)});

    setState(() {
      _handling = false;
      _errorMessage = result.message;
    });
    // Resume so the user can immediately try another code.
    await _controller.start();
  }

  static String _resultLabel(FriendError? error) {
    switch (error) {
      case FriendError.expiredToken:
        return 'expired';
      case FriendError.invalidToken:
        return 'invalid';
      case FriendError.self:
        return 'self';
      case FriendError.blocked:
        return 'blocked';
      case FriendError.notAuthenticated:
        return 'not_authenticated';
      default:
        return 'error';
    }
  }

  void _showInlineError(String message) {
    if (_errorMessage == message) return;
    setState(() => _errorMessage = message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan a friend code'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_added == null)
            IconButton(
              tooltip: 'Torch',
              icon: const Icon(Icons.flashlight_on_rounded),
              onPressed: () => _controller.toggleTorch(),
            ),
        ],
      ),
      body: _added != null ? _buildSuccess(context, _added!) : _buildScanner(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          // Covers permission-denied, no-camera and unsupported devices in one
          // place — mobile_scanner surfaces all of them as an error state.
          errorBuilder: (context, error) => _buildCameraError(error),
        ),
        // Reticle.
        IgnorePointer(
          child: Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 3),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_handling)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              const Text(
                "Point at your friend's QR code",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.withOpacity(0.8)),
                  ),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCameraError(MobileScannerException error) {
    final isPermission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_rounded,
                color: Colors.white70, size: 56),
            const SizedBox(height: 16),
            Text(
              isPermission
                  ? 'Camera access is off'
                  : "The camera isn't available",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              isPermission
                  ? 'Allow camera access in Settings to scan a friend code, or '
                      'ask your friend to send you their link instead.'
                  : 'Ask your friend to send you their friend link instead.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccess(BuildContext context, Friend friend) {
    final theme = Theme.of(context);
    return Container(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ChameleonAvatar(avatarId: friend.avatarId, size: 96),
              const SizedBox(height: 20),
              Text(
                friend.displayHandle,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(
                _alreadyFriends
                    ? "You're already friends 🦎"
                    : "You're friends now 🦎",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.textTheme.bodySmall?.color),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Done'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  setState(() {
                    _added = null;
                    _alreadyFriends = false;
                    _errorMessage = null;
                  });
                  await _controller.start();
                },
                child: const Text('Scan another'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
