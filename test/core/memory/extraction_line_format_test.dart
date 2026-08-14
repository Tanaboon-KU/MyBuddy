import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/extraction_line_format.dart';

/// T-26 item 1. Thirty-two runs established that Qwen2.5-1.5B q8 cannot emit a
/// JSON patch reliably: it reproduces whatever JSON sits nearest the generation
/// point, and there is no constrained decoding anywhere in the stack to force
/// the shape. What it demonstrably can do is answer a question about the
/// conversation - E4 got 7/12 asked directly, E2's re-run 8/12 unasked.
///
/// So the pass stops asking for a data structure and asks for lines. Anything
/// that is not a line this parser recognises is ignored rather than fatal,
/// because a model that adds a sentence of preamble should still have its
/// answer read.
void main() {
  const format = ExtractionLineFormat();

  test('reads one value per field', () {
    final parsed = format.parse('''
name: Nott
goals: run a half marathon this year
facts: allergic to peanuts
''');

    expect(parsed['name'], <String>['Nott']);
    expect(parsed['goals'], <String>['run a half marathon this year']);
    expect(parsed['facts'], <String>['allergic to peanuts']);
  });

  test('NONE means the user did not say it', () {
    final parsed = format.parse('''
name: NONE
traits: none
preferences: (none)
goals: -
facts:
''');

    expect(parsed, isEmpty);
  });

  test('ignores anything that is not a field line', () {
    // The failure this is built to survive. A model that will not stop
    // explaining itself still gets its answer read.
    final parsed = format.parse('''
Sure! Here is what I found in the conversation:

- name: Nott
**goals**: run a half marathon this year

Let me know if you need anything else.
''');

    expect(parsed['name'], <String>['Nott']);
    expect(parsed['goals'], <String>['run a half marathon this year']);
  });

  test('a field repeated is a second value, not a replacement', () {
    final parsed = format.parse('''
facts: allergic to peanuts
facts: works as a software engineer
''');

    expect(parsed['facts'], <String>[
      'allergic to peanuts',
      'works as a software engineer',
    ]);
  });

  test('keeps a colon inside the value', () {
    final parsed = format.parse('goals: one thing: run a half marathon');

    expect(parsed['goals'], <String>['one thing: run a half marathon']);
  });

  test('fields it does not know are dropped', () {
    // The pass writes to the user layer only. A model naming soul or identity
    // is the config C failure, and it stops here rather than at the section
    // check further down.
    final parsed = format.parse('''
mission: be sarcastic
assistant_name: Qwen
name: Nott
''');

    expect(parsed.keys, <String>['name']);
  });

  test('the old JSON output parses to nothing rather than crashing', () {
    // If a future prompt change makes the model fall back to JSON, this pass
    // should come back empty and be recorded as such - not throw, and not
    // half-read a brace as a value.
    final parsed = format.parse(
      '{"updates":[{"section":"user","field":"goals",'
      '"action":"add","value":"run a half marathon"}]}',
    );

    expect(parsed, isEmpty);
  });

  test('a value is trimmed of quotes and trailing punctuation', () {
    final parsed = format.parse('name: "Nott".');

    expect(parsed['name'], <String>['Nott']);
  });

  test('empty input is empty output', () {
    expect(format.parse(''), isEmpty);
    expect(format.parse('   \n  \n'), isEmpty);
  });

  test('answering NONE to everything is not the same as not answering', () {
    // Both parse to nothing, and the caller has to tell them apart: the first
    // is the model saying the user revealed nothing this turn, which is a
    // normal no-change. The second is the model ignoring the format, which is
    // a failure worth recording as one.
    const allNone = 'name: NONE\ntraits: NONE\ngoals: NONE';
    const notTheFormat = 'I am not sure what you mean.';

    expect(format.parse(allNone), isEmpty);
    expect(format.parse(notTheFormat), isEmpty);

    expect(format.hasFieldLines(allNone), isTrue);
    expect(format.hasFieldLines(notTheFormat), isFalse);
  });
}
