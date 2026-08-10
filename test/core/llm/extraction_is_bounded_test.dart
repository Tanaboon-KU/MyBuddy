import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/app/app_controller.dart';
import 'package:mybuddy/app/model_controller.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/model/model_descriptor.dart';
import 'package:mybuddy/core/model/model_store.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_llm_platform.dart';

/// T-28: an extraction pass has to stop on its own.
///
/// E1 block 2 measured five passes averaging 178,016 ms that every one of them
/// then failed to parse. Nothing stopped them - the `Duration(seconds: 60)` on
/// the stream is `Stream.timeout`, which measures the gap between events, so a
/// model emitting steadily never trips it. The user waits three minutes for
/// nothing and, through T-21, pays again on the following turn.
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

  setUp(() async {
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
    // Extraction short-circuits on an empty dialogue, so give it a turn to
    // work from. Consumes the fake's default batch, leaving anything queued
    // afterwards for the extraction call itself.
    await app.chatOnce('I am cutting down on coffee');
  });

  test('stops a pass whose output has collapsed into repetition', () async {
    // The shape of the real 5,438-character runaway, in the fake's chunks.
    platform.asyncResponseBatches.add(List<String>.filled(100, '!%'));

    await expectLater(
      llm.extractMemoryFromChat('{}'),
      throwsA(
        isA<MemoryExtractionAbortedException>()
            .having((e) => e.reason, 'reason', 'repetition'),
      ),
    );
  });

  test('cuts the pass off before it consumes everything on offer', () async {
    // The point of the exercise: not that it fails, it failed before too, but
    // that it stops early. 200 characters were on offer and the guard needs
    // 120 before it will judge anything, so it should land between the two.
    platform.asyncResponseBatches.add(List<String>.filled(100, '!%'));

    try {
      await llm.extractMemoryFromChat('{}');
      fail('expected the pass to be aborted');
    } on MemoryExtractionAbortedException catch (e) {
      expect(e.chars, greaterThanOrEqualTo(120));
      expect(e.chars, lessThan(200));
    }
  });

  test('stops a pass that runs past the character ceiling', () async {
    // Diverse text, so the repetition guard has nothing to say and the length
    // ceiling is what has to catch it. A real patch for this schema is a
    // couple of hundred characters.
    final prose = File(
      'test/fixtures/coherent_long_reply.txt',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final chunks = <String>[];
    for (var i = 0; i < prose.length; i += 100) {
      chunks.add(prose.substring(i, (i + 100).clamp(0, prose.length)));
    }
    platform.asyncResponseBatches.add([...chunks, ...chunks]);

    await expectLater(
      llm.extractMemoryFromChat('{}'),
      throwsA(
        isA<MemoryExtractionAbortedException>()
            .having((e) => e.reason, 'reason', 'char-limit')
            .having((e) => e.chars, 'chars', greaterThan(2000)),
      ),
    );
  });

  test('leaves an ordinary pass alone', () async {
    // The guard must not touch the case it was never aimed at. This is the
    // shape of the one extraction that has ever succeeded on this build.
    platform.asyncResponseBatches.add([
      '{"updates":[{"section":"user","field":"goals",',
      '"action":"add","value":"Run a half marathon this year"}]}',
    ]);

    final raw = await llm.extractMemoryFromChat('{}');

    expect(raw, contains('half marathon'));
    expect(raw.length, lessThan(LlmService.extractionCharLimit));
  });

  test('the ceilings are set clear of anything a real pass produces', () async {
    // Pinned so neither can be tightened to the point of cutting off working
    // extractions. The successful T-07 verification finished in 10.3s, and
    // pre-fix passes averaged 6.7s against this 90s deadline.
    expect(LlmService.extractionDeadline.inSeconds, greaterThanOrEqualTo(60));
    expect(LlmService.extractionCharLimit, greaterThan(500));
  });
}
