// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();
  factory AnalyticsService() => _instance;
  AnalyticsService._internal();

  static const String _analyticsOptOutKey = 'analytics_opt_out';
  static const String _posthogApiKey = String.fromEnvironment('POSTHOG_API_KEY');
  static const String _posthogHost = String.fromEnvironment('POSTHOG_HOST', defaultValue: 'https://us.i.posthog.com');

  bool _isInitialized = false;
  bool _isOptedOut = false;
  String? _currentUserId;
  String? _deviceId;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _isOptedOut = prefs.getBool(_analyticsOptOutKey) ?? false;

      if (!_isOptedOut && !kDebugMode) {
        final config = PostHogConfig(_posthogApiKey);
        config.host = _posthogHost;
        config.captureApplicationLifecycleEvents = true;
        config.debug = kDebugMode;
        
        // Configure person profiles for cost optimization
        // Using identifiedOnly to capture anonymous events by default
        // and only create person profiles after identify/alias/group
        config.personProfiles = PostHogPersonProfiles.identifiedOnly;
        
        // Configure offline queue
        config.maxQueueSize = 1000; // Max events to store offline
        config.flushAt = 20; // Batch size for sending events
        config.flushInterval = Duration(seconds: 30); // How often to flush
        
        await Posthog().setup(config);
        _isInitialized = true;
        
        await _setDefaultSuperProperties();
      }
    } catch (e) {
      debugPrint('Failed to initialize analytics: $e');
    }
  }

  Future<void> _setDefaultSuperProperties() async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      await Posthog().register(
        'app_version', '0.9.0+59',
      );
      await Posthog().register(
        'platform', defaultTargetPlatform.toString().split('.').last,
      );
    } catch (e) {
      debugPrint('Failed to set super properties: $e');
    }
  }

  Future<void> identifyUser(String userId, Map<String, dynamic>? properties, [Map<String, dynamic>? propertiesSetOnce]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      _currentUserId = userId;
      final userProps = properties?.cast<String, Object>() ?? <String, Object>{};
      final userPropsOnce = propertiesSetOnce?.cast<String, Object>();
      await Posthog().identify(
        userId: userId, 
        userProperties: userProps,
        userPropertiesSetOnce: userPropsOnce,
      );
      
      if (_deviceId != null && _deviceId != userId) {
        await Posthog().alias(alias: userId);
      }
    } catch (e) {
      debugPrint('Failed to identify user: $e');
    }
  }

  Future<void> identifyAnonymousUser(String deviceId) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      _deviceId = deviceId;
      await Posthog().identify(userId: deviceId, userProperties: {
        'is_authenticated': false,
        'device_id': deviceId,
      });
    } catch (e) {
      debugPrint('Failed to identify anonymous user: $e');
    }
  }

  Future<void> setUserProperties(Map<String, dynamic> properties) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      final userProps = properties.cast<String, Object>();
      await Posthog().identify(userId: _currentUserId ?? _deviceId ?? '', userProperties: userProps);
    } catch (e) {
      debugPrint('Failed to set user properties: $e');
    }
  }

  Future<void> trackEvent(String eventName, [Map<String, dynamic>? properties, bool? processPersonProfile]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      final eventProps = properties?.cast<String, Object>() ?? <String, Object>{};
      
      // Add person profile processing flag if specified
      if (processPersonProfile != null) {
        eventProps['\$process_person_profile'] = processPersonProfile;
      }
      
      await Posthog().capture(eventName: eventName, properties: eventProps);
    } catch (e) {
      debugPrint('Failed to track event $eventName: $e');
    }
  }
  
  // Convenience method for tracking events without person profile processing
  Future<void> trackEventAnonymous(String eventName, [Map<String, dynamic>? properties]) async {
    await trackEvent(eventName, properties, false);
  }

  Future<void> trackScreenView(String screenName, [Map<String, dynamic>? properties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      final screenProperties = properties?.cast<String, Object>() ?? <String, Object>{};
      await Posthog().screen(screenName: screenName, properties: screenProperties);
    } catch (e) {
      debugPrint('Failed to track screen view $screenName: $e');
    }
  }

  // Onboarding funnel tracking
  Future<void> trackOnboardingStep(String stepName, int stepNumber, [Map<String, dynamic>? additionalProperties, bool? processPersonProfile]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'step_name': stepName,
      'step_number': stepNumber,
      ...?additionalProperties,
    };
    
    await trackEvent('onboarding_step', properties, processPersonProfile);
  }

  // Question interaction tracking
  Future<void> trackQuestionViewed(String questionId, String questionType, String category, String viewSource, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    // Track question revisit behavior
    final revisitData = await _trackQuestionRevisitBehavior(questionId);
    
    final properties = {
      'question_id': questionId,
      'question_type': questionType,
      'category': category,
      'view_source': viewSource,
      'view_count': revisitData['viewCount'],
      'is_revisit': revisitData['isRevisit'],
      'days_since_first_view': revisitData['daysSinceFirstView'],
      'time_since_last_view_minutes': revisitData['timeSinceLastViewMinutes'],
      ...?additionalProperties,
    };
    
    await trackEvent('question_viewed', properties);
    
    // Track specific revisit event if this is a return visit
    if (revisitData['isRevisit'] == true) {
      await trackQuestionRevisited(questionId, revisitData['viewCount'], {
        'days_since_first_view': revisitData['daysSinceFirstView'],
        'time_since_last_view_minutes': revisitData['timeSinceLastViewMinutes'],
        'question_type': questionType,
        'category': category,
        'view_source': viewSource,
      });
    }
  }
  
  // Phase 5: Question revisit behavior tracking
  Future<Map<String, dynamic>> _trackQuestionRevisitBehavior(String questionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      
      // Track view history for this question
      final viewHistoryKey = 'question_views_$questionId';
      final viewHistoryString = prefs.getString(viewHistoryKey);
      
      List<String> viewHistory = [];
      if (viewHistoryString != null) {
        viewHistory = List<String>.from(json.decode(viewHistoryString));
      }
      
      // Add current view
      viewHistory.add(now.toIso8601String());
      
      // Keep only last 10 views to prevent storage bloat
      if (viewHistory.length > 10) {
        viewHistory = viewHistory.sublist(viewHistory.length - 10);
      }
      
      // Save updated history
      await prefs.setString(viewHistoryKey, json.encode(viewHistory));
      
      // Calculate revisit metrics
      final viewCount = viewHistory.length;
      final isRevisit = viewCount > 1;
      
      int? daysSinceFirstView;
      int? timeSinceLastViewMinutes;
      
      if (viewHistory.isNotEmpty) {
        final firstView = DateTime.parse(viewHistory.first);
        daysSinceFirstView = now.difference(firstView).inDays;
        
        if (viewHistory.length > 1) {
          final lastView = DateTime.parse(viewHistory[viewHistory.length - 2]);
          timeSinceLastViewMinutes = now.difference(lastView).inMinutes;
        }
      }
      
      return {
        'viewCount': viewCount,
        'isRevisit': isRevisit,
        'daysSinceFirstView': daysSinceFirstView,
        'timeSinceLastViewMinutes': timeSinceLastViewMinutes,
      };
      
    } catch (e) {
      debugPrint('Failed to track question revisit behavior: $e');
      return {
        'viewCount': 1,
        'isRevisit': false,
        'daysSinceFirstView': 0,
        'timeSinceLastViewMinutes': null,
      };
    }
  }

  Future<void> trackQuestionAnswered(String questionId, String questionType, String answerType, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'question_id': questionId,
      'question_type': questionType,
      'answer_type': answerType,
      ...?additionalProperties,
    };
    
    await trackEvent('question_answered', properties);
  }

  Future<void> trackQuestionRevisited(String questionId, int viewCount, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'question_id': questionId,
      'view_count': viewCount,
      ...?additionalProperties,
    };
    
    await trackEvent('question_revisited', properties);
  }

  // Guide tracking
  Future<void> trackGuideOpened(String source, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'source': source,
      ...?additionalProperties,
    };
    
    await trackEvent('guide_opened', properties);
  }

  Future<void> trackGuideClosed(Duration timeSpent, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'time_spent_seconds': timeSpent.inSeconds,
      ...?additionalProperties,
    };
    
    await trackEvent('guide_closed', properties);
  }

  // Notification tracking
  Future<void> trackNotificationPermissionRequested() async {
    await trackEvent('notification_permission_requested');
  }

  Future<void> trackNotificationPermissionGranted(bool granted) async {
    await trackEvent('notification_permission_result', {'granted': granted});
  }

  Future<void> trackQotdNotificationPermissionRequested() async {
    await trackEvent('qotd_notification_permission_requested');
  }

  Future<void> trackQotdNotificationPermissionResult(bool granted) async {
    await trackEvent('qotd_notification_permission_result', {'granted': granted});
  }

  Future<void> trackQuestionSubscriptionNotificationEnabled(bool enabled) async {
    await trackEvent('question_subscription_notification_enabled', {'enabled': enabled});
  }

  Future<void> trackNotificationReceived(String notificationType, [Map<String, dynamic>? additionalProperties]) async {
    final properties = {
      'notification_type': notificationType,
      ...?additionalProperties,
    };
    
    await trackEvent('notification_received', properties);
    
    // Store notification received timestamp for effectiveness tracking
    try {
      final prefs = await SharedPreferences.getInstance();
      final receivedKey = 'notification_received_$notificationType';
      await prefs.setString(receivedKey, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('Failed to store notification received timestamp: $e');
    }
  }

  Future<void> trackNotificationOpened(String notificationType, [Map<String, dynamic>? additionalProperties]) async {
    final properties = {
      'notification_type': notificationType,
      ...?additionalProperties,
    };
    
    await trackEvent('notification_opened', properties);
    
    // Track notification effectiveness
    await _trackNotificationEffectiveness(notificationType, additionalProperties);
  }
  
  // Phase 5: Notification effectiveness tracking
  Future<void> _trackNotificationEffectiveness(String notificationType, Map<String, dynamic>? additionalProperties) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      
      // Track time between notification received and opened
      final receivedKey = 'notification_received_$notificationType';
      final receivedTimeString = prefs.getString(receivedKey);
      
      if (receivedTimeString != null) {
        final receivedTime = DateTime.parse(receivedTimeString);
        final timeDifference = now.difference(receivedTime);
        
        await trackEvent('notification_response_time', {
          'notification_type': notificationType,
          'response_time_seconds': timeDifference.inSeconds,
          'response_time_minutes': timeDifference.inMinutes,
          'response_time_hours': timeDifference.inHours,
          'received_at': receivedTimeString,
          'opened_at': now.toIso8601String(),
          ...?additionalProperties,
        });
        
        // Clear the received timestamp
        await prefs.remove(receivedKey);
      }
      
      // PostHog automatically tracks daily patterns, so we just track the effectiveness
      
    } catch (e) {
      debugPrint('Failed to track notification effectiveness: $e');
    }
  }

  Future<void> trackQotdSubscribed(bool subscribed) async {
    await trackEvent('qotd_subscription_changed', {'subscribed': subscribed});
    await setUserProperties({'qotd_subscribed': subscribed});
  }

  Future<void> trackQotdClicked(String questionId, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'question_id': questionId,
      'source': 'homepage',
      ...?additionalProperties,
    };
    
    await trackEvent('qotd_clicked', properties);
  }

  // Location tracking
  Future<void> trackLocationChanged(String locationType, String locationValue, [Map<String, dynamic>? additionalProperties]) async {
    final properties = {
      'location_type': locationType,
      'location_value': locationValue,
      ...?additionalProperties,
    };
    
    await trackEvent('location_changed', properties);
    await setUserProperties({
      'current_$locationType': locationValue,
    });
  }

  // App lifecycle - typically tracked anonymously for cost optimization
  Future<void> trackAppOpened([Map<String, dynamic>? additionalProperties, bool processPersonProfile = false]) async {
    await trackEvent('app_opened', additionalProperties, processPersonProfile);
    
    // Track session metrics for retention analysis
    await _trackSessionMetrics();
  }
  
  // Phase 5: Session and retention tracking
  Future<void> _trackSessionMetrics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      
      // Track returning user patterns
      final firstOpenDate = prefs.getString('first_app_open');
      if (firstOpenDate == null) {
        // First time user
        await prefs.setString('first_app_open', now.toIso8601String());
        await trackEvent('user_first_open', {
          'first_open_date': now.toIso8601String(),
        });
      } else {
        // Returning user - calculate retention metrics
        final firstOpen = DateTime.parse(firstOpenDate);
        final daysSinceFirst = now.difference(firstOpen).inDays;
        
        await trackEvent('user_return', {
          'days_since_first_open': daysSinceFirst,
          'first_open_date': firstOpenDate,
          'return_date': now.toIso8601String(),
        });
        
        // Track retention milestones (only once per milestone)
        final milestoneKey = 'retention_milestone_day_$daysSinceFirst';
        final alreadyTracked = prefs.getBool(milestoneKey) ?? false;
        
        if (!alreadyTracked) {
          if (daysSinceFirst == 1) {
            await trackEvent('retention_day_1', {'first_open_date': firstOpenDate});
            await prefs.setBool('retention_milestone_day_1', true);
          } else if (daysSinceFirst == 7) {
            await trackEvent('retention_day_7', {'first_open_date': firstOpenDate});
            await prefs.setBool('retention_milestone_day_7', true);
          } else if (daysSinceFirst == 28) {
            await trackEvent('retention_day_28', {'first_open_date': firstOpenDate});
            await prefs.setBool('retention_milestone_day_28', true);
          }
        }
      }
      
      // Update user properties with session info
      await setUserProperties({
        'last_session_start': now.toIso8601String(),
        'total_days_since_first_open': firstOpenDate != null ? now.difference(DateTime.parse(firstOpenDate)).inDays : 0,
      });
      
    } catch (e) {
      debugPrint('Failed to track session metrics: $e');
    }
  }

  Future<void> trackAppBackgrounded([bool processPersonProfile = false]) async {
    await trackEvent('app_backgrounded', null, processPersonProfile);
  }

  Future<void> trackAppResumed([bool processPersonProfile = false]) async {
    await trackEvent('app_resumed', null, processPersonProfile);
  }

  // Session management
  Future<void> reset() async {
    if (!_isInitialized) return;
    
    try {
      await Posthog().reset();
      _currentUserId = null;
    } catch (e) {
      debugPrint('Failed to reset analytics: $e');
    }
  }

  // Opt-out management
  Future<void> setOptOut(bool optOut) async {
    _isOptedOut = optOut;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_analyticsOptOutKey, optOut);
    
    if (optOut && _isInitialized) {
      await Posthog().disable();
    } else if (!optOut && _isInitialized) {
      await Posthog().enable();
    }
  }

  Future<bool> isOptedOut() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_analyticsOptOutKey) ?? false;
  }

  // Feature flags (if using PostHog feature flags)
  Future<bool> isFeatureEnabled(String featureKey) async {
    if (_isOptedOut || !_isInitialized) return false;
    
    try {
      return await Posthog().isFeatureEnabled(featureKey) ?? false;
    } catch (e) {
      debugPrint('Failed to check feature flag $featureKey: $e');
      return false;
    }
  }

  Future<dynamic> getFeatureFlagPayload(String featureKey) async {
    if (_isOptedOut || !_isInitialized) return null;
    
    try {
      return await Posthog().getFeatureFlagPayload(featureKey);
    } catch (e) {
      debugPrint('Failed to get feature flag payload $featureKey: $e');
      return null;
    }
  }

  // Flush events immediately (useful for critical events)
  Future<void> flush() async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      await Posthog().flush();
    } catch (e) {
      debugPrint('Failed to flush analytics: $e');
    }
  }
  
  // Get the current user's distinct ID
  Future<String?> getDistinctId() async {
    if (_isOptedOut || !_isInitialized) return null;
    
    try {
      return await Posthog().getDistinctId();
    } catch (e) {
      debugPrint('Failed to get distinct ID: $e');
      return null;
    }
  }
  
  // Phase 5: Feature adoption tracking
  Future<void> trackFeatureAdoption(String featureName, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final featureKey = 'feature_first_use_$featureName';
      final hasUsedBefore = prefs.getBool(featureKey) ?? false;
      
      if (!hasUsedBefore) {
        // This is the first time using this feature
        await prefs.setBool(featureKey, true);
        
        // Track first use event
        await trackEvent('feature_first_use', {
          'feature_name': featureName,
          'first_use_date': DateTime.now().toIso8601String(),
          ...?additionalProperties,
        });
        
        // Track feature adoption milestone
        await _trackFeatureAdoptionMilestone(featureName);
      }
      
      // Always track feature usage
      await trackEvent('feature_used', {
        'feature_name': featureName,
        'is_first_use': !hasUsedBefore,
        ...?additionalProperties,
      });
      
    } catch (e) {
      debugPrint('Failed to track feature adoption: $e');
    }
  }
  
  Future<void> _trackFeatureAdoptionMilestone(String featureName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Get list of features user has adopted
      final adoptedFeaturesString = prefs.getString('adopted_features');
      List<String> adoptedFeatures = [];
      if (adoptedFeaturesString != null) {
        adoptedFeatures = List<String>.from(json.decode(adoptedFeaturesString));
      }
      
      if (!adoptedFeatures.contains(featureName)) {
        adoptedFeatures.add(featureName);
        await prefs.setString('adopted_features', json.encode(adoptedFeatures));
        
        // Track adoption milestone
        await trackEvent('feature_adoption_milestone', {
          'feature_name': featureName,
          'total_features_adopted': adoptedFeatures.length,
          'adopted_features': adoptedFeatures,
        });
        
        // Update user properties
        await setUserProperties({
          'total_features_adopted': adoptedFeatures.length,
          'adopted_features': adoptedFeatures,
        });
      }
      
    } catch (e) {
      debugPrint('Failed to track feature adoption milestone: $e');
    }
  }
  
  // Convenience methods for specific features
  Future<void> trackLocationChangeAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('location_change', properties);
  }
  
  Future<void> trackPrivateQuestionAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('private_question', properties);
  }
  
  Future<void> trackCategoryFilterAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('category_filter', properties);
  }
  
  Future<void> trackFeedSwitchAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('feed_switch', properties);
  }
  
  Future<void> trackQuestionTypeAdoption(String questionType, [Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('question_type_$questionType', {
      'question_type': questionType,
      ...?properties,
    });
  }

  // Widget uptake tracking
  Future<void> trackWidgetUpdated(String widgetType, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('widget_updated', {
      'widget_type': widgetType,
      ...?additionalProperties,
    });

    // Track as feature adoption (first use tracking)
    await trackFeatureAdoption('widget_$widgetType');

    // Set user property so we can filter/breakdown by active widgets
    await _updateActiveWidgets(widgetType);
  }

  Future<void> _updateActiveWidgets(String widgetType) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activeWidgetsString = prefs.getString('active_widgets');
      List<String> activeWidgets = [];
      if (activeWidgetsString != null) {
        activeWidgets = List<String>.from(json.decode(activeWidgetsString));
      }

      if (!activeWidgets.contains(widgetType)) {
        activeWidgets.add(widgetType);
        await prefs.setString('active_widgets', json.encode(activeWidgets));
      }

      await setUserProperties({
        'active_widgets': activeWidgets,
        'has_streak_widget': activeWidgets.contains('streak'),
        'has_qotd_widget': activeWidgets.contains('qotd'),
      });
    } catch (e) {
      debugPrint('Failed to update active widgets: $e');
    }
  }

  // Theme mode tracking
  Future<void> trackThemeModeChanged(String themeMode) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('theme_mode_changed', {
      'theme_mode': themeMode,
    });

    await setUserProperties({
      'theme_mode': themeMode,
    });
  }
  
  // Enable analytics after opt-in
  Future<void> enable() async {
    try {
      await Posthog().enable();
      _isOptedOut = false;
    } catch (e) {
      debugPrint('Failed to enable analytics: $e');
    }
  }
  
  // Disable analytics for privacy
  Future<void> disable() async {
    try {
      await Posthog().disable();
      _isOptedOut = true;
    } catch (e) {
      debugPrint('Failed to disable analytics: $e');
    }
  }
}