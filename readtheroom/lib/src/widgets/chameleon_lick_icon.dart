// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Asset path of the chameleon-lick mark, so tests and callers share one
/// spelling.
const String kChameleonLickAsset = 'assets/icons/chameleon_lick.svg';

/// The chameleon-lick mark: a chameleon head in profile with its tongue out.
///
/// Replaces the 👅 emoji everywhere a lick is *drawn* (the chat overlay's big
/// button, the timeline bubbles, the empty state). Where a lick has to live
/// inside a string instead — push copy, SnackBars, settings prose — the app
/// uses 🦎, because a string cannot carry a widget.
///
/// Drawn in the avatar set's flat-vector style (same palette, same #263944
/// outline, no gradients or external refs) so a lick and a chameleon avatar
/// look like they come from the same hand.
///
/// **On [color].** Passing it flattens the whole mark to one colour via
/// `colorFilter`. That is offered for a genuinely monochrome context, but it is
/// *not* the default and is deliberately unused in the app today: the eye, the
/// mouth and the tongue are what make this read as a lick, and a flat tint
/// collapses all three into a blob. The full-colour mark also sits happily on
/// the teal primary button, which is the one place a tint would have been
/// tempting.
class ChameleonLickIcon extends StatelessWidget {
  const ChameleonLickIcon({
    Key? key,
    this.size = 24,
    this.color,
    this.semanticsLabel = 'Lick',
  }) : super(key: key);

  /// Rendered width/height in logical pixels.
  final double size;

  /// Optional flat tint — see the class doc before reaching for it.
  final Color? color;

  /// Screen-reader label. Pass `null` where the surrounding widget already
  /// carries one (a labelled button, a bubble with its own semantics).
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      kChameleonLickAsset,
      width: size,
      height: size,
      colorFilter:
          color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn),
      semanticsLabel: semanticsLabel,
      // Nothing stands in while the asset parses: a placeholder box would make
      // the lick button jump on first open.
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }
}
