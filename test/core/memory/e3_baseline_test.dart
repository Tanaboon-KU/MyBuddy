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

  group('applyE3Baseline', () {
    test('sets exactly the values §5.3 specifies', () async {
      await memory.applyE3Baseline();

      final data = await memory.loadMemoryData();
      expect(data.identity.voice, MemoryService.e3BaselineVoice);
      expect(data.soul.boundaries, contains(MemoryService.e3BaselineBoundary));
    });

    test('is byte-identical every time it is applied', () async {
      // §5.5 step 5 diffs each trial against baseline.json. A setup that
      // varied even slightly between trials would read as a memory change and
      // be scored as a lock failure.
      await memory.applyE3Baseline();
      final first = (await memory.loadMemoryData()).toJsonString();

      await memory.applyE3Baseline();
      final second = (await memory.loadMemoryData()).toJsonString();

      expect(second, first);
    });

    test('clears anything a previous trial left behind', () async {
      await memory.saveMemoryData(
        const UserMemory(
          user: UserProfileMemory(name: 'Nott', facts: <String>['likes cats']),
          identity: IdentityMemory(voice: <String>['Sarcastic']),
        ),
      );

      await memory.applyE3Baseline();

      final data = await memory.loadMemoryData();
      expect(data.user.name, isNull);
      expect(data.user.facts, isEmpty);
      expect(data.identity.voice, MemoryService.e3BaselineVoice);
      expect(data.identity.voice, isNot(contains('Sarcastic')));
    });

    test('leaves the condition unlocked, so it must be set deliberately', () async {
      await memory.setE3Locked(true);
      await memory.applyE3Baseline();

      expect(await memory.isE3Locked(), isFalse);
    });
  });

  group('setE3Locked', () {
    test('locks both probed fields together', () async {
      await memory.setE3Locked(true);

      final locked = await memory.loadLockedFields();
      expect(locked, containsAll(MemoryService.e3LockedFields));
      expect(await memory.isE3Locked(), isTrue);
    });

    test('unlocking clears them', () async {
      await memory.setE3Locked(true);
      await memory.setE3Locked(false);

      expect(await memory.isE3Locked(), isFalse);
      expect(await memory.loadLockedFields(), isEmpty);
    });

    test('round-trips across 16 toggles without drifting', () async {
      // The RA does this 16 times. A leak in either direction would silently
      // put trials in the wrong condition.
      for (var i = 0; i < 16; i++) {
        final want = i.isEven;
        await memory.setE3Locked(want);
        expect(await memory.isE3Locked(), want, reason: 'toggle $i');
      }
    });
  });

  group('isE3Locked', () {
    test('a half-applied condition is no longer reachable', () async {
      // This asserted the opposite until T-23: locking only identity.voice
      // left isE3Locked false, so a tap that half-landed surfaced as neither
      // condition rather than quietly running a trial in the wrong one.
      //
      // Grouping made that state unreachable instead of merely detectable.
      // Locking any persona field now locks the whole persona, so
      // identity.voice on its own implies soul.boundaries as well and the
      // condition is whole by construction. The protection the old test wanted
      // is stronger now, not weaker — which is why the expectation flips.
      await memory.saveLockedFields(<String>{MemoryFieldPaths.identityVoice});

      expect(
        await memory.loadLockedFields(),
        containsAll(MemoryService.e3LockedFields),
      );
      expect(await memory.isE3Locked(), isTrue);
    });

    test('is still false when nothing is locked', () async {
      expect(await memory.isE3Locked(), isFalse);
    });
  });
}
