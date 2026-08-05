import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/memory_extraction_prompt_builder.dart';
import 'package:mybuddy/core/memory/memory_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// T-07. The extraction pass never produced a usable patch across E1 and E3.
///
/// The reason is visible in what the model actually returned. Three E3 trials
/// produced this, which parses as JSON and reaches validation:
///
///   {"updates":[{"section":"soul|identity|user","field":"allowed_field",
///                "action":"set","value":"one concise"}]}
///
/// That is the prompt's own output-format line, copied. The prompt introduces
/// it with "Output exactly one JSON object and no markdown or explanation:",
/// which reads as an instruction to emit that exact object, and its
/// placeholders are themselves valid JSON strings: a pipe-alternation of the
/// allowed sections, a literal `allowed_field`, and `one concise value`. A 1.5B
/// model decoding greedily copies it. The remaining trials show the same
/// fingerprint in fragments - `"voice|voice"`, `"sarcastic|sarcasset"`, `"|add"`
/// - so the notation leaks into generation even when the copy is not clean.
///
/// The invariant that stops this recurring: **anything the prompt shows the
/// model as output must itself survive validation.** Never show a model a
/// sample it would be punished for reproducing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = MemoryService();
  });

  /// Every `{"updates":[...]}` object the prompt puts in front of the model.
  List<Map<String, dynamic>> samplesIn(String prompt) {
    final samples = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(prompt)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{"updates"')) continue;
      samples.add(jsonDecode(trimmed) as Map<String, dynamic>);
    }
    return samples;
  }

  for (final section in MemoryExtractionSection.values) {
    test('every patch the ${section.name} prompt shows is applicable', () async {
      final prompt = const MemoryExtractionPromptBuilder().build(
        section: section,
        conversation: 'User: Call yourself Nova.\nAssistant: Understood.',
        currentMemory: '{}',
        lockedFields: const <String>{},
      );

      final samples = samplesIn(prompt);
      expect(
        samples,
        isNotEmpty,
        reason: 'the prompt should show the model at least one sample',
      );

      for (final sample in samples) {
        final updates = (sample['updates'] as List).cast<Map<String, dynamic>>();
        if (updates.isEmpty) continue; // {"updates":[]} is the no-op sample

        final result = await service.applyMemoryPatches(
          updates.map(MemoryPatch.fromJson).toList(growable: false),
        );

        expect(
          result.rejections.map((r) => '${r.section}.${r.field}:${r.code.name}'),
          isEmpty,
          reason:
              'The ${section.name} prompt shows the model\n  '
              '${jsonEncode(sample)}\n'
              'but copying it verbatim is rejected. That is exactly what the '
              'model did in E3.',
        );
      }
    });
  }
}
