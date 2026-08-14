import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/app/app_controller.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/app/model_controller.dart';
import 'package:mybuddy/core/model/model_store.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/llm/fakes/fake_llm_platform.dart';

class _FakeModelStore implements ModelStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Every turn gets to be the last one.
///
/// Sixty-three runs measured a rule the memory system never intended: a value
/// only reaches `user.facts` when the user said it in the final turn before
/// extraction runs. The same allergy sentence at position 3 is lost three runs
/// of three, and at position 4 is stored three of three, with everything else
/// held constant. `name`, `traits` and `goals` come out of any position; facts
/// do not. That is why "I work as a software engineer" was lost in all 51 runs
/// that contained it - it never once sat at the end.
///
/// The debounce is what made every turn but the last invisible. It cancelled
/// and restarted on each turn and only fired after five of them, so a five-turn
/// conversation extracted exactly once, from the end. Scheduling after every
/// turn gives each sentence one pass in which it is the last thing said.
///
/// The timings this replaces are RC-1 in ROOT_CAUSE_ANALYSIS.md and the comment
/// on them says not to change them without before/after data. T26_lines is the
/// before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLlmPlatform platform;
  late AppController app;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    platform = FakeLlmPlatform();
    final memory = MemoryService();
    app = AppController(
      models: ModelController(store: _FakeModelStore()),
      llm: LlmService(
        platform: platform,
        unityBridge: UnityBridge(),
        memoryService: memory,
      ),
      memory: memory,
    );
  });

  test('one turn schedules a pass', () async {
    await app.chatOnce('My name is Nott.');

    expect(app.extractionPhase, ExtractionPhase.scheduled);
  });

  test('every turn is due soon, not only the fifth', () async {
    // Being "scheduled" was never the problem - the old path scheduled after
    // every turn too, a minute out, and cancelled it when the next turn
    // arrived. In a conversation that pass never came due, so only the sentence
    // the user stopped on could reach `facts`. Only the fifth turn got the
    // three-second treatment, which is why five-turn runs extract exactly once.
    for (final turn in const <String>[
      'My name is Nott.',
      'I am a very detail-oriented person.',
      'I work as a software engineer.',
      'I am allergic to peanuts.',
    ]) {
      await app.chatOnce(turn);
      final due = app.extractionScheduledFor;
      expect(due, isNotNull, reason: 'a pass should be due after "$turn"');
      expect(
        due!.difference(DateTime.now()),
        lessThan(const Duration(seconds: 30)),
        reason: 'and due soon enough to run before the next turn: "$turn"',
      );
    }
  });

  test('the pass is due in seconds, not a minute', () async {
    // The old path scheduled a minute out and restarted that on every turn, so
    // in a conversation nothing was ever due. What the delay is for now is
    // letting a fast typist's next keystroke land first, not waiting for them
    // to go away.
    await app.chatOnce('My name is Nott.');

    final due = app.extractionScheduledFor;
    expect(due, isNotNull);
    expect(
      due!.difference(DateTime.now()),
      lessThan(const Duration(seconds: 30)),
    );
  });
}
