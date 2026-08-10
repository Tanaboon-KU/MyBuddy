import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/memory_extraction_prompt_builder.dart';
import 'package:mybuddy/core/llm/memory_tool_semantics.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Replaces extraction_prompt_example_is_valid_test.dart, which asserted the
/// opposite and was written to stop exactly the change this now describes.
///
/// That test enforced "never show the model a sample it would be punished for
/// reproducing", and 231af60 removed the copyable schema template to satisfy
/// it. The fix worked on its own terms - the model stopped echoing the schema -
/// but it never made extraction succeed, and E1 block 2 measured what it cost:
/// a failing pass went from 6,681 ms to 178,016 ms, because with no template to
/// copy the model simply kept generating (T-28). Fifteen further runs in T-26
/// established the pass cannot do this task on Qwen2.5-1.5B q8 under any of the
/// three promptings tried, so the choice was between two prompts that both fail
/// and one of them is 26 times more expensive. 231af60 was reverted.
///
/// What this test pins is the property that made that acceptable: **copying the
/// template fails clean.** The copy is rejected before anything is written, so
/// the outcome is an empty user layer, not a corrupted one. That is the same
/// line T-26 drew when it kept config B and threw out config C - C returned
/// VALID and stored the extraction prompt's own opening line as the user's
/// goal, which is worse than storing nothing, because a silent failure is
/// recoverable and bad data is not.
///
/// If this test ever goes red, the revert has stopped being safe and the cost
/// argument no longer covers it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = MemoryService();
  });

  String promptFor(MemoryExtractionSection section) =>
      const MemoryExtractionPromptBuilder().build(
        section: section,
        conversation: 'User: Call yourself Nova.\nAssistant: Understood.',
        currentMemory: '{}',
        lockedFields: const <String>{},
      );

  test('the prompt shows the schema template again, on purpose', () {
    // The literal line three E3 trials copied back almost character for
    // character. Present again, and deliberately so.
    expect(
      promptFor(MemoryExtractionSection.all),
      contains('{"updates":[{"section":"soul|identity|user"'),
    );
  });

  test('copying the template writes nothing at all', () async {
    // The E3 output verbatim, from the trials that produced it.
    final copied = <MemoryPatch>[
      MemoryPatch.fromJson(const <String, dynamic>{
        'section': 'soul|identity|user',
        'field': 'allowed_field',
        'action': 'set',
        'value': 'one concise',
      }),
    ];

    final before = (await service.loadMemoryData()).toJsonString();
    final result = await service.applyMemoryPatches(copied);
    final after = (await service.loadMemoryData()).toJsonString();

    expect(result.rejections, isNotEmpty, reason: 'the copy must be rejected');
    expect(
      result.rejections.map((r) => r.code.name),
      contains('unknownSection'),
      reason: 'matches the rejection code E3 recorded',
    );
    expect(after, before, reason: 'a rejected copy must not touch memory');
  });

  test('every section routes the copy to the same clean rejection', () async {
    // A single-section pass names the section outright rather than offering
    // the alternation, so the copy carries `allowed_field` instead - still not
    // a real field, still rejected, still nothing written.
    for (final section in MemoryExtractionSection.values) {
      final prompt = promptFor(section);
      expect(prompt, contains('"field":"allowed_field"'), reason: section.name);

      final before = (await service.loadMemoryData()).toJsonString();
      final result = await service.applyMemoryPatches(<MemoryPatch>[
        MemoryPatch.fromJson(<String, dynamic>{
          'section': section == MemoryExtractionSection.all
              ? 'soul|identity|user'
              : section.name,
          'field': 'allowed_field',
          'action': 'set',
          'value': 'one concise value',
        }),
      ]);
      final after = (await service.loadMemoryData()).toJsonString();

      expect(result.rejections, isNotEmpty, reason: section.name);
      expect(after, before, reason: section.name);
    }
  });

  test('the user-capture rule from 8ca05b6 survived the revert', () {
    // Kept deliberately. T-26 measured it as changing nothing, and kept it
    // anyway because the asymmetry it corrects is real: the extraction prompt
    // demanded an explicit instruction for everything while the chat tool
    // prompt already allowed storing what a user says about themselves. It is
    // a separate change from 231af60 and reverting that one must not take it.
    expect(
      promptFor(MemoryExtractionSection.all),
      contains(MemoryToolSemantics.userCaptureRule),
    );
    expect(
      promptFor(MemoryExtractionSection.soul),
      isNot(contains(MemoryToolSemantics.userCaptureRule)),
      reason: 'a soul-only pass cannot route to the user layer',
    );
  });
}
