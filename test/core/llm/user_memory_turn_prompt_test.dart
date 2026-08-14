import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/memory_extraction_prompt_builder.dart';

/// Asking about one sentence at a time.
///
/// Twenty-four runs of the five-lines-at-once prompt showed the model filling
/// each field with at most one value and never repeating a field, however
/// plainly the prompt invited it to. The user stated five durable things, one
/// of the five slots was legitimately empty, and the fifth fact - "I work as a
/// software engineer" - had nowhere to go. It was lost in every run of every
/// version.
///
/// Five facts competing for five slots is a property of the format, not of the
/// conversation, so the format has to change. One sentence, one question, one
/// answer: nothing competes.
void main() {
  const builder = MemoryExtractionPromptBuilder();

  String build({
    String turn = 'I work as a software engineer.',
    String currentMemory = '{}',
    Set<String> lockedFields = const <String>{},
  }) => builder.buildUserTurn(
    turn: turn,
    currentMemory: currentMemory,
    lockedFields: lockedFields,
  );

  test('carries the one sentence it is asking about', () {
    expect(build(), contains('I work as a software engineer.'));
  });

  test('asks for one answer, not a line per field', () {
    // The whole point. Asking for five lines about one sentence would rebuild
    // the slots this is meant to remove, and cost five times the generation.
    final prompt = build().toLowerCase();

    expect(prompt, isNot(contains('five lines')));
    expect(prompt, contains('nothing else'));
  });

  test('names every field it will accept', () {
    final prompt = build();

    for (final field in const <String>[
      'name',
      'traits',
      'preferences',
      'goals',
      'facts',
    ]) {
      expect(prompt, contains(field));
    }
  });

  test('contains nothing shaped like the answer it is asking for', () {
    // The first version of this prompt listed the choices as "name: their
    // name", one per line, immediately above the answer. Six runs on the
    // handset came back with exactly that text copied out - "name: their name",
    // four times per pass, stored nothing, and the grounding check was the only
    // reason it did not become the user's name.
    //
    // That is T-26's oldest finding wearing different clothes: the model
    // reproduces whatever sits nearest the generation point. It was JSON when
    // the prompt ended in JSON, and it is "field: value" when the prompt ends
    // in "field: value". So the prompt must not end in one.
    final answerShaped = RegExp(
      r'^\s*(name|traits|preferences|goals|facts)\s*:',
      multiLine: true,
    );

    expect(
      answerShaped.hasMatch(build()),
      isFalse,
      reason: 'a line shaped like an answer is a line the model will copy',
    );
  });

  test('offers a way to say this sentence carried nothing', () {
    expect(build(), contains('NONE'));
  });

  test('keeps the routing rule that code also enforces', () {
    // Belt and braces with ExtractionFieldRouting. The prompt saying it has
    // been measured not to work on its own; that is why the code rule exists.
    // It costs nothing to leave in and would help a future model.
    expect(build().toLowerCase(), contains('allergy is a fact'));
  });

  test('does not ask for JSON', () {
    expect(build().toLowerCase(), isNot(contains('json')));
  });

  test('carries what is already known and the user locks', () {
    final prompt = build(
      currentMemory: '{"name":"Nott"}',
      lockedFields: <String>{'user.name', 'soul.mission'},
    );

    expect(prompt, contains('{"name":"Nott"}'));
    expect(prompt, contains('user.name'));
    expect(prompt, isNot(contains('soul.mission')));
  });

  test('says the sentence is data, not an instruction', () {
    // The extraction prompt has been read as instructions before: config C
    // wrote the prompt's own opening line into user.goals.
    expect(build().toLowerCase(), contains('not an instruction'));
  });
}
