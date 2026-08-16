import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';

import 'fakes/fake_llm_platform.dart';

/// One failed extraction must not take the next one with it.
///
/// Measured on the handset with a six-turn conversation, three runs. The idle
/// timer fired a pass mid-conversation, it aborted at ~12s, and the pass after
/// it died before generating anything:
///
///   IllegalStateException: Previous invocation still processing. Wait for done=true.
///     at LlmInferenceSession.close(LlmInferenceSession.java:344)
///     at MediaPipeSession.close(MediaPipeSession.kt:109)
///     at PlatformServiceImpl$createSession$1.invokeSuspend(FlutterGemmaPlugin.kt:203)
///
/// Breaking out of the response stream stops Dart reading, but the native
/// invocation is still running, so `close()` throws. That throw was swallowed,
/// the session stayed open, and the *plugin* then closed it while creating the
/// next session - which is where it surfaced, one pass later and nowhere near
/// the cause. Two of three runs, nothing stored in any of them.
///
/// The five-turn set hid this for 45 runs by only ever extracting once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLlmPlatform platform;
  late LlmService service;

  setUp(() {
    platform = FakeLlmPlatform();
    service = LlmService(
      platform: platform,
      unityBridge: UnityBridge(),
      memoryService: MemoryService(),
    );
  });

  test('a session that will not close does not break the next pass', () async {
    await service.generateChat(systemText: 'sys', userText: 'My name is Nott.');

    platform.failSessionClose = true;
    await service.extractUserMemoryFromChat('{}');

    // The next pass has to reach the model rather than die closing the corpse
    // of the last one.
    platform.failSessionClose = false;
    final modelsBefore = platform.getActiveModelCount;

    await service.generateChat(systemText: 'sys', userText: 'I like tea.');
    final second = await service.extractUserMemoryFromChat('{}');

    expect(second, isNotEmpty, reason: 'the second pass must still run');
    expect(
      platform.getActiveModelCount,
      greaterThan(modelsBefore),
      reason: 'a wedged session means the model is rebuilt before it is reused',
    );
  });

  test('recovering from a wedged session keeps the conversation', () async {
    // The first version of this fix called _resetNativeState, which clears the
    // canonical dialogue along with the model. On the handset that turned the
    // crash into something quieter and just as useless: the pass after the
    // wedged one ran in 1ms against an empty conversation and stored nothing,
    // three runs of three. Reloading the engine must not throw away what the
    // user said.
    await service.generateChat(systemText: 'sys', userText: 'My name is Nott.');

    platform.failSessionClose = true;
    await service.extractUserMemoryFromChat('{}');
    platform.failSessionClose = false;

    // No new turn in between - the next pass has only the earlier conversation
    // to work from, which is exactly the case that failed on the device.
    final recovered = await service.extractUserMemoryFromChat('{}');

    expect(
      recovered,
      isNotEmpty,
      reason: 'the conversation must survive the model reload',
    );
    expect(service.userTurns, contains('My name is Nott.'));
  });

  test('an ordinary pass does not rebuild the model', () async {
    await service.generateChat(systemText: 'sys', userText: 'My name is Nott.');
    await service.extractUserMemoryFromChat('{}');
    final modelsBefore = platform.getActiveModelCount;

    await service.generateChat(systemText: 'sys', userText: 'I like tea.');
    await service.extractUserMemoryFromChat('{}');

    expect(
      platform.getActiveModelCount,
      modelsBefore,
      reason: 'reloading the model costs seconds and heat; only do it when the '
          'session is actually stuck',
    );
  });
}
