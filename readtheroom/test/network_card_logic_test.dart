import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/network_card_logic.dart';
import 'package:read_the_room/src/widgets/network_demo_card.dart';

void main() {
  test('friend goal matches the demo card', () {
    expect(kNetworkMinFriends, kCircleFriendGoal);
  });

  test('under 5 friends always gets the sample network', () {
    expect(networkCardState(friendCount: 0, networkAnswered: null),
        NetworkCardState.demo);
    expect(networkCardState(friendCount: 4, networkAnswered: 4),
        NetworkCardState.demo);
  });

  test('a circle with too few answers gets the lick nudge', () {
    expect(networkCardState(friendCount: 5, networkAnswered: null),
        NetworkCardState.notEnoughAnswers);
    expect(networkCardState(friendCount: 9, networkAnswered: 2),
        NetworkCardState.notEnoughAnswers);
  });

  test('a circle with 3+ answers gets the real map', () {
    expect(networkCardState(friendCount: 5, networkAnswered: 3),
        NetworkCardState.realMap);
  });
}
