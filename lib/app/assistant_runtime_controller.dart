import 'package:flutter/foundation.dart';

abstract class AssistantRuntimeController extends ChangeNotifier {
  bool get llmInstalled;
  bool get installingLlm;
  String? get llmError;
  bool get generatingResponse;
  bool get transcribingAudio;
  List<Map<String, String>> get conversation;

  Future<String> chatOnce(String userText);

  /// Discards the current conversation and starts a fresh one.
  ///
  /// Does not touch persisted memory and does not reload the model.
  Future<void> startNewConversation();

  Future<void> activateSelectedModel();
  void beginTranscribing();
  void endTranscribing();
}
