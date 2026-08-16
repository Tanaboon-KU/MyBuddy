import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/prompt_budgeter.dart';

import 'fakes/fake_llm_platform.dart';

void main() {
  const budgeter = PromptBudgeter();

  test('normalizes legacy 4096/3584 buffer to 512', () {
    expect(
      budgeter.effectiveTokenBuffer(
        maxTokens: 4096,
        configuredTokenBuffer: 3584,
      ),
      512,
    );
    expect(
      budgeter.effectiveTokenBuffer(
        maxTokens: 4096,
        configuredTokenBuffer: 768,
      ),
      768,
    );
  });

  test('a buffer that swallows the window falls back to a usable reserve', () {
    // Gemma3-1B-IT ships tokenBuffer 4096 against maxTokens 4096. The rescue
    // branch matched only the exact value maxTokens - 512, so this entry fell
    // through to clamp(1, maxTokens - 1) and produced a 4,095-token reserve:
    // inputLimit 1. Every prompt longer than a single token threw
    // inputTooLong, so that model could not hold a conversation at all - a
    // catalogue value, not a capability of the model.
    expect(
      budgeter.effectiveTokenBuffer(
        maxTokens: 4096,
        configuredTokenBuffer: 4096,
      ),
      512,
    );
    // A reserve that takes at least half the window is not a reserve. 2048
    // would leave as much room for the answer as for everything being asked.
    expect(
      budgeter.effectiveTokenBuffer(
        maxTokens: 4096,
        configuredTokenBuffer: 2048,
      ),
      512,
    );
  });

  test('accounts for system history user and template reserve', () async {
    final platform = FakeLlmPlatform();
    final model = await platform.getActiveModel(
      maxTokens: 100,
      preferredBackend: PreferredBackend.cpu,
    );
    final session = await model.createSession();

    final result = await budgeter.assess(
      session: session,
      maxTokens: 100,
      configuredTokenBuffer: 20,
      systemText: 'one two three',
      history: <Message>[Message.text(text: 'four five', isUser: true)],
      userText: 'six seven',
    );

    expect(result.inputTokens, 75);
    expect(result.inputLimit, 80);
    expect(result.fits, isTrue);
  });

  test('reports the system prompt on its own, without the reserve', () async {
    // §1c wants the system prompt's own token count and forbids estimating it.
    // inputTokens cannot stand in: it also carries the 64-token template
    // reserve, the user's message and the history, which is how 1,843 came to
    // be recorded in TASKS.md as if it were the prompt's size.
    final platform = FakeLlmPlatform();
    final model = await platform.getActiveModel(
      maxTokens: 100,
      preferredBackend: PreferredBackend.cpu,
    );
    final session = await model.createSession();

    final result = await budgeter.assess(
      session: session,
      maxTokens: 100,
      configuredTokenBuffer: 20,
      systemText: 'one two three',
      history: <Message>[Message.text(text: 'four five', isUser: true)],
      userText: 'six seven',
    );

    expect(result.systemTokens, await session.sizeInTokens('one two three'));
    expect(result.systemTokens, lessThan(result.inputTokens));
  });
}
