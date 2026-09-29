// The home-screen widget's "answered" state comes from the local answered
// list, because `responses` is anonymous and the server cannot say whether a
// given user answered.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/user_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('true only for an id in the persisted answered list', () async {
    SharedPreferences.setMockInitialValues({
      'answered_questions': json.encode([
        {'id': 'q-1', 'timestamp': '2026-09-19T10:00:00Z'},
      ]),
    });
    expect(await UserService.hasAnsweredLocally('q-1'), isTrue);
    expect(await UserService.hasAnsweredLocally('q-2'), isFalse);
  });

  test('false when nothing is stored or the store is corrupt', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await UserService.hasAnsweredLocally('q-1'), isFalse);
    SharedPreferences.setMockInitialValues({'answered_questions': 'not json'});
    expect(await UserService.hasAnsweredLocally('q-1'), isFalse);
  });
}
