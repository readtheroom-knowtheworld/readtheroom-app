import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/results_surface.dart';

void main() {
  _borders();
  test('light: sections are the card colour, theme untouched', () {
    final t = ThemeData(brightness: Brightness.light, cardColor: Colors.white);
    expect(resultsSectionColor(t), Colors.white);
    expect(identical(resultsTheme(t), t), isTrue);
  });

  test('dark: sections take the ego graph tone and cards follow', () {
    final t = ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E0E0E));
    final tone = resultsSectionColor(t);
    expect(tone,
        Color.alphaBlend(Colors.white.withOpacity(0.04), const Color(0xFF0E0E0E)));
    final rt = resultsTheme(t);
    expect(rt.cardColor, tone);
    expect(rt.cardTheme.color, tone);
  });
}

void _borders() {
  test('dark: sections and cards carry the teal outline; light: none', () {
    final dark = ThemeData(
        brightness: Brightness.dark, primaryColor: const Color(0xFF00897B));
    final b = resultsSectionBorder(dark) as Border;
    expect(b.top.color, const Color(0xFF00897B).withOpacity(0.18));
    final shape = resultsTheme(dark).cardTheme.shape as RoundedRectangleBorder;
    expect(shape.side.color, const Color(0xFF00897B).withOpacity(0.18));
    expect(resultsSectionBorder(ThemeData(brightness: Brightness.light)),
        isNull);
  });
}
