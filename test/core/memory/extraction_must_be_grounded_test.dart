import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/fakes/fake_llm_platform.dart';

/// T-26, the write-path fabrication. The automatic pass wrote
/// `Explore new hiking trails in Chiang Mai.` into `user.goals` on three runs
/// of a conversation where the user never mentioned a goal, and it stayed,
/// because the user layer goes back into the prompt every turn after that.
///
/// E4 measured `fabrication = 0`, but only on the read path. This is the write
/// path, and nothing was checking it.
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
  }) async => response;
}

String _patch(String field, String value) =>
    '{"updates":[{"section":"user","field":"$field",'
    '"action":"add","value":"$value"}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService service;

  const noGoalTurns = <String>[
    'My name is Nott.',
    'I love hiking on weekends.',
    'I work as a software engineer.',
    "I'm allergic to peanuts.",
    'I live in Chiang Mai.',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = MemoryService();
  });

  test('a goal the user never stated is not written to memory', () async {
    final llm = _StubLlm(
      response: _patch('goals', 'Explore new hiking trails in Chiang Mai.'),
      turns: noGoalTurns,
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);
    final stored = await service.loadUserMemoryData();

    expect(stored.goals, isEmpty);
    expect(outcome.memoryChanged, isFalse);
  });

  test('the rejection says why, so the log can show it', () async {
    final llm = _StubLlm(
      response: _patch('goals', 'Explore new hiking trails in Chiang Mai.'),
      turns: noGoalTurns,
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);

    expect(outcome.parseResult, ExtractionParseResult.rejected);
    expect(outcome.rejectionCodes.join(','), contains('ungrounded'));
    expect(outcome.rejectionCodes.join(','), contains('goals'));
  });

  test('what the user did say is still written', () async {
    // The same pass, the same shape of patch, on the conversation where the
    // user stated the goal. Fifteen T-26 runs produced exactly this value.
    final llm = _StubLlm(
      response: _patch('goals', 'run a half marathon this year'),
      turns: const <String>[
        'My name is Nott.',
        'My goal this year is to run a half marathon.',
      ],
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);
    final stored = await service.loadUserMemoryData();

    expect(stored.goals, contains('run a half marathon this year'));
    expect(outcome.parseResult, ExtractionParseResult.valid);
    expect(outcome.memoryChanged, isTrue);
  });

  test('a grounded patch still applies when another is rejected', () async {
    final llm = _StubLlm(
      response:
          '{"updates":['
          '{"section":"user","field":"facts","action":"add",'
          '"value":"allergic to peanuts"},'
          '{"section":"user","field":"goals","action":"add",'
          '"value":"Explore new hiking trails in Chiang Mai."}'
          ']}',
      turns: noGoalTurns,
    );

    final outcome = await service.updateMemoryFromChat(llm: llm);
    final stored = await service.loadUserMemoryData();

    expect(stored.facts, contains('allergic to peanuts'));
    expect(stored.goals, isEmpty);
    expect(outcome.parseResult, ExtractionParseResult.valid);
    expect(outcome.rejectionCodes.join(','), contains('ungrounded'));
  });
}
