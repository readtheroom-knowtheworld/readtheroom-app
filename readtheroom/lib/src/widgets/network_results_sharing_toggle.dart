// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Change your mind" — the un-share affordance for an answer you already gave
// (owner decision D-5, 2026-09-22).
//
// The 2026-09-17 rule was that the per-answer close-friend flag froze at submit
// time, and that was honest while the flag sat on an anonymous row: there was
// nobody to re-consent as. The linkage gives the row an author, so
// `set_answer_sharing(question_id, shared)` can move it, and every reader
// filters at read time — turning it off removes the answer from the close-friend
// row and greys the graph node on the next look, retroactively.
//
// It reuses [ShareWithCloseFriendsToggle] exactly as the answer forms do, down
// to the SnackBar wording, so the control means the same thing in both places.
// That widget renders nothing at all for a viewer with no close friends, which
// is the right behaviour here too: there is nobody the choice could apply to.
//
// STATE: read from the local record. No read RPC returns the viewer's own share
// flag — see the note on `NetworkService.localSharing`, which is also where the
// consequence (a flip on one device is not visible on another until touched) is
// written down.

import 'package:flutter/material.dart';

import '../services/analytics_service.dart';
import '../services/network_service.dart';
import 'share_with_close_friends_toggle.dart';

class NetworkResultsSharingToggle extends StatefulWidget {
  const NetworkResultsSharingToggle({
    Key? key,
    required this.questionId,
    required this.answered,
    this.service,
    this.surface = 'results',
  }) : super(key: key);

  final String questionId;

  /// Whether the viewer answered this question. There is nothing to share
  /// otherwise, and the RPC would report `updated: 0`.
  final bool answered;

  final NetworkService? service;
  final String surface;

  @override
  State<NetworkResultsSharingToggle> createState() =>
      _NetworkResultsSharingToggleState();
}

class _NetworkResultsSharingToggleState
    extends State<NetworkResultsSharingToggle> {
  NetworkService get _service => widget.service ?? NetworkService.shared();

  bool? _shared;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    if (!widget.answered) return;
    final shared = await _service.currentSharing(widget.questionId);
    if (!mounted) return;
    setState(() => _shared = shared);
  }

  Future<void> _onChanged(bool next) async {
    // Optimistic: the toggle already moved and showed its SnackBar. A failure
    // puts it back rather than leaving a lie on screen.
    setState(() {
      _shared = next;
      _busy = true;
    });
    final ok = await _service.setAnswerSharing(widget.questionId, next);
    // Review 2026-09-22 B3: this used to fire before `ok` was known, so a flip
    // that failed was logged as one that worked. It now reports the outcome.
    AnalyticsService().trackEventAnonymous('answer_sharing_changed', {
      'shared': next,
      'surface': widget.surface,
      'result': ok ? 'ok' : 'failed',
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) return;
    // The known `updated: 0` case: an answer filed before the linkage shipped
    // has no link row to move. How often that happens is the number this
    // event was added for.
    AnalyticsService()
        .trackRpcFailed('set_answer_sharing', reason: 'not_updated');
    // `updated: 0` means there is no linked answer to move — an answer filed
    // before the linkage shipped. Saying nothing would imply it worked.
    setState(() => _shared = !next);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 2600),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).primaryColor,
          content: const Text(
            "Couldn't change this one — it was answered before sharing could be "
            'edited.',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final shared = _shared;
    if (!widget.answered || shared == null) return const SizedBox.shrink();
    // The toggle hides itself when the viewer has no close friends; without
    // this check the label and the frame would still be drawn around nothing.
    if (!ShareWithCloseFriendsToggle.hasCloseFriends(context)) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              // Centred in the room between the card's left edge and the
              // toggle, with a little breathing space on both sides.
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                shared
                    ? 'Sharing this answer with close friends'
                    : 'Hiding this answer from close friends',
                textAlign: TextAlign.center,
                // Teal while sharing; the usual text colour in ghost mode
                // (owner, 2026-09-22).
                style: theme.textTheme.bodySmall?.copyWith(
                  color: shared ? theme.primaryColor : null,
                  fontWeight: shared ? FontWeight.w600 : null,
                  height: 1.35,
                ),
              ),
            ),
          ),
          ShareWithCloseFriendsToggle(
            value: shared,
            enabled: !_busy,
            onChanged: _onChanged,
          ),
        ],
      ),
    );
  }
}
