// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A one-way "please switch the bottom-nav tab" channel for widgets that live
// below MainScreen but were not handed a callback (dialogs, shared cards).
// MainScreen listens and maps the symbolic tab to its index, so nothing outside
// it needs to know the tab order.

import 'package:flutter/foundation.dart';

enum MainTab { home, community, activity, me }

class MainTabRequests extends ChangeNotifier {
  MainTabRequests._();
  static final MainTabRequests instance = MainTabRequests._();

  MainTab? _pending;

  /// Ask MainScreen to show [tab]. A no-op when no MainScreen is mounted.
  void goTo(MainTab tab) {
    _pending = tab;
    notifyListeners();
  }

  /// Read-and-clear, so one request switches tabs exactly once.
  MainTab? take() {
    final tab = _pending;
    _pending = null;
    return tab;
  }
}
