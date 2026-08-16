import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/features/diagnostics/experiment_tools_access.dart';

/// Who can reach the experiment tools.
///
/// The sheet behind the flask icon resets the user's memory, seeds fake facts
/// into their profile, writes their conversation to /sdcard, and toggles the
/// consent flag. Every experiment block in this project needed all of that, and
/// every one of those blocks ran on a debug build.
///
/// Shipped to a release build it is a two-tap route to lifting someone's memory
/// out of the app, so the decision gets a home of its own and a test, rather
/// than living as an unguarded button in the app bar.
///
/// `kDebugMode` is a compile-time constant and a test always runs in debug, so
/// the policy takes the build mode as an argument. [ExperimentToolsAccess.current]
/// is the one line that feeds it the real one.
void main() {
  group('release builds', () {
    test('cannot reach the tools', () {
      expect(
        ExperimentToolsAccess.decide(debugBuild: false, define: ''),
        isFalse,
      );
    });

    test('can reach them when the build explicitly asks', () {
      // The escape hatch exists because a block might one day need to run on a
      // release build - a latency block, say, where debug overhead is the thing
      // being measured. It has to be asked for by name, the same way the
      // extraction arm is.
      expect(
        ExperimentToolsAccess.decide(debugBuild: false, define: 'on'),
        isTrue,
      );
    });

    test('a value that is not "on" does not open them', () {
      // A typo in a build script must fail closed, not open.
      for (final value in ['ON', 'true', '1', 'yes', 'off', ' on', 'on ']) {
        expect(
          ExperimentToolsAccess.decide(debugBuild: false, define: value),
          isFalse,
          reason: 'define=$value should not expose the tools',
        );
      }
    });
  });

  group('debug builds', () {
    test('always reach the tools', () {
      expect(
        ExperimentToolsAccess.decide(debugBuild: true, define: ''),
        isTrue,
      );
    });

    test('are unaffected by the define', () {
      // Every block collected so far ran on a debug build with no define. If
      // this ever returned false, the collection scripts would stop working and
      // the reason would be hard to see from the device.
      for (final value in ['', 'on', 'off', 'nonsense']) {
        expect(
          ExperimentToolsAccess.decide(debugBuild: true, define: value),
          isTrue,
          reason: 'debug builds keep the tools regardless of define=$value',
        );
      }
    });
  });

  test('the wired-up value is reachable and is true under test', () {
    // Tests run in debug, so this pins the wiring rather than the policy: if
    // `current` were ever inverted, this fails.
    expect(ExperimentToolsAccess.current, isTrue);
  });
}
