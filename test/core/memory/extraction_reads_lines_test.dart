import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/fakes/fake_llm_platform.dart';

/// T-26 item 1: the automatic pass asks for lines, and this is the end of that
/// path - what the model answers has to reach memory.
class _StubLlm extends LlmService {
  _StubLlm({required this.response, required this.turns})
    : super(
        platform: FakeLlmPlatform(),
        unityBridge: UnityBridge(),
        memoryService: MemoryService(),
      );

  final String response;
  final List<String> turns;

  @override
  List<String> get userTurns => turns;

  @override
  Future<String> extractUserMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
    bool reAskAllTurns = false,
  }) async => response;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService service;

  const turns = <String>[
    'My name is Nott.',
    'I work as a software engineer.',
    'My goal this year is to run a half marathon.',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = MemoryService();
  });

  test('a line answer reaches memory', () async {
    final llm = _StubLlm(
      response: '''
name: Nott
traits: NONE
preferences: NONE
goals: run a half marathon this year
facts: works as a software engineer
''',
      turns: turns,
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);
    final stored = await service.loadUserMemoryData();

    expect(outcome.parseResult, ExtractionParseResult.valid);
    expect(stored.name, 'Nott');
    expect(stored.goals, contains('run a half marathon this year'));
    expect(stored.facts, contains('works as a software engineer'));
  });

  test('all NONE is no change, not a failure', () async {
    final llm = _StubLlm(
      response: '''
name: NONE
traits: NONE
preferences: NONE
goals: NONE
facts: NONE
''',
      turns: turns,
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);

    expect(outcome.parseResult, ExtractionParseResult.noChange);
    expect(outcome.memoryChanged, isFalse);
  });

  test('the grounding check still applies to a line answer', () async {
    // The two halves of this work meet here: the format made the answer
    // readable, and the grounding check decides whether it is the user's.
    final llm = _StubLlm(
      response: 'goals: Explore new hiking trails in Chiang Mai.',
      turns: turns,
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);
    final stored = await service.loadUserMemoryData();

    expect(stored.goals, isEmpty);
    expect(outcome.rejectionCodes.join(','), contains('ungrounded'));
  });

  test('a model that answers in JSON anyway is still read', () async {
    // Keeping the old reader is not politeness. The prompt changed, the model
    // did not, and 32 runs say it reproduces whatever JSON is nearest. If it
    // falls back, the answer should still land rather than be recorded as a
    // failure that never happened.
    final llm = _StubLlm(
      response:
          '{"updates":[{"section":"user","field":"goals","action":"add",'
          '"value":"run a half marathon this year"}]}',
      turns: turns,
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);
    final stored = await service.loadUserMemoryData();

    expect(outcome.parseResult, ExtractionParseResult.valid);
    expect(stored.goals, contains('run a half marathon this year'));
  });

  test('junk is still a failure', () async {
    final llm = _StubLlm(response: 'I am not sure what you mean.', turns: turns);

    final outcome = await service.updateMemoryFromChat(llm: llm);

    expect(outcome.parseResult, ExtractionParseResult.failed);
  });
}
