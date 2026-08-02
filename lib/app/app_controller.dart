import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/llm/llm_service.dart';
import '../core/memory/memory_service.dart';
import '../core/model/model_descriptor.dart';
import 'assistant_runtime_controller.dart';
import 'model_controller.dart';

abstract final class AppPreferenceKeys {
  static const String hideChatLog = 'hideChatLog';
}

class AppController extends AssistantRuntimeController {
  AppController({
    required this.models,
    required this.llm,
    required this.memory,
  });

  final ModelController models;
  final LlmService llm;
  final MemoryService memory;
  final List<Map<String, String>> _conversation = <Map<String, String>>[];
  @override
  List<Map<String, String>> get conversation =>
      List<Map<String, String>>.unmodifiable(_conversation);

  bool _llmInstalled = false;
  @override
  bool get llmInstalled => _llmInstalled;
  bool _installingLlm = false;
  @override
  bool get installingLlm => _installingLlm;
  String? _llmError;
  @override
  String? get llmError => _llmError;

  bool _hideChatLog = false;
  bool get hideChatLog => _hideChatLog;

  int _activeChatRequests = 0;
  @override
  bool get generatingResponse => _activeChatRequests > 0;

  int _activeTranscriptions = 0;
  @override
  bool get transcribingAudio => _activeTranscriptions > 0;

  bool _memoryUpdateRunning = false;
  int _turnsSinceMemoryUpdate = 0;
  Timer? _memoryIdleTimer;

  Future<void>? _startupFuture;
  bool _startupCompleted = false;

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _hideChatLog = prefs.getBool(AppPreferenceKeys.hideChatLog) ?? false;
    notifyListeners();
  }

  Future<void> setHideChatLog(bool value) async {
    if (value == _hideChatLog) return;

    _hideChatLog = value;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppPreferenceKeys.hideChatLog, value);
  }

  Future<void> startup() async {
    if (_startupCompleted) {
      debugPrint('AppController.startup: Already completed, skipping.');
      return;
    }

    final inFlight = _startupFuture;
    if (inFlight != null) {
      debugPrint('AppController.startup: Awaiting in-flight startup...');
      return inFlight;
    }

    final future = _runStartup();
    _startupFuture = future;
    return future;
  }

  Future<void> _runStartup() async {
    debugPrint('AppController.startup: Starting...');

    try {
      await loadPreferences();
      await llm.initialize();
      await models.loadLocalState();
      await models.refreshInstalled();

      debugPrint(
        'AppController.startup: Installed models: ${models.installedModels.length}',
      );
      debugPrint(
        'AppController.startup: Last used model ID: ${models.lastUsedModelId}',
      );

      await _restoreLastUsedModel();

      _startupCompleted = true;
      debugPrint(
        'AppController.startup: Complete. LLM installed: $llmInstalled',
      );
    } catch (e, st) {
      _llmError = 'Startup failed: $e';
      _llmInstalled = false;
      debugPrint('AppController.startup: Failed: $e\n$st');
      notifyListeners();
      rethrow;
    } finally {
      _startupFuture = null;
    }
  }

  Future<void> _restoreLastUsedModel() async {
    final lastUsedId = models.lastUsedModelId;
    debugPrint('_restoreLastUsedModel: lastUsedId=$lastUsedId');

    if (lastUsedId == null || lastUsedId.trim().isEmpty) {
      debugPrint('_restoreLastUsedModel: No last used model ID, skipping');
      return;
    }

    final stillInstalled = models.installedModels.any(
      (m) => m.id == lastUsedId,
    );

    debugPrint('_restoreLastUsedModel: stillInstalled=$stillInstalled');

    if (!stillInstalled) {
      debugPrint('_restoreLastUsedModel: Model no longer installed, skipping');
      return;
    }

    debugPrint('_restoreLastUsedModel: Activating model $lastUsedId');
    models.setPendingSelection(lastUsedId);
    await models.commitSelection();
    await activateSelectedModel();
  }

  Future<void>? _activationFuture;
  String? _activeModelFingerprint;

  @override
  Future<void> activateSelectedModel() {
    final existing = _activationFuture;
    if (existing != null) return existing;

    final selected = models.selectedInstalledModel;
    final fingerprint = selected == null ? null : _modelFingerprint(selected);
    if (_llmInstalled &&
        fingerprint != null &&
        fingerprint == _activeModelFingerprint) {
      return Future<void>.value();
    }

    final completer = Completer<void>();
    _activationFuture = completer.future;

    final future = () async {
      final selected = models.selectedInstalledModel;
      if (selected == null) {
        _clearLlmState();
        _llmError = 'No model selected.';
        notifyListeners();
        return;
      }

      final fingerprint = _modelFingerprint(selected);
      if (_llmInstalled && fingerprint == _activeModelFingerprint) {
        return;
      }

      final isSameModel = _llmInstalled &&
          _activeModelFingerprint != null &&
          _activeModelFingerprint!.split('|')[0] == selected.id &&
          _activeModelFingerprint!.split('|')[1] == selected.localPath;

      if (isSameModel) {
        try {
          await llm.applyConfig(
            modelType: selected.config.toGemmaModelType(),
            maxTokens: selected.config.maxTokens,
            tokenBuffer: selected.config.tokenBuffer,
            temperature: selected.config.temperature,
            randomSeed: selected.config.randomSeed,
            topK: selected.config.topK,
            topP: selected.config.topP,
            isThinking: selected.config.isThinking,
            supportsFunctionCalls: selected.config.supportsFunctionCalls,
            modelFileType: selected.config.fileType,
            resetNative: false,
          );
          _activeModelFingerprint = fingerprint;
          notifyListeners();
        } catch (e) {
          _llmError = 'Model configuration update failed: $e';
          _llmInstalled = false;
          _activeModelFingerprint = null;
          notifyListeners();
        }
        return;
      }

      _clearLlmState();
      notifyListeners();

      _installingLlm = true;
      notifyListeners();

      try {
        await llm.applyConfig(
          modelType: selected.config.toGemmaModelType(),
          maxTokens: selected.config.maxTokens,
          tokenBuffer: selected.config.tokenBuffer,
          temperature: selected.config.temperature,
          randomSeed: selected.config.randomSeed,
          topK: selected.config.topK,
          topP: selected.config.topP,
          isThinking: selected.config.isThinking,
          supportsFunctionCalls: selected.config.supportsFunctionCalls,
          modelFileType: selected.config.fileType,
        );

        await llm.installFromLocalFile(
          selected.localPath,
          preferModelType: selected.config.toGemmaModelType(),
          preferModelFileType: selected.config.fileType,
        );

        _llmInstalled = true;
        _activeModelFingerprint = fingerprint;
        await models.markLastUsedSelected();
      } catch (e) {
        _llmError = 'Model initialization failed: $e';
        _llmInstalled = false;
        _activeModelFingerprint = null;
      } finally {
        _installingLlm = false;
        notifyListeners();
      }
    }();

    future.then(
      (_) => completer.complete(),
      onError: (e, st) => completer.completeError(e, st),
    );

    completer.future.whenComplete(() {
      _activationFuture = null;
    });

    return completer.future;
  }

  void _clearLlmState() {
    _llmError = null;
    _llmInstalled = false;
    _activeModelFingerprint = null;
  }

  String _modelFingerprint(InstalledModel model) {
    final config = model.config;
    return [
      model.id,
      model.localPath,
      config.type,
      config.maxTokens,
      config.tokenBuffer,
      config.temperature,
      config.randomSeed,
      config.topK,
      config.topP,
      config.isThinking,
      config.supportsFunctionCalls,
      config.fileType.name,
    ].join('|');
  }

  @override
  Future<String> chatOnce(String userText) async {
    if (generatingResponse) {
      throw StateError(
        'Assistant is still generating a response. Please wait.',
      );
    }

    _activeChatRequests += 1;
    notifyListeners();

    try {
      final memoryData = await memory.loadMemoryData();
      final systemPrompt = await memory.buildSystemPrompt(memory: memoryData);

      _conversation.add(_createMessage('user', userText));
      notifyListeners();

      final assistant = await llm.generateChat(
        systemText: systemPrompt,
        userText: userText,
      );

      _conversation.add(_createMessage('assistant', assistant));
      notifyListeners();

      unawaited(_handleMemoryTurnProgress());

      return assistant;
    } finally {
      if (_activeChatRequests > 0) {
        _activeChatRequests -= 1;
      }
      notifyListeners();
    }
  }

  @override
  Future<void> startNewConversation() async {
    if (generatingResponse) {
      throw StateError(
        'Assistant is still generating a response. Please wait.',
      );
    }

    // A pending extraction is dropped, not flushed. Log it loudly: silently
    // losing the last turns is exactly the failure mode the experiment
    // protocol needs to be able to see.
    if (_memoryIdleTimer?.isActive ?? false) {
      debugPrint(
        'AppController.startNewConversation: cancelling a pending memory '
        'extraction ($_turnsSinceMemoryUpdate turn(s) since the last update '
        'will NOT be written to memory)',
      );
    }
    _memoryIdleTimer?.cancel();
    _memoryIdleTimer = null;
    _turnsSinceMemoryUpdate = 0;

    _conversation.clear();
    notifyListeners();

    await llm.startNewConversation();
    notifyListeners();
  }

  /// Wipes persisted memory back to cold start *and* starts a new conversation.
  ///
  /// Both halves are required: clearing storage alone would leave the previous
  /// turns in the live session, where they would be replayed into the next
  /// prompt and fed to the extraction pass.
  Future<void> resetMemoryToColdStart() async {
    await memory.resetToColdStart();
    await startNewConversation();
    debugPrint('AppController.resetMemoryToColdStart: done');
  }

  Future<void> _handleMemoryTurnProgress() async {
    _turnsSinceMemoryUpdate += 1;

    if (_turnsSinceMemoryUpdate >= 5) {
      _memoryIdleTimer?.cancel();
      _turnsSinceMemoryUpdate = 0;
      _memoryIdleTimer = Timer(const Duration(seconds: 3), () {
        unawaited(_updateMemory());
      });
      return;
    }

    _memoryIdleTimer?.cancel();

    const idleDuration = Duration(minutes: 1);

    _memoryIdleTimer = Timer(idleDuration, () {
      _turnsSinceMemoryUpdate = 0;
      unawaited(_updateMemory());
    });
  }

  Map<String, String> _createMessage(String role, String text) {
    return <String, String>{'role': role, 'text': text};
  }

  @override
  void beginTranscribing() {
    _activeTranscriptions += 1;
    notifyListeners();
  }

  @override
  void endTranscribing() {
    if (_activeTranscriptions > 0) {
      _activeTranscriptions -= 1;
    }
    notifyListeners();
  }

  Future<void> _updateMemory() async {
    if (_memoryUpdateRunning) {
      return;
    }

    final allowed = await memory.isAutoUpdateAllowed();
    if (!allowed) {
      return;
    }

    _memoryUpdateRunning = true;
    try {
      await memory.updateMemoryFromChat(llm: llm);
    } finally {
      _memoryUpdateRunning = false;
    }
  }

  @override
  void dispose() {
    _memoryIdleTimer?.cancel();
    _memoryIdleTimer = null;
    super.dispose();
  }
}
