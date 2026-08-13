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

  /// Used when a catalogue entry's `tokenBuffer` is not a usable reserve.
  /// Matches what every working entry resolves to today.
  static const int _defaultReserve = 512;

  final int templateSafetyTokens;

  /// How many tokens to hold back for the answer.
  ///
  /// Catalogue entries carry two different meanings under one name. Some hold
  /// the reserve itself (512); others hold the input limit (3584 against
  /// maxTokens 4096, which is the same window described from the other end).
  /// A value taking half the window or more cannot be a reserve - it would
  /// leave no more room for the question than for the answer - so it is read
  /// as the second kind and [_defaultReserve] is used instead.
  ///
  /// This replaces an exact match on `maxTokens - 512`, which rescued the one
  /// legacy value that happened to be in the catalogue and let every other
  /// entry fall through to `clamp(1, maxTokens - 1)`. Gemma3-1B-IT ships
  /// `tokenBuffer: 4096` and so got a 4,095-token reserve and an input limit
  /// of 1: it threw `inputTooLong` on any real prompt and could not chat at
  /// all. Qwen2.5-1.5B, which every experiment ran on, is unaffected - 3584
  /// resolved to 512 before and resolves to 512 now.
  int effectiveTokenBuffer({
    required int maxTokens,
    required int configuredTokenBuffer,
  }) {
    final half = maxTokens ~/ 2;
    final fallback = _defaultReserve < half ? _defaultReserve : half;
    if (configuredTokenBuffer <= 0 || configuredTokenBuffer >= half) {
      return fallback.clamp(1, maxTokens - 1);
    }
    return configuredTokenBuffer;
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
