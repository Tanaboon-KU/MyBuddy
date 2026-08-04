import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/memory_service.dart';

/// Replaces the one line that legitimately changes between runs.
String _withoutDate(String prompt) {
  return prompt.replaceAll(
    RegExp(r'Remember today is \d{4}-\d{2}-\d{2}\.'),
    'Remember today is <DATE>.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = MemoryService();

  group('cold-start prompt', () {
    test('is byte-identical to what the device produced', () async {
      // Captured from the Mi 10T Pro at commit a4cb917 with memory empty, in
      // my-tasks/step0-artifacts/prompts/, with the '\n\n' that
      // LlmService._composeSystemText inserts between the memory block and the
      // tool blocks removed. Pins the defaults refactor: the `effective` half
      // of a memory dump is only trustworthy if composing the prompt still
      // produces exactly this.
      final golden = File(
        'test/fixtures/cold_start_memory_block.txt',
      ).readAsStringSync();

      final built = await service.buildSystemPrompt(
        memory: const UserMemory(),
      );

      // _composeSystemText trims before joining, so this is the exact text the
      // model receives ahead of <tool_rules>.
      expect(_withoutDate(built.trim()), _withoutDate(golden));
    });

    test('substitutes every default the dump has to report', () async {
      final built = await service.buildSystemPrompt(
        memory: const UserMemory(),
      );

      expect(built, contains(MemoryPromptDefaults.soulMission));
      expect(built, contains(MemoryPromptDefaults.identityName));
      expect(built, contains(MemoryPromptDefaults.identityRole));
      for (final v in MemoryPromptDefaults.identityVoice) {
        expect(built, contains('- $v'));
      }
      for (final p in MemoryPromptDefaults.soulPrinciples) {
        expect(built, contains('- $p'));
      }
      for (final b in MemoryPromptDefaults.soulBoundaries) {
        expect(built, contains('- $b'));
      }
      for (final r in MemoryPromptDefaults.behaviorRules) {
        expect(built, contains('- $r'));
      }
    });

    test('a stored value wins over its default', () async {
      const stored = UserMemory(
        identity: IdentityMemory(voice: <String>['Blunt']),
      );

      final built = await service.buildSystemPrompt(memory: stored);

      expect(built, contains('- Blunt'));
      expect(built, isNot(contains('- Encouraging')));
    });
  });

  group('applyTo', () {
    test('fills the layers the prompt substitutes', () {
      final effective = MemoryPromptDefaults.applyTo(const UserMemory());

      expect(effective.soul.mission, MemoryPromptDefaults.soulMission);
      expect(effective.soul.principles, MemoryPromptDefaults.soulPrinciples);
      expect(effective.soul.boundaries, MemoryPromptDefaults.soulBoundaries);
      expect(effective.identity.voice, MemoryPromptDefaults.identityVoice);
      expect(
        effective.identity.behaviorRules,
        MemoryPromptDefaults.behaviorRules,
      );
    });

    test('leaves the USER layer completely alone', () {
      // E1 c1_stored and E2 write are scored by searching the dump. If a
      // default ever appeared under `user`, that search would return a false
      // positive and the write path would look healthier than it is.
      final effective = MemoryPromptDefaults.applyTo(const UserMemory());

      expect(effective.user.name, isNull);
      expect(effective.user.preferences, isEmpty);
      expect(effective.user.goals, isEmpty);
      expect(effective.user.facts, isEmpty);
      expect(effective.user.traits, isEmpty);
    });

    test('does not invent a response_style the prompt never uses', () {
      final effective = MemoryPromptDefaults.applyTo(const UserMemory());

      expect(effective.soul.responseStyle, isEmpty);
    });
  });
}
