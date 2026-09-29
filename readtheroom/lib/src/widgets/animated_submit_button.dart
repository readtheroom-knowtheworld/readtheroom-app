// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// Handle that lets callers fire an [AnimatedSubmitButton] programmatically —
/// the tap-to-submit flows (MC option tap, approval slider release) need the
/// button to *visibly* play its press + progress animation rather than
/// duplicating it.
///
/// Usage: keep one per button (`final _c = AnimatedSubmitButtonController();`),
/// pass it via `controller:`, dispose it with the State, and call
/// `_c.trigger()` from the shortcut gesture. `trigger()` is a no-op when the
/// button is disabled (`onPressed == null`), already loading, or unmounted, so
/// taps during an in-flight submission are ignored for free.
class AnimatedSubmitButtonController extends ChangeNotifier {
  _AnimatedSubmitButtonState? _state;

  void _attach(_AnimatedSubmitButtonState state) => _state = state;

  void _detach(_AnimatedSubmitButtonState state) {
    if (_state == state) _state = null;
  }

  /// Whether a trigger would currently do anything.
  bool get canTrigger => _state?._canTrigger ?? false;

  /// Play the press animation and invoke the button's `onPressed`, exactly as
  /// if the user had tapped it.
  void trigger() => _state?._triggerFromController();
}

class AnimatedSubmitButton extends StatefulWidget {
  /// The height this button renders at, in both its enabled and loading
  /// states, with the default padding (`EdgeInsets.symmetric(vertical:
  /// 16)`) that every current call site uses and the standard 16px/w500
  /// button text. The loading state is pinned to this same value (rather
  /// than its own hardcoded number) so the button doesn't resize the moment
  /// a submit starts, and anything placed beside the button on the same row
  /// — e.g. [ShareWithCloseFriendsToggle] — should read this constant too,
  /// rather than hardcoding a number, so the two never drift apart.
  static const double height = 55.0;

  final VoidCallback? onPressed;
  final bool isLoading;
  final String buttonText;
  final String disabledText;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final EdgeInsetsGeometry? padding;

  /// Optional handle for programmatic triggering (see
  /// [AnimatedSubmitButtonController]).
  final AnimatedSubmitButtonController? controller;

  const AnimatedSubmitButton({
    Key? key,
    required this.onPressed,
    required this.isLoading,
    this.buttonText = 'Submit Answer',
    this.disabledText = 'Cannot Submit',
    this.backgroundColor,
    this.foregroundColor,
    this.padding,
    this.controller,
  }) : super(key: key);

  @override
  _AnimatedSubmitButtonState createState() => _AnimatedSubmitButtonState();
}

class _AnimatedSubmitButtonState extends State<AnimatedSubmitButton>
    with TickerProviderStateMixin {
  late AnimationController _progressController;
  late AnimationController _typewriterController;
  late AnimationController _pressController;
  late Animation<double> _progressAnimation;
  late Animation<double> _pressScale;

  String _displayText = '';
  static const String _loadingMessage = 'Submitting answer...';
  static const Duration _animationDuration = Duration(seconds: 2);
  static const Duration _typewriterDelay = Duration(milliseconds: 80);
  static const Duration _pressDuration = Duration(milliseconds: 110);

  @override
  void initState() {
    super.initState();

    widget.controller?._attach(this);

    // Press feedback (also used when triggered programmatically, so a
    // tap-to-submit gesture visibly "presses" the button).
    _pressController = AnimationController(
      duration: _pressDuration,
      vsync: this,
    );
    _pressScale = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );

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
    widget.controller?._detach(this);
    _progressController.dispose();
    _typewriterController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  /// Whether [AnimatedSubmitButtonController.trigger] would do anything.
  bool get _canTrigger =>
      mounted && !widget.isLoading && widget.onPressed != null;

  /// Play the press animation, then invoke `onPressed` — the programmatic
  /// equivalent of a user tap. Ignored while a submission is in flight.
  void _triggerFromController() {
    if (!_canTrigger) return;
    final onPressed = widget.onPressed!;
    _pressController.forward().then((_) {
      if (mounted) _pressController.reverse();
    });
    onPressed();
  }

  @override
  void didUpdateWidget(AnimatedSubmitButton oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }

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
    return AnimatedBuilder(
      animation: _pressScale,
      builder: (context, child) => Transform.scale(
        scale: _pressScale.value,
        child: child,
      ),
      child: _buildButton(context),
    );
  }

  Widget _buildButton(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = widget.onPressed != null && !widget.isLoading;
    final backgroundColor = widget.backgroundColor ?? theme.primaryColor;
    final foregroundColor = widget.foregroundColor ?? Colors.white;

    if (widget.isLoading) {
      return AnimatedBuilder(
        animation: _progressAnimation,
        builder: (context, child) {
          return Container(
            height: AnimatedSubmitButton.height,
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
        minimumSize: Size(double.infinity, AnimatedSubmitButton.height),
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