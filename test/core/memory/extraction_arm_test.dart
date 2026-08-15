import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/extraction_arm.dart';

/// Three arms of one experiment, selected at build time.
///
/// The paper describes the write path as "a separate model call re-reads the
/// conversation and the current memory and outputs updated memory as JSON"
/// (my-tasks/README.md §0), and §9 says the contribution is what a small
/// on-device model can and cannot do with a layered memory. That makes the JSON
/// pass the instrument, not a legacy path - and this block had quietly replaced
/// it with a line format, which measures a different task.
///
/// So all three run, on the same conversation, on the same day, and the arm is
/// a labelled build rather than a branch:
///
///   json        the pass exactly as the protocol describes it
///   lines       the same pass asked for five lines instead of a JSON object
///   linesRules  lines, plus deterministic capture of identity facts
///
/// Grounding and field routing sit downstream of parsing and run in every arm,
/// so what separates the arms is only what the model is asked for and whether
/// code captures alongside it.
void main() {
  test('the default arm is the one the protocol describes', () {
    // A build with no --dart-define must be the paper's system. Anything else
    // means an unlabelled build silently measures something the paper does not
    // describe, which is how this block ended up with 66 runs of a pass that
    // is not in §0.
    expect(ExtractionArm.fromEnvironment(), ExtractionArm.json);
  });

  test('each arm is selectable by name', () {
    expect(ExtractionArm.parse('json'), ExtractionArm.json);
    expect(ExtractionArm.parse('lines'), ExtractionArm.lines);
    expect(ExtractionArm.parse('lines_rules'), ExtractionArm.linesRules);
  });

  test('an unknown name falls back to the protocol arm, loudly', () {
    // Never silently: a typo in a run script must not turn into a mislabelled
    // block. Falling back to json means the worst case is measuring the
    // documented system, not an undocumented one.
    expect(ExtractionArm.parse('lnes'), ExtractionArm.json);
    expect(ExtractionArm.parse(''), ExtractionArm.json);
  });

  test('only the rules arm captures deterministically', () {
    expect(ExtractionArm.json.usesRules, isFalse);
    expect(ExtractionArm.lines.usesRules, isFalse);
    expect(ExtractionArm.linesRules.usesRules, isTrue);
  });

  test('only the json arm asks for a JSON object', () {
    expect(ExtractionArm.json.asksForJson, isTrue);
    expect(ExtractionArm.lines.asksForJson, isFalse);
    expect(ExtractionArm.linesRules.asksForJson, isFalse);
  });

  test('the arm names itself for the log and the CSV', () {
    // Every run has to say which arm produced it or the block is unreadable
    // three weeks later - the same reason §4.1 asks for labelled builds.
    expect(ExtractionArm.json.label, 'json');
    expect(ExtractionArm.lines.label, 'lines');
    expect(ExtractionArm.linesRules.label, 'lines_rules');
  });
}
