import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../google/calendar_event_gateway.dart';
import '../memory/memory_service.dart';
import '../unity/unity_bridge.dart';
import 'llm_errors.dart';
import 'llm_platform.dart';
import 'memory_extraction_prompt_builder.dart';
import 'model_turn_collector.dart';
import 'prompt_budgeter.dart';
import 'temporal_context.dart';
import 'tool_loop_chat.dart';
import 'tool_orchestrator.dart';
import 'tool_prompt_builder.dart';
import 'tool_registry.dart';

typedef CalendarEventGatewayProvider = CalendarEventGateway? Function();

class LlmService {
  LlmService({
    LlmPlatform? platform,
    this.modelType = ModelType.qwen,
    this.preferredBackend = PreferredBackend.gpu,
    this.maxTokens = 4096,
    this.tokenBuffer = 512,
    this.temperature = 0.8,
    this.randomSeed = 1,
    this.topK = 1,
    this.topP,
    this.isThinking = false,
    this.supportsFunctionCalls = false,
    this.modelFileType = ModelFileType.task,
    required this.unityBridge,
    required this.memoryService,
    CalendarEventGatewayProvider? calendarEventGateway,
    TemporalContextSource? temporalContextSource,
  }) : _calendarEventGatewayProvider = calendarEventGateway,
       platform = platform ?? const FlutterGemmaLlmPlatform(),
       temporalContextSource =
           temporalContextSource ?? const DeviceTemporalContextSource();

  factory LlmService.dummy() =>
      LlmService(unityBridge: UnityBridge(), memoryService: MemoryService());

  static const _memoryExtractionPromptBuilder = MemoryExtractionPromptBuilder();
  static const _promptBudgeter = PromptBudgeter();

  int get _effectiveTokenBuffer => _promptBudgeter.effectiveTokenBuffer(
    maxTokens: maxTokens,
    configuredTokenBuffer: tokenBuffer,
  );

  final LlmPlatform platform;
  ModelType modelType;
  PreferredBackend preferredBackend;
  int maxTokens;
  int tokenBuffer;
  double temperature;
  int randomSeed;
  int topK;
  double? topP;
  bool isThinking;
  bool supportsFunctionCalls;
  ModelFileType modelFileType;

  final UnityBridge unityBridge;
  final MemoryService memoryService;
  final CalendarEventGatewayProvider? _calendarEventGatewayProvider;
  final TemporalContextSource temporalContextSource;

  CalendarEventGateway? get calendarEventGateway =>
      _calendarEventGatewayProvider?.call();

  InferenceModel? _model;
  InferenceChat? _chat;
  Future<void> _operationTail = Future<void>.value();
  bool _initialized = false;
  static final Object _exclusiveZoneKey = Object();
  Future<void>? _initializeFuture;
  Future<void>? _activationFuture;
  String? _systemFingerprint;
  final List<Message> _canonicalDialogue = <Message>[];

  String? _lastComposedSystemText;

  /// The exact system instruction most recently handed to the model.
  ///
  /// This is the post-[_composeSystemText] string — memory block *plus* the
  /// `<tool_rules>` and `<tools>` blocks. `MemoryService.buildSystemPrompt`
  /// alone returns only the memory block, which is roughly a third of what the
  /// model actually receives, so instrumentation must read this instead.
  ///
  /// Null until the first [generateChat]; survives [startNewConversation] so a
  /// dump taken right after a turn still reports that turn's prompt.
  String? get lastComposedSystemText => _lastComposedSystemText;

  /// Character count of [lastComposedSystemText]; 0 before the first turn.
  int get lastComposedSystemChars => _lastComposedSystemText?.length ?? 0;

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    if (Zone.current[_exclusiveZoneKey] == true) {
      return action();
    }

    final result = _operationTail.then(
      (_) => runZoned<Future<T>>(
        action,
        zoneValues: <Object?, Object?>{_exclusiveZoneKey: true},
      ),
    );
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  Future<void> initialize({String? huggingFaceToken}) {
    if (_initialized) return Future<void>.value();
    final existing = _initializeFuture;
    if (existing != null) {
      return existing;
    }

    final completer = Completer<void>();
    _initializeFuture = completer.future;

    final future = _runExclusive(() async {
      await platform.initialize(huggingFaceToken: huggingFaceToken);
      _initialized = true;
    });

    future.then(
      (_) => completer.complete(),
      onError: (e, st) => completer.completeError(e, st),
    );

    completer.future.whenComplete(() {
      _initializeFuture = null;
    });

    return completer.future;
  }

  bool _isSessionNotCreatedError(Object error) {
    if (error is PlatformException) {
      final msg = (error.message ?? '').toLowerCase();
      final code = error.code.toLowerCase();
      if (code.contains('illegalstateexception') &&
          msg.contains('session not created')) {
        return true;
      }
      if (msg.contains('session not created')) return true;
    }
    return error.toString().toLowerCase().contains('session not created');
  }

  Future<void> _resetNativeState() async {
    final model = _model;
    _chat = null;
    _model = null;
    _systemFingerprint = null;
    _canonicalDialogue.clear();
    if (model != null) {
      try {
        await model.close();
      } catch (_) {}
    }
  }

  Future<void> applyConfig({
    required ModelType modelType,
    required int maxTokens,
    required int tokenBuffer,
    required double temperature,
    required int randomSeed,
    required int topK,
    required double? topP,
    required bool isThinking,
    required bool supportsFunctionCalls,
    required ModelFileType modelFileType,
    bool resetNative = true,
  }) async {
    return _runExclusive(() async {
      this.modelType = modelType;
      this.maxTokens = maxTokens;
      this.tokenBuffer = tokenBuffer;
      this.temperature = temperature;
      this.randomSeed = randomSeed;
      this.topK = topK;
      this.topP = topP;
      this.isThinking = isThinking;
      this.supportsFunctionCalls = supportsFunctionCalls;
      this.modelFileType = modelFileType;

      if (resetNative) {
        await _resetNativeState();
      } else {
        final chat = _chat;
        if (chat != null) {
          try {
            await chat.session.close();
          } catch (_) {}
          _chat = null;
        }
        _systemFingerprint = null;
      }
    });
  }

  Future<T> _withRecovery<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      if (!_isSessionNotCreatedError(e)) rethrow;
      debugPrint(
        'Session not created error detected, resetting native state and retrying...',
      );
      await _resetNativeState();
      return await action();
    }
  }

  Future<InferenceModel> _ensureModel() async {
    if (_model != null) return _model!;

    debugPrint(
      'LlmService: Attempting to load model with backend: $preferredBackend',
    );
    try {
      final model = await platform.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: preferredBackend,
      );
      _model = model;
      return model;
    } catch (e) {
      debugPrint(
        'LlmService: Initial model load failed with backend $preferredBackend: $e',
      );
      await _resetNativeState();
      await Future<void>.delayed(const Duration(seconds: 2));

      final fallbackBackend = preferredBackend == PreferredBackend.gpu
          ? PreferredBackend.cpu
          : PreferredBackend.gpu;

      debugPrint(
        'LlmService: Attempting fallback model load with backend: $fallbackBackend',
      );
      final retryModel = await platform.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: fallbackBackend,
      );
      _model = retryModel;
      return retryModel;
    }
  }

  String _composeSystemText(String systemText, String toolsInstruction) {
    final base = systemText.trim();
    if (toolsInstruction.isEmpty) return base;
    if (base.isEmpty) return toolsInstruction;
    return '$base\n\n$toolsInstruction';
  }

  Future<void> _replayCanonicalDialogue(InferenceChat chat) async {
    if (_canonicalDialogue.isEmpty) return;

    final systemInstruction = _systemFingerprint ?? '';
    final systemTokens = await chat.session.sizeInTokens(systemInstruction);
    final budget = chat.maxTokens - chat.tokenBuffer - systemTokens;

    final turns = <List<Message>>[];
    for (var i = 0; i < _canonicalDialogue.length; i += 2) {
      if (i + 1 < _canonicalDialogue.length) {
        turns.add([_canonicalDialogue[i], _canonicalDialogue[i + 1]]);
      } else {
        turns.add([_canonicalDialogue[i]]);
      }
    }

    final turnsToReplay = <List<Message>>[];
    var currentTokens = 0;
    for (var i = turns.length - 1; i >= 0; i--) {
      final turn = turns[i];
      var turnTokens = 0;
      for (final msg in turn) {
        turnTokens += await chat.session.sizeInTokens(msg.text);
      }

      if (currentTokens + turnTokens <= budget) {
        turnsToReplay.insert(0, turn);
        currentTokens += turnTokens;
      } else {
        break;
      }
    }

    final messagesToReplay = turnsToReplay.expand((t) => t).toList();
    await chat.clearHistory(replayHistory: messagesToReplay);
  }

  Future<void> installFromLocalFile(
    String localPath, {
    ModelType? preferModelType,
    ModelFileType? preferModelFileType,
  }) {
    final existing = _activationFuture;
    if (existing != null) {
      return existing;
    }

    final completer = Completer<void>();
    _activationFuture = completer.future;

    final future = _runExclusive(() async {
      await platform.activateLocalModel(
        path: localPath,
        modelType: preferModelType ?? modelType,
        fileType: preferModelFileType ?? modelFileType,
      );
      await _ensureModel();
    });

    future.then(
      (_) => completer.complete(),
      onError: (e, st) => completer.completeError(e, st),
    );

    completer.future.whenComplete(() {
      _activationFuture = null;
    });

    return completer.future;
  }

  /// Generates a single text response from a prompt.
  Future<String> generateText(String prompt) async {
    return _runExclusive(() async {
      return _withRecovery(() async {
        final model = await _ensureModel();
        final session = await model.createSession(
          temperature: temperature,
          randomSeed: randomSeed,
          topK: topK,
          topP: topP,
        );
        try {
          await session.addQueryChunk(Message.text(text: prompt, isUser: true));
          final response = await session.getResponse();
          return response;
        } finally {
          await session.close();
        }
      });
    });
  }

  String _cleanResponse(String text) {
    String cleaned = text;

    final thinkingRegex = RegExp(r'<think>.*?</think>', dotAll: true);
    cleaned = cleaned.replaceAll(thinkingRegex, '').trim();

    cleaned = cleaned.replaceAll(RegExp(r'<end_of_turn>\s*$'), '').trim();
    cleaned = cleaned.replaceAll(RegExp(r'<\|im_end\|>\s*$'), '').trim();
    cleaned = cleaned.replaceAll(r'\n', '\n').trim();

    return cleaned;
  }

  static const int _maxCanonicalMessages = 50;
  static const Duration _chatGenerationTimeout = Duration(minutes: 5);

  Future<String> generateChat({
    String? systemText,
    required String userText,
  }) async {
    return _runExclusive(() async {
      final model = await _ensureModel();
      final temporalContext = calendarEventGateway?.isAvailable ?? false
          ? await temporalContextSource.capture()
          : null;
      final toolSnapshot = await ToolRegistry.forApp(
        unityBridge: unityBridge,
        memoryService: memoryService,
        calendarEventGateway: calendarEventGateway,
        calendarTimeZoneId: temporalContext?.timeZoneId,
      ).snapshot();
      final toolsInstruction = const ToolPromptBuilder().build(
        toolSnapshot.definitions,
      );
      final composedSystemText = _composeSystemText(
        systemText ?? '',
        toolsInstruction,
      );
      _lastComposedSystemText = composedSystemText;

      final needsRebuild =
          _chat == null || _systemFingerprint != composedSystemText;
      if (needsRebuild) {
        if (_chat != null) {
          try {
            await _chat!.session.close();
          } catch (_) {}
        }
        _chat = await model.createChat(
          temperature: temperature,
          randomSeed: randomSeed,
          topK: topK,
          topP: topP,
          tokenBuffer: _effectiveTokenBuffer,
          supportsFunctionCalls: supportsFunctionCalls,
          isThinking: isThinking,
          modelType: modelType,
          tools: supportsFunctionCalls
              ? toolSnapshot.definitions
              : const <Tool>[],
          systemInstruction: composedSystemText,
        );
        _systemFingerprint = composedSystemText;
        await _replayCanonicalDialogue(_chat!);
      }

      final modelUserText = temporalContext == null
          ? userText
          : '${temporalContext.toPromptBlock()}\n$userText';
      final userMessage = Message.text(text: modelUserText, isUser: true);
      final canonicalUserMessage = Message.text(text: userText, isUser: true);
      var stage = _GenerationStage.preparing;
      var attempts = 0;

      while (true) {
        attempts++;
        try {
          if (stage == _GenerationStage.preparing) {
            final budget = await _promptBudgeter.assess(
              session: _chat!.session,
              maxTokens: maxTokens,
              configuredTokenBuffer: tokenBuffer,
              systemText: composedSystemText,
              history: _canonicalDialogue,
              userText: modelUserText,
            );
            debugPrint(
              'LlmService: prompt tokens=${budget.inputTokens} '
              'limit=${budget.inputLimit} buffer=${budget.effectiveTokenBuffer}',
            );
            if (!budget.fits) {
              throw const LlmRuntimeException(
                LlmErrorCode.inputTooLong,
                'The conversation context is too long for this model. '
                'Please shorten the message or start a new conversation.',
              );
            }
            await _chat!.addQueryChunk(userMessage);
            stage = _GenerationStage.queryAccepted;
          }

          stage = _GenerationStage.generating;
          final result = await ToolOrchestrator(
            chat: InferenceToolLoopChat(
              _chat!,
              generationTimeout: _chatGenerationTimeout,
            ),
            collector: ModelTurnCollector(modelType: modelType),
            tools: toolSnapshot,
          ).run();

          _canonicalDialogue.add(canonicalUserMessage);
          _canonicalDialogue.add(Message.text(text: result, isUser: false));
          if (_canonicalDialogue.length > _maxCanonicalMessages) {
            _canonicalDialogue.removeRange(
              0,
              _canonicalDialogue.length - _maxCanonicalMessages,
            );
          }
          return result;
        } catch (e) {
          debugPrint('LlmService: generateChat error at stage $stage: $e');

          if (e is LlmRuntimeException && e.code == LlmErrorCode.inputTooLong) {
            rethrow;
          }

          if (stage == _GenerationStage.preparing && attempts == 1) {
            debugPrint(
              'LlmService: Recovery attempt 1 for pre-acceptance failure...',
            );
            await _resetNativeState();
            final model = await _ensureModel();
            _chat = await model.createChat(
              temperature: temperature,
              randomSeed: randomSeed,
              topK: topK,
              topP: topP,
              tokenBuffer: _effectiveTokenBuffer,
              supportsFunctionCalls: supportsFunctionCalls,
              isThinking: isThinking,
              modelType: modelType,
              tools: supportsFunctionCalls
                  ? toolSnapshot.definitions
                  : const <Tool>[],
              systemInstruction: composedSystemText,
            );
            _systemFingerprint = composedSystemText;
            await _replayCanonicalDialogue(_chat!);
            continue;
          }

          debugPrint(
            'LlmService: Post-acceptance failure, closing session and propagating error.',
          );
          await _resetNativeState();
          if (e is LlmRuntimeException) rethrow;
          throw LlmRuntimeException(
            LlmErrorCode.generationInterrupted,
            'Generation was interrupted and could not complete.',
            cause: e,
          );
        }
      }
    });
  }

  /// Runs memory extraction in a temporary one-shot session WITHOUT closing
  /// the active [_chat]. This prevents session corruption when called from
  /// inside a tool-call (which itself runs inside [_runExclusive]).
  Future<String> _runExclusiveMemoryExtraction(String prompt) async {
    return _runExclusive(() async {
      final model = await _ensureModel();

      // Create a temporary session directly on the model.
      // We intentionally do NOT touch _chat here — it must stay alive so that
      // any ongoing generateChat() call can continue without corruption.
      final session = await model.createSession(
        temperature: 0.2,
        randomSeed: randomSeed,
        topK: 1,
        topP: topP,
      );
      try {
        await session.addQueryChunk(Message.text(text: prompt, isUser: true));
        final responseBuffer = StringBuffer();
        await for (final chunk in session.getResponseAsync().timeout(
          const Duration(seconds: 60),
        )) {
          responseBuffer.write(chunk);
        }
        return _cleanResponse(responseBuffer.toString());
      } on TimeoutException {
        debugPrint(
          'LlmService: memory extraction timed out after 60s - returning empty.',
        );
        return '';
      } finally {
        try {
          await session.close().timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
    });
  }

  Future<String> extractMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async {
    final conversationText = _formatHistoryForMemory(_canonicalDialogue);
    if (conversationText.isEmpty) {
      return '';
    }

    final prompt = _buildMemoryPrompt(
      conversationText,
      currentMemoryJson,
      lockedFields,
    );
    return _runExclusiveMemoryExtraction(prompt);
  }

  Future<String> extractSoulMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async {
    final conversationText = _formatHistoryForMemory(_canonicalDialogue);
    if (conversationText.isEmpty) {
      return '';
    }

    final prompt = _buildSoulMemoryPrompt(
      conversationText,
      currentMemoryJson,
      lockedFields,
    );
    return _runExclusiveMemoryExtraction(prompt);
  }

  Future<String> extractIdentityMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async {
    final conversationText = _formatHistoryForMemory(_canonicalDialogue);
    if (conversationText.isEmpty) {
      return '';
    }

    final prompt = _buildIdentityMemoryPrompt(
      conversationText,
      currentMemoryJson,
      lockedFields,
    );
    return _runExclusiveMemoryExtraction(prompt);
  }

  Future<String> extractUserMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async {
    final conversationText = _formatHistoryForMemory(_canonicalDialogue);
    if (conversationText.isEmpty) {
      return '';
    }

    final prompt = _buildUserMemoryPrompt(
      conversationText,
      currentMemoryJson,
      lockedFields,
    );
    return _runExclusiveMemoryExtraction(prompt);
  }

  static String _formatHistoryForMemory(List<Message> history) {
    // const maxMessages = 20;

    final filtered = history.where((m) {
      if (m.hasImage) return false;
      if (m.type != MessageType.text) return false;
      final text = m.text.trim();
      if (text.isEmpty) return false;
      if (!m.isUser && text.startsWith('This is a system instruction')) {
        return false;
      }
      return true;
    }).toList();

    if (filtered.isEmpty) return '';

    // final recent = filtered.length > maxMessages
    //     ? filtered.sublist(filtered.length - maxMessages)
    //     : filtered;

    final buffer = StringBuffer();
    for (final m in filtered) {
      //recent
      final role = m.isUser ? 'User' : 'Assistant';
      final text = m.text.trim();
      buffer.writeln('$role: $text');
    }
    return buffer.toString().trim();
  }

  static String _buildMemoryPrompt(
    String conversation,
    String currentMemory,
    Set<String> lockedFields,
  ) => _memoryExtractionPromptBuilder.build(
    section: MemoryExtractionSection.all,
    conversation: conversation,
    currentMemory: currentMemory,
    lockedFields: lockedFields,
  );

  static String _buildSoulMemoryPrompt(
    String conversation,
    String currentMemory,
    Set<String> lockedFields,
  ) => _memoryExtractionPromptBuilder.build(
    section: MemoryExtractionSection.soul,
    conversation: conversation,
    currentMemory: currentMemory,
    lockedFields: lockedFields,
  );

  static String _buildIdentityMemoryPrompt(
    String conversation,
    String currentMemory,
    Set<String> lockedFields,
  ) => _memoryExtractionPromptBuilder.build(
    section: MemoryExtractionSection.identity,
    conversation: conversation,
    currentMemory: currentMemory,
    lockedFields: lockedFields,
  );

  static String _buildUserMemoryPrompt(
    String conversation,
    String currentMemory,
    Set<String> lockedFields,
  ) => _memoryExtractionPromptBuilder.build(
    section: MemoryExtractionSection.user,
    conversation: conversation,
    currentMemory: currentMemory,
    lockedFields: lockedFields,
  );

  /// Drops the current conversation and starts a fresh one.
  ///
  /// Clears [_canonicalDialogue] and disposes the active chat session so the
  /// next [generateChat] rebuilds from an empty history. The loaded [_model] is
  /// deliberately kept — reloading it would cost seconds and generate heat,
  /// which would contaminate the timing measurements this method exists to
  /// support.
  ///
  /// Persisted memory is untouched; see `MemoryService.resetToColdStart`.
  Future<void> startNewConversation() async {
    return _runExclusive(() async {
      final discarded = _canonicalDialogue.length;
      _canonicalDialogue.clear();
      _systemFingerprint = null;

      final chat = _chat;
      _chat = null;
      if (chat != null) {
        try {
          await chat.session.close();
        } catch (e) {
          debugPrint('LlmService.startNewConversation: session close failed: $e');
        }
      }

      debugPrint(
        'LlmService.startNewConversation: cleared $discarded message(s), '
        'model kept loaded',
      );
    });
  }

  Future<void> close() async {
    return _runExclusive(() async {
      final model = _model;
      _chat = null;
      _model = null;
      if (model != null) {
        await model.close();
      }
    });
  }
}

enum _GenerationStage { preparing, queryAccepted, generating }
