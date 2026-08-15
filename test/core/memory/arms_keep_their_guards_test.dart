import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/extraction_arm.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/fakes/fake_llm_platform.dart';

/// The guards belong to the write path, not to one arm of it.
///
/// Going back to the JSON pass the protocol describes must not quietly take the
/// fabrication check with it. The invented goal from ng1-3 scores 0.33 against
/// ExtractionGrounding's 0.6 threshold, and that arithmetic has nothing to do
/// with whether the model produced JSON or lines - but nothing had ever proved
/// the JSON path still runs it, and asserting it in prose is not proof.
///
/// If this file ever goes red, reverting the format silently removes the only
/// thing standing between a fabricated allergy and a memory that is read back
/// into every prompt.
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
    ExtractionArm? arm,
  }) async => response;
}

const _noGoalTurns = <String>[
  'My name is Nott.',
  'I love hiking on weekends.',
  'I work as a software engineer.',
  "I'm allergic to peanuts.",
  'I live in Chiang Mai.',
];

String _json(String field, String value) =>
    '{"updates":[{"section":"user","field":"$field",'
    '"action":"add","value":"$value"}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = MemoryService();
  });

  for (final arm in ExtractionArm.values) {
    group('${arm.label} arm', () {
      test('refuses the goal the model invented in ng1, ng2 and ng3', () async {
        final llm = _StubLlm(
          response: _json('goals', 'Explore new hiking trails in Chiang Mai.'),
          turns: _noGoalTurns,
        );

        final outcome = await service.updateMemoryFromChat(llm: llm, arm: arm);
        final stored = await service.loadUserMemoryData();

        expect(stored.goals, isEmpty);
        expect(outcome.rejectionCodes.join(','), contains('ungrounded'));
      });

      test('files an allergy under facts wherever the model put it', () async {
        final llm = _StubLlm(
          response: _json('preferences', 'allergic to peanuts'),
          turns: _noGoalTurns,
        );

        await service.updateMemoryFromChat(llm: llm, arm: arm);
        final stored = await service.loadUserMemoryData();

        expect(stored.facts, contains('allergic to peanuts'));
        expect(stored.preferences, isEmpty);
      });

      test('still stores what the user did say', () async {
        final llm = _StubLlm(
          response: _json('goals', 'run a half marathon this year'),
          turns: const <String>[
            'My name is Nott.',
            'My goal this year is to run a half marathon.',
          ],
        );

        final outcome = await service.updateMemoryFromChat(llm: llm, arm: arm);
        final stored = await service.loadUserMemoryData();

        expect(stored.goals, contains('run a half marathon this year'));
        expect(outcome.parseResult, ExtractionParseResult.valid);
      });
    });
  }

  group('what separates the arms', () {
    test('only the rules arm writes what the model never produced', () async {
      // The model says nothing usable. In the two model-only arms that is the
      // end of it; with rules the occupation and the allergy are already
      // captured from the user's own turns.
      Future<UserProfileMemory> run(ExtractionArm arm) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final fresh = MemoryService();
        await fresh.updateMemoryFromChat(
          llm: _StubLlm(response: '{"updates":[]}', turns: _noGoalTurns),
          arm: arm,
          ruleCaptures: arm.usesRules
              ? _noGoalTurns
              : const <String>[],
        );
        return fresh.loadUserMemoryData();
      }

      expect((await run(ExtractionArm.json)).facts, isEmpty);
      expect((await run(ExtractionArm.lines)).facts, isEmpty);

      final withRules = await run(ExtractionArm.linesRules);
      expect(withRules.facts, contains('allergic to peanuts'));
      expect(withRules.facts, contains('works as a software engineer'));
      expect(withRules.name, 'Nott');
    });
  });

  test('in the rules arm the model may not write what the rules own', () async {
    // Measured, arm_lines_rules_1..3. Rules write the facts, so for the first
    // time in this project <already_known> was not empty - and the model read
    // its own memory back and answered with it:
    //
    //   facts: works as a software engineer, allergic to peanuts
    //
    // stored as a third entry beside the two real ones. The prompt says "NONE
    // if it is already known"; wording has never steered this model and did not
    // here either.
    //
    // So ownership is enforced where it can be, in the write policy: in this arm
    // `name` and `facts` come from the rules and a model patch for either is
    // dropped. The prompt is byte-identical to the lines arm, so the two arms
    // still differ by one thing.
    final llm = _StubLlm(
      response: 'name: Someone Else\n'
          'traits: detail-oriented\n'
          'facts: works as a software engineer, allergic to peanuts\n',
      turns: const <String>[
        'My name is Nott.',
        "I'm a very detail-oriented person.",
        'I work as a software engineer.',
      ],
    );

    final outcome = await service.updateMemoryFromChat(
      llm: llm,
      arm: ExtractionArm.linesRules,
      ruleCaptures: const <String>[
        'My name is Nott.',
        'I work as a software engineer.',
      ],
    );
    final stored = await service.loadUserMemoryData();

    expect(stored.name, 'Nott', reason: 'the rules own the name');
    expect(stored.facts, <String>['works as a software engineer']);
    expect(stored.traits, contains('detail-oriented'),
        reason: 'traits still belong to the model');
    expect(outcome.rejectionCodes.join(','), contains('ruleOwned'));
  });
}
