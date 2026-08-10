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
