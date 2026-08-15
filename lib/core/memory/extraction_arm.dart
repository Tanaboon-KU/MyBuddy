/// Which write path this build runs, chosen at build time.
///
/// Protocol v2.0 §0 described the write path as "a separate model call re-reads
/// the conversation and the current memory and outputs updated memory as JSON".
/// Measured on 2026-08-15 against a five-fact conversation, that pass stored one
/// fact of five, always the one from the last turn (`T26_arms/`). The owner
/// accepted the line format as the write path the system ships, and §0 was
/// rewritten for v2.1 to describe it.
///
/// [json] therefore stays as a labelled arm rather than being deleted. It is
/// the build every block from E1 through E4 was collected on, and it is the
/// measurement §9 asks for - what a small on-device model can do unaided.
///
/// Three arms, one codebase, so a run is identified by a `--dart-define` rather
/// than by which branch happened to be checked out:
///
/// ```
/// fvm flutter build apk --debug --dart-define-from-file=env.json \
///     --dart-define=EXTRACTION_ARM=lines_rules
/// ```
///
/// [ExtractionGrounding] and [ExtractionFieldRouting] sit downstream of parsing
/// and run in every arm. What separates the arms is only what the model is asked
/// to produce, and whether code captures anything alongside it.
enum ExtractionArm {
  /// The pass as protocol v2.0 described it: one model call, JSON out. Kept as
  /// the baseline the paper reports for the model working unaided.
  json('json', asksForJson: true, usesRules: false),

  /// The same call asked for five `field: value` lines instead of an object,
  /// and what the system ships as of v2.1 of the protocol. Three values stored
  /// per conversation where the JSON pass stored one, at the same latency.
  lines('lines', asksForJson: false, usesRules: false),

  /// Lines, plus [UserFactRules] capturing identity facts from the user's own
  /// turn as it is typed - the one moment the last-turn rule does not apply.
  linesRules('lines_rules', asksForJson: false, usesRules: true);

  const ExtractionArm(
    this.label, {
    required this.asksForJson,
    required this.usesRules,
  });

  /// Goes in the log line and the per-turn CSV. A block whose rows do not name
  /// their arm cannot be read later, which is what §4.1 asks for about builds.
  final String label;

  final bool asksForJson;
  final bool usesRules;

  static const String _key = 'EXTRACTION_ARM';

  /// The arm a build with no `--dart-define` runs. It has to be the arm the
  /// system ships, so that the worst case for a missing or mistyped flag is a
  /// run that measures documented behaviour rather than undocumented behaviour.
  static const ExtractionArm shipped = ExtractionArm.lines;

  static ExtractionArm fromEnvironment() =>
      parse(const String.fromEnvironment(_key));

  static ExtractionArm parse(String name) {
    for (final arm in ExtractionArm.values) {
      if (arm.label == name) return arm;
    }
    return shipped;
  }
}
