// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

class BuildConfig {
  static const bool isFDroidBuild = bool.fromEnvironment(
    'FDROID_BUILD',
    defaultValue: false,
  );
}
