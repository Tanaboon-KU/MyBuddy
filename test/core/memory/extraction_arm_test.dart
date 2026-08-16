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
  test('the default arm is the one the system ships', () {
    // A build with no --dart-define must be the system as it ships, so that an
    // unlabelled build never measures something no document describes - which
    // is how this block once ended up with 66 runs of a pass that was not in
    // §0 at all.
    //
    // That arm is `lines` as of 2026-08-15. The JSON pass measured 1 of the 5
    // facts the user stated (T26_arms §3) and the owner accepted the line
    // format as the shipped write path; README §0 was rewritten to match and
    // the protocol went to v2.1. `json` remains a selectable arm because every
    // block from E1 through E4 was collected on it, and because it is still the
    // measurement of what the model alone can do.
    expect(ExtractionArm.fromEnvironment(), ExtractionArm.lines);
  });

  test('each arm is selectable by name', () {
    expect(ExtractionArm.parse('json'), ExtractionArm.json);
    expect(ExtractionArm.parse('lines'), ExtractionArm.lines);
    expect(ExtractionArm.parse('lines_rules'), ExtractionArm.linesRules);
  });

  test('an unknown name falls back to the shipped arm', () {
    // A typo in a run script must not turn into a mislabelled block. Falling
    // back to the shipped arm means the worst case is a run that measures the
    // documented system rather than an undocumented one.
    expect(ExtractionArm.parse('lnes'), ExtractionArm.lines);
    expect(ExtractionArm.parse(''), ExtractionArm.lines);
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
