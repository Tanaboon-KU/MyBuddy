import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// T-12. RUNTIME POLICY has six rules and every one is about *writing* memory.
/// Nothing ever told the model to read the profile back.
///
/// E4 measured what that costs with the fact verifiably in the prompt: explicit
/// recall 7/12, applying it unasked 2/12. Three of the five explicit failures
/// were the model answering about itself — *"As an AI, I don't have personal
/// preferences"* to "when do I like to work", and a description of its own
/// persona to "how would you describe me".
///
/// Two changes, and both are aimed at something that was observed rather than
/// guessed at. The profile moves to the end, after the tool blocks, because
/// T-26 established this model reproduces whatever sits nearest the generation
/// point. And the rule about whose facts these are is repeated where the
/// profile is, because saying it once at the top demonstrably did not take.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService memory;

  const seeded = UserMemory(
    user: UserProfileMemory(
      name: 'Nott',
      preferences: <String>['Does not eat spicy food'],
    ),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    memory = MemoryService();
  });

  test('the tail carries the profile', () async {
    final tail = await memory.buildUserPromptTail(memory: seeded);

    expect(tail, contains('Nott'));
    expect(tail, contains('Does not eat spicy food'));
  });

  test('it says to use the profile, which nothing did before', () async {
    final tail = await memory.buildUserPromptTail(memory: seeded);

    expect(tail, contains('MUST use it'));
    expect(
      tail,
      contains('do not offer that thing at all'),
      reason: 'E4 pair 4 offered nuts to a user recorded as allergic to peanuts',
    );
  });

  test('it says whose facts these are', () async {
    // E4 pairs 6 and 12: asked what the *user* likes, the model answered about
    // itself. The prompt already said "you" means you and not the human, once,
    // near the top, ~7,000 characters earlier.
    final tail = await memory.buildUserPromptTail(memory: seeded);

    expect(tail, contains('This describes the human, not you.'));
    expect(tail, contains('"I", "me" and "my"'));
  });

  test('it says to admit ignorance rather than guess', () async {
    // The one thing E4 found the model already doing well - 0 fabrications
    // when asked directly - so the instruction has to protect it, not just
    // push for more use of the profile.
    final tail = await memory.buildUserPromptTail(memory: seeded);

    expect(tail, contains('say you do not know'));
  });

  test('the profile leaves the main block when the tail is used', () async {
    // Or it would appear twice, and the whole point is that one copy sits last.
    final without = await memory.buildSystemPrompt(
      memory: seeded,
      includeUserBlock: false,
    );

    expect(without, isNot(contains('Does not eat spicy food')));
    expect(without, isNot(contains('USER (Long-term User Profile)')));
    expect(without, contains('SOUL'), reason: 'the rest must be untouched');
    expect(without, contains('IDENTITY'));
  });

  test('the old arrangement still composes exactly as it did', () async {
    // The before half of the comparison has to stay reproducible: E1, E2, E3
    // and E4 were all collected with the profile inline.
    final inline = await memory.buildSystemPrompt(memory: seeded);

    expect(inline, contains('USER (Long-term User Profile)'));
    expect(inline, contains('Does not eat spicy food'));
  });
}
