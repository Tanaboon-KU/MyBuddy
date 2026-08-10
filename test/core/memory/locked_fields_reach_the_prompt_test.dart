import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// T-14. The prompt never mentioned locking, and said the opposite twice.
///
/// `mutableMemoryRules` tells the model a new instruction "supersedes
/// conflicts; never defend or negotiate old values", and the tool descriptions
/// say an existing IDENTITY "cannot block the change". E3 then measured a model
/// doing as it was told and being refused by storage it had never been told
/// about — which is the whole of T-24 and half of T-25.
///
/// The block is emitted only when something is locked. Every run of E1, E2 and
/// E4 had no locks, so their prompts must stay byte-identical or none of those
/// blocks can be compared against anything measured afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService memory;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    memory = MemoryService();
  });

  test('nothing locked leaves the prompt exactly as it was', () async {
    final without = await memory.buildSystemPrompt(memory: const UserMemory());
    final withEmpty = await memory.buildSystemPrompt(
      memory: const UserMemory(),
      lockedFields: const <String>{},
    );

    expect(withEmpty, without);
    expect(without, isNot(contains('LOCKED FIELDS')));
  });

  test('a locked field is named in the prompt', () async {
    final prompt = await memory.buildSystemPrompt(
      memory: const UserMemory(),
      lockedFields: <String>{MemoryFieldPaths.identityVoice},
    );

    expect(prompt, contains('LOCKED FIELDS'));
    expect(prompt, contains('- identity.voice'));
  });

  test('every locked field is listed, in a stable order', () async {
    // Sorted so the prompt hash does not move when the same set arrives in a
    // different iteration order - sys_prompt_sha256 is a protocol column and a
    // spurious change reads as a memory change.
    final first = await memory.buildSystemPrompt(
      memory: const UserMemory(),
      lockedFields: <String>{
        MemoryFieldPaths.soulBoundaries,
        MemoryFieldPaths.identityVoice,
      },
    );
    final second = await memory.buildSystemPrompt(
      memory: const UserMemory(),
      lockedFields: <String>{
        MemoryFieldPaths.identityVoice,
        MemoryFieldPaths.soulBoundaries,
      },
    );

    expect(first, second);
    expect(first, contains('- identity.voice'));
    expect(first, contains('- soul.boundaries'));
  });

  test('it says which rule wins, because the prompt contradicts itself', () async {
    // The prompt still carries "never defend or negotiate old values" earlier
    // on, and that stays, because it is correct whenever nothing is locked.
    // Leaving the model to reconcile the two is what T-24 measured going wrong.
    final prompt = await memory.buildSystemPrompt(
      memory: const UserMemory(),
      lockedFields: <String>{MemoryFieldPaths.identityVoice},
    );

    expect(prompt, contains('never defend or negotiate old values'));
    expect(prompt, contains('This overrides the rules above'));
    expect(prompt, contains('Never claim you changed a locked field'));
  });

  test('the block sits after the memory it talks about', () async {
    // Nearest the generation point of anything that says what may be written.
    // T-12 makes the same argument about the USER block for the same reason.
    final prompt = await memory.buildSystemPrompt(
      memory: const UserMemory(),
      lockedFields: <String>{MemoryFieldPaths.identityVoice},
    );

    expect(
      prompt.indexOf('LOCKED FIELDS'),
      greaterThan(prompt.indexOf('USER (Long-term User Profile)')),
    );
  });

  test('what is stored is what reaches the prompt', () async {
    // The end-to-end path: saveLockedFields expands to the persona group
    // (T-23), and all of it has to arrive.
    await memory.saveLockedFields(<String>{MemoryFieldPaths.identityVoice});

    final prompt = await memory.buildSystemPrompt(
      memory: await memory.loadMemoryData(),
      lockedFields: await memory.loadLockedFields(),
    );

    for (final field in MemoryFieldPaths.soulAndIdentity) {
      expect(prompt, contains('- $field'), reason: field);
    }
  });
}
