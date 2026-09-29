// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The QOTD push contract, in one place.
//
// The Drop (`feature-documentation/qotd-drop-voting-2026-08-31.md` §10.2,
// `qotd-ballot-live-window-2026-08-31.md` §11) makes the push itself the event:
// the server picks a random minute, sends once, and every device is expected to
// show it **the moment it arrives**. Nobody schedules anything locally any more.
//
// `supabase/functions/send-qotd-push/index.ts` can send two shapes, chosen by
// the `QOTD_PUSH_MODE` secret, and a client in the field may see either:
//
//   drop   (`QOTD_PUSH_MODE` unset / `drop`)
//          notification block + data, `data.type = 'qotd_drop'`, Android
//          channel `qotd_drop`, iOS `interruption-level: time-sensitive`,
//          ttl 300 s. Carries `historyId`, `publishedAt`, `liveUntil`,
//          `spotCap`, `spotsRemaining`, `liveWindowSeconds` — the ladder
//          numbers, so copy can change server-side without an app release.
//
//   legacy (`QOTD_PUSH_MODE=legacy`, the required first-deploy state)
//          the pre-Drop data-only payload: `data.type = 'qotd'`, `questionId`,
//          `title`, `body`, `deepLink`, no notification block.
//
// Everything past `type` and `questionId` is optional and is parsed
// defensively: the server may add fields (and does — the spots/live-window
// keys), values arrive as strings because FCM `data` is string-only, and a
// hand-made test push from the Firebase console may carry almost nothing. A
// missing or malformed field must never throw and never block the
// notification, which is why this is a pure function with its own tests
// (`test/qotd_push_payload_test.dart`) rather than inline parsing in the
// message handlers.

/// Which of the two `send-qotd-push` payload shapes arrived.
enum QotdPushKind {
  /// `data.type == 'qotd_drop'` — the Drop push, normally with a notification
  /// block the OS renders on its own.
  drop,

  /// `data.type == 'qotd'` — the pre-Drop data-only push.
  legacy,
}

/// A parsed QOTD push, whichever shape the server sent.
class QotdPushPayload {
  const QotdPushPayload({
    required this.kind,
    required this.title,
    required this.body,
    required this.hasOsNotificationBlock,
    this.questionId,
    this.historyId,
    this.publishedAt,
    this.liveUntil,
    this.spotCap,
    this.spotsRemaining,
    this.liveWindowSeconds,
  });

  final QotdPushKind kind;

  /// What to render. Always non-empty: the server duplicates the notification
  /// copy into `data` (drop spec §10.2) and we fall back to the notification
  /// block and then to house copy.
  final String title;
  final String body;

  /// True when the message arrived with an FCM `notification` block, i.e. the
  /// OS renders it itself while the app is backgrounded or terminated.
  ///
  /// Call sites use this to avoid a **second** notification from the background
  /// isolate; in the foreground it means nothing, because neither Android nor
  /// iOS displays a notification block while the app is in front.
  final bool hasOsNotificationBlock;

  /// The day's question. Absent only from a malformed push. Used for the
  /// home-screen widget refresh and the activity log, not for navigation.
  final String? questionId;

  /// `question_of_the_day_history.id` for this drop. Drop mode only.
  final String? historyId;

  final DateTime? publishedAt;
  final DateTime? liveUntil;

  /// Ladder values (`qotd_config`) as they stood when the push was sent.
  /// Present in drop mode; ignored by this release beyond being parsed.
  final int? spotCap;
  final int? spotsRemaining;
  final int? liveWindowSeconds;

  bool get isDrop => kind == QotdPushKind.drop;

  /// The Android channel the notification belongs on. `qotd_drop` is created
  /// at app init at max importance (a push cannot create a channel).
  String get androidChannelId => isDrop ? 'qotd_drop' : 'qotd_channel';

  /// Local-notification payload, i.e. what `_onNotificationTap` routes on.
  ///
  /// A tapped QOTD notification opens the app on **home** (owner decision
  /// 2026-09-22), where the day's question already sits at the top — never the
  /// question screen itself. The `qotd` prefix is what the tap handlers route
  /// on; the question id rides along only so the in-app activity log can still
  /// link the entry to its question.
  String get navigationPayload =>
      questionId == null ? 'qotd' : 'qotd_$questionId';

  /// True for a local-notification payload minted by [navigationPayload].
  static bool isQotdNavigationPayload(String payload) =>
      payload == 'qotd' || payload.startsWith('qotd_');

  /// The question id carried by a [navigationPayload], if any.
  static String? questionIdFromNavigationPayload(String payload) =>
      payload.startsWith('qotd_') ? payload.substring('qotd_'.length) : null;

  /// House fallbacks, used only when neither `data` nor the notification block
  /// carried copy. Lead with the moment, never a countdown (ballot spec §11).
  static const String dropFallbackTitle = '⚡ Today\'s question just dropped';
  static const String legacyFallbackTitle = '📆 Question of the Day';
  static const String fallbackBody = 'Tap to read today\'s question.';

  /// True for either QOTD payload shape.
  static bool isQotdPush(Map<String, dynamic> data) {
    final type = data['type'];
    return type == 'qotd' || type == 'qotd_drop';
  }

  /// Parses [data] (an FCM `RemoteMessage.data` map). Returns null when the
  /// message is not a QOTD push, so callers can keep their type chain.
  ///
  /// [notificationTitle] / [notificationBody] are `RemoteMessage.notification`'s
  /// fields when present; passing them non-null is also what marks the message
  /// as carrying an OS-rendered notification block.
  static QotdPushPayload? parse(
    Map<String, dynamic> data, {
    String? notificationTitle,
    String? notificationBody,
    bool? hasOsNotificationBlock,
  }) {
    if (!isQotdPush(data)) return null;

    final isDrop = data['type'] == 'qotd_drop';

    final title = _firstNonEmpty([
      _string(data['title']),
      notificationTitle,
      isDrop ? dropFallbackTitle : legacyFallbackTitle,
    ]);
    final body = _firstNonEmpty([
      _string(data['body']),
      notificationBody,
      fallbackBody,
    ]);

    return QotdPushPayload(
      kind: isDrop ? QotdPushKind.drop : QotdPushKind.legacy,
      title: title,
      body: body,
      hasOsNotificationBlock: hasOsNotificationBlock ??
          ((notificationTitle != null && notificationTitle.isNotEmpty) ||
              (notificationBody != null && notificationBody.isNotEmpty)),
      questionId: _string(data['questionId']) ?? _string(data['question_id']),
      historyId: _string(data['historyId']) ?? _string(data['history_id']),
      publishedAt: _dateTime(data['publishedAt'] ?? data['published_at']),
      liveUntil: _dateTime(data['liveUntil'] ?? data['live_until']),
      spotCap: _int(data['spotCap'] ?? data['spot_cap']),
      spotsRemaining: _int(data['spotsRemaining'] ?? data['spots_remaining']),
      liveWindowSeconds:
          _int(data['liveWindowSeconds'] ?? data['live_window_seconds']),
    );
  }

  /// Trimmed non-empty string, or null. FCM `data` values are strings, but a
  /// hand-made push (or a future server change) can put anything here.
  static String? _string(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static int? _int(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString().trim());
  }

  static DateTime? _dateTime(Object? value) {
    final text = _string(value);
    if (text == null) return null;
    return DateTime.tryParse(text)?.toUtc();
  }

  static String _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      if (candidate != null && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return '';
  }
}
