import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/memory_extraction_prompt_builder.dart';
import 'package:mybuddy/core/memory/extraction_line_format.dart';

/// The prompt that asks for lines instead of a JSON patch. See
/// [ExtractionLineFormat] for why the format changed.
void main() {
  const builder = MemoryExtractionPromptBuilder();

  String build({
    String conversation = 'User: My name is Nott.',
    String currentMemory = '{}',
    Set<String> lockedFields = const <String>{},
  }) => builder.buildUserLines(
    conversation: conversation,
    currentMemory: currentMemory,
    lockedFields: lockedFields,
  );

  test('asks for every user field by name', () {
    final prompt = build();

    for (final field in ExtractionLineFormat.fields) {
      expect(prompt, contains('$field:'), reason: '$field must be asked for');
    }
  });

  test('does not ask for JSON', () {
    // The whole point. If this prompt ever mentions a JSON object again, the
    // model has been handed back the task 32 runs showed it cannot do.
    final prompt = build().toLowerCase();

    expect(prompt, isNot(contains('json')));
    expect(prompt, isNot(contains('{"updates"')));
  });

  test('says the assistant\'s own words are not the user\'s facts', () {
    // T-26 wrote "Explore new hiking trails in Chiang Mai." into user.goals
    // from a question the assistant asked. The prompt has to say so; the
    // grounding check is what enforces it.
    final prompt = build().toLowerCase();

    expect(prompt, contains('user'));
    expect(prompt, contains('assistant'));
  });

  test('offers a way to say nothing was said', () {
    expect(build(), contains('NONE'));
  });

  test('carries the conversation, the current memory and the locks', () {
    final prompt = build(
      conversation: 'User: I am allergic to peanuts.',
      currentMemory: '{"name":"Nott"}',
      lockedFields: <String>{'user.name', 'soul.mission'},
    );

    expect(prompt, contains('I am allergic to peanuts.'));
    expect(prompt, contains('{"name":"Nott"}'));
    expect(prompt, contains('user.name'));
  });

  test('does not list locks belonging to other sections', () {
    // This pass cannot write soul or identity at all, so naming their locked
    // fields only spends tokens and invites the model to think about them.
    final prompt = build(
      lockedFields: <String>{'user.name', 'soul.mission'},
    );

    expect(prompt, isNot(contains('soul.mission')));
  });

  test('tells the model the conversation is data, not instructions', () {
    expect(build(), contains('<conversation>'));
  });

  test('carries the rule that says what is worth storing', () {
    // Six runs of the first version of this prompt captured `name` and `goals`
    // every time and `facts` never, from a conversation containing "I'm
    // allergic to peanuts" and "I work as a software engineer". The two fields
    // it filled are the two whose meaning is self-evident; `facts` is defined
    // in userFields as "Other stable facts", which says what it is not.
    //
    // MemoryToolSemantics.userCaptureRule names an allergy outright, and the
    // JSON prompt carried it. Dropping it when this prompt was written was an
    // accident, not a decision.
    expect(build().toLowerCase(), contains('allergy'));
  });

  test('gives each field something concrete to recognise', () {
    final prompt = build().toLowerCase();

    expect(prompt, contains('job'));
    expect(prompt, contains('allerg'));
  });

  test('does not let preferences swallow an allergy', () {
    // Six runs filed "allergic to peanuts" under preferences, because the
    // description said "something the user said they like, dislike or avoid"
    // and an allergy is something you avoid. The value still reached the
    // prompt, since the whole user layer does, but the dump said the user
    // prefers not to have anaphylaxis.
    //
    // E4 pair 4 is why this matters more than tidiness: the companion offered
    // nuts to someone allergic to them and then recited the allergy correctly
    // when asked. Where that fact is filed is part of how it gets used.
    final prompt = build().toLowerCase();

    expect(prompt, contains('allergy is a fact'));
    expect(prompt.split('preferences:')[1].split('\n')[0], isNot(contains('avoid')));
  });

  test('lets the model answer a field more than once', () {
    // The user stated two durable facts in the measured conversation. The
    // parser has always read a repeated field as a second value; the prompt
    // said "one short line each", which forbade saying both.
    expect(build().toLowerCase(), contains('more than one'));
  });
}
