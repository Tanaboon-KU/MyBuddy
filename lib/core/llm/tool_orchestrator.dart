import 'package:flutter/foundation.dart';

import 'llm_errors.dart';
import 'model_turn_collector.dart';
import 'tool_loop_chat.dart';
import 'tool_protocol.dart';
import 'tool_registry.dart';

typedef ToolDiagnosticSink =
    void Function({
      required String runId,
      required int round,
      required String stage,
      String? toolName,
      String? errorCode,
    });

final class ToolOrchestrator {
  ToolOrchestrator({
    required this.chat,
    required this.collector,
    required this.tools,
    String Function()? runIdFactory,
    this.maxRepairAttempts = defaultMaxRepairAttempts,
    this.maxConsecutiveNoProgress = defaultMaxConsecutiveNoProgress,
    this.maxProgressingRounds = defaultMaxProgressingRounds,
    this.maxRequestedCalls = defaultMaxRequestedCalls,
    ToolDiagnosticSink? diagnosticSink,
  }) : _runIdFactory = runIdFactory ?? _defaultRunId,
       _diagnosticSink = diagnosticSink;

  static const int defaultMaxRepairAttempts = 3;
  static const int defaultMaxConsecutiveNoProgress = 2;
  static const int defaultMaxProgressingRounds = 8;
  static const int defaultMaxRequestedCalls = 20;

  final ToolLoopChat chat;
  final ModelTurnCollector collector;
  final ToolRegistrySnapshot tools;
  final int maxRepairAttempts;
  final int maxConsecutiveNoProgress;
  final int maxProgressingRounds;
  final int maxRequestedCalls;
  final String Function() _runIdFactory;
  final ToolDiagnosticSink? _diagnosticSink;

  final Map<String, ToolExecutionResult> _resultLedger =
      <String, ToolExecutionResult>{};

  /// Every distinct call that actually reached the registry this turn, in the
  /// order it was first executed, as `name:ok` or `name:<errorCode>`.
  ///
  /// The turn log recorded which tools were *offered* and never which were
  /// *called*, so "tried to write and was refused" and "claimed a write it
  /// never attempted" produced identical rows. E3 has to tell those apart:
  /// T-25 L_P06 is a reply claiming an action with no call behind it, and the
  /// E3 re-run's P3 row blames an invalid argument without saying which. Both
  /// were diagnosed by reading replies because the log could not answer.
  ///
  /// Distinct rather than every attempt, keyed off the same ledger the
  /// duplicate-call guard uses, so a model that repeats one call in a loop
  /// leaves one entry and not forty.
  List<String> get executedCalls => <String>[
    for (final result in _resultLedger.values)
      '${result.name}:${result.errorCode?.name ?? 'ok'}',
  ];

  Future<String> run() async {
    final runId = _runIdFactory();
    var modelRound = 0;
    var progressingRounds = 0;
    var requestedCalls = 0;
    var repairAttempts = 0;
    var consecutiveNoProgress = 0;
    var hasSuccessfulSideEffect = false;

    while (true) {
      modelRound++;
      final turn = await collector.collect(chat.generate());
      switch (turn) {
        case FinalTextTurn(:final text):
          _diagnose(runId, modelRound, 'final_text');
          _log(runId, modelRound, 'final_text');
          return text;
        case MalformedToolTurn():
        case EmptyTurn():
          consecutiveNoProgress++;
          if (repairAttempts >= maxRepairAttempts) {
            return _finalize(
              runId: runId,
              modelRound: modelRound,
              hasSuccessfulSideEffect: hasSuccessfulSideEffect,
              code: LlmErrorCode.toolProtocolFailed,
            );
          }
          repairAttempts++;
          await chat.addProtocolFeedback(
            _repairFeedback(
              turn,
              attempt: repairAttempts,
              remainingAttempts: maxRepairAttempts - repairAttempts,
            ),
          );
        case ToolCallTurn(:final calls):
          if (progressingRounds >= maxProgressingRounds ||
              requestedCalls + calls.length > maxRequestedCalls) {
            return _finalize(
              runId: runId,
              modelRound: modelRound,
              hasSuccessfulSideEffect: hasSuccessfulSideEffect,
              code: LlmErrorCode.toolLoopLimitReached,
            );
          }
          requestedCalls += calls.length;
          final invocations = <ToolInvocation>[
            for (var index = 0; index < calls.length; index++)
              ToolInvocation(
                id: '$runId-r$modelRound-c${index + 1}',
                name: calls[index].name,
                arguments: calls[index].args,
              ),
          ];
          for (final invocation in invocations) {
            _diagnose(
              runId,
              modelRound,
              'tool_requested',
              toolName: invocation.name,
            );
          }
          final execution = await _executeBatch(invocations);
          for (final result in execution.results) {
            _diagnose(
              runId,
              modelRound,
              'tool_completed',
              toolName: result.name,
              errorCode: result.errorCode?.name,
            );
          }
          await chat.addToolResults(execution.results);
          hasSuccessfulSideEffect |= execution.results.any(
            (result) => result.isSuccess && !result.cached,
          );
          if (execution.hasRetryableValidationFailure) {
            if (repairAttempts >= maxRepairAttempts) {
              return _finalize(
                runId: runId,
                modelRound: modelRound,
                hasSuccessfulSideEffect: hasSuccessfulSideEffect,
                code: LlmErrorCode.toolProtocolFailed,
              );
            }
            repairAttempts++;
            consecutiveNoProgress = 0;
            continue;
          }
          if (execution.hasProgress) {
            progressingRounds++;
            consecutiveNoProgress = 0;
          } else {
            consecutiveNoProgress++;
            if (consecutiveNoProgress >= maxConsecutiveNoProgress) {
              return _finalize(
                runId: runId,
                modelRound: modelRound,
                hasSuccessfulSideEffect: hasSuccessfulSideEffect,
                code: LlmErrorCode.toolLoopLimitReached,
              );
            }
          }
      }
    }
  }

  Future<
    ({
      List<ToolExecutionResult> results,
      bool hasProgress,
      bool hasRetryableValidationFailure,
    })
  >
  _executeBatch(List<ToolInvocation> invocations) async {
    final pending = <String, Future<ToolExecutionResult>>{};
    final newSignatures = <String>{};
    final futures = <Future<ToolExecutionResult>>[];

    for (final invocation in invocations) {
      final signature = invocation.canonicalSignature;
      final cached = _resultLedger[signature];
      if (cached != null) {
        futures.add(
          Future<ToolExecutionResult>.value(
            cached.copyForDuplicate(id: invocation.id),
          ),
        );
        continue;
      }

      final existing = pending[signature];
      if (existing != null) {
        futures.add(
          existing.then((result) => result.copyForDuplicate(id: invocation.id)),
        );
        continue;
      }

      newSignatures.add(signature);
      final future = tools.invoke(invocation).then((result) {
        _resultLedger[signature] = result;
        return result;
      });
      pending[signature] = future;
      futures.add(future);
    }

    final results = await Future.wait(futures);
    final newResults = <ToolExecutionResult>[
      for (var index = 0; index < invocations.length; index++)
        if (newSignatures.contains(invocations[index].canonicalSignature))
          results[index],
    ];
    return (
      results: results,
      hasProgress: newResults.any(_isProgress),
      hasRetryableValidationFailure: newResults.any(
        (result) =>
            result.errorCode == ToolResultErrorCode.invalidArguments &&
            result.retryable,
      ),
    );
  }

  bool _isProgress(ToolExecutionResult result) {
    return switch (result.errorCode) {
      null => true,
      ToolResultErrorCode.executionFailed ||
      ToolResultErrorCode.timedOut => true,
      _ => false,
    };
  }

  Map<String, Object?> _repairFeedback(
    ModelTurn turn, {
    required int attempt,
    required int remainingAttempts,
  }) => <String, Object?>{
    'status': 'error',
    'code': turn is EmptyTurn ? 'empty_model_turn' : 'invalid_tool_format',
    'retryable': true,
    'attempt': attempt,
    'remaining_attempts': remainingAttempts,
    'message':
        'Correct the malformed output. Return either plain text or valid tool '
        'JSON using name and parameters.',
    'single_call_example': <String, Object?>{
      'name': 'function_name',
      'parameters': <String, Object?>{},
    },
  };

  Future<String> _finalize({
    required String runId,
    required int modelRound,
    required bool hasSuccessfulSideEffect,
    required LlmErrorCode code,
  }) async {
    await chat.addProtocolFeedback(<String, Object?>{
      'status': 'error',
      'code': 'tool_loop_stopped',
      'tools_disabled': true,
      'message': 'Answer the user in plain text without calling more tools.',
    });
    final turn = await collector.collect(chat.generate());
    if (turn case FinalTextTurn(:final text)) return text;

    _log(runId, modelRound, 'finalization_failed');
    throw LlmRuntimeException(
      code,
      hasSuccessfulSideEffect
          ? 'The assistant could not finish the response. Some requested '
                'actions may already have completed.'
          : 'The assistant could not complete the tool request. Please try '
                'again.',
    );
  }

  void _log(String runId, int round, String stage) {
    if (!kDebugMode) return;
    debugPrint('tool_run run=$runId round=$round stage=$stage');
  }

  void _diagnose(
    String runId,
    int round,
    String stage, {
    String? toolName,
    String? errorCode,
  }) {
    _diagnosticSink?.call(
      runId: runId,
      round: round,
      stage: stage,
      toolName: toolName,
      errorCode: errorCode,
    );
  }

  static String _defaultRunId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}
