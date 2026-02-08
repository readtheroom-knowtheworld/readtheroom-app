// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/widgets/location_filter_dialog.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/location_service.dart';

enum LocationFilterType {
  global,
  country,
  city,
}

class LocationFilterDialog extends StatelessWidget {
  final LocationFilterType currentFilter;
  final Function(LocationFilterType) onFilterSelected;

  const LocationFilterDialog({
    Key? key,
    required this.currentFilter,
    required this.onFilterSelected,
  }) : super(key: key);

  static Future<LocationFilterType?> show(
    BuildContext context,
    LocationFilterType currentFilter,
  ) {
    return showDialog<LocationFilterType>(
      context: context,
      builder: (context) => LocationFilterDialog(
        currentFilter: currentFilter,
        onFilterSelected: (filter) => Navigator.of(context).pop(filter),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LocationService>(
      builder: (context, locationService, child) {
        final hasCountry = locationService.selectedCountry != null;
        final hasCity = locationService.selectedCity != null;
        final countryName = locationService.selectedCountry ?? 'My Country';
        final cityName = locationService.selectedCity?['name'] ?? 'My City';

        return AlertDialog(
          title: Text('Feed Location Filter'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Global Option
              _buildFilterOption(
                context: context,
                type: LocationFilterType.global,
                icon: Icons.public,
                title: 'World',
                subtitle: 'Everything, everywhere',
                isSelected: currentFilter == LocationFilterType.global,
                isEnabled: true,
              ),
              SizedBox(height: 12),
              
              // Country Option
              _buildFilterOption(
                context: context,
                type: LocationFilterType.country,
                icon: Icons.flag,
                title: countryName,
                subtitle: hasCountry 
                    ? 'Questions addressed to your country'
                    : 'Tap to set your country',
                isSelected: currentFilter == LocationFilterType.country,
                isEnabled: hasCountry,
              ),
              SizedBox(height: 12),
              
              // City Option
              _buildFilterOption(
                context: context,
                type: LocationFilterType.city,
                icon: Icons.location_city,
                title: cityName,
                subtitle: hasCity 
                    ? 'Questions from nearby communities'
                    : 'Tap to set your city',
                isSelected: currentFilter == LocationFilterType.city,
                isEnabled: hasCity,
              ),
            ],
          ),
          actions: [
            Center(
              child: ElevatedButton(
                onPressed: () {
                  // Close the dialog first
                  Navigator.of(context).pop();
                  // Navigate to settings screen to set location
                  Navigator.pushNamed(context, '/settings');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: Text('Set New Location'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFilterOption({
    required BuildContext context,
    required LocationFilterType type,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isSelected,
    required bool isEnabled,
  }) {
    return InkWell(
      onTap: isEnabled 
          ? () => onFilterSelected(type)
          : () {
              // Close the dialog first
              Navigator.of(context).pop();
              // Navigate to settings screen to set location
              Navigator.pushNamed(context, '/settings');
            },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected 
                ? Theme.of(context).primaryColor
                : Theme.of(context).dividerColor,
            width: isSelected ? 2 : 1,
          ),
          color: isSelected 
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : Theme.of(context).colorScheme.surface,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 32,
              color: isSelected 
                  ? Theme.of(context).primaryColor 
                  : Theme.of(context).iconTheme.color,
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: isSelected 
                          ? Theme.of(context).primaryColor 
                          : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: !isEnabled 
                          ? Theme.of(context).primaryColor.withOpacity(0.8)
                          : Colors.grey.shade600,
                    ),
                    overflow: TextOverflow.visible,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).primaryColor,
              ),
          ],
        ),
      ),
    );
  }
}