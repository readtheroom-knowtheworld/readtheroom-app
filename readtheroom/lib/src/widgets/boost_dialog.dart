// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/boost_service.dart';

class BoostDialog {
  static void show(BuildContext context, Map<String, dynamic> question) {
    final boostService = Provider.of<BoostService>(context, listen: false);

    // Quick client-side eligibility check
    final eligibilityError = boostService.checkEligibility(question);
    if (eligibilityError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.orange,
          content: Text(
            BoostResult(success: false, error: eligibilityError).errorMessage,
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
      return;
    }

    final scaffoldContext = context;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.rocket_launch,
              color: Theme.of(dialogContext).primaryColor,
              size: 24,
            ),
            SizedBox(width: 12),
            Text('Boost Question'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nominate this for Question of the Day!',
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.titleSmall?.copyWith(
                height: 1.4,
              ),
            ),
            SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(dialogContext).dividerColor,
                ),
              ),
              child: Text(
                question['prompt'] ?? question['title'] ?? '',
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                ),
              ),
            ),
            SizedBox(height: 20),
            _buildBoostRule(dialogContext, Icons.today, 'You can boost 1 question per day'),
            SizedBox(height: 10),
            _buildBoostRule(dialogContext, Icons.person_off, 'You can\'t boost your own question'),
            SizedBox(height: 10),
            _buildBoostRule(dialogContext, Icons.calendar_month, 'Must be over 1 month old'),
            SizedBox(height: 10),
            _buildBoostRule(dialogContext, Icons.timelapse, 'At least 3 months since last boost'),
          ],
        ),
        actions: [
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: Theme.of(dialogContext).primaryColor,
                  ),
                ),
              ),
              Spacer(),
              ElevatedButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  final result = await boostService.boostQuestion(question['id'].toString());
                  if (scaffoldContext.mounted) {
                    ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                      SnackBar(
                        backgroundColor: result.success
                            ? Theme.of(scaffoldContext).primaryColor
                            : Colors.orange,
                        content: Text(
                          result.success
                              ? 'Question boosted! It may appear as a future Question of the Day.'
                              : result.errorMessage,
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: Text('Boost'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _buildBoostRule(BuildContext context, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          color: Theme.of(context).primaryColor,
          size: 20,
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}
