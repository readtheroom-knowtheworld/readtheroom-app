// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'request_deduplication_service.dart';

/// Coordinates service initialization to prevent race conditions and duplicate work
/// This helps reduce startup time by sequencing expensive operations and sharing results
class InitializationCoordinator {
  static final InitializationCoordinator _instance = InitializationCoordinator._internal();
  factory InitializationCoordinator() => _instance;
  InitializationCoordinator._internal();

  // Track initialization state
  bool _isInitializing = false;
  bool _isInitialized = false;
  final Map<String, bool> _serviceInitializationStatus = {};
  final Map<String, Completer<void>> _serviceInitializationCompleters = {};
  
  // Shared expensive operations to avoid duplicate work
  final Map<String, dynamic> _sharedInitializationData = {};
  final RequestDeduplicationService _deduplicationService = RequestDeduplicationService();
  
  // Services that need coordinated initialization
  static const List<String> _initializationOrder = [
    'UserService',
    'LocationService', 
    'QuestionService',
    'WatchlistService',
    'NotificationService',
    'DeepLinkService',
  ];

  /// Main initialization method that coordinates all services
  Future<void> initializeServices({
    required Future<void> Function() initializeUserService,
    required Future<void> Function() initializeLocationService,
    required Future<void> Function() initializeQuestionService,
    required Future<void> Function() initializeWatchlistService,
    required Future<void> Function() initializeNotificationService,
    required Future<void> Function() initializeDeepLinkService,
  }) async {
    if (_isInitialized) {
      print('🔄 INIT COORDINATOR: Services already initialized');
      return;
    }
    
    if (_isInitializing) {
      print('⏳ INIT COORDINATOR: Initialization already in progress, waiting...');
      await _waitForInitialization();
      return;
    }

    _isInitializing = true;
    print('🚀 INIT COORDINATOR: Starting coordinated service initialization');
    
    try {
      // Initialize services in the specified order to minimize race conditions
      await _initializeServiceInOrder('UserService', initializeUserService);
      await _initializeServiceInOrder('LocationService', initializeLocationService);
      await _initializeServiceInOrder('QuestionService', initializeQuestionService);
      await _initializeServiceInOrder('WatchlistService', initializeWatchlistService);
      await _initializeServiceInOrder('NotificationService', initializeNotificationService);
      await _initializeServiceInOrder('DeepLinkService', initializeDeepLinkService);
      
      _isInitialized = true;
      print('✅ INIT COORDINATOR: All services initialized successfully');
    } catch (e) {
      print('❌ INIT COORDINATOR: Error during initialization: $e');
      throw e;
    } finally {
      _isInitializing = false;
      _completeAllWaitingServices();
    }
  }

  /// Initialize a specific service and track its completion
  Future<void> _initializeServiceInOrder(String serviceName, Future<void> Function() initializeFunction) async {
    print('🔧 INIT COORDINATOR: Initializing $serviceName...');
    final startTime = DateTime.now();
    
    try {
      await initializeFunction();
      _serviceInitializationStatus[serviceName] = true;
      final duration = DateTime.now().difference(startTime);
      print('✅ INIT COORDINATOR: $serviceName initialized in ${duration.inMilliseconds}ms');
    } catch (e) {
      _serviceInitializationStatus[serviceName] = false;
      print('❌ INIT COORDINATOR: Failed to initialize $serviceName: $e');
      rethrow;
    }
  }

  /// Wait for initialization to complete if it's already in progress
  Future<void> _waitForInitialization() async {
    while (_isInitializing && !_isInitialized) {
      await Future.delayed(Duration(milliseconds: 100));
    }
  }

  /// Complete all waiting service completers
  void _completeAllWaitingServices() {
    for (final completer in _serviceInitializationCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _serviceInitializationCompleters.clear();
  }

  /// Wait for a specific service to be initialized
  Future<void> waitForService(String serviceName) async {
    if (_serviceInitializationStatus[serviceName] == true) {
      return; // Already initialized
    }

    if (!_serviceInitializationCompleters.containsKey(serviceName)) {
      _serviceInitializationCompleters[serviceName] = Completer<void>();
    }

    return _serviceInitializationCompleters[serviceName]!.future;
  }

  /// Check if a specific service is initialized
  bool isServiceInitialized(String serviceName) {
    return _serviceInitializationStatus[serviceName] == true;
  }

  /// Check if all services are initialized
  bool get isInitialized => _isInitialized;

  /// Store shared data that multiple services might need during initialization
  void setSharedInitializationData(String key, dynamic data) {
    _sharedInitializationData[key] = data;
    print('💾 INIT COORDINATOR: Cached shared data for key: $key');
  }

  /// Get shared data that was cached during initialization
  T? getSharedInitializationData<T>(String key) {
    final data = _sharedInitializationData[key];
    if (data != null) {
      print('🎯 INIT COORDINATOR: Retrieved shared data for key: $key');
    }
    return data as T?;
  }

  /// Clear shared data (useful for logout or major state changes)
  void clearSharedData() {
    _sharedInitializationData.clear();
    _deduplicationService.clearCache();
    print('🧹 INIT COORDINATOR: Cleared all shared data');
  }

  /// Reset coordinator state (useful for testing or full restart)
  void reset() {
    _isInitializing = false;
    _isInitialized = false;
    _serviceInitializationStatus.clear();
    _serviceInitializationCompleters.clear();
    clearSharedData();
    print('🔄 INIT COORDINATOR: Reset complete');
  }

  /// Get initialization status for debugging
  Map<String, dynamic> getInitializationStatus() {
    return {
      'isInitializing': _isInitializing,
      'isInitialized': _isInitialized,
      'services': Map<String, bool>.from(_serviceInitializationStatus),
      'sharedDataKeys': _sharedInitializationData.keys.toList(),
    };
  }
}