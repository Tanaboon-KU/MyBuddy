import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/app/app_controller.dart';
import 'package:mybuddy/app/model_controller.dart';
import 'package:mybuddy/core/diagnostics/battery_status_service.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/model/model_descriptor.dart';
import 'package:mybuddy/core/model/model_store.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/llm/fakes/fake_llm_platform.dart';

/// End-to-end coverage of T-04: one log row per turn, populated from the
/// generation telemetry and the extraction outcome.
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
  late MemoryService memory;
  late AppController app;
  late List<MethodCall> batteryCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    batteryCalls = <MethodCall>[];

    const channel = MethodChannel(BatteryStatusService.defaultChannelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          batteryCalls.add(call);
          return <String, Object?>{'percent': 84, 'temperatureC': 31.5};
        });

    platform = FakeLlmPlatform();
    memory = MemoryService();
    llm = LlmService(
      platform: platform,
      unityBridge: UnityBridge(),
      memoryService: memory,
    );
    app = AppController(
      models: ModelController(store: _FakeModelStore()),
      llm: llm,
      memory: memory,
      battery: BatteryStatusService(channel: channel),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(BatteryStatusService.defaultChannelName),
          null,
        );
  });

  group('per-turn row', () {
    test('one row per turn, indexed from zero', () async {
      await app.chatOnce('first');
      await app.chatOnce('second');

      expect(app.turnLog.length, 2);
      expect(app.turnLog.entries.map((e) => e.turnIndex), [0, 1]);
      expect(app.turnLog.entries.map((e) => e.inputText), [
        'first',
        'second',
      ]);
    });

    test('captures prompt size and hash from the real composed prompt',
        () async {
      await app.chatOnce('hello');
      final row = app.turnLog.last!;

      expect(row.sysPromptChars, llm.lastComposedSystemChars);
      expect(
        row.sysPromptSha256,
        TurnLogEntry.hashPrompt(llm.lastComposedSystemText!),
      );
      expect(row.sysPromptSha256, hasLength(64));
    });

    test('the hash is stable while memory is unchanged and moves when it is',
        () async {
      await app.chatOnce('one');
      final first = app.turnLog.entries[0].sysPromptSha256;

      await app.chatOnce('two');
      expect(app.turnLog.entries[1].sysPromptSha256, first);

      await memory.saveMemoryData(
        const UserMemory(user: UserProfileMemory(name: 'Nott')),
      );
      await app.chatOnce('three');

      expect(app.turnLog.entries[2].sysPromptSha256, isNot(first));
    });

    test('records reply timing and time to first token', () async {
      await app.chatOnce('hello');
      final row = app.turnLog.last!;

      expect(row.replyStartMs, isNotNull);
      expect(row.replyEndMs, isNotNull);
      expect(row.replyEndMs! >= row.replyStartMs!, true);
      // The fake streams a chunk, so ttft must be observed.
      expect(row.ttftMs, isNotNull);
      expect(row.ttftMs! >= 0, true);
    });

    test('flags the turn where the session was rebuilt', () async {
      await app.chatOnce('one');
      expect(app.turnLog.entries[0].sessionRebuilt, true);

      await app.chatOnce('two');
      expect(app.turnLog.entries[1].sessionRebuilt, false);

      // A memory write changes the prompt, forcing a rebuild on the next turn.
      await memory.saveMemoryData(
        const UserMemory(user: UserProfileMemory(name: 'Nott')),
      );
      await app.chatOnce('three');
      expect(app.turnLog.entries[2].sessionRebuilt, true);
      expect(app.turnLog.entries[2].replayedMessageCount, greaterThan(0));
    });

    test('reads the battery once per turn', () async {
      await app.chatOnce('hello');
      final row = app.turnLog.last!;

      expect(batteryCalls.map((c) => c.method), ['read']);
      expect(row.batteryPct, 84);
      expect(row.batteryTempC, 31.5);
    });

    test('still writes a row when the turn throws', () async {
      platform.failNextAddQuery = true;
      platform.failAfterAccept = true;

      await expectLater(app.chatOnce('doomed'), throwsA(isA<Exception>()));

      expect(app.turnLog.length, 1);
      expect(app.turnLog.last!.inputText, 'doomed');
      expect(app.turnLog.last!.notes, contains('chat failed'));
    });

    test('starts a fresh session id and turn index on a new conversation',
        () async {
      await app.chatOnce('one');
      final firstSession = app.sessionId;

      await app.startNewConversation();
      await app.chatOnce('two');

      expect(app.sessionId, isNot(firstSession));
      expect(app.turnLog.entries.last.turnIndex, 0);
      expect(app.turnLog.length, 2, reason: 'earlier rows must be kept');
    });
  });

  group('extraction columns', () {
    test('are NOT_RUN until the pass actually runs', () async {
      await app.chatOnce('hello');
      final row = app.turnLog.last!;

      expect(row.extractParseResult, ExtractionParseResult.notRun);
      expect(row.extractStartMs, isNull);
      expect(row.extractTotalMs, isNull);
    });

    test('forceExtractionNow fills timing and marks the row as forced',
        () async {
      await app.chatOnce('I am cutting down on coffee');
      await app.forceExtractionNow();

      final row = app.turnLog.last!;
      expect(row.extractStartMs, isNotNull);
      expect(row.extractEndMs, isNotNull);
      expect(row.extractTotalMs! >= 0, true);
      expect(row.notes, contains('forced'));
    });

    test('records FAILED with the raw output when the model returns junk',
        () async {
      await app.chatOnce('hello');
      // The fake replies with plain prose, which holds no JSON object.
      await app.forceExtractionNow();

      final row = app.turnLog.last!;
      expect(row.extractParseResult, ExtractionParseResult.failed);
      expect(row.extractRawOutput, isNotNull);
      expect(row.memoryChanged, false);
    });

    test('skips extraction and says so when consent is off', () async {
      await memory.setAutoUpdateAllowed(false);
      await app.chatOnce('hello');

      await app.forceExtractionNow();

      final row = app.turnLog.last!;
      expect(row.extractParseResult, ExtractionParseResult.notRun);
      expect(row.notes, contains('allowAutoUpdate is off'));
      expect(app.extractionPhase, ExtractionPhase.idle);
    });
  });

  group('extraction signal', () {
    test('moves idle -> scheduled -> running -> complete', () async {
      expect(app.extractionPhase, ExtractionPhase.idle);

      await app.chatOnce('hello');
      expect(app.extractionPhase, ExtractionPhase.scheduled);
      expect(app.extractionScheduledFor, isNotNull);

      await app.forceExtractionNow();
      expect(app.extractionPhase, ExtractionPhase.complete);
      expect(app.lastExtractionCompletedAt, isNotNull);
      expect(app.lastExtractionResult, isNotNull);
    });

    test('resets to idle on a new conversation', () async {
      await app.chatOnce('hello');
      await app.startNewConversation();

      expect(app.extractionPhase, ExtractionPhase.idle);
      expect(app.extractionScheduledFor, isNull);
    });

    test('the scheduled deadline is short enough to run between turns',
        () async {
      await app.chatOnce('hello');

      final remaining = app.extractionScheduledFor!.difference(DateTime.now());
      // This was "shows the one-minute debounce (RC-1)", and the note on it
      // asked for the expectation to be changed deliberately if the wait ever
      // shortened rather than left to drift. It has, so here is the reason.
      //
      // T26_lines measured that a value only reaches `user.facts` when the user
      // said it in the last turn before the pass runs - the same sentence is
      // lost at position 3 and stored at position 4, three runs each. A minute
      // restarted by every turn meant one pass per conversation, so one
      // sentence out of five could reach that field and the rest were gone.
      // Three seconds gives every turn a pass in which it is the last one.
      expect(remaining.inSeconds, lessThan(30));
    });
  });

  group('csv export', () {
    test('round-trips every recorded turn', () async {
      await app.chatOnce('first');
      await app.chatOnce('second');

      final lines = app.turnLog.toCsv().trim().split('\n');
      expect(lines.first, TurnLogEntry.csvHeader);
      expect(lines.length, 3);
      expect(lines[1], startsWith(app.sessionId));
    });
  });
}
