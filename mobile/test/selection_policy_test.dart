import 'package:flutter_test/flutter_test.dart';
import 'package:pictoiq_mobile/selection_policy.dart';

KeepDecision _decide({
  List<String> ranked = const ['a', 'b', 'c'],
  Set<String> liked = const {},
  Set<String> disliked = const {},
  bool manualOnly = false,
  bool confident = true,
}) => decideKeepers(
  rankedIds: ranked,
  liked: liked,
  disliked: disliked,
  manualOnly: manualOnly,
  confident: confident,
);

void main() {
  test('keeps the top-ranked photo when nothing is marked', () {
    final decision = _decide();
    expect(decision.keepIds, {'a'});
    expect(decision.isUserChoice, isFalse);
    expect(decision.needsReview, isFalse);
    expect(decision.removals(['a', 'b', 'c']), ['b', 'c']);
  });

  test('an unconfident group is suggested but needs review', () {
    final decision = _decide(confident: false);
    expect(decision.keepIds, {'a'});
    expect(decision.needsReview, isTrue);
  });

  test('every thumbs-up photo is kept, never just one', () {
    final decision = _decide(liked: {'b', 'c'}, confident: false);
    expect(decision.keepIds, {'b', 'c'});
    expect(decision.isUserChoice, isTrue);
    expect(decision.needsReview, isFalse);
    expect(decision.removals(['a', 'b', 'c']), ['a']);
  });

  test('thumbs-up marks from other groups are ignored', () {
    final decision = _decide(liked: {'zzz'});
    expect(decision.keepIds, {'a'});
    expect(decision.isUserChoice, isFalse);
  });

  test('skips a disliked top photo', () {
    expect(_decide(disliked: {'a'}).keepIds, {'b'});
  });

  test('never removes every photo when all are disliked', () {
    final decision = _decide(disliked: {'a', 'b', 'c'});
    expect(decision.keepIds, {'a'});
    expect(decision.removals(['a', 'b', 'c']), ['b', 'c']);
  });

  test('manual-only mode selects nothing until the user picks', () {
    final untouched = _decide(manualOnly: true);
    expect(untouched.hasDecision, isFalse);
    expect(untouched.needsReview, isTrue);
    expect(untouched.removals(['a', 'b', 'c']), isEmpty);

    final picked = _decide(manualOnly: true, liked: {'c'});
    expect(picked.keepIds, {'c'});
    expect(picked.removals(['a', 'b', 'c']), ['a', 'b']);
  });

  test('an empty group has no decision', () {
    final decision = _decide(ranked: const []);
    expect(decision.hasDecision, isFalse);
    expect(decision.removals(const []), isEmpty);
  });
}
