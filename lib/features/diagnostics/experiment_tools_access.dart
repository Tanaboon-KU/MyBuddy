import 'package:flutter/foundation.dart';

/// Whether the experiment tools are reachable from the app bar.
///
/// The sheet behind the flask icon resets the user's memory to cold start,
/// seeds facts into their profile by hand, writes the conversation and the
/// composed system prompt to `/sdcard`, and toggles the consent flag. The
/// research needs every one of those, and every block collected so far ran on
/// a debug build - `flutter build apk --debug`.
///
/// In a release build the same sheet is a two-tap route to lifting someone's
/// memory out of the app, so it is gated here rather than left as an unguarded
/// button. Gating it costs the research nothing: no block has ever run on a
/// release build.
///
/// The escape hatch is spelled the same way the write-path arm is
/// (`ExtractionArm.fromEnvironment`), because a block might one day need a
/// release build - a latency measurement where debug overhead is the thing
/// under test:
///
/// ```
/// fvm flutter build apk --release --dart-define=EXPERIMENT_TOOLS=on
/// ```
class ExperimentToolsAccess {
  const ExperimentToolsAccess._();

  static const String _key = 'EXPERIMENT_TOOLS';

  /// The policy, with its inputs passed in so it can be tested.
  ///
  /// `kDebugMode` is a compile-time constant and tests always run in debug, so
  /// a policy that read it directly could only ever be observed in one state.
  ///
  /// Anything other than exactly `on` fails closed. A build script with a typo
  /// should ship a release app without the tools, not with them.
  static bool decide({required bool debugBuild, required String define}) =>
      debugBuild || define == 'on';

  /// The policy applied to this build. The only untested line, and it holds no
  /// logic of its own.
  static bool get current => decide(
    debugBuild: kDebugMode,
    define: const String.fromEnvironment(_key),
  );
}
