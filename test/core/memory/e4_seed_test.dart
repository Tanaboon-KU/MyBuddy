import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService memory;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    memory = MemoryService();
  });

  group('applyE4Seed', () {
    test('puts the value in the field it was asked for', () async {
      await memory.applyE4Seed('preferences', 'Drinks tea in the afternoon');

      final user = (await memory.loadMemoryData()).user;
      expect(user.preferences, <String>['Drinks tea in the afternoon']);
    });

    test('reaches all five USER fields', () async {
      // The twelve pairs are spread across all five, so a field that silently
      // did nothing would show up as a read-path failure for those pairs
      // rather than as the setup bug it is.
      for (final field in MemoryService.e4SeedFields) {
        await memory.applyE4Seed(field, 'seeded value');

        final user = (await memory.loadMemoryData()).user;
        final landed = switch (field) {
          'name' => user.name,
          'traits' => user.traits.join(),
          'preferences' => user.preferences.join(),
          'goals' => user.goals.join(),
          _ => user.facts.join(),
        };
        expect(landed, 'seeded value', reason: 'field $field');
      }
    });

    test('touches nothing outside the USER layer', () async {
      // The whole design of the block is that the only difference from E2 is
      // where the fact came from. If seeding also moved SOUL or IDENTITY, the
      // prompt would differ from E2's in a second way and the comparison
      // against E2's 0/12 would not hold.
      await memory.applyE4Seed('facts', 'Allergic to peanuts');

      final data = await memory.loadMemoryData();
      const cold = UserMemory();
      expect(data.soul.toJson(), cold.soul.toJson());
      expect(data.identity.toJson(), cold.identity.toJson());
    });

    test('does not let one pair inherit the pair before it', () async {
      await memory.applyE4Seed('facts', 'Has a dog named Momo');
      await memory.applyE4Seed('goals', 'Save for a trip to Japan');

      final user = (await memory.loadMemoryData()).user;
      expect(user.goals, <String>['Save for a trip to Japan']);
      expect(user.facts, isEmpty, reason: 'pair N-1 leaked into pair N');
    });

    test('clears locked fields left over from an E3 block', () async {
      await memory.setE3Locked(true);
      await memory.applyE4Seed('name', 'Nott');

      expect(await memory.loadLockedFields(), isEmpty);
    });

    test('is byte-identical every time the same seed is applied', () async {
      await memory.applyE4Seed('traits', 'Detail-oriented');
      final first = (await memory.loadMemoryData()).toJsonString();

      await memory.applyE4Seed('traits', 'Detail-oriented');
      final second = (await memory.loadMemoryData()).toJsonString();

      expect(second, first);
    });

    test('rejects a field that is not part of the USER layer', () async {
      // Typed by hand into a text box on the device, so a typo is likely. It
      // has to fail loudly: a seed that quietly did nothing would be scored as
      // the model failing to use memory it was never given.
      await expectLater(
        memory.applyE4Seed('preference', 'x'),
        throwsArgumentError,
      );
      await expectLater(
        memory.applyE4Seed('soul.mission', 'x'),
        throwsArgumentError,
      );
    });

    test('rejects an empty value', () async {
      await expectLater(memory.applyE4Seed('facts', '   '), throwsArgumentError);
    });

    test('leaves memory untouched when it rejects the input', () async {
      await memory.applyE4Seed('name', 'Nott');
      await expectLater(
        memory.applyE4Seed('nickname', 'Bee'),
        throwsArgumentError,
      );

      // Validation happens before the cold-start wipe, so a mistyped field
      // cannot destroy the pair that is already set up.
      expect((await memory.loadMemoryData()).user.name, 'Nott');
    });

    test('accepts the field name in any case, with stray spaces', () async {
      await memory.applyE4Seed('  Preferences ', 'Avoids spicy food');

      final user = (await memory.loadMemoryData()).user;
      expect(user.preferences, <String>['Avoids spicy food']);
    });
  });

  group('the seeded fact reaches the model', () {
    // The precondition the whole block rests on. If the fact is stored but
    // never composed into the prompt, a PASS/FAIL on the reply would be
    // measuring the prompt builder, not the model's use of memory - and the
    // result would be indistinguishable from E2's.
    test('appears verbatim in the composed system prompt', () async {
      for (final (field, value) in const <(String, String)>[
        ('name', 'Nott'),
        ('traits', 'Gets anxious in large groups'),
        ('preferences', 'Cutting down on coffee, drinks tea in the afternoon'),
        ('goals', 'Training for a half marathon in November'),
        ('facts', 'Allergic to peanuts'),
      ]) {
        await memory.applyE4Seed(field, value);
        final prompt = await memory.buildSystemPrompt(
          memory: await memory.loadMemoryData(),
        );

        expect(prompt, contains(value), reason: 'user.$field');
      }
    });

    test('a cold-start prompt still contains none of it', () async {
      // Guards the other direction: if these strings were somehow in the
      // prompt already, the test above would pass while proving nothing.
      final prompt = await memory.buildSystemPrompt(
        memory: const UserMemory(),
      );

      expect(prompt, isNot(contains('Allergic to peanuts')));
      expect(prompt, isNot(contains('Nott')));
    });
  });
}
