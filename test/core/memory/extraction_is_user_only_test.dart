import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/fakes/fake_llm_platform.dart';

/// T-26. The automatic extraction pass asks about the USER layer only.
///
/// Fifteen runs established the failure is not wording: across all three
/// promptings tried, the model reproduces whatever JSON sits nearest the
/// generation point and cannot separate its instructions from the conversation
/// it is meant to analyse. Config C is the clearest case - it wrote the
/// extraction prompt's own opening line into `user.goals` and its own name into
/// `identity.assistant_name`, three runs running, byte-identical.
///
/// Choosing a section is part of what it was being asked to get right, and that
/// is where config C visibly failed. A user-only pass removes the choice.
///
/// T-26 listed this and weighed it against "three calls instead of one, each
/// costing a session rebuild through T-21". Neither half holds now: it is one
/// call, because the paper's claim is about user facts, and T-21 is fixed so
/// the rebuild happens once per turn however many passes ran.
class _StubLlm extends LlmService {
  _StubLlm(this.response)
    : super(
        platform: FakeLlmPlatform(),
        unityBridge: UnityBridge(),
        memoryService: MemoryService(),
      );

  final String response;
  int userCalls = 0;
  int allSectionCalls = 0;

  // This file is about which section the pass may write to, so every patch it
  // sends has to reach `allowedSections` to be judged there. The grounding
  // check runs first and drops anything the user never said, which on a stub
  // with no conversation is everything - the soul and identity cases would
  // still come back `rejected`, but for provenance rather than routing, and
  // would no longer prove what they are here to prove. These three sentences
  // ground every value the file uses, so the routing rules stay under test.
  @override
  List<String> get userTurns => const <String>[
    'My goal this year is to run a half marathon.',
    'Be sarcastic with me.',
    'I think your name is Qwen.',
  ];

  @override
  Future<String> extractUserMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async {
    userCalls++;
    return response;
  }

  @override
  Future<String> extractMemoryFromChat(
    String currentMemoryJson, {
    Set<String> lockedFields = const <String>{},
  }) async {
    allSectionCalls++;
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = MemoryService();
  });

  test('the automatic pass asks for the USER layer, not all three', () async {
    final llm = _StubLlm('{"updates":[]}');

    await service.updateMemoryFromChat(llm: llm);

    expect(llm.userCalls, 1);
    expect(llm.allSectionCalls, 0);
  });

  test('a user patch still applies', () async {
    const raw =
        '{"updates":[{"section":"user","field":"goals","action":"add",'
        '"value":"Run a half marathon this year"}]}';

    final outcome = await service.updateMemoryFromChat(llm: _StubLlm(raw));

    expect(outcome.parseResult, ExtractionParseResult.valid);
    expect((await service.loadMemoryData()).user.goals,
        contains('Run a half marathon this year'));
  });

  test('a soul patch is refused even if the model names the section', () async {
    // The prompt asks for user only; allowedSections enforces it. Config C
    // showed the model naming a section it was not asked about, so the prompt
    // alone is not enough.
    const raw =
        '{"updates":[{"section":"soul","field":"mission","action":"set",'
        '"value":"Be sarcastic"}]}';

    final before = (await service.loadMemoryData()).toJsonString();
    final outcome = await service.updateMemoryFromChat(llm: _StubLlm(raw));

    expect(outcome.parseResult, ExtractionParseResult.rejected);
    expect((await service.loadMemoryData()).toJsonString(), before);
  });

  test('an identity patch is refused too', () async {
    // Config C's other half: it set identity.assistant_name to the model's own
    // name, "Qwen", in all three runs.
    const raw =
        '{"updates":[{"section":"identity","field":"assistant_name",'
        '"action":"set","value":"Qwen"}]}';

    final outcome = await service.updateMemoryFromChat(llm: _StubLlm(raw));

    expect(outcome.parseResult, ExtractionParseResult.rejected);
    expect((await service.loadMemoryData()).identity.assistantName, isNull);
  });

  test('the tool-call path can still write soul and identity', () async {
    // Narrowing the automatic pass must not make those layers unwritable. E3
    // measured the model writing both through the tool-call path during
    // ordinary chat, and that path is untouched.
    final result = await service.updateMemoryFromToolCall(
      toolName: 'update_assistant_soul',
      args: <String, dynamic>{
        'updates': <Map<String, dynamic>>[
          <String, dynamic>{
            'field': 'mission',
            'action': 'set',
            'value': 'Help the user thrive',
          },
        ],
      },
    );

    expect(result.appliedCount, 1);
    expect((await service.loadMemoryData()).soul.mission, 'Help the user thrive');
  });
}
