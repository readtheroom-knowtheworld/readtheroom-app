// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class AnimatedSubmitButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final bool isLoading;
  final String buttonText;
  final String disabledText;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final EdgeInsetsGeometry? padding;

  const AnimatedSubmitButton({
    Key? key,
    required this.onPressed,
    required this.isLoading,
    this.buttonText = 'Submit Answer',
    this.disabledText = 'Cannot Submit',
    this.backgroundColor,
    this.foregroundColor,
    this.padding,
  }) : super(key: key);

  @override
  _AnimatedSubmitButtonState createState() => _AnimatedSubmitButtonState();
}

class _AnimatedSubmitButtonState extends State<AnimatedSubmitButton>
    with TickerProviderStateMixin {
  late AnimationController _progressController;
  late AnimationController _typewriterController;
  late Animation<double> _progressAnimation;
  
  String _displayText = '';
  static const String _loadingMessage = 'Submitting answer...';
  static const Duration _animationDuration = Duration(seconds: 2);
  static const Duration _typewriterDelay = Duration(milliseconds: 80);

  @override
  void initState() {
    super.initState();
    
    // Progress bar animation (3 seconds)
    _progressController = AnimationController(
      duration: _animationDuration,
      vsync: this,
    );
    
    _progressAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _progressController,
      curve: Curves.easeInOut,
    ));
    
    // Typewriter animation
    _typewriterController = AnimationController(
      duration: Duration(milliseconds: _loadingMessage.length * _typewriterDelay.inMilliseconds),
      vsync: this,
    );
    
    _typewriterController.addListener(_updateTypewriterText);
  }

  @override
  void dispose() {
    _progressController.dispose();
    _typewriterController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AnimatedSubmitButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.isLoading && !oldWidget.isLoading) {
      // Start loading animations
      _startLoadingAnimation();
    } else if (!widget.isLoading && oldWidget.isLoading) {
      // Reset animations
      _resetAnimations();
    }
  }

  void _startLoadingAnimation() {
    _progressController.reset();
    _typewriterController.reset();
    
    // Start both animations
    _progressController.forward();
    _typewriterController.forward();
  }

  void _resetAnimations() {
    _progressController.reset();
    _typewriterController.reset();
    setState(() {
      _displayText = '';
    });
  }

  void _updateTypewriterText() {
    final progress = _typewriterController.value;
    final targetLength = (_loadingMessage.length * progress).round();
    setState(() {
      _displayText = _loadingMessage.substring(0, targetLength);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = widget.onPressed != null && !widget.isLoading;
    final backgroundColor = widget.backgroundColor ?? theme.primaryColor;
    final foregroundColor = widget.foregroundColor ?? Colors.white;

    if (widget.isLoading) {
      return AnimatedBuilder(
        animation: _progressAnimation,
        builder: (context, child) {
          return Container(
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: backgroundColor.withOpacity(0.3)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  // Progress bar background
                  Container(
                    width: double.infinity,
                    height: double.infinity,
                    color: Colors.grey.withOpacity(0.1),
                  ),
                  // Animated progress bar
                  FractionallySizedBox(
                    widthFactor: _progressAnimation.value,
                    child: Container(
                      height: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            backgroundColor.withOpacity(0.3),
                            backgroundColor,
                          ],
                          stops: [0.0, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // Typewriter text overlay
                  Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              foregroundColor.withOpacity(0.8),
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            _displayText,
                            style: TextStyle(
                              color: foregroundColor,
                              fontWeight: FontWeight.w500,
                              fontSize: 16,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Blinking cursor effect
                        if (_displayText.length < _loadingMessage.length)
                          AnimatedBuilder(
                            animation: _typewriterController,
                            builder: (context, child) {
                              return Opacity(
                                opacity: (_typewriterController.value * 4) % 1 > 0.5 ? 1.0 : 0.3,
                                child: Text(
                                  '|',
                                  style: TextStyle(
                                    color: foregroundColor,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 16,
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    // Normal button state
    return ElevatedButton(
      onPressed: isEnabled ? widget.onPressed : null,
      style: ElevatedButton.styleFrom(
        padding: widget.padding ?? EdgeInsets.symmetric(vertical: 16),
        backgroundColor: isEnabled ? backgroundColor : Colors.grey,
        foregroundColor: foregroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        minimumSize: Size(double.infinity, 48),
      ),
      child: Text(
        isEnabled ? widget.buttonText : widget.disabledText,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}