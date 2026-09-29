// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Where "Join the beta" sends people, per platform.
///
/// ============================================================================
/// TODO(owner): FILL THESE IN. Both are deliberately empty.
///
/// A repo-wide search turned up no live enrolment link — only TestFlight as a
/// *release process* in README_RELEASE.md / README_CI_CD.md / codemagic.yaml.
/// The one that ever existed in the client was
/// `https://testflight.apple.com/join/MgNSptPg` (settings_screen.dart at
/// `ec7c28c`, removed in `861c4f7` with the v1.1.4 widgets work) — it is not
/// reinstated here because there is no way to tell from the repo whether that
/// invite is still open. No Play open-testing URL has ever been in the tree.
///
/// Expected shapes:
///   kTestFlightUrl = 'https://testflight.apple.com/join/XXXXXXXX';
///   kPlayBetaUrl   = 'https://play.google.com/apps/testing/com.readtheroom.app';
///
/// A button whose URL is still empty is **hidden**, so shipping with one or
/// both blank degrades to "no button" rather than a dead link.
/// ============================================================================
const String kTestFlightUrl = 'https://testflight.apple.com/join/gk5bYthq';
const String kPlayBetaUrl = 'https://play.google.com/apps/testing/com.readtheroom.app';

/// Whether a platform's join button has anywhere to go.
bool hasBetaLink(String url) => url.trim().isNotEmpty;
