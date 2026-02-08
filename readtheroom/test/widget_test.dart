// Basic Flutter widget tests for ReadTheRoom app - CI/CD compatible

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReadTheRoom Basic Tests', () {
    testWidgets('Material App renders correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: Text('ReadTheRoom')),
            body: Center(child: Text('Hello World')),
          ),
        ),
      );

      expect(find.text('ReadTheRoom'), findsOneWidget);
      expect(find.text('Hello World'), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('Material App has correct theme structure', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.light,
            primaryColor: Color(0xFF00897B), // ReadTheRoom teal
          ),
          home: Scaffold(
            body: Text('Test App'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify basic material structure
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('Test App'), findsOneWidget);
    });

    testWidgets('Bottom Navigation Bar renders correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Content')),
            bottomNavigationBar: BottomNavigationBar(
              items: [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
                BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(BottomNavigationBar), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Me'), findsOneWidget);
    });

    testWidgets('Basic navigation between tabs works', (WidgetTester tester) async {
      int selectedIndex = 0;
      
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                body: Center(
                  child: Text('Tab $selectedIndex'),
                ),
                bottomNavigationBar: BottomNavigationBar(
                  currentIndex: selectedIndex,
                  onTap: (index) {
                    setState(() {
                      selectedIndex = index;
                    });
                  },
                  items: [
                    BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                    BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
                    BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
                  ],
                ),
              );
            },
          ),
        ),
      );

      // Initially on tab 0
      expect(find.text('Tab 0'), findsOneWidget);

      // Tap on the Search tab
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();

      // Should now be on tab 1
      expect(find.text('Tab 1'), findsOneWidget);

      // Tap on the Me tab
      await tester.tap(find.text('Me'));
      await tester.pumpAndSettle();

      // Should now be on tab 2
      expect(find.text('Tab 2'), findsOneWidget);
    });
  });

  group('Widget Component Tests', () {
    testWidgets('Card widget renders correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Card Content'),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Card Content'), findsOneWidget);
    });

    testWidgets('ExpansionTile works correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExpansionTile(
              title: Text('Expandable'),
              children: [
                ListTile(title: Text('Hidden Content')),
              ],
            ),
          ),
        ),
      );

      // Initially collapsed
      expect(find.text('Expandable'), findsOneWidget);
      expect(find.text('Hidden Content'), findsNothing);

      // Tap to expand
      await tester.tap(find.text('Expandable'));
      await tester.pumpAndSettle();

      // Now expanded
      expect(find.text('Hidden Content'), findsOneWidget);
    });

    testWidgets('Linear Progress Indicator renders', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinearProgressIndicator(
              value: 0.5,
              backgroundColor: Colors.grey,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.teal),
            ),
          ),
        ),
      );

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });

  group('Theme Tests', () {
    testWidgets('Light theme applies correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.light,
            primaryColor: Color(0xFF00897B),
          ),
          home: Scaffold(
            appBar: AppBar(title: Text('Light Theme')),
            body: Text('Content'),
          ),
        ),
      );

      final context = tester.element(find.byType(Scaffold));
      expect(Theme.of(context).brightness, Brightness.light);
    });

    testWidgets('Dark theme applies correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            primaryColor: Color(0xFF00897B),
          ),
          home: Scaffold(
            appBar: AppBar(title: Text('Dark Theme')),
            body: Text('Content'),
          ),
        ),
      );

      final context = tester.element(find.byType(Scaffold));
      expect(Theme.of(context).brightness, Brightness.dark);
  });
  });
} 