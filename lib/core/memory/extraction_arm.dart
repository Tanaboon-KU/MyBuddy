/// Which write path this build runs, chosen at build time.
///
/// The protocol describes the write path as "a separate model call re-reads the
/// conversation and the current memory and outputs updated memory as JSON"
/// (`my-tasks/README.md` §0), and §9 states the contribution as what a small
/// on-device model can and cannot do with a layered memory. The JSON pass is
/// therefore the instrument the paper is about, and anything else measures a
/// different task and has to say so.
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
  /// The pass as the protocol describes it: one model call, JSON out.
  json('json', asksForJson: true, usesRules: false),

  /// The same call asked for five `field: value` lines instead of an object.
  /// Measured in T26_lines: more values captured per conversation, and a
  /// different task from the one §0 describes.
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

  /// Defaults to [json] deliberately. A build with no define is the system the
  /// paper describes; the worst case for a missing or mistyped flag is that a
  /// run measures the documented behaviour rather than an undocumented one.
  static ExtractionArm fromEnvironment() =>
      parse(const String.fromEnvironment(_key));

  static ExtractionArm parse(String name) {
    for (final arm in ExtractionArm.values) {
      if (arm.label == name) return arm;
    }
    return ExtractionArm.json;
  }
}
