// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../utils/haptic_utils.dart';

class ApprovalSlider extends StatefulWidget {
  final double initialValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final bool enabled;

  const ApprovalSlider({
    Key? key,
    this.initialValue = 0.0,
    required this.onChanged,
    this.onChangeEnd,
    this.enabled = true,
  }) : super(key: key);

  @override
  State<ApprovalSlider> createState() => _ApprovalSliderState();
}

class _ApprovalSliderState extends State<ApprovalSlider> {
  late double _sliderValue;
  int _lastHapticZone = 0;

  @override
  void initState() {
    super.initState();
    _sliderValue = widget.initialValue;
  }

  Widget _getIconForValue(double value) {
    if (value <= -0.8) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.thumb_down, color: Colors.red, size: 24),
          SizedBox(width: 2),
          Icon(Icons.thumb_down, color: Colors.red, size: 24),
        ],
      );
    } else if (value <= -0.3) {
      return Icon(Icons.thumb_down, color: Colors.red[200], size: 24);
    } else if (value <= 0.3) {
      return Icon(Icons.sentiment_neutral, color: Colors.grey[600], size: 24);
    } else if (value <= 0.8) {
      return Icon(Icons.thumb_up, color: Colors.green[200], size: 24);
    } else {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.thumb_up, color: Colors.green, size: 24),
          SizedBox(width: 2),
          Icon(Icons.thumb_up, color: Colors.green, size: 24),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final binEdges = [-0.8, -0.3, 0.3, 0.8];

    return Column(
      children: [
        // Bin markers above the slider
        LayoutBuilder(
          builder: (context, constraints) {
            final sliderWidth = constraints.maxWidth - 48;

            return Container(
              height: 12,
              child: Stack(
                children: [
                  ...binEdges.map((edge) {
                    final position = (edge + 1.0) / 2.0;
                    final leftOffset = 24 + (position * sliderWidth);

                    return Positioned(
                      left: leftOffset - 1,
                      child: Container(
                        width: 2,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.grey[600],
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    );
                  }).toList(),
                ],
              ),
            );
          },
        ),

        // The actual slider
        Slider(
          value: _sliderValue,
          min: -1.0,
          max: 1.0,
          divisions: 100,
          onChanged: widget.enabled
              ? (value) {
                  final distanceFromCenter = value.abs();

                  int currentZone;
                  if (distanceFromCenter >= 0.8) {
                    currentZone = 2;
                  } else if (distanceFromCenter >= 0.3) {
                    currentZone = 1;
                  } else {
                    currentZone = 0;
                  }

                  if (currentZone > _lastHapticZone) {
                    if (currentZone == 2) {
                      AppHaptics.mediumImpact();
                    } else if (currentZone == 1) {
                      AppHaptics.lightImpact();
                    }
                  }
                  _lastHapticZone = currentZone;

                  setState(() {
                    _sliderValue = value;
                  });
                  widget.onChanged(value);
                }
              : null,
          onChangeEnd: widget.enabled ? widget.onChangeEnd : null,
        ),

        // Current selection icon
        SizedBox(height: 12),
        _getIconForValue(_sliderValue),
      ],
    );
  }
}
