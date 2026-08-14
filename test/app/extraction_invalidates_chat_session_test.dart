import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/app/app_controller.dart';
import 'package:mybuddy/app/model_controller.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/model/model_descriptor.dart';
import 'package:mybuddy/core/model/model_store.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/llm/fakes/fake_llm_platform.dart';

/// T-21 and T-29, which are one fault with two symptoms.
///
/// The extraction pass opens its own session and deliberately leaves `_chat`
/// alone, on the reasoning that a separate session cannot disturb it. The
/// vendored fork says otherwise: `MediaPipeEngine.createSession` builds every
/// session from the same `LlmInference`, and that engine holds the working
/// context, so generating from a second session leaves the first one's context
/// gone.
///
/// Nothing caught it because `needsRebuild` only asked whether the composed
/// system prompt had changed, and an extraction that stores nothing leaves it
/// identical. So the app kept a session the native side had already emptied,
/// and said so in the log: `session_rebuilt=N`, `replayed_message_count=0`.
///
/// What that cost, on the device:
///
/// * **T-21** - `ttft_ms` on the next turn went from 1,843-1,925 to
///   20,601-27,799 in E1 block 2, the whole prompt being prefilled again.
/// * **T-29** - that turn also answered as if the conversation had not
///   happened. E2's condition A and condition B produced byte-identical replies
///   in all twelve pairs, and E1's `nowait` arm, which never runs extraction,
///   is the control that still remembers.
class _FakeModelStore extends ModelStore {
  @override
  Future<List<InstalledModel>> listInstalled() async => const <InstalledModel>[];

  @override
  Future<String> resolveLocalPath(String fileName) async => fileName;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLlmPlatform platform;
  late LlmService llm;
  late AppController app;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final memory = MemoryService();
    platform = FakeLlmPlatform();
    llm = LlmService(
      platform: platform,
      unityBridge: UnityBridge(),
      memoryService: memory,
    );
    app = AppController(
      models: ModelController(store: _FakeModelStore()),
      llm: llm,
      memory: memory,
    );
  });

  test('an ordinary turn reuses the session', () async {
    // The control. Without this the test below would pass even if the session
    // were rebuilt on every single turn, which would be a different bug.
    await app.chatOnce('first');
    final afterFirst = platform.createChatCount;

    await app.chatOnce('second');

    expect(platform.createChatCount, afterFirst);
    expect(app.turnLog.entries.last.sessionRebuilt, isFalse);
  });

  test('a turn after extraction rebuilds and replays', () async {
    await app.chatOnce('I am cutting down on coffee');
    await app.chatOnce('and switching to tea');
    final before = platform.createChatCount;

    // The fake's default response is not JSON, so nothing is stored and the
    // composed system prompt is unchanged. Any rebuild after this is therefore
    // attributable to the extraction pass and not to a prompt change.
    await llm.extractMemoryFromChat('{}');

    await app.chatOnce('what should I get at the cafe?');

    expect(
      platform.createChatCount,
      before + 1,
      reason: 'the session extraction emptied must not be reused',
    );

    final row = app.turnLog.entries.last;
    expect(row.sessionRebuilt, isTrue, reason: 'and it must say so');
    expect(
      row.replayedMessageCount,
      greaterThan(0),
      reason: 'T-29: the conversation has to be put back, or the model '
          'answers as though it never happened',
    );
  });

  test('only the first turn after extraction pays for it', () async {
    await app.chatOnce('first');
    await llm.extractMemoryFromChat('{}');

    await app.chatOnce('second');
    final afterRebuild = platform.createChatCount;
    await app.chatOnce('third');

    expect(
      platform.createChatCount,
      afterRebuild,
      reason: 'the flag has to clear, or every later turn re-prefills too',
    );
    expect(app.turnLog.entries.last.sessionRebuilt, isFalse);
  });

  test('an extraction that fails still invalidates the session', () async {
    // What matters is that a second session generated on this LlmInference at
    // all. On this build every measured pass failed, so a fix that only
    // triggered on success would never once have run.
    await app.chatOnce('first');
    final before = platform.createChatCount;

    // A repeated answer rather than the `!%` runaway: the extraction path now
    // aborts on a repeated line, and leaves a single unbroken line to the
    // character ceiling. Either ends the pass; this one ends it in three lines.
    platform.asyncResponseBatches.add(List<String>.filled(20, 'name: Nott\n'));
    await expectLater(
      llm.extractMemoryFromChat('{}'),
      throwsA(isA<MemoryExtractionAbortedException>()),
    );

    await app.chatOnce('second');

    expect(platform.createChatCount, before + 1);
  });
}
