import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/llm_service.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:mybuddy/core/unity/unity_bridge.dart';

import 'fakes/fake_llm_platform.dart';

/// The pass asks about one user sentence at a time, so it also has to decide
/// which sentences it has already asked about.
///
/// Getting this wrong is not theoretical. The first version skipped every turn
/// an earlier pass had seen, with no way to override, and that quietly broke
/// the measurement harness: `Invoke-ForcedExtraction` drains any automatic pass
/// first, clears the log, and only then presses "force extraction now". The
/// automatic pass had already consumed all five turns, so the forced pass found
/// nothing, stored nothing, and reported an empty response - on six runs, with
/// the evidence of the pass that did the work wiped by the log clear.
///
/// An operator pressing that button means "ask again", and so does the harness.
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
      modelType: ModelType.qwen,
    );
  });

  Future<void> say(String text) async {
    platform.asyncResponseBatches.add(<String>['Understood.']);
    await service.generateChat(systemText: 'system', userText: text);
  }

  int promptsAskingAbout(String fragment) => platform.acceptedQueries
      .where((q) => q.contains('<user_said>') && q.contains(fragment))
      .length;

  test('asks about each turn once, not again on the next pass', () async {
    await say('My name is Nott.');
    await say('I work as a software engineer.');

    await service.extractUserMemoryFromChat('{}');
    expect(promptsAskingAbout('My name is Nott.'), 1);
    expect(promptsAskingAbout('I work as a software engineer.'), 1);

    await service.extractUserMemoryFromChat('{}');
    expect(
      promptsAskingAbout('My name is Nott.'),
      1,
      reason: 'a second pass with no new turns should ask nothing',
    );
  });

  test('a new turn is asked about, the old ones are not', () async {
    await say('My name is Nott.');
    await service.extractUserMemoryFromChat('{}');

    await say('I am allergic to peanuts.');
    await service.extractUserMemoryFromChat('{}');

    expect(promptsAskingAbout('My name is Nott.'), 1);
    expect(promptsAskingAbout('I am allergic to peanuts.'), 1);
  });

  test('a forced pass asks about every turn again', () async {
    await say('My name is Nott.');
    await say('I work as a software engineer.');
    await service.extractUserMemoryFromChat('{}');

    await service.extractUserMemoryFromChat('{}', reAskAllTurns: true);

    expect(promptsAskingAbout('My name is Nott.'), 2);
    expect(promptsAskingAbout('I work as a software engineer.'), 2);
  });

  test('starting a new conversation starts the count over', () async {
    await say('My name is Nott.');
    await service.extractUserMemoryFromChat('{}');

    await service.startNewConversation();
    await say('My name is Nott.');
    await service.extractUserMemoryFromChat('{}');

    expect(promptsAskingAbout('My name is Nott.'), 2);
  });
}
