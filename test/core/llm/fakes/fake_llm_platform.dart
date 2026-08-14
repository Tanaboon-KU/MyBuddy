import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:mybuddy/core/llm/llm_platform.dart';

class FakeLlmPlatform implements LlmPlatform {
  int initializeCount = 0;
  int activateCount = 0;
  int getActiveModelCount = 0;
  int createSessionCount = 0;
  int createChatCount = 0;
  int closeModelCount = 0;
  int closeSessionCount = 0;
  int getResponseCount = 0;
  int getResponseAsyncCount = 0;
  int stopCount = 0;

  String? lastActivatedPath;
  ModelType? lastActivatedModelType;
  ModelFileType? lastActivatedFileType;

  bool failNextAddQuery = false;
  bool failAfterAccept = false;

  /// Makes session close throw the way MediaPipe does when the native
  /// invocation is still running - what an aborted extraction leaves behind.
  bool failSessionClose = false;

  Completer<void>? generationCompleter;

  List<String> acceptedQueries = [];
  final List<List<String>> asyncResponseBatches = [];

  @override
  Future<void> initialize({String? huggingFaceToken}) async {
    initializeCount++;
  }

  @override
  Future<void> activateLocalModel({
    required String path,
    required ModelType modelType,
    required ModelFileType fileType,
  }) async {
    activateCount++;
    lastActivatedPath = path;
    lastActivatedModelType = modelType;
    lastActivatedFileType = fileType;
  }

  @override
  Future<InferenceModel> getActiveModel({
    required int maxTokens,
    required PreferredBackend preferredBackend,
  }) async {
    getActiveModelCount++;
    return FakeInferenceModel(
      maxTokens: maxTokens,
      fileType: ModelFileType.task,
      platform: this,
    );
  }

  Future<void> waitOnGeneration() async {
    final c = generationCompleter;
    if (c != null) {
      await c.future;
    }
  }
}

class FakeInferenceModel implements InferenceModel {
  FakeInferenceModel({
    required this.maxTokens,
    required this.fileType,
    required this.platform,
  });

  @override
  final int maxTokens;
  @override
  final ModelFileType fileType;
  final FakeLlmPlatform platform;

  @override
  InferenceModelSession? session;

  @override
  InferenceChat? chat;

  @override
  Future<InferenceModelSession> createSession({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
  }) async {
    platform.createSessionCount++;
    final s = FakeInferenceModelSession(
      platform: platform,
      systemInstruction: systemInstruction,
    );
    session = s;
    return s;
  }

  @override
  Future<InferenceChat> createChat({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool isThinking = false,
    ModelType? modelType,
    ToolChoice toolChoice = ToolChoice.auto,
    String? systemInstruction,
  }) async {
    platform.createChatCount++;
    final c = InferenceChat(
      sessionCreator: () => createSession(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage ?? false,
        enableAudioModality: supportAudio ?? false,
        systemInstruction: systemInstruction,
        enableThinking: isThinking,
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? false,
      supportAudio: supportAudio ?? false,
      supportsFunctionCalls: supportsFunctionCalls ?? false,
      tools: tools,
      isThinking: isThinking,
      modelType: modelType ?? ModelType.gemmaIt,
      fileType: fileType,
      toolChoice: toolChoice,
      systemInstruction: systemInstruction,
    );
    chat = c;
    await c.initSession();
    return c;
  }

  @override
  Future<void> close() async {
    platform.closeModelCount++;
  }
}

class FakeInferenceModelSession implements InferenceModelSession {
  FakeInferenceModelSession({required this.platform, this.systemInstruction});

  final FakeLlmPlatform platform;
  final String? systemInstruction;
  final List<Message> queries = [];
  bool isClosed = false;

  @override
  Future<void> addQueryChunk(Message message) async {
    if (isClosed) throw StateError('Session is closed');
    if (platform.failNextAddQuery) {
      platform.failNextAddQuery = false;
      throw Exception('Fake addQueryChunk platform error');
    }
    queries.add(message);
    platform.acceptedQueries.add(message.text);
  }

  @override
  Future<String> getResponse() async {
    if (isClosed) throw StateError('Session is closed');
    platform.getResponseCount++;
    if (platform.failAfterAccept) {
      platform.failAfterAccept = false;
      throw Exception('Fake getResponse platform error');
    }
    await platform.waitOnGeneration();
    return 'fake response';
  }

  @override
  Stream<String> getResponseAsync() async* {
    if (isClosed) throw StateError('Session is closed');
    platform.getResponseAsyncCount++;
    if (platform.failAfterAccept) {
      platform.failAfterAccept = false;
      throw Exception('Fake getResponseAsync platform error');
    }
    await platform.waitOnGeneration();
    final batch = platform.asyncResponseBatches.isEmpty
        ? const <String>['fake response chunk']
        : platform.asyncResponseBatches.removeAt(0);
    for (final chunk in batch) {
      yield chunk;
    }
  }

  @override
  Future<int> sizeInTokens(String text) async {
    return text.split(' ').length;
  }

  @override
  Future<void> stopGeneration() async {
    platform.stopCount++;
  }

  @override
  Future<void> close() async {
    if (platform.failSessionClose) {
      throw StateError(
        'Previous invocation still processing. Wait for done=true.',
      );
    }
    isClosed = true;
    platform.closeSessionCount++;
  }
}
