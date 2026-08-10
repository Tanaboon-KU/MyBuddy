import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../../shared/utils/json_extractor.dart';
import 'repetition_guard.dart';
import 'tool_protocol.dart';

final class ModelTurnCollector {
  const ModelTurnCollector({
    required this.modelType,
    this.repetitionGuard = const RepetitionGuard(),
  });

  final ModelType modelType;
  final RepetitionGuard repetitionGuard;

  Future<ModelTurn> collect(Stream<ModelResponse> responses) async {
    final text = StringBuffer();
    final calls = <FunctionCallResponse>[];

    await for (final response in responses) {
      debugPrint('ModelTurnCollector: received response: $response');
      switch (response) {
        case TextResponse(:final token):
          text.write(token);
        case FunctionCallResponse():
          calls.add(response);
        case ParallelFunctionCallResponse(calls: final parallelCalls):
          calls.addAll(parallelCalls);
        case ThinkingResponse():
          break;
      }
    }

    if (calls.isNotEmpty) return ToolCallTurn(calls);

    final rawText = text.toString();

    // T-30. Measured and reported, deliberately not acted on.
    //
    // Two of E4's twenty-four replies ended in this collapse and the user read
    // the result. Truncating instead would decide two things this class should
    // not: what the user ought to see in place of a broken answer is a product
    // call, and trimming would change `reply_text`, the column E1 through E4
    // were every one of them scored from, so a later block could no longer be
    // set against them. Counting it first gives the rate on a build whose
    // replies still mean the same thing as the ones already measured.
    if (repetitionGuard.hasCollapsed(rawText)) {
      final ratio = repetitionGuard.distinctRatio(rawText);
      debugPrint(
        'REPLY_COLLAPSED chars=${rawText.length} '
        'distinct${repetitionGuard.gram}=${ratio?.toStringAsFixed(2)}',
      );
    }

    final parsed = FunctionCallParser.parseAll(rawText, modelType: modelType);
    if (parsed.isNotEmpty) return ToolCallTurn(parsed);

    final fallbackCalls = <FunctionCallResponse>[];
    for (final block in extractJsonBlocks(rawText)) {
      final call = FunctionCallParser.parse(block, modelType: modelType);
      if (call != null) fallbackCalls.add(call);
    }
    if (fallbackCalls.isNotEmpty) return ToolCallTurn(fallbackCalls);

    final cleaned = _cleanText(rawText);
    if (cleaned.isEmpty) return const EmptyTurn();
    if (_looksLikeToolCall(cleaned)) {
      return const MalformedToolTurn('invalid_tool_format');
    }
    return FinalTextTurn(cleaned);
  }

  bool _looksLikeToolCall(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('<tool_call') || lower.contains('<|tool_call')) {
      return true;
    }
    final trimmed = text.trimLeft();
    final startsStructured = trimmed.startsWith('{') || trimmed.startsWith('[');
    return startsStructured &&
        lower.contains('"name"') &&
        (lower.contains('"parameters"') || lower.contains('"arguments"'));
  }

  String _cleanText(String text) => text
      .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
      .replaceAll(RegExp(r'<end_of_turn>\s*$'), '')
      .replaceAll(RegExp(r'<\|im_end\|>\s*$'), '')
      .replaceAll(r'\n', '\n')
      .trim();
}
