import 'dart:async';

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

/// Covers T-01 (start a new conversation) and T-02 (reset memory to cold
/// start) from `my-tasks/TASKS.md`.
///
/// The experiment protocol resets between every E1 run, every E2 pair and all
/// 16 E3 trials, so these two operations have to be exact: a leftover turn or
/// a surviving preference key silently contaminates the next trial.
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

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
    );
  });

  group('startNewConversation', () {
    test('clears the visible transcript', () async {
      await app.chatOnce('first');
      await app.chatOnce('second');
      expect(app.conversation.length, 4); // 2 user + 2 assistant

      await app.startNewConversation();

      expect(app.conversation, isEmpty);
    });

    test('clears the history the model and extraction pass see', () async {
      await app.chatOnce('I am cutting down on coffee');

      // Non-empty canonical dialogue -> extraction actually runs.
      expect(await llm.extractMemoryFromChat('{}'), isNotEmpty);

      await app.startNewConversation();

      // Empty canonical dialogue -> extractMemoryFromChat short-circuits to ''
      // without calling the model at all.
      expect(await llm.extractMemoryFromChat('{}'), isEmpty);
    });

    test('does not reload the model', () async {
      await app.chatOnce('hello');
      final loadsBefore = platform.getActiveModelCount;
      final activationsBefore = platform.activateCount;

      await app.startNewConversation();

      expect(platform.getActiveModelCount, loadsBefore);
      expect(platform.activateCount, activationsBefore);
      expect(platform.closeModelCount, 0);
    });

    test('leaves stored memory byte-identical', () async {
      await memory.saveMemoryData(
        const UserMemory(
          user: UserProfileMemory(
            name: 'Nott',
            preferences: <String>['tea in the afternoons'],
          ),
        ),
      );
      await app.chatOnce('hello');
      final before = await memory.loadMemory();

      await app.startNewConversation();

      expect(await memory.loadMemory(), before);
    });

    test('is rejected while a reply is still generating', () async {
      final gate = platform.generationCompleter = Completer<void>();
      final pending = app.chatOnce('slow one');
      await Future<void>.delayed(Duration.zero);

      expect(app.generatingResponse, true);
      await expectLater(
        app.startNewConversation(),
        throwsA(isA<StateError>()),
      );

      gate.complete();
      platform.generationCompleter = null;
      await pending;
    });

    test('the next turn still works afterwards', () async {
      await app.chatOnce('before');
      await app.startNewConversation();

      final reply = await app.chatOnce('after');

      expect(reply, isNotEmpty);
      expect(app.conversation.length, 2);
    });
  });

  group('resetToColdStart', () {
    Future<void> seedEverything() async {
      await memory.saveMemoryData(
        const UserMemory(
          soul: SoulMemory(mission: 'help', boundaries: <String>['no lies']),
          identity: IdentityMemory(
            assistantName: 'Buddy',
            voice: <String>['Warm'],
          ),
          user: UserProfileMemory(
            name: 'Nott',
            preferences: <String>['tea'],
          ),
        ),
      );
      await memory.setAutoUpdateAllowed(false);
      await memory.saveLockedFields(<String>{
        MemoryFieldPaths.identityVoice,
        MemoryFieldPaths.soulBoundaries,
      });
    }

    test('removes every key listed in MemoryStorageKeys.all', () async {
      await seedEverything();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        MemoryStorageKeys.legacyMemory,
        '{"name":"old value"}',
      );

      await memory.resetToColdStart();

      for (final key in MemoryStorageKeys.all) {
        expect(
          prefs.containsKey(key),
          false,
          reason: '$key survived the reset',
        );
      }
    });

    test('does not resurrect the legacy v2 blob on the next load', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        MemoryStorageKeys.legacyMemory: '{"name":"Ada","facts":["stale"]}',
      });
      memory = MemoryService();

      await memory.resetToColdStart();

      expect((await memory.loadMemoryData()).isEmpty, true);
    });

    test('produces an identical dump every time', () async {
      final dumps = <String>[];
      for (var i = 0; i < 5; i++) {
        await seedEverything();
        await memory.resetToColdStart();
        dumps.add(await memory.loadMemory());
      }

      expect(dumps.toSet().length, 1, reason: 'cold start is not stable');
    });

    test('restores the consent flag to its default', () async {
      await memory.setAutoUpdateAllowed(false);
      expect(await memory.isAutoUpdateAllowed(), false);

      await memory.resetToColdStart();

      expect(await memory.isAutoUpdateAllowed(), true);
    });

    test('clears every locked-field set', () async {
      await seedEverything();

      await memory.resetToColdStart();

      expect(await memory.loadLockedFields(), isEmpty);
      expect(await memory.loadSoulLockedFields(), isEmpty);
      expect(await memory.loadIdentityLockedFields(), isEmpty);
    });

    test('leaves keys outside the memory namespace alone', () async {
      const modelKey = 'mybuddy.selected_model_id.v1';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(modelKey, 'gemma-3n-e2b-it');
      await seedEverything();

      await memory.resetToColdStart();

      expect(prefs.getString(modelKey), 'gemma-3n-e2b-it');
    });
  });

  group('resetMemoryToColdStart', () {
    test('wipes storage and the live conversation together', () async {
      await app.chatOnce('I am allergic to peanuts');
      await memory.saveMemoryData(
        const UserMemory(user: UserProfileMemory(facts: <String>['peanuts'])),
      );

      await app.resetMemoryToColdStart();

      expect((await memory.loadMemoryData()).isEmpty, true);
      expect(app.conversation, isEmpty);
      // Storage alone is not enough: a surviving canonical dialogue would be
      // replayed into the next prompt and fed to the extraction pass.
      expect(await llm.extractMemoryFromChat('{}'), isEmpty);
    });

    test('does not reload the model', () async {
      await app.chatOnce('hello');
      final loadsBefore = platform.getActiveModelCount;

      await app.resetMemoryToColdStart();

      expect(platform.getActiveModelCount, loadsBefore);
      expect(platform.closeModelCount, 0);
    });
  });
}
