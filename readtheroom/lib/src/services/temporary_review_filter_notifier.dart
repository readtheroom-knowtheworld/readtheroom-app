// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class TemporaryReviewFilterNotifier extends ChangeNotifier {
  String? _temporaryReviewFilter;
  Set<String> _qualifyingQuestionIds = {};

  String? get temporaryReviewFilter => _temporaryReviewFilter;
  Set<String> get qualifyingQuestionIds => _qualifyingQuestionIds;

  void setTemporaryReviewFilter(String? tagName, {Set<String> questionIds = const {}}) {
    _temporaryReviewFilter = tagName;
    _qualifyingQuestionIds = questionIds;
    notifyListeners();
  }

  bool get hasTemporaryReviewFilter => _temporaryReviewFilter != null;
}
