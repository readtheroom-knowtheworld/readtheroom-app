// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The app's one root navigator key, hoisted out of `_ReadTheRoomAppState` so
// services (which have no `BuildContext`) can ask what is currently on screen.
// `main.dart` still owns it — it just reads it from here instead of creating a
// private one, so every existing `_navigatorKey` call site is unchanged.

import 'package:flutter/material.dart';

/// Root navigator key, handed to the app's `MaterialApp`.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// The topmost [ModalRoute] of the root navigator, or null when there is no
/// navigator yet (pre-first-frame) or the top entry is not a modal route.
///
/// Peeking at the top route via `popUntil` with an always-true predicate is the
/// standard trick: `Navigator.popUntil` evaluates the predicate against the top
/// entry *before* popping, so returning true pops nothing.
ModalRoute<dynamic>? topModalRoute() {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return null;
  ModalRoute<dynamic>? top;
  try {
    navigator.popUntil((route) {
      if (route is ModalRoute) top = route;
      return true;
    });
  } catch (e) {
    // A navigator mid-transition can throw; "unknown" is the safe answer.
    return null;
  }
  return top;
}

/// Whether a dialog, bottom sheet or other popup is currently covering the
/// screen.
///
/// Deliberately narrower than "is anything pushed": a *pushed page* (an answer
/// screen, a results screen) is a normal place to be and must not block an
/// OS-owned sheet, whereas a [PopupRoute] — which `showDialog`,
/// `showModalBottomSheet` and `showMenu` all create — sits over the page it was
/// launched from, and a second sheet stacked on it would be stealing the tap.
bool isPopupRouteOnTop() => topModalRoute() is PopupRoute;
