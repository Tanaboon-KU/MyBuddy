import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/fakes/fake_llm_platform.dart';

/// Returns a canned extraction response instead of running a model.
class _StubExtractionLlm extends LlmService {
  _StubExtractionLlm(this.response)
    : super(
        platform: FakeLlmPlatform(),
        unityBridge: UnityBridge(),
        memoryService: MemoryService(),
      );

  final String response;

  // Same reasoning as the two overrides below. The grounding check drops any
  // value the user never said, and a stub with no conversation behind it would
  // have every patch dropped - so these tests would go red over provenance,
  // which is not what this file is about. The sentence grounds the value the
  // success case writes.
  @override
  List<String> get userTurns => const <String>[
    'My goal this year is to run a half marathon.',
  ];

  // Both, so the test keeps testing what it is about. T-26 moved the automatic
  // pass from the three-section prompt to the USER-only one; which prompt it
  // uses is not what this file is checking, and stubbing only the old entry
  // point would have made these fail for a reason unrelated to rawOutput.
  @override
  Future<String> extractMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async => response;

  @override
  Future<String> extractUserMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async => response;
}

/// T-27. `extract_raw_output` is the column §1b relies on to show what the
/// model produced, and on the one path that matters most - the pass that
/// worked - it was blank.
///
/// `MemoryExtractionOutcome` set `rawOutput: rejectionCodes.isEmpty ? null :
/// rawResponse` on success, and `TurnLogEntry.copyWith` reads null as "keep
/// what is already there". So a successful extraction left the *previous*
/// attempt's output on the row, next to its own verdict. That is worse than
/// blank: it reads as evidence.
///
/// Seen for real while verifying T-07 — a row recording VALID alongside
/// `the user: I call me call Nova assistant name Nova.`, which was the output
/// of an earlier automatic pass that had failed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = MemoryService();
  });

  test('a successful extraction records the output it actually produced', () async {
    const raw =
        '{"updates":[{"section":"user","field":"goals","action":"add",'
        '"value":"Run a half marathon this year"}]}';

    final outcome = await service.updateMemoryFromChat(
      llm: _StubExtractionLlm(raw),
    );

    expect(outcome.parseResult, ExtractionParseResult.valid);
    expect(outcome.memoryChanged, true);
    expect(
      outcome.rawOutput,
      raw,
      reason: 'a blank rawOutput here lets the previous attempt\'s output '
          'survive on the row, beside this attempt\'s verdict',
    );
  });

  test('every other outcome still carries its output', () async {
    final rejected = await service.updateMemoryFromChat(
      llm: _StubExtractionLlm(
        '{"updates":[{"section":"nonsense","field":"x","action":"set",'
        '"value":"y"}]}',
      ),
    );
    expect(rejected.parseResult, ExtractionParseResult.rejected);
    expect(rejected.rawOutput, isNotNull);

    final failed = await service.updateMemoryFromChat(
      llm: _StubExtractionLlm('not json at all'),
    );
    expect(failed.parseResult, ExtractionParseResult.failed);
    expect(failed.rawOutput, 'not json at all');

    final noChange = await service.updateMemoryFromChat(
      llm: _StubExtractionLlm('{"updates":[]}'),
    );
    expect(noChange.parseResult, ExtractionParseResult.noChange);
    expect(noChange.rawOutput, '{"updates":[]}');
  });
}
