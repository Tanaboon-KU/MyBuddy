import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/repetition_guard.dart';

/// Reads a captured sample with newlines normalised.
///
/// These are real device output committed to the repo, so git's autocrlf
/// decides whether they arrive with CRLF, which would change both the length
/// and the trigram counts depending on who checked the repo out.
String _fixture(String name) => File(
  'test/fixtures/$name',
).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  const guard = RepetitionGuard();

  group('the failures this was built from', () {
    test('flags the extraction runaway T-28 measured', () {
      // The real 5,438-character output from E1 block 2 run 01, the pass that
      // took 175,576 ms and then failed to parse.
      final text = _fixture('degenerate_extraction_output.txt');

      expect(text.length, 5438);
      expect(guard.hasCollapsed(text), isTrue);
      expect(guard.distinctRatio(text), lessThan(0.65));
    });

    test('flags the reply E4 pair 10 ended with', () {
      final text = _fixture('degenerate_reply.txt');

      expect(guard.hasCollapsed(text), isTrue);
      expect(guard.distinctRatio(text), lessThan(0.65));
    });

    test('does NOT flag the incoherent reply from E4 pair 6', () {
      // Deliberate, and the reason T-30 is not fully closed by this class.
      // Pair 6 degenerated into incoherence rather than repetition, scores
      // 0.79, and sits inside the range ordinary replies occupy. Pinned so
      // that anyone lowering the threshold to catch it sees this test fail and
      // has to think about the 22 good replies between 0.77 and 1.00 first.
      final text = _fixture('incoherent_reply.txt');

      expect(guard.hasCollapsed(text), isFalse);
      expect(guard.distinctRatio(text), greaterThan(0.70));
    });

    test('does not flag a long ordinary reply', () {
      // E4 pair 12's implicit reply: 1,591 characters of numbered advice, the
      // longest text scored as ordinary. Repetitive in shape - every item
      // opens the same way - which is what makes it the useful negative.
      final text = _fixture('coherent_long_reply.txt');

      expect(guard.hasCollapsed(text), isFalse);
      expect(guard.distinctRatio(text), greaterThan(0.75));
    });
  });

  group('boundaries', () {
    test('says nothing about text too short to judge', () {
      // "Your name is Nott." is a correct answer at 18 characters and has a
      // low distinct ratio for entirely innocent reasons.
      expect(guard.hasCollapsed('Your name is Nott.'), isFalse);
      expect(guard.distinctRatio('Your name is Nott.'), isNull);
      expect(guard.hasCollapsed(''), isFalse);
    });

    test('a single character repeated past the length floor collapses', () {
      expect(guard.hasCollapsed('a' * 300), isTrue);
    });

    test('judges the tail, not the whole string', () {
      // The case the window exists for: a sound reply that comes apart at the
      // end. Judging the whole thing would let the healthy part outvote it.
      final healthy = _fixture('coherent_long_reply.txt');
      expect(guard.hasCollapsed(healthy), isFalse);
      expect(guard.hasCollapsed('$healthy${'!%' * 150}'), isTrue);
    });

    test('a collapse scrolled out of the window is no longer reported', () {
      // Consequence of judging only the tail, written down rather than left to
      // be discovered: the guard answers "is it collapsing now", which is what
      // a caller watching a live stream needs.
      final recovered = '${'!%' * 150}${_fixture('coherent_long_reply.txt')}';
      expect(guard.hasCollapsed(recovered), isFalse);
    });
  });

  test('the threshold still separates every sample we have', () {
    // The calibration itself, so it fails loudly if a fixture is edited or the
    // constants are tuned without re-checking both sides.
    const positives = ['degenerate_extraction_output.txt', 'degenerate_reply.txt'];
    const negatives = ['coherent_long_reply.txt', 'incoherent_reply.txt'];

    for (final name in positives) {
      expect(guard.distinctRatio(_fixture(name)), lessThan(guard.minDistinctRatio),
          reason: name);
    }
    for (final name in negatives) {
      expect(guard.distinctRatio(_fixture(name)),
          greaterThan(guard.minDistinctRatio), reason: name);
    }
  });
}
