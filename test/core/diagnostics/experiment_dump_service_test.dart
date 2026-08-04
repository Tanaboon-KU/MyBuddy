import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/experiment_dump_service.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/fakes/fake_llm_platform.dart';

/// Covers T-03 from `my-tasks/TASKS.md`: memory and system-prompt dumps.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getExternalStoragePath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late MemoryService memory;
  late FakeLlmPlatform platform;
  late LlmService llm;
  late ExperimentDumpService dumps;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempRoot = await Directory.systemTemp.createTemp('mybuddy_dump_test');
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);

    memory = MemoryService();
    platform = FakeLlmPlatform();
    llm = LlmService(
      platform: platform,
      unityBridge: UnityBridge(),
      memoryService: memory,
    );
    dumps = ExperimentDumpService(memoryService: memory, llmService: llm);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('dumpMemory', () {
    test('writes canonical JSON under memory_dumps/', () async {
      await memory.saveMemoryData(
        const UserMemory(
          user: UserProfileMemory(
            name: 'Nott',
            preferences: <String>['tea in the afternoons'],
          ),
        ),
      );

      final file = await dumps.dumpMemory(label: 'run01_after_input_a');

      expect(file.path, contains('mybuddy-experiments'));
      expect(file.path, contains('memory_dumps'));
      expect(file.path, endsWith('run01_after_input_a.json'));

      final decoded = jsonDecode(await file.readAsString());
      expect(decoded['stored']['user']['preferences'], [
        'tea in the afternoons',
      ]);
    });

    test('reports stored and effective side by side', () async {
      // T-16. Cold start writes nothing to identity.voice, but the prompt
      // substitutes four values, so a dump showing only `stored` reads as
      // though the model were told nothing at all.
      final decoded =
          jsonDecode(await (await dumps.dumpMemory()).readAsString())
              as Map<String, Object?>;

      expect(decoded.keys, containsAll(<String>['stored', 'effective']));

      final stored = decoded['stored']! as Map<String, Object?>;
      final effective = decoded['effective']! as Map<String, Object?>;

      expect((stored['identity']! as Map)['voice'], isEmpty);
      expect(
        (effective['identity']! as Map)['voice'],
        MemoryPromptDefaults.identityVoice,
      );
      expect((stored['soul']! as Map)['mission'], isNull);
      expect(
        (effective['soul']! as Map)['mission'],
        MemoryPromptDefaults.soulMission,
      );
    });

    test('keeps the USER layer identical in both halves', () async {
      // c1_stored (§3) and write (§4) are scored by searching this file. A
      // default leaking into `user` would score a failed write as a success.
      await memory.saveMemoryData(
        const UserMemory(user: UserProfileMemory(name: 'Nott')),
      );

      final decoded =
          jsonDecode(await (await dumps.dumpMemory()).readAsString())
              as Map<String, Object?>;

      expect(
        (decoded['effective']! as Map)['user'],
        (decoded['stored']! as Map)['user'],
      );
    });

    test('a stored value is not overwritten by its default', () async {
      await memory.saveMemoryData(
        const UserMemory(
          identity: IdentityMemory(voice: <String>['Blunt']),
        ),
      );

      final decoded =
          jsonDecode(await (await dumps.dumpMemory()).readAsString())
              as Map<String, Object?>;

      expect((decoded['effective']! as Map)['identity']['voice'], ['Blunt']);
    });

    test('sorts keys at every level so a plain diff is valid', () async {
      await memory.saveMemoryData(
        const UserMemory(user: UserProfileMemory(name: 'Nott')),
      );

      final content = await (await dumps.dumpMemory()).readAsString();
      final topLevel = RegExp(r'^  "(\w+)":', multiLine: true)
          .allMatches(content)
          .map((m) => m.group(1))
          .toList();

      expect(topLevel, List<String>.from(topLevel)..sort());
    });

    test('is byte-identical when nothing changed between dumps', () async {
      await memory.saveMemoryData(
        const UserMemory(
          identity: IdentityMemory(voice: <String>['Warm', 'Direct']),
        ),
      );

      final first = await (await dumps.dumpMemory(label: 'a')).readAsBytes();
      final second = await (await dumps.dumpMemory(label: 'b')).readAsBytes();

      expect(second, first);
    });

    test('reflects a cold start after reset', () async {
      await memory.saveMemoryData(
        const UserMemory(user: UserProfileMemory(name: 'Nott')),
      );
      await memory.resetToColdStart();

      final content = await (await dumps.dumpMemory()).readAsString();

      expect(content, isNot(contains('Nott')));
    });
  });

  group('dumpSystemPrompt', () {
    test('throws before any turn instead of writing an empty file', () async {
      await expectLater(dumps.dumpSystemPrompt(), throwsA(isA<StateError>()));

      final promptDir = Directory(
        '${tempRoot.path}/mybuddy-experiments/prompts',
      );
      expect(await promptDir.exists(), false);
    });

    test('captures the composed prompt including the tool blocks', () async {
      await llm.generateChat(
        systemText: await memory.buildSystemPrompt(
          memory: await memory.loadMemoryData(),
        ),
        userText: 'hello',
      );

      final file = await dumps.dumpSystemPrompt(
        label: 'run01_turn02_system_prompt',
      );
      final content = await file.readAsString();

      expect(file.path, contains('prompts'));
      expect(file.path, endsWith('run01_turn02_system_prompt.txt'));

      // The memory block alone is only about a third of the real prompt.
      // These three markers prove the tool instruction block was included.
      expect('<tool_rules>'.allMatches(content).length, 1);
      expect(content, contains('<tools>'));
      expect(content, contains('CURRENT MUTABLE MEMORY'));
    });

    test('matches LlmService.lastComposedSystemChars exactly', () async {
      await llm.generateChat(systemText: 'SYSTEM', userText: 'hi');

      final content = await (await dumps.dumpSystemPrompt()).readAsString();

      expect(content.length, llm.lastComposedSystemChars);
      expect(content, llm.lastComposedSystemText);
    });

    test('survives startNewConversation so a post-turn dump still works',
        () async {
      await llm.generateChat(systemText: 'SYSTEM', userText: 'hi');
      final before = llm.lastComposedSystemText;

      await llm.startNewConversation();

      expect(llm.lastComposedSystemText, before);
      await expectLater(dumps.dumpSystemPrompt(), completes);
    });
  });

  group('sanitizeLabel', () {
    test('keeps protocol-style names untouched', () {
      expect(
        ExperimentDumpService.sanitizeLabel('run01_after_input_a'),
        'run01_after_input_a',
      );
      expect(ExperimentDumpService.sanitizeLabel('L_P01_after'), 'L_P01_after');
    });

    test('replaces characters that are unsafe in a file name', () {
      expect(ExperimentDumpService.sanitizeLabel('run 1/2'), 'run_1_2');
      expect(ExperimentDumpService.sanitizeLabel(r'a\b:c*d'), 'a_b_c_d');
    });

    test('returns null when nothing usable is left', () {
      expect(ExperimentDumpService.sanitizeLabel(null), isNull);
      expect(ExperimentDumpService.sanitizeLabel('   '), isNull);
      expect(ExperimentDumpService.sanitizeLabel('///'), isNull);
    });

    test('falls back to a timestamp when the label is empty', () async {
      final file = await dumps.dumpMemory(label: '   ');
      expect(file.path, contains('memory_'));
    });
  });

  group('cold-start prompt size', () {
    // Measured 2026-08-02 against this build:
    //   memory block  2,632 chars
    //   tool block    4,471 chars  (63% of the prompt, and it comes last)
    //   total         7,104 chars  ~2,000-2,400 tokens at 3.0-3.5 chars/token
    //   USER block starts at char 1,888 with 5,216 chars after it
    //
    // With the default maxTokens of 4096 the input limit is 3,584, so the
    // system prompt alone consumes roughly half the context before the user
    // has typed anything. See ROOT_CAUSE_ANALYSIS.md section 4 (RC-4); T-13
    // exists to bring this down. The bounds are wide on purpose: this guards
    // against accidental drift, not against deliberate tuning.
    test('stays within the range the analysis is based on', () async {
      final memoryBlock = await memory.buildSystemPrompt(
        memory: await memory.loadMemoryData(),
      );
      await llm.generateChat(systemText: memoryBlock, userText: 'hi');
      final full = llm.lastComposedSystemText!;

      expect(memoryBlock.length, inInclusiveRange(2000, 3500));
      expect(full.length, inInclusiveRange(5500, 9000));

      final toolBlockStart = full.indexOf('<tool_rules>');
      expect(toolBlockStart, greaterThan(0));

      // The tool instructions must stay the tail of the prompt: they occupy
      // the recency position that the USER profile needs (RC-3/RC-4).
      final toolBlockLength = full.length - toolBlockStart;
      expect(toolBlockLength / full.length, greaterThan(0.4));

      final userBlockStart = full.indexOf('USER (Long-term User Profile)');
      expect(userBlockStart, greaterThan(0));
      expect(userBlockStart, lessThan(toolBlockStart));
    });
  });

  group('canonicalJson', () {
    test('sorts nested maps but preserves list order', () {
      final out = ExperimentDumpService.canonicalJson(<String, Object?>{
        'z': 1,
        'a': <String, Object?>{'y': 2, 'b': 3},
        'list': <String>['second', 'first'],
      });

      expect(out.indexOf('"a"'), lessThan(out.indexOf('"z"')));
      expect(out.indexOf('"b"'), lessThan(out.indexOf('"y"')));
      // Entry order decides what survives the 5-entry cap, so it is meaningful.
      expect(out.indexOf('second'), lessThan(out.indexOf('first')));
    });
  });
}
