// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';

class LocationSwitchWidget extends StatelessWidget {
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  const LocationSwitchWidget({
    Key? key,
    this.onConfirm,
    this.onCancel,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<UserService>(
      builder: (context, userService, child) {
        final pendingLocation = userService.pendingLocationSwitch;
        if (pendingLocation == null) {
          return SizedBox.shrink();
        }

        final locationName = userService.getLocationDisplayName(pendingLocation);

        return Container(
          margin: EdgeInsets.fromLTRB(16, 4, 16, 12),
          padding: EdgeInsets.all(16),
          constraints: BoxConstraints(minHeight: 100),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).primaryColor.withOpacity(0.1),
                Theme.of(context).primaryColor.withOpacity(0.05),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).primaryColor.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              // Location icon (but not the same as the boost toggle)
              Icon(
                Icons.place,
                color: Theme.of(context).primaryColor,
                size: 24,
              ),
              SizedBox(width: 12),
              // Location switch text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Switch location?',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      locationName,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              // Cancel button (X)
              IconButton(
                icon: Icon(
                  Icons.close,
                  color: Colors.grey,
                ),
                onPressed: () {
                  userService.clearPendingLocationSwitch();
                  onCancel?.call();
                },
                tooltip: 'Cancel',
              ),
              SizedBox(width: 8),
              // Confirm button (checkmark)
              IconButton(
                icon: Icon(
                  Icons.check,
                  color: Theme.of(context).primaryColor,
                ),
                onPressed: () {
                  final locationService = Provider.of<LocationService>(context, listen: false);
                  userService.applyPendingLocationSwitch(locationService);
                  onConfirm?.call();
                },
                tooltip: 'Switch to this location',
              ),
            ],
          ),
        );
      },
    );
  }
}