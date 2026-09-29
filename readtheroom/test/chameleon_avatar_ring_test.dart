import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/widgets/chameleon_avatar.dart';

void main() {
  Widget app(Widget child) => MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: Scaffold(body: Center(child: child)));

  testWidgets('close friends get a primary-colour ring at the same size',
      (tester) async {
    await tester.pumpWidget(app(const ChameleonAvatar(
        avatarId: null, size: 44, closeFriend: true)));
    expect(find.byKey(const ValueKey('close-friend-ring')), findsOneWidget);
    final box = tester.getSize(find.byType(ChameleonAvatar));
    expect(box, const Size(44, 44));
    final container = tester
        .widget<Container>(find.byKey(const ValueKey('close-friend-ring')));
    final border = (container.decoration as BoxDecoration).border as Border;
    expect(border.top.color, const Color(0xFF00897B));
  });

  testWidgets('regular friends have no ring', (tester) async {
    await tester.pumpWidget(
        app(const ChameleonAvatar(avatarId: null, size: 44)));
    expect(find.byKey(const ValueKey('close-friend-ring')), findsNothing);
    expect(tester.getSize(find.byType(ChameleonAvatar)), const Size(44, 44));
  });
}
