// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class OnboardingTouchingScope extends InheritedWidget {
  final bool isTouching;

  const OnboardingTouchingScope({
    Key? key,
    required this.isTouching,
    required Widget child,
  }) : super(key: key, child: child);

  static bool of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<OnboardingTouchingScope>();
    return scope?.isTouching ?? false;
  }

  @override
  bool updateShouldNotify(OnboardingTouchingScope oldWidget) =>
      isTouching != oldWidget.isTouching;
}

class OnboardingSlide extends StatefulWidget {
  final String title;
  final String description;
  final Widget? illustration;
  final VoidCallback? onNext;
  final String? buttonText;
  final bool showCurio;
  final Widget? customContent;

  const OnboardingSlide({
    Key? key,
    required this.title,
    required this.description,
    this.illustration,
    this.onNext,
    this.buttonText,
    this.showCurio = true,
    this.customContent,
  }) : super(key: key);

  @override
  State<OnboardingSlide> createState() => _OnboardingSlideState();
}

class _OnboardingSlideState extends State<OnboardingSlide> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewKey = GlobalKey();
  final GlobalKey _buttonKey = GlobalKey();
  bool _isScrollable = false;
  bool _buttonInViewport = false;
  bool _buttonClearOfPillZone = true;

  // Height of the pill area at the bottom of the slide (pill ≈ 32px + 2px inset
  // + a small safety margin). Any part of the button inside this zone is
  // considered "covered" by the pill.
  static const double _pillZoneHeight = 44.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollState());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _updateScrollState() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final scrollable = position.maxScrollExtent > 1.0;

    bool buttonInViewport = widget.onNext == null ? false : true;
    bool buttonClearOfPillZone = true;

    if (widget.onNext != null) {
      final buttonBox =
          _buttonKey.currentContext?.findRenderObject() as RenderBox?;
      final viewportBox =
          _scrollViewKey.currentContext?.findRenderObject() as RenderBox?;
      if (buttonBox != null &&
          buttonBox.hasSize &&
          viewportBox != null &&
          viewportBox.hasSize) {
        final buttonTop = buttonBox.localToGlobal(Offset.zero).dy;
        final buttonBottom = buttonTop + buttonBox.size.height;
        final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
        final viewportBottom = viewportTop + viewportBox.size.height;
        buttonInViewport =
            buttonTop < viewportBottom && buttonBottom > viewportTop;
        final pillZoneTop = viewportBottom - _pillZoneHeight;
        buttonClearOfPillZone =
            !buttonInViewport || buttonBottom <= pillZoneTop;
      }
    }

    if (scrollable != _isScrollable ||
        buttonInViewport != _buttonInViewport ||
        buttonClearOfPillZone != _buttonClearOfPillZone) {
      setState(() {
        _isScrollable = scrollable;
        _buttonInViewport = buttonInViewport;
        _buttonClearOfPillZone = buttonClearOfPillZone;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTouching = OnboardingTouchingScope.of(context);
    // Scroll hint: content overflows and the button (if any) isn't in the viewport at all.
    final showScrollHint = _isScrollable &&
        widget.onNext != null &&
        !_buttonInViewport;
    // Swipe hint: only when not touching, the scroll hint isn't visible, and
    // the pill wouldn't cover the button.
    final showSwipeHint =
        !isTouching && !showScrollHint && _buttonClearOfPillZone;

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _updateScrollState();
            return false;
          },
          child: SingleChildScrollView(
            key: _scrollViewKey,
            controller: _scrollController,
            padding: EdgeInsets.all(24.0),
            child: Column(
              children: [
                if (widget.showCurio) ...[
                  SizedBox(height: 20),
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.teal[50],
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/Curio_smiling_trans.png',
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.teal[100],
                            ),
                            child: Icon(
                              Icons.pets,
                              size: 50,
                              color: Colors.teal[600],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  SizedBox(height: 24),
                ],

                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).primaryColor,
                      ),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 16),

                Text(
                  widget.description,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        height: 1.5,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black,
                      ),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 32),

                widget.customContent ?? widget.illustration ?? Container(),

                SizedBox(height: 32),

                if (widget.onNext != null)
                  SizedBox(
                    key: _buttonKey,
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: widget.onNext,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        widget.buttonText ?? 'Next',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                SizedBox(height: 64),
              ],
            ),
          ),
        ),

        Positioned(
          bottom: 2,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: showScrollHint ? 1.0 : 0.0,
                duration: Duration(milliseconds: 200),
                child: _HintPill(
                  icon: Icons.keyboard_arrow_down,
                  label: 'Scroll for more',
                ),
              ),
            ),
          ),
        ),

        Positioned(
          bottom: 2,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: showSwipeHint ? 1.0 : 0.0,
                duration: Duration(milliseconds: 200),
                child: _HintPill(
                  icon: Icons.swipe_left,
                  label: 'Swipe to explore',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HintPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _HintPill({Key? key, required this.icon, required this.label})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
