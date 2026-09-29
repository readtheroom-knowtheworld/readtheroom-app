// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE event catalogue. One place, machine-checked.
//
// Every analytics event this app can emit is declared here with the property
// keys it is allowed to carry. `test/analytics_events_test.dart` scans `lib/`
// and fails if a `trackEvent(...)` call site emits a name that is not declared
// or a property key the declaration does not list — so adding an event, or
// slipping a new property onto one, is a deliberate edit to this file rather
// than a surprise in a PostHog breakdown three weeks later.
//
// It also encodes the two rules that are easy to break by accident:
//
//   * [kIdentifiedAnswerEvents] — events that fire against an IDENTIFIED
//     person and therefore may never carry a question id. `responses` has no
//     `user_id` by design (DBarchitecture.md:167) and
//     `networks-client-2026-09-22.md` §5 rule 5 makes it a project rule; a
//     `question_id` here would re-create that join inside PostHog.
//   * [kForbiddenPropertyKeys] — property names that must never appear on any
//     event, because they carry user-authored content or an identifier: an
//     email, a handle, an emoji, a comment body, a place name, a raw error
//     message.
//
// Review: feature-documentation/posthog-events-review-2026-09-22.md
// Handover: feature-documentation/HANDOVER-posthog-2026-09-22.md

/// What one event is allowed to look like.
class AnalyticsEventSchema {
  const AnalyticsEventSchema({
    required this.when,
    this.properties = const <String>{},
    this.anonymous = false,
  });

  /// One line: when this fires. Kept next to the shape so the catalogue in the
  /// handover doc can be regenerated from the code rather than drifting.
  final String when;

  /// Every property key the event may carry. A superset — an event need not
  /// send all of them (most are conditional).
  final Set<String> properties;

  /// True when the event is sent with `trackEventAnonymous`, i.e. it must not
  /// mint a person profile. Used for things the user did not individually
  /// choose: a push receipt, a card impression, a cold start.
  final bool anonymous;
}

/// Property keys that may never appear on any event, on any surface.
///
/// Not a style rule — each of these has either leaked or nearly leaked. The
/// rule for every failure event in particular is CODES ONLY: a PostgREST
/// message can quote a question prompt, an HTTP body can quote a comment.
const Set<String> kForbiddenPropertyKeys = <String>{
  'email',
  'device_id',
  'username',
  'handle',
  'display_name',
  'emoji',
  'reaction',
  'content',
  'comment',
  'comment_body',
  'answer_text',
  'text_response',
  'prompt',
  'message',
  'error_message',
  'stack',
  'stack_trace',
  'token',
  'city',
  'country',
  'location_value',
  'place_name',
};

/// Events that fire against an identified person and describe that person's
/// own answer or rating. None of them may carry `question_id`.
const Set<String> kIdentifiedAnswerEvents = <String>{
  'question_answer_started',
  'question_answered',
  'question_answer_abandoned',
  'question_rated',
  'answer_submit_failed',
};

/// Super properties registered on every event.
const Set<String> kSuperProperties = <String>{
  'app_version',
  'build',
  'platform',
  'is_authenticated',
};

/// Person properties, for people who have one (guests do not — the project
/// runs `personProfiles: identifiedOnly`).
const Set<String> kPersonProperties = <String>{
  'is_authenticated',
  'auth_provider',
  'account_created_at',
  'first_login_at',
  'qotd_subscribed',
  'qotd_topic_subscribed',
  'last_session_start',
  'total_days_since_first_open',
  'total_features_adopted',
  'adopted_features',
  'active_widgets',
  'has_streak_widget',
  'has_qotd_widget',
  'theme_mode',
};

/// The catalogue.
const Map<String, AnalyticsEventSchema> kAnalyticsEventRegistry =
    <String, AnalyticsEventSchema>{
  // ------------------------------------------------------------ lifecycle
  'app_opened': AnalyticsEventSchema(when: 'App foregrounded or launched.'),
  'app_backgrounded': AnalyticsEventSchema(when: 'App sent to background.'),
  'app_resumed': AnalyticsEventSchema(when: 'App resumed from background.'),
  'app_main_screen_loaded': AnalyticsEventSchema(
    when: 'MainScreen finished its first build.',
    properties: <String>{'initial_tab_index', 'timestamp'},
  ),
  'app_started': AnalyticsEventSchema(
    when: 'Service initialisation finished (cold-start timing).',
    properties: <String>{'services_ms', 'slowest_service', 'slowest_ms'},
    anonymous: true,
  ),
  'app_error': AnalyticsEventSchema(
    when: 'An unhandled Flutter or platform error. Types only, never messages.',
    properties: <String>{'error_type', 'library', 'fatal'},
  ),
  'user_first_open': AnalyticsEventSchema(
    when: 'The very first app open on this install.',
    properties: <String>{'first_open_date'},
  ),
  'user_return': AnalyticsEventSchema(
    when: 'Any app open after the first.',
    properties: <String>{
      'days_since_first_open',
      'first_open_date',
      'return_date'
    },
  ),

  // ----------------------------------------------------------- onboarding
  'onboarding_step': AnalyticsEventSchema(
    when: 'One canonical onboarding step. Group on step_id, never step_index.',
    properties: <String>{
      'step_id',
      'step_index',
      'step_name', // legacy dual-write
      'step_number', // legacy dual-write
      'slide_number',
      'total_slides',
      'triggered_from',
      'abandoned_at_step_id',
      'auth_method',
      'os_status',
      'question_type',
      'granularity',
      'has_city',
      'generation',
    },
  ),
  'onboarding_auth_completed': AnalyticsEventSchema(
    when: 'Supabase reported an authenticated session.',
    properties: <String>{'auth_method'},
  ),
  'onboarding_first_interaction': AnalyticsEventSchema(
    when: 'The first thing a new user touches.',
    properties: <String>{'interaction_type', 'is_guest'},
  ),
  'onboarding_triggered_from_guide': AnalyticsEventSchema(
    when: 'The guide bounced the user back into onboarding.',
    properties: <String>{
      'trigger_reason',
      'is_authenticated',
      'has_location',
      'missing_auth',
      'missing_location',
      'not_authenticated',
    },
  ),
  'onboarding_tutorial_opened': AnalyticsEventSchema(
    when: 'The tutorial was opened from onboarding.',
    properties: <String>{'source'},
  ),
  'auth_failed': AnalyticsEventSchema(
    when: 'A passkey register or authenticate failed. Our own reason codes.',
    properties: <String>{'stage', 'reason'},
  ),
  'profile_set': AnalyticsEventSchema(
    when: 'A handle and/or chameleon was chosen.',
    properties: <String>{'has_avatar', 'suggested', 'username_source'},
  ),
  'profile_setup_sheet_shown': AnalyticsEventSchema(
    when: 'The post-onboarding profile sheet appeared.',
  ),
  'username_set': AnalyticsEventSchema(
    when: 'A handle was saved.',
    properties: <String>{'is_change'},
  ),
  'generation_selected': AnalyticsEventSchema(
    when: 'A generation was chosen.',
    properties: <String>{'generation', 'source'},
  ),

  // ------------------------------------------------------------- answering
  'question_viewed': AnalyticsEventSchema(
    when: 'A question card was opened. Carries revisit metrics, not an id.',
    properties: <String>{
      'question_type',
      'category',
      'view_source',
      'view_count',
      'is_revisit',
      'days_since_first_view',
      'time_since_last_view_minutes',
      'poll_location',
      'is_nsfw',
      'vote_count',
      'comment_count',
    },
  ),
  'question_answer_started': AnalyticsEventSchema(
    when: 'An answer screen was opened. NO question id.',
    properties: <String>{'question_type', 'source'},
  ),
  'question_answered': AnalyticsEventSchema(
    when: 'An answer was accepted by the server. NO question id.',
    properties: <String>{
      'question_type',
      'answer_type',
      'source',
      'is_first',
      'shared_with_close_friends',
    },
  ),
  'question_answer_abandoned': AnalyticsEventSchema(
    when: 'An answer screen was left without a successful submit.',
    properties: <String>{'question_type', 'source', 'time_on_screen_seconds'},
  ),
  'answer_submit_failed': AnalyticsEventSchema(
    when: 'A submit was refused or threw. Reason rides on the paired rpc_failed.',
    properties: <String>{'question_type', 'source'},
  ),
  'question_rated': AnalyticsEventSchema(
    when: 'The optional rating slider was submitted. Bucket only, no id.',
    properties: <String>{'rating_bucket'},
  ),
  'question_results_viewed': AnalyticsEventSchema(
    when: 'A results screen was opened.',
    properties: <String>{'question_type'},
  ),
  'results_viz_mode': AnalyticsEventSchema(
    when: 'A results visualisation mode was chosen.',
    properties: <String>{'mode', 'respondent_count'},
  ),
  'submit_response_fallback_used': AnalyticsEventSchema(
    when: 'submit_response is not deployed; the unlinked legacy insert ran. '
        'Once per session.',
    properties: <String>{'reason'},
  ),

  // -------------------------------------------------------------- creating
  'question_create_started': AnalyticsEventSchema(
    when: 'The new-question screen was opened.',
    properties: <String>{'entry_point'},
  ),
  'question_create_abandoned': AnalyticsEventSchema(
    when: 'The creation flow was left without posting. Field name, never text.',
    properties: <String>{'furthest_field'},
  ),
  'question_asked': AnalyticsEventSchema(
    when: 'A question was posted. Participation here is public, so the id is '
        'allowed.',
    properties: <String>{
      'question_id',
      'question_type',
      'categories',
      'has_description',
      'is_nsfw',
      'is_private',
      'is_first_question',
      'mentioned_countries_count',
      'targeting',
    },
  ),

  // ------------------------------------------------------------ engagement
  'reaction_added': AnalyticsEventSchema(
    when: 'A reaction was added. Never the emoji.',
    properties: <String>{'emoji_source', 'question_id', 'is_first'},
  ),
  'reaction_removed': AnalyticsEventSchema(
    when: 'A reaction was removed.',
    properties: <String>{'emoji_source', 'question_id'},
  ),
  'comment_posted': AnalyticsEventSchema(
    when: 'A comment was posted. Never the body.',
    properties: <String>{'question_id', 'has_linked_questions', 'is_first'},
  ),
  'review_tags_submitted': AnalyticsEventSchema(
    when: 'Rating stage 2 submitted. Count only.',
    properties: <String>{'tag_count'},
  ),
  'review_tags_skipped':
      AnalyticsEventSchema(when: 'Rating stage 2 skipped.'),
  'question_shared': AnalyticsEventSchema(
    when: 'A question was shared from a card.',
    properties: <String>{'question_id', 'question_type', 'category', 'method'},
  ),
  'share_initiated': AnalyticsEventSchema(
    when: 'A share action started.',
    properties: <String>{'surface', 'method', 'question_id'},
  ),
  'home_refreshed': AnalyticsEventSchema(
    when: 'Pull-to-refresh on a feed.',
    properties: <String>{'surface'},
  ),
  'archive_opened': AnalyticsEventSchema(
    when: 'The archive was opened.',
    properties: <String>{'source'},
  ),
  'archive_sort_changed': AnalyticsEventSchema(
    when: 'The archive sort or section changed.',
    properties: <String>{'section', 'sort'},
  ),
  'search_opened': AnalyticsEventSchema(
    when: 'Search was opened.',
    properties: <String>{'source'},
  ),
  'search_performed': AnalyticsEventSchema(
    when: 'A search ran. Length only, never the query.',
    properties: <String>{'query_length', 'result_count', 'filters_active'},
  ),
  'search_result_tapped': AnalyticsEventSchema(
    when: 'A search result was opened.',
    properties: <String>{'result_rank', 'section'},
  ),
  'generation_filter_applied': AnalyticsEventSchema(
    when: 'A generation filter was applied on a results screen.',
    properties: <String>{'generation', 'question_id', 'question_type'},
  ),
  'map_fullscreen_opened': AnalyticsEventSchema(
    when: 'The response map was opened fullscreen.',
    properties: <String>{'question_type'},
  ),
  'map_world_view': AnalyticsEventSchema(
    when: 'The map zoomed out to the world.',
    properties: <String>{'question_type'},
  ),
  'map_country_tapped': AnalyticsEventSchema(
    when: 'A country was tapped on the map.',
    properties: <String>{'question_type'},
  ),
  'map_city_filtered': AnalyticsEventSchema(
    when: 'The map was filtered to a city.',
    properties: <String>{'question_type'},
  ),
  'map_option_highlighted': AnalyticsEventSchema(
    when: 'An answer option was highlighted on the map.',
    properties: <String>{'question_type'},
  ),
  'streak_card_tapped': AnalyticsEventSchema(
    when: 'The streak card was tapped.',
    properties: <String>{'compact', 'current_streak', 'has_extended_today'},
  ),
  'streak_dialog_widget_link_tapped': AnalyticsEventSchema(
    when: 'The "add the widget" link in the streak dialog was tapped.',
  ),
  // streak_reminder_changed / streak_reminder_time_changed: removed with the
  // feature on 2026-09-22 (streak-reminders-removed-2026-09-22.md).
  'results_filter_applied': AnalyticsEventSchema(
    when: 'A results-page filter was chosen (World, a country, a city, a '
        'generation, or "network" = My Network). Aggregate only.',
    properties: <String>{'filter', 'question_type'},
  ),
  'results_comparison_applied': AnalyticsEventSchema(
    when: 'A results-page comparison was chosen; each side is a filter kind '
        '("network" = My Network). Aggregate only.',
    properties: <String>{'filter', 'question_type'},
  ),
  'theme_mode_changed': AnalyticsEventSchema(
    when: 'The theme was changed.',
    properties: <String>{'theme_mode'},
  ),
  'location_changed': AnalyticsEventSchema(
    when: 'The location filter changed. No longer mirrored to a person.',
    properties: <String>{'location_type', 'location_value'},
  ),
  'widget_updated': AnalyticsEventSchema(
    when: 'A home-screen widget was refreshed.',
    properties: <String>{
      'widget_type',
      'streak_count',
      'has_extended_today',
      'curio_state',
      'question_id',
      'has_answered',
    },
  ),
  'feature_first_use': AnalyticsEventSchema(
    when: 'A feature was used for the first time on this install.',
    properties: <String>{'feature_name', 'first_use_date', 'question_type'},
  ),
  'feature_used': AnalyticsEventSchema(
    when: 'A feature was used.',
    properties: <String>{'feature_name', 'is_first_use', 'question_type'},
  ),
  'feature_adoption_milestone': AnalyticsEventSchema(
    when: 'A new feature joined this person\'s adopted set.',
    properties: <String>{
      'feature_name',
      'total_features_adopted',
      'adopted_features'
    },
  ),

  // ------------------------------------------------------------------ QOTD
  'qotd_home_viewed': AnalyticsEventSchema(
    when: 'Home resolved today\'s question into a state.',
    properties: <String>{'state', 'entry_source', 'ms_to_state', 'attempts'},
  ),
  'qotd_clicked': AnalyticsEventSchema(
    when: 'The QOTD card was opened from home.',
    properties: <String>{'question_id', 'source'},
  ),
  'qotd_nomination': AnalyticsEventSchema(
    when: 'The QOTD pick sheet was used.',
    properties: <String>{
      'action',
      'answer_rank',
      'candidates_shown',
      'picked',
      'source'
    },
  ),
  'qotd_subscription_changed': AnalyticsEventSchema(
    when: 'The QOTD notification preference changed.',
    properties: <String>{'subscribed'},
  ),
  'pending_answer_replayed': AnalyticsEventSchema(
    when: 'A guest\'s stashed first answer was replayed after sign-in.',
    properties: <String>{'success'},
  ),

  // --------------------------------------------------------- notifications
  'notification_received': AnalyticsEventSchema(
    when: 'A push arrived. Background receipts are drained on the next launch.',
    properties: <String>{
      'notification_type',
      'delivery_context',
      'push_kind',
      'is_drop',
      'drop_date',
      'seconds_to_report',
    },
  ),
  'notification_opened': AnalyticsEventSchema(
    when: 'A push was tapped.',
    properties: <String>{
      'notification_type',
      'delivery',
      'push_kind',
      'is_drop',
      'seconds_since_publish',
    },
  ),
  'notification_response_time': AnalyticsEventSchema(
    when: 'Derived from a received/opened pair.',
    properties: <String>{
      'notification_type',
      'response_time_seconds',
      'response_time_minutes',
      'response_time_hours',
      'received_at',
      'opened_at',
      'delivery',
      'push_kind',
      'is_drop',
      'seconds_since_publish',
    },
  ),
  'notification_prompt_shown': AnalyticsEventSchema(
    when: 'A notification ask was displayed.',
    properties: <String>{'source', 'decision', 'os_status'},
  ),
  'notification_prompt_result': AnalyticsEventSchema(
    when: 'A notification ask resolved.',
    properties: <String>{'source', 'granted'},
  ),
  'qotd_notification_permission_requested': AnalyticsEventSchema(
    when: 'The QOTD-specific permission ask was made.',
  ),
  'qotd_notification_permission_result': AnalyticsEventSchema(
    when: 'The QOTD-specific permission ask resolved.',
    properties: <String>{'granted'},
  ),
  'question_subscription_notification_enabled': AnalyticsEventSchema(
    when: 'Per-question activity notifications were toggled.',
    properties: <String>{'enabled'},
  ),
  'push_topic_subscription': AnalyticsEventSchema(
    when: 'An FCM topic subscribe/unsubscribe attempt.',
    properties: <String>{'topic', 'result', 'trigger'},
    anonymous: true,
  ),

  // --------------------------------------------------------------- social
  'community_viewed': AnalyticsEventSchema(
    when: 'The Community tab was opened.',
    properties: <String>{'friend_count'},
  ),
  'friend_lookup': AnalyticsEventSchema(
    when: 'A handle was looked up. found/not_found only.',
    properties: <String>{'result'},
  ),
  'friend_request_sent': AnalyticsEventSchema(
    when: 'A friend request was sent.',
    properties: <String>{'method'},
  ),
  'friend_request_responded': AnalyticsEventSchema(
    when: 'A request was accepted, declined (incoming) or cancelled (outgoing).',
    properties: <String>{'accepted', 'direction', 'friend_count'},
  ),
  'friend_removed': AnalyticsEventSchema(
    when: 'A friend was removed.',
    properties: <String>{'friend_count'},
  ),
  'user_blocked': AnalyticsEventSchema(
    when: 'A user was blocked.',
    properties: <String>{'friend_count', 'surface'},
  ),
  'close_friend_set': AnalyticsEventSchema(
    when: 'A close-friend flag was flipped.',
    properties: <String>{'value', 'mutual', 'surface'},
  ),
  'friend_chat_opened': AnalyticsEventSchema(
    when: 'The friend chat overlay was opened.',
    properties: <String>{'unread'},
  ),
  'friend_lick_sent': AnalyticsEventSchema(
    when: 'A lick was sent.',
    properties: <String>{'surface'},
  ),
  'friend_lick_blocked': AnalyticsEventSchema(
    when: 'A lick was refused by the client-side cooldown.',
    properties: <String>{'reason', 'surface'},
  ),
  'friend_reaction_sent': AnalyticsEventSchema(
    when: 'A reaction was sent in chat. Never the emoji.',
  ),
  'friend_forward_sent': AnalyticsEventSchema(
    when: 'A question was forwarded to a friend.',
    properties: <String>{'source'},
  ),
  'friend_forward_opened': AnalyticsEventSchema(
    when: 'A forwarded question was opened.',
  ),
  'qr_shown': AnalyticsEventSchema(
    when: 'The friend QR dialog was shown. Surface from kQrSurfaces.',
    properties: <String>{'surface'},
  ),
  'qr_scanned': AnalyticsEventSchema(
    when: 'A friend QR was scanned.',
    properties: <String>{'result', 'already_friends'},
  ),

  // -------------------------------------------------------------- networks
  'network_card_shown': AnalyticsEventSchema(
    when: 'A "Your network" card was actually rendered. Never in demo mode.',
    properties: <String>{
      'state',
      'respondents_bucket',
      'friend_count_bucket',
      'question_type',
      'surface',
    },
    anonymous: true,
  ),
  'network_node_tapped': AnalyticsEventSchema(
    when: 'A node in the ego graph was opened. Never a handle or an id.',
    properties: <String>{'node_kind', 'has_answer', 'surface'},
    anonymous: true,
  ),
  'network_demo_cta_tapped': AnalyticsEventSchema(
    when: 'The sample-circle card\'s CTA was tapped.',
    properties: <String>{'surface', 'friend_count'},
  ),
  'network_demo_dismissed': AnalyticsEventSchema(
    when: 'The sample-circle card was dismissed.',
    properties: <String>{'surface', 'friend_count'},
  ),
  'network_not_enough_cta_tapped': AnalyticsEventSchema(
    when: 'The "send a lick" nudge was tapped.',
    properties: <String>{'surface', 'friend_count'},
    anonymous: true,
  ),
  'answer_sharing_changed': AnalyticsEventSchema(
    when: 'The per-answer close-friend flag was flipped, with its outcome.',
    properties: <String>{'shared', 'surface', 'result'},
    anonymous: true,
  ),

  // ---------------------------------------------------------- entry points
  'deeplink_opened': AnalyticsEventSchema(
    when: 'A deep link or widget tap opened the app. Kind from kDeepLinkKinds.',
    properties: <String>{'kind'},
  ),
  'join_beta_viewed': AnalyticsEventSchema(
    when: 'The join-beta surface was shown.',
    properties: <String>{'source'},
  ),
  'beta_link_tapped': AnalyticsEventSchema(
    when: 'A beta link was tapped.',
    properties: <String>{'platform'},
  ),
  'email_signup_submitted': AnalyticsEventSchema(
    when: 'The waitlist card was submitted. Never the address.',
    properties: <String>{'source', 'success'},
  ),

  // ------------------------------------------------------------- app store
  'app_review_requested': AnalyticsEventSchema(
    when: 'The OS review prompt was requested.',
    properties: <String>{'answered_count', 'request_number'},
  ),
  'app_review_skipped': AnalyticsEventSchema(
    when: 'The review prompt was not shown, and why.',
    properties: <String>{'reason'},
  ),

  // ----------------------------------------------------------------- guide
  'guide_opened': AnalyticsEventSchema(
    when: 'The guide was opened.',
    properties: <String>{'source'},
  ),
  'guide_closed': AnalyticsEventSchema(
    when: 'The guide was closed.',
    properties: <String>{'time_spent_seconds'},
  ),
  'guide_link_clicked': AnalyticsEventSchema(
    when: 'An outbound link in the guide was tapped.',
    properties: <String>{'link_name', 'source', 'url'},
  ),
  'guide_app_store_review_clicked': AnalyticsEventSchema(
    when: 'The store-review link in the guide was tapped.',
    properties: <String>{'source'},
  ),

  // ------------------------------------------------------------ app health
  'rpc_failed': AnalyticsEventSchema(
    when: 'A backend call failed. `action` is our verb, `reason` our code — '
        'never a server message.',
    properties: <String>{'action', 'reason'},
  ),
};
