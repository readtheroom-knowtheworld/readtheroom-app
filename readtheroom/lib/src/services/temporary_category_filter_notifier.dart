// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class TemporaryCategoryFilterNotifier extends ChangeNotifier {
  String? _temporaryCategoryFilter;

  String? get temporaryCategoryFilter => _temporaryCategoryFilter;

  void setTemporaryCategoryFilter(String? categoryName) {
    _temporaryCategoryFilter = categoryName;
    notifyListeners();
  }

  bool get hasTemporaryCategoryFilter => _temporaryCategoryFilter != null;
} 