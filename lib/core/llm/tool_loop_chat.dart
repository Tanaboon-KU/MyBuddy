import 'package:flutter_gemma/flutter_gemma.dart';

import 'tool_protocol.dart';

abstract interface class ToolLoopChat {
  Stream<ModelResponse> generate();

  Future<void> addToolResults(List<ToolExecutionResult> results);

  Future<void> addProtocolFeedback(Map<String, Object?> feedback);
}

final class InferenceToolLoopChat implements ToolLoopChat {
  InferenceToolLoopChat(
    this.chat, {
    required this.generationTimeout,
    this.onFirstToken,
  });

  final InferenceChat chat;
  final Duration generationTimeout;

  /// Fired once, when the model emits its first chunk.
  ///
  /// This is the only place `ttft_ms` (protocol section 1b) can be observed:
  /// `generateChat` returns after the whole reply — and after any tool rounds —
  /// so measuring there would report total generation time, not time to first
  /// token.
  final void Function()? onFirstToken;

  @override
  Stream<ModelResponse> generate() {
    var sawFirst = false;
    return chat.generateChatResponseAsync().timeout(generationTimeout).map((
      response,
    ) {
      if (!sawFirst) {
        sawFirst = true;
        onFirstToken?.call();
      }
      return response;
    });
  }

  @override
  Future<void> addToolResults(List<ToolExecutionResult> results) {
    return chat.addQueryChunk(
      Message.toolResponses(
        results
            .map(
              (result) => ToolResponseMessage(
                toolName: result.name,
                callId: result.id,
                response: result.toModelJson(),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  @override
  Future<void> addProtocolFeedback(Map<String, Object?> feedback) {
    return chat.addQueryChunk(
      Message.toolResponse(toolName: 'tool_protocol', response: feedback),
    );
  }
}
