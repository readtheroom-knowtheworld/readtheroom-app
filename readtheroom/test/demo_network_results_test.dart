import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/models/network_graph.dart';
import 'package:read_the_room/src/services/demo/demo_friends_data.dart';
import 'package:read_the_room/src/services/demo/demo_network_results.dart';

void main() {
  for (final type in ['multiple_choice', 'approval_rating', 'text']) {
    test('$type: demo results are ungated, parse, and have a real graph', () {
      final r = buildDemoNetworkResults('q-$type', type);
      expect(r.available, isTrue);
      expect(r.gated, isFalse);
      expect(r.hasGraph, isTrue);
      expect(r.friendCount, greaterThanOrEqualTo(5));
      expect(r.respondents % r.k, 0, reason: 'quantised to k');
      final nodes = r.graph!.nodes;
      expect(nodes.where((n) => n.kind == NetworkNodeKind.self).length, 1);
      expect(nodes.where((n) => n.kind == NetworkNodeKind.closeFriend).length,
          1);
      final fofs = nodes.where((n) => n.kind == NetworkNodeKind.friendOfFriend);
      for (final f in fofs) {
        expect(f.parentId, startsWith('f_'));
        expect(f.handle, isNull);
      }
      // Regular friends never carry an answer, whatever the type.
      for (final n in nodes.where((n) => n.kind == NetworkNodeKind.friend)) {
        expect(n.hasAnswer, isFalse);
      }
      if (type == 'text') {
        for (final n in nodes) {
          expect(n.hasAnswer, isFalse, reason: 'text answers colour nothing');
        }
      }
    });
  }

  test('deterministic per question, different across questions', () {
    final a1 = buildDemoNetworkResultsJson('q-1', 'multiple_choice');
    final a2 = buildDemoNetworkResultsJson('q-1', 'multiple_choice');
    final b = buildDemoNetworkResultsJson('q-2', 'multiple_choice');
    expect(a1, equals(a2));
    expect(a1['graph'], isNot(equals(b['graph'])));
  });

  test('close-friend row is Curio only, coloured like the graph', () {
    final r = buildDemoNetworkResults('q-mc', 'multiple_choice');
    final row = buildDemoCloseFriendAnswers('q-mc', '');
    final curio = r.graph!.nodes
        .firstWhere((n) => n.kind == NetworkNodeKind.closeFriend);
    if (curio.hasAnswer) {
      expect(row, hasLength(1));
      expect(row.single.handle, '@${kDemoFriendHandles[kDemoCloseMutualId]}');
      expect(row.single.optionIndex, curio.optionIndex);
    } else {
      expect(row, isEmpty);
    }
  });

  test('answered counts cover every id and pass the gate', () {
    final c = buildDemoNetworkAnsweredCounts(['q-1', 'q-2']);
    expect(c.available, isTrue);
    expect(c.gatedAll, isFalse);
    expect(c.byQuestion.keys, containsAll(['q-1', 'q-2']));
  });
}
