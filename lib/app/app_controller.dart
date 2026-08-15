import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diagnostics/battery_status_service.dart';
import '../core/diagnostics/turn_log.dart';
import '../core/diagnostics/turn_log_recorder.dart';
import '../core/llm/llm_service.dart';
import '../core/memory/extraction_arm.dart';
import '../core/memory/memory_service.dart';
import '../core/model/model_descriptor.dart';
import 'assistant_runtime_controller.dart';
import 'model_controller.dart';

abstract final class AppPreferenceKeys {
  static const String hideChatLog = 'hideChatLog';
}

/// What the write path is doing right now.
///
/// Protocol section 1a item 6 requires a visible "extraction complete" signal
/// so the RA waits for the pass instead of guessing. Section 3 step 4 and
/// section 4 step 2 both hinge on it.
enum ExtractionPhase { idle, scheduled, running, complete }

class AppController extends AssistantRuntimeController {
  AppController({
    required this.models,
    required this.llm,
    required this.memory,
    TurnLogRecorder? turnLog,
    BatteryStatusService? battery,
  }) : turnLog = turnLog ?? TurnLogRecorder(),
       battery = battery ?? BatteryStatusService();

  final ModelController models;
  final LlmService llm;
  final MemoryService memory;

  /// Per-turn log required by protocol section 1b.
  final TurnLogRecorder turnLog;
  final BatteryStatusService battery;

  /// Identifies the current conversation in the log. Rotates on every
  /// [startNewConversation].
  String _sessionId = _newSessionId();
  String get sessionId => _sessionId;

  int _turnIndex = 0;

  ExtractionPhase _extractionPhase = ExtractionPhase.idle;
  ExtractionPhase get extractionPhase => _extractionPhase;

  DateTime? _lastExtractionCompletedAt;
  DateTime? get lastExtractionCompletedAt => _lastExtractionCompletedAt;

  ExtractionParseResult? _lastExtractionResult;
  ExtractionParseResult? get lastExtractionResult => _lastExtractionResult;

  /// When the pending extraction timer will fire, so the RA can see how long
  /// is left instead of counting seconds.
  DateTime? _extractionScheduledFor;
  DateTime? get extractionScheduledFor => _extractionScheduledFor;

  static int _sessionCounter = 0;

  static String _newSessionId() {
    _sessionCounter += 1;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 's${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '_$_sessionCounter';
  }

  void _setExtractionPhase(ExtractionPhase phase, {DateTime? scheduledFor}) {
    _extractionPhase = phase;
    _extractionScheduledFor = scheduledFor;
    if (phase == ExtractionPhase.complete) {
      _lastExtractionCompletedAt = DateTime.now();
    }
    debugPrint('EXTRACTION_SIGNAL phase=${phase.name}');
    notifyListeners();
  }
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

  /// Which write path this build measures. Named in the log on every pass so a
  /// block cannot be read back without knowing which arm produced it.
  final ExtractionArm _arm = ExtractionArm.fromEnvironment();

  /// User turns the rules layer has not been given yet. Only filled in the
  /// rules arm; see the comment at the call site for why they are not written
  /// as they arrive.
  final List<String> _pendingRuleTurns = <String>[];

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

    final turnIndex = _turnIndex++;
    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    final extractionWasRunning = _memoryUpdateRunning;

    try {
      final memoryData = await memory.loadMemoryData();
      // T-12: the USER profile is composed last, after the tool blocks, rather
      // than inline a quarter of the way through the prompt. See
      // MemoryService.buildUserPromptTail for what E4 measured and why
      // position is the lever being pulled.
      final systemPrompt = await memory.buildSystemPrompt(
        memory: memoryData,
        lockedFields: await memory.loadLockedFields(),
        includeUserBlock: false,
      );
      final userPromptTail = await memory.buildUserPromptTail(
        memory: memoryData,
      );

      _conversation.add(_createMessage('user', userText));
      notifyListeners();

      final assistant = await llm.generateChat(
        systemText: systemPrompt,
        userText: userText,
        trailingSystemText: userPromptTail,
      );

      _conversation.add(_createMessage('assistant', assistant));
      notifyListeners();

      await _recordTurn(
        turnIndex: turnIndex,
        startedAtMs: startedAtMs,
        inputText: userText,
        replyText: assistant,
        prevExtractionStillRunning: extractionWasRunning,
      );

      // Buffered, not written. The deterministic layer reads the sentence at
      // the one moment the last-turn rule cannot reach it, but writing here
      // would change the composed system prompt and force a session rebuild on
      // every following turn - `Y N N N N` becomes `Y Y Y Y Y` and ttft goes
      // from about 1,700 ms to about 8,700 ms. The flush happens inside the
      // extraction boundary, which already pays that cost once.
      if (_arm.usesRules) _pendingRuleTurns.add(userText);

      unawaited(_handleMemoryTurnProgress(turnIndex));

      return assistant;
    } catch (e) {
      // Section 0: log everything, including failures. A turn that threw is
      // still a turn, and losing its row would hide crashes from the results.
      await _recordTurn(
        turnIndex: turnIndex,
        startedAtMs: startedAtMs,
        inputText: userText,
        replyText: '',
        prevExtractionStillRunning: extractionWasRunning,
        notes: 'chat failed: $e',
      );
      rethrow;
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
    // A fresh session id keeps the log rows of two trials from colliding on
    // turn_index — E3 runs 16 of them back to back.
    _sessionId = _newSessionId();
    _turnIndex = 0;
    _setExtractionPhase(ExtractionPhase.idle);

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

  Future<void> _recordTurn({
    required int turnIndex,
    required int startedAtMs,
    required String inputText,
    required String replyText,
    required bool prevExtractionStillRunning,
    String? notes,
  }) async {
    final telemetry = llm.lastGenerationTelemetry;
    final batteryStatus = await battery.read();

    turnLog.add(
      TurnLogEntry(
        sessionId: _sessionId,
        turnIndex: turnIndex,
        timestampMs: startedAtMs,
        inputText: inputText,
        replyText: replyText,
        ttftMs: telemetry?.ttftMs,
        replyStartMs: telemetry?.replyStartMs,
        replyEndMs: telemetry?.replyEndMs,
        sysPromptChars: telemetry?.sysPromptChars,
        sysPromptSha256: telemetry?.sysPromptSha256,
        sessionRebuilt: telemetry?.sessionRebuilt,
        replayedMessageCount: telemetry?.replayedMessageCount,
        toolsExposed: telemetry?.toolsExposed ?? const <String>[],
        toolCalls: telemetry?.toolCalls ?? const <String>[],
        prevExtractionStillRunning: prevExtractionStillRunning,
        batteryTempC: batteryStatus.temperatureC,
        batteryPct: batteryStatus.percent,
        notes: notes,
      ),
    );

    // Grep-able turn boundary. The extraction signal marks the write path, but
    // nothing marked the end of the read path, so "has the reply finished?"
    // could only be answered by watching the screen. E1-nowait needs the answer
    // the instant it changes.
    debugPrint(
      'EXTRACTION_ARM ${_arm.label}',
    );
    debugPrint(
      'TURN_RECORDED session=$_sessionId turn=$turnIndex '
      'ttft=${telemetry?.ttftMs} chars=${telemetry?.sysPromptChars}',
    );
  }

  Future<void> _handleMemoryTurnProgress(int turnIndex) async {
    _turnsSinceMemoryUpdate += 1;

    // NOTE: this debounce is RC-1 in ROOT_CAUSE_ANALYSIS.md. Every turn inside
    // the window cancels and restarts the timer, so a normal back-and-forth
    // never triggers extraction until the 5-turn threshold. T-08 fixes it;
    // T-04 only makes the behaviour observable. Do not change the timings here
    // without the before/after data the protocol requires.
    if (_turnsSinceMemoryUpdate >= 5) {
      _memoryIdleTimer?.cancel();
      _turnsSinceMemoryUpdate = 0;
      const delay = Duration(seconds: 3);
      _memoryIdleTimer = Timer(delay, () {
        unawaited(_updateMemory(turnIndex));
      });
      _setExtractionPhase(
        ExtractionPhase.scheduled,
        scheduledFor: DateTime.now().add(delay),
      );
      return;
    }

    _memoryIdleTimer?.cancel();

    const idleDuration = Duration(minutes: 1);

    _memoryIdleTimer = Timer(idleDuration, () {
      _turnsSinceMemoryUpdate = 0;
      unawaited(_updateMemory(turnIndex));
    });
    _setExtractionPhase(
      ExtractionPhase.scheduled,
      scheduledFor: DateTime.now().add(idleDuration),
    );
  }

  /// Runs the extraction pass now instead of waiting for the debounce.
  ///
  /// The RA needs this: with the current timings a turn waits a full minute
  /// before anything is written, which makes a 12-pair E2 block mostly idle
  /// time. Turns forced this way are flagged in the log so they can be told
  /// apart from the timings a real user would see.
  Future<void> forceExtractionNow() async {
    _memoryIdleTimer?.cancel();
    _memoryIdleTimer = null;
    _turnsSinceMemoryUpdate = 0;
    await _updateMemory(_turnIndex - 1, forced: true);
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

  Future<void> _updateMemory(int turnIndex, {bool forced = false}) async {
    if (_memoryUpdateRunning) {
      // The dropped update is RC-1's second half: it is not rescheduled. Log
      // it so `prev_extraction_still_running` has something to correlate with.
      debugPrint(
        'AppController: extraction skipped for turn $turnIndex - the previous '
        'pass is still running and this one is NOT rescheduled',
      );
      turnLog.update(
        _sessionId,
        turnIndex,
        (e) => e.copyWith(
          notes: [
            if (e.notes != null) e.notes!,
            'extraction skipped: previous pass still running',
          ].join(' | '),
        ),
      );
      return;
    }

    if (!await memory.isAutoUpdateAllowed()) {
      debugPrint('AppController: extraction skipped - consent flag is off');
      turnLog.update(
        _sessionId,
        turnIndex,
        (e) => e.copyWith(notes: 'extraction skipped: allowAutoUpdate is off'),
      );
      _setExtractionPhase(ExtractionPhase.idle);
      return;
    }

    _memoryUpdateRunning = true;
    _setExtractionPhase(ExtractionPhase.running);

    // Section 1b timer boundary: start when extraction is triggered, stop when
    // memory is persisted *or* the system determines nothing changed.
    final startMs = DateTime.now().millisecondsSinceEpoch;
    MemoryExtractionOutcome outcome;
    try {
      final ruleTurns = List<String>.of(_pendingRuleTurns);
      _pendingRuleTurns.clear();
      outcome = await memory.updateMemoryFromChat(
        llm: llm,
        arm: _arm,
        ruleCaptures: ruleTurns,
      );
    } catch (e) {
      debugPrint('AppController: extraction threw: $e');
      outcome = MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.failed,
        rawOutput: 'exception: $e',
      );
    } finally {
      _memoryUpdateRunning = false;
    }
    final endMs = DateTime.now().millisecondsSinceEpoch;

    turnLog.update(
      _sessionId,
      turnIndex,
      (e) => e.copyWith(
        extractStartMs: startMs,
        extractEndMs: endMs,
        extractParseResult: outcome.parseResult,
        extractRawOutput: outcome.rawOutput,
        extractRejectionCodes: outcome.rejectionCodes,
        memoryChanged: outcome.memoryChanged,
        layersChanged: outcome.layersChanged,
        notes: forced ? 'extraction forced by operator' : null,
      ),
    );

    _lastExtractionResult = outcome.parseResult;
    debugPrint(
      'EXTRACTION_SIGNAL complete turn=$turnIndex '
      'result=${outcome.parseResult.csvValue} '
      'changed=${outcome.memoryChanged} '
      'layers=${outcome.layersChanged.join('|')} '
      'ms=${endMs - startMs}',
    );
    _setExtractionPhase(ExtractionPhase.complete);
  }

  @override
  void dispose() {
    _memoryIdleTimer?.cancel();
    _memoryIdleTimer = null;
    super.dispose();
  }
}
