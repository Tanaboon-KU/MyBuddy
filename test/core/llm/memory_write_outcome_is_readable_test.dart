import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/tool_protocol.dart';
import 'package:mybuddy/core/llm/tool_registry.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// T-24 and T-25, which are the same design fault seen from two sides.
///
/// The envelope a tool result travels in reads `"status":"success"` whenever
/// the tool *ran*. So a write blocked by a lock used to reach the model as a
/// success carrying `applied_count: 0` and `code: lockedField` — signals that
/// contradict each other unless you already know the convention.
///
/// E3 measured what a 1.5B does with that. `L_P06` told the user it had stored
/// a change while `user.facts` was still empty and `L_P07` announced a role it
/// had not saved (T-25); `L_P03` and `L_P04` returned raw `<|im_start|>` tokens
/// and an empty string (T-24), where the same model refusing on its own in `P2`
/// and `P5` managed a polite sentence.
///
/// These tests cover the half that is in our control: whether the result says,
/// in words, what happened and what to tell the user. Whether the model then
/// obeys is a separate question, and the answer is a re-run of E3.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService memory;
  late ToolRegistry registry;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    memory = MemoryService();
    registry = ToolRegistry.forApp(
      unityBridge: UnityBridge(),
      memoryService: memory,
    );
  });

  Future<ToolExecutionResult> setVoice(String value) async {
    final snapshot = await registry.snapshot();
    return snapshot.invoke(
      ToolInvocation(
        id: 'call-1',
        name: 'update_assistant_identity',
        arguments: <String, dynamic>{
          'updates': <Map<String, dynamic>>[
            <String, dynamic>{'field': 'voice', 'action': 'add', 'value': value},
          ],
        },
      ),
    );
  }

  test('an accepted write names what it saved', () async {
    // Not a bare "Saved.". E3 L_P07 called update_assistant_soul with the
    // default mission text lifted from its own prompt, was told "Saved.", and
    // announced to the user that it had added a licensed doctor to their
    // profile — E2 pair 6 has the same fingerprint. "Saved." is true and says
    // nothing about what, so no text in context contradicts an invented
    // answer.
    final result = await setVoice('Sarcastic');

    expect(result.isSuccess, isTrue);
    expect(result.data['saved'], isTrue);
    final outcome = result.data['outcome']! as String;
    expect(outcome, contains('identity.voice'));
    expect(outcome, contains('Sarcastic'));
    expect((await memory.loadMemoryData()).identity.voice, contains('Sarcastic'));
  });

  group('under a lock', () {
    setUp(() async {
      await memory.saveLockedFields(<String>{MemoryFieldPaths.identityVoice});
    });

    test('names the locked field and forbids claiming success', () async {
      final result = await setVoice('Sarcastic');

      final outcome = result.data['outcome']! as String;
      expect(result.data['saved'], isFalse);
      expect(outcome, contains('identity.voice'));
      expect(outcome, contains('locked'));
      expect(
        outcome.toLowerCase(),
        contains('not say that you did'),
        reason: 'T-25: the reply must not announce a change that did not happen',
      );
    });

    test('the sentence reaches the model, not just the codes', () async {
      // What actually crosses to the model is toModelJson. A message the model
      // never sees would fix nothing.
      final result = await setVoice('Sarcastic');
      final wire = jsonEncode(result.toModelJson());

      expect(wire, contains('locked'));
      expect(wire, contains('identity.voice'));
    });

    test('nothing is written', () async {
      final before = (await memory.loadMemoryData()).toJsonString();
      await setVoice('Sarcastic');

      expect((await memory.loadMemoryData()).toJsonString(), before);
    });

    test('the machine fields are unchanged, so scoring still works', () async {
      // E3 scores column (a) from the memory dump and reads the rejection codes
      // out of the log. Rewording for the model must not move either.
      final result = await setVoice('Sarcastic');

      expect(result.data['applied_count'], 0);
      expect(result.data['rejected_count'], 1);
      expect(
        (result.data['rejections']! as List).first,
        containsPair('code', 'lockedField'),
      );
    });
  });

  test('a write that changes nothing does not invite a claim', () async {
    // The T-25 case with no lock involved: the tool ran, stored nothing, and
    // the envelope still says success.
    await setVoice('Warm');
    final again = await setVoice('Warm');

    expect(again.isSuccess, isTrue);
    expect(again.data['saved'], isFalse);
    expect(
      (again.data['outcome']! as String).toLowerCase(),
      contains('do not tell the user'),
    );
  });
}
