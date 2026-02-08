// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// Platform-aware haptic feedback utility.
///
/// On iOS, uses Flutter's built-in HapticFeedback which maps to
/// UIImpactFeedbackGenerator and works reliably.
///
/// On Android, uses the Vibration plugin which directly accesses
/// the Vibrator service, bypassing the unreliable
/// View.performHapticFeedback() that Flutter uses by default.
class AppHaptics {
  static bool _hasVibrator = false;
  static bool _initialized = false;

  /// Call once at app startup (e.g. in main) to eagerly check
  /// vibrator availability. This ensures haptic calls don't need
  /// to await and can fire reliably from synchronous contexts.
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    _hasVibrator = await Vibration.hasVibrator() ?? false;
    _initialized = true;
  }

  /// Light impact - used for selections, toggles.
  static Future<void> lightImpact() async {
    if (Platform.isAndroid) {
      if (_hasVibrator) {
        Vibration.vibrate(duration: 20, amplitude: 40);
      }
    } else {
      HapticFeedback.lightImpact();
    }
  }

  /// Medium impact - used for confirmations, pull-to-refresh triggers.
  static Future<void> mediumImpact() async {
    if (Platform.isAndroid) {
      if (_hasVibrator) {
        Vibration.vibrate(duration: 30, amplitude: 80);
      }
    } else {
      HapticFeedback.mediumImpact();
    }
  }

  /// Heavy impact - used for important actions, errors.
  static Future<void> heavyImpact() async {
    if (Platform.isAndroid) {
      if (_hasVibrator) {
        Vibration.vibrate(duration: 40, amplitude: 128);
      }
    } else {
      HapticFeedback.heavyImpact();
    }
  }
}
