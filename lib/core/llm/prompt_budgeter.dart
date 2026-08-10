import 'package:flutter_gemma/flutter_gemma.dart';

final class PromptBudgetAssessment {
  const PromptBudgetAssessment({
    required this.inputTokens,
    required this.inputLimit,
    required this.effectiveTokenBuffer,
    required this.systemTokens,
  });

  final int inputTokens;
  final int inputLimit;
  final int effectiveTokenBuffer;

  /// What the composed system prompt alone costs, by the model's own tokenizer.
  ///
  /// Already computed as part of [inputTokens]; carried separately because §1c
  /// asks for the system prompt's own count and forbids estimating it, and
  /// [inputTokens] cannot answer that - it also carries
  /// [PromptBudgeter.templateSafetyTokens], the user's message and the whole
  /// replayed history. The 1,843 recorded in TASKS.md as "the prompt's token
  /// count" is an [inputTokens] reading, so it overstates the prompt by at
  /// least the 64-token safety margin plus that turn's user text.
  final int systemTokens;

  bool get fits => inputTokens <= inputLimit;
}

final class PromptBudgeter {
  const PromptBudgeter({this.templateSafetyTokens = 64});

  final int templateSafetyTokens;

  int effectiveTokenBuffer({
    required int maxTokens,
    required int configuredTokenBuffer,
  }) {
    if (configuredTokenBuffer == maxTokens - 512) return 512;
    return configuredTokenBuffer.clamp(1, maxTokens - 1);
  }

  Future<PromptBudgetAssessment> assess({
    required InferenceModelSession session,
    required int maxTokens,
    required int configuredTokenBuffer,
    required String systemText,
    required Iterable<Message> history,
    required String userText,
  }) async {
    final effectiveBuffer = effectiveTokenBuffer(
      maxTokens: maxTokens,
      configuredTokenBuffer: configuredTokenBuffer,
    );
    final systemTokens = await session.sizeInTokens(systemText);
    var inputTokens = templateSafetyTokens + systemTokens;
    inputTokens += await session.sizeInTokens(userText);
    for (final message in history) {
      inputTokens += await session.sizeInTokens(message.text);
      inputTokens += 4;
    }
    return PromptBudgetAssessment(
      inputTokens: inputTokens,
      inputLimit: maxTokens - effectiveBuffer,
      effectiveTokenBuffer: effectiveBuffer,
      systemTokens: systemTokens,
    );
  }
}
