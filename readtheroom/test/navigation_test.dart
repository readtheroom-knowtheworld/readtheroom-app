// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Navigation restructure tests (design doc §4.5): the Home / Community /
// Activity / Me tab order, the Home-only FAB, and the home archive link beneath
// the QotdHeroCard (v1.3 "Today" home replaces the pinned search pill).
//
// The Community tab's own content is covered by `community_screen_test.dart`
// (WP-E replaced the Phase 1 "coming soon" placeholder with the real friend
// graph); what is asserted here is only its position in the tab order and the
// guest state, which is all a navigation test should care about.
//
// MainScreen and HomeScreen hard-instantiate Supabase and require the full
// provider tree in initState/build, so they cannot be pumped in a unit test.
// Instead we assert the extracted tab-order constants (the real source of truth
// wired into MainScreen's BottomNavigationBar), widget-test the self-contained
// CommunityScreen, and verify the search-pill wiring against a faithful
// reconstruction using the shared kSearchHeroTag. See the report for the
// consciously-left gap (full MainScreen pump).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:read_the_room/src/screens/community_screen.dart';
import 'package:read_the_room/src/screens/main_screen.dart'
    show
        kMainTabLabels,
        kHomeTabIndex,
        kCommunityTabIndex,
        kActivityTabIndex,
        kMeTabIndex;
import 'package:read_the_room/src/services/friend_service.dart';
import 'package:read_the_room/src/widgets/email_signup_card.dart';
import 'package:read_the_room/src/services/profile_service.dart';
import 'package:read_the_room/src/screens/search_screen.dart' show kSearchHeroTag;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Bottom navigation tab order (source of truth)', () {
    test('tabs are Home / Community / Activity / Me in order', () {
      expect(kMainTabLabels, ['Home', 'Community', 'Activity', 'Me']);
    });

    test('Home is index 0 (FAB tab) and Activity is index 2 (badge tab)', () {
      expect(kHomeTabIndex, 0);
      expect(kActivityTabIndex, 2);
      expect(kMainTabLabels[kHomeTabIndex], 'Home');
      expect(kMainTabLabels[kActivityTabIndex], 'Activity');
    });

    // A scanned friend QR / friend link lands on the Community tab
    // (DeepLinkService._handleFriendLink), so this index is load-bearing.
    test('Community is index 1 — the friend deep-link landing tab', () {
      expect(kCommunityTabIndex, 1);
      expect(kMainTabLabels[kCommunityTabIndex], 'Community');
      expect(kMeTabIndex, 3);
    });
  });

  group('CommunityScreen in the tab position', () {
    /// A guest FriendService: `isAuthenticated` reads Supabase, which is not
    /// initialised here, so the screen takes its §5.2 sign-in path — exactly
    /// what a navigation test wants, since it needs no backend at all.
    Widget harnessedCommunity() => MultiProvider(
          providers: [
            ChangeNotifierProvider<FriendService>(
                create: (_) => FriendService(listenToAuth: false)),
            ChangeNotifierProvider<ProfileService>(
                create: (_) => ProfileService(listenToAuth: false)),
          ],
          child: const MaterialApp(home: CommunityScreen()),
        );

    testWidgets('renders as a self-contained tab with its app bar title',
        (tester) async {
      await tester.pumpWidget(harnessedCommunity());
      await tester.pumpAndSettle();

      expect(find.text('Community'), findsOneWidget); // app bar
      // Guests get the sign-in prompt only (§5.2).
      expect(find.text('Verify that you are a human'), findsOneWidget);
      // The Phase 1 placeholder is gone.
      expect(find.text('COMING SOON'), findsNothing);
      expect(find.text('DEMO'), findsNothing);
    });

    testWidgets('keeps the email signup card', (tester) async {
      await tester.pumpWidget(harnessedCommunity());
      await tester.pumpAndSettle();

      expect(find.text('Keep in touch'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Sign up'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('already-submitted state hides the email card entirely',
        (tester) async {
      // The thank-you copy shows once, right after signing up; on any later
      // visit the card is gone (2026-09-16).
      SharedPreferences.setMockInitialValues(
          {'community_email_submitted': true});
      await tester.pumpWidget(harnessedCommunity());
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining("You're on the list"), findsNothing);
      expect(find.text('Keep in touch'), findsNothing);
    });

    testWidgets('the email card is the shared EmailSignupCard', (tester) async {
      // Community and Join-the-beta must not drift: one widget, one
      // `subscribe_email` call, one persisted flag (2026-09-17).
      await tester.pumpWidget(harnessedCommunity());
      await tester.pumpAndSettle();

      expect(find.byType(EmailSignupCard), findsOneWidget);
    });

    testWidgets('the footer links into the beta', (tester) async {
      await tester.pumpWidget(harnessedCommunity());
      await tester.pumpAndSettle();

      expect(find.text('Join the beta'), findsOneWidget);
    });

    testWidgets('the beta link survives the card being hidden', (tester) async {
      // The link carries its own spacing precisely so it does not vanish with
      // the card once the user is already on the list.
      SharedPreferences.setMockInitialValues(
          {'community_email_submitted': true});
      await tester.pumpWidget(harnessedCommunity());
      await tester.pumpAndSettle();

      expect(find.text('Keep in touch'), findsNothing);
      expect(find.text('Join the beta'), findsOneWidget);
    });
  });

  group('Home archive link', () {
    // v1.3 refinement: the header archive IconButton is gone. Archive access is
    // now a "Browse the archive" text link BENEATH the QotdHeroCard, present in
    // every hero state so it's never stranded (HomeScreen._buildArchiveLink).
    // It still pushes the Archive (SearchScreen, source 'archive_icon') and
    // SearchScreen still owns kSearchHeroTag for its own text-search entry.
    test('SearchScreen still exposes the shared search hero tag', () {
      expect(kSearchHeroTag, 'home_search_bar');
    });

    testWidgets('archive link pushes a route on tap', (tester) async {
      // Faithful reconstruction of HomeScreen._buildArchiveLink (TextButton.icon
      // with the manage_search icon + "Browse the archive" label; the real tap
      // pushes SearchScreen with source 'archive_icon').
      var pushed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.manage_search, size: 20),
                  label: const Text('Browse the archive'),
                  onPressed: () {
                    pushed = true;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            const Scaffold(body: Text('archive-destination')),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Browse the archive'), findsOneWidget);
      expect(find.byIcon(Icons.manage_search), findsOneWidget);

      await tester.tap(find.text('Browse the archive'));
      await tester.pumpAndSettle();

      expect(pushed, isTrue);
      expect(find.text('archive-destination'), findsOneWidget);
    });
  });

  group('FAB visibility rule (Home tab only)', () {
    // Mirrors MainScreen: `if (_selectedIndex == kHomeTabIndex) <FAB>`.
    Widget harness(int selectedIndex) => MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                if (selectedIndex == kHomeTabIndex)
                  const Positioned(
                    bottom: 16,
                    right: 16,
                    child: FloatingActionButton(
                      onPressed: null,
                      child: Icon(Icons.create),
                    ),
                  ),
              ],
            ),
          ),
        );

    testWidgets('FAB shows on Home (index 0)', (tester) async {
      await tester.pumpWidget(harness(kHomeTabIndex));
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('FAB hidden on Community / Activity / Me', (tester) async {
      for (final index in [kCommunityTabIndex, kActivityTabIndex, kMeTabIndex]) {
        await tester.pumpWidget(harness(index));
        expect(find.byType(FloatingActionButton), findsNothing);
      }
    });
  });
}
