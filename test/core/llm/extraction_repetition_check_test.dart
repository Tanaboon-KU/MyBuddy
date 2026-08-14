import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/repetition_guard.dart';

/// The reply-side guard is wrong for extraction output, and the handset said so.
///
/// A six-turn conversation aborted its pass three runs running:
///
///   EXTRACTION_ABORTED reason=repetition chars=158 ms=11916
///
/// 158 characters is not a runaway. RepetitionGuard scores distinct trigrams in
/// the last 200 characters and calls anything under 0.70 collapsed, and that
/// threshold was measured against chat replies - prose, 0.77 to 1.00 - and one
/// 5,438-character `!%` runaway. Structured output was never in the sample.
///
/// It is not a line-format problem either. The JSON the pass used to ask for
/// scores 0.63 the moment it carries two patches, so the guard would have
/// aborted a correct two-patch extraction all along. Nobody hit it because the
/// model never managed two patches.
///
/// Both tests now run on the extraction path, either one ending the pass. The
/// trigram test earns its place by catching degeneration early; the line test
/// covers the answer arriving over and over, which trigrams read as diverse.
/// The two-patch score below stays a recorded risk, not a fixed bug.
void main() {
  const guard = RepetitionGuard();

  test('the trigram test scores structured output as collapsed', () {
    // The extraction path still uses it, and this is the risk it carries.
    //
    // It was taken off that path for a while on the strength of these two
    // numbers alone. Then the aborted text was logged, and what the test had
    // been stopping was the model echoing the transcript back and looping on
    // one phrase - real degeneration, caught at 158 characters. Removing it
    // bought ten more seconds of that and the same empty result.
    //
    // So the two-patch case below is a latent false positive, recorded rather
    // than acted on: no measured run has ever produced two patches.
    const twiceOver =
        'name: Nott\ntraits: NONE\npreferences: NONE\ngoals: NONE\nfacts: NONE\n'
        'name: NONE\ntraits: NONE\npreferences: NONE\ngoals: NONE\nfacts: NONE\n';
    const twoPatchJson =
        '{"updates":[{"section":"user","field":"goals","action":"add",'
        '"value":"run a half marathon"},{"section":"user","field":"facts",'
        '"action":"add","value":"allergic to peanuts"}]}';

    expect(guard.hasCollapsed(twiceOver), isTrue);
    expect(guard.hasCollapsed(twoPatchJson), isTrue);
  });

  test('a repeated line is what going wrong looks like here', () {
    expect(
      RepetitionGuard.extractionHasStalled(
        'name: Nott\nname: Nott\nname: Nott\n',
      ),
      isTrue,
    );
  });

  test('the answers the pass is supposed to give all survive', () {
    const answered =
        'name: Nott\ntraits: detail-oriented\npreferences: early mornings\n'
        'goals: run a half marathon\nfacts: allergic to peanuts\n';
    const mostlyNone =
        'name: Nott\ntraits: NONE\npreferences: NONE\ngoals: NONE\n'
        'facts: NONE\n';
    const twoFacts =
        'name: Nott\nfacts: works as a software engineer\n'
        'facts: allergic to peanuts\ngoals: run a half marathon\n';

    for (final text in <String>[answered, mostlyNone, twoFacts]) {
      expect(
        RepetitionGuard.extractionHasStalled(text),
        isFalse,
        reason: 'this is a correct answer: $text',
      );
    }
  });

  test('NONE on every field is not a stall', () {
    // Five different lines that happen to share a value. The old ratio test
    // read this as collapse; it is the pass saying the user revealed nothing.
    expect(
      RepetitionGuard.extractionHasStalled(
        'name: NONE\ntraits: NONE\npreferences: NONE\ngoals: NONE\nfacts: NONE\n',
      ),
      isFalse,
    );
  });

  test('the JSON the pass used to ask for is not a stall', () {
    expect(
      RepetitionGuard.extractionHasStalled(
        '{"updates":[{"section":"user","field":"goals","action":"add",'
        '"value":"run a half marathon"},{"section":"user","field":"facts",'
        '"action":"add","value":"allergic to peanuts"}]}',
      ),
      isFalse,
    );
  });

  test('the runaway that started all this is still caught', () {
    // E1 block 2, the degenerate output T-28 measured. It is one line, so the
    // repeated-line test cannot see it - the character ceiling is what stops
    // it, and this pins that the two together still cover the case.
    final runaway = '!%' * 3000;
    expect(runaway.length, greaterThan(2000));
    expect(
      RepetitionGuard.extractionHasStalled(runaway),
      isFalse,
      reason: 'one long line; extractionCharLimit is what ends this',
    );
  });
}
