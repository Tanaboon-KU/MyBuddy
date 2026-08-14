import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/extraction_grounding.dart';

void main() {
  const grounding = ExtractionGrounding();

  // The five turns of the T-26 "no goal" runs (ng1, ng2, ng3), verbatim. The
  // user never states a goal anywhere in them.
  const noGoalTurns = <String>[
    'My name is Nott.',
    'I love hiking on weekends.',
    'I work as a software engineer.',
    "I'm allergic to peanuts.",
    'I live in Chiang Mai.',
  ];

  // The five turns of the runs that extracted correctly.
  const goalTurns = <String>[
    'My name is Nott.',
    'I love hiking on weekends.',
    'I work as a software engineer.',
    "I'm allergic to peanuts.",
    'My goal this year is to run a half marathon.',
  ];

  test('rejects the goal the model invented in ng1, ng2 and ng3', () {
    // Written to user.goals on all three runs, from a conversation where the
    // user never mentioned a goal. "Explore new trails" came out of the
    // assistant's own question; only "hiking" and "Chiang Mai" came from the
    // user, and from two different turns.
    expect(
      grounding.isGrounded('Explore new hiking trails in Chiang Mai.', noGoalTurns),
      isFalse,
    );
  });

  test('keeps the goal the model extracted correctly on fifteen runs', () {
    expect(
      grounding.isGrounded('run a half marathon this year', goalTurns),
      isTrue,
    );
    expect(grounding.isGrounded('run a half marathon', goalTurns), isTrue);
  });

  test('scores against one turn, not the turns joined together', () {
    // The whole point of the ng case: every content word of the invented goal
    // can be found somewhere across the conversation, but no single thing the
    // user said carries them together. Joining the turns first would score this
    // 0.50 and let a threshold through that per-turn scoring stops at 0.33.
    expect(
      grounding.score('Explore new hiking trails in Chiang Mai.', noGoalTurns),
      lessThan(0.5),
    );
  });

  test('keeps a human paraphrase of what the user said', () {
    // The twelve values E4 seeded are paraphrases a person wrote from the
    // twelve E2 sentences. They are what a working extraction would produce, so
    // the rule has to keep them. These two are the weakest of the twelve, both
    // 0.75: "gets" against "get", and "saving" against "save".
    expect(
      grounding.isGrounded('Gets anxious in large groups', const <String>[
        'I get anxious in large groups.',
      ]),
      isTrue,
    );
    expect(
      grounding.isGrounded('Saving money for a trip to Japan', const <String>[
        'I want to save money for a trip to Japan.',
      ]),
      isTrue,
    );
  });

  test('an inflected form still counts as the word the user said', () {
    expect(
      grounding.isGrounded('Works as a software engineer', const <String>[
        'I work as a software engineer.',
      ]),
      isTrue,
    );
  });

  test('keeps what the pass actually produced on the handset', () {
    // Measured, not imagined. Six runs of the line format produced these five
    // values, and an earlier version of this rule threw the first one away
    // three times out of three: the user said "I love hiking on weekends", the
    // pass wrote "loving to hike on weekends", and neither `love`/`loving` nor
    // `hike`/`hiking` is a prefix of the other. A true statement by the user,
    // refused.
    //
    // The threshold cannot come down to fix it - the invented goal scores 0.33
    // and would come with it - so the words have to match better.
    expect(
      grounding.isGrounded('loving to hike on weekends', goalTurns),
      isTrue,
      reason: 'love/loving and hike/hiking are the same words',
    );
    expect(
      grounding.isGrounded('running a half marathon', goalTurns),
      isTrue,
      reason: 'run/running is the same word',
    );
    expect(grounding.isGrounded('allergic to peanuts', goalTurns), isTrue);
    expect(grounding.isGrounded('lives in Chiang Mai', noGoalTurns), isTrue);
    expect(
      grounding.isGrounded('loves hiking on weekends', noGoalTurns),
      isTrue,
    );
  });

  test('matching words better does not let the invented goal back in', () {
    // The check that keeps the fix honest. Every relaxation of the comparison
    // has to be measured against this one value, which is the only fabrication
    // the project has actually recorded.
    expect(
      grounding.score('Explore new hiking trails in Chiang Mai.', noGoalTurns),
      lessThan(ExtractionGrounding.defaultThreshold),
    );
  });

  test('a value with nothing to check is not treated as grounded', () {
    // All stopwords, or empty. Nothing here came from the user in any
    // meaningful sense, and a 0/0 that scored 1.0 would wave it through.
    expect(grounding.isGrounded('', goalTurns), isFalse);
    expect(grounding.isGrounded('to the it', goalTurns), isFalse);
  });

  test('no user turns means nothing can be grounded', () {
    expect(
      grounding.isGrounded('run a half marathon', const <String>[]),
      isFalse,
    );
  });
}
