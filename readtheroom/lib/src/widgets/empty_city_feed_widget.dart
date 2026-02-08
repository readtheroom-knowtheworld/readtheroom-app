// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/widgets/empty_city_feed_widget.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/location_service.dart';

class EmptyCityFeedWidget extends StatelessWidget {
  final VoidCallback? onSwitchToGlobal;
  
  const EmptyCityFeedWidget({Key? key, this.onSwitchToGlobal}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<LocationService>(
      builder: (context, locationService, child) {
        final cityName = locationService.selectedCity?['name'] ?? 'your city';
        
        return Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.location_city,
                size: 64,
                color: Colors.grey.shade400,
              ),
              SizedBox(height: 24),
              Text(
                'No local questions yet!',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              Text(
                'Be the first to ask a question in $cityName.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.grey.shade600,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 32),
              
              // Switch to Global feed button
              TextButton.icon(
                onPressed: onSwitchToGlobal,
                icon: Icon(Icons.public),
                label: Text('View Global'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).primaryColor,
                ),
              ),
              
              SizedBox(height: 24),
              
              // QR Code (exact same as app drawer)
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark 
                      ? Colors.black 
                      : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.grey.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: QrImageView(
                  data: 'https://readtheroom.site/#download',
                  version: QrVersions.auto,
                  size: 200.0,
                  backgroundColor: Theme.of(context).brightness == Brightness.dark 
                      ? Colors.black 
                      : Colors.white,
                  embeddedImage: AssetImage('assets/images/RTR-logo_Aug2025.png'),
                  embeddedImageStyle: QrEmbeddedImageStyle(
                    size: Size(40, 40),
                    color: Theme.of(context).brightness == Brightness.dark 
                        ? Colors.white 
                        : Colors.black,
                  ),
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.circle,
                    color: Colors.grey,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.circle,
                    color: Colors.grey,
                  ),
                ),
              ),
              SizedBox(height: 8),
              Text(
                'readtheroom.site/#download',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  fontSize: 10,
                ),
              ),
              
              SizedBox(height: 24),
              Text(
                'Share this QR code to help others find and join your local community.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      },
    );
  }
}