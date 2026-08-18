import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/llm/llm_backend_choice.dart';

/// Which backend the inference runs on, chosen at build time.
///
/// Written because a block could not be collected without it. On 2026-08-18 an
/// E2 block on Gemma 4 E2B died at pair 5: the app took SIGSEGV inside
/// `libCB.so`, Qualcomm's OpenCL driver, on the `AdrenoOsLib` thread, during
/// the extraction pass. That is a vendor driver fault on Adreno 6xx, not
/// anything the app can catch - the process is gone.
///
/// `LlmService` already has a GPU->CPU fallback, and it could not help: it
/// fires only when the *initial* model load throws, and this load had
/// succeeded a hour earlier. The backend was a constructor default with no
/// override anywhere in the app, so the only way to reach CPU was to edit the
/// source. That is what this replaces.
///
/// The default has to stay GPU. Every block in the project so far ran on it,
/// and a flag that silently changed the backend of an un-flagged build would
/// make those blocks unreproducible.
void main() {
  group('parse', () {
    test('names the two backends', () {
      expect(LlmBackendChoice.parse('gpu'), LlmBackendChoice.gpu);
      expect(LlmBackendChoice.parse('cpu'), LlmBackendChoice.cpu);
    });

    test('an empty define is the shipped backend', () {
      // The un-flagged build is every block collected before 2026-08-18.
      expect(LlmBackendChoice.parse(''), LlmBackendChoice.shipped);
    });

    test('the shipped backend is GPU', () {
      // Not a preference - a fact about the data already collected. Changing
      // it would silently reinterpret every block that ran without the flag.
      expect(LlmBackendChoice.shipped, LlmBackendChoice.gpu);
    });

    test('anything unrecognised falls back rather than throwing', () {
      // Same rule as ExtractionArm: a typo in a build script must produce a
      // run that measures documented behaviour, not a crash on startup and not
      // an undocumented configuration.
      for (final value in ['GPU', 'Cpu', 'npu', 'true', '1', ' cpu', 'cpu ']) {
        expect(
          LlmBackendChoice.parse(value),
          LlmBackendChoice.shipped,
          reason: 'define=$value should fall back to the shipped backend',
        );
      }
    });
  });

  group('the value handed to flutter_gemma', () {
    test('maps to the matching PreferredBackend', () {
      expect(LlmBackendChoice.gpu.backend, PreferredBackend.gpu);
      expect(LlmBackendChoice.cpu.backend, PreferredBackend.cpu);
    });
  });

  group('the label', () {
    test('is what goes in the log line a block reads back', () {
      // §4.1: a row that does not say what produced it cannot be read later.
      // The block driver greps this out of logcat rather than trusting that
      // the right APK was installed - which is how the arm is already checked.
      expect(LlmBackendChoice.gpu.label, 'gpu');
      expect(LlmBackendChoice.cpu.label, 'cpu');
    });

    test('round-trips through parse', () {
      for (final choice in LlmBackendChoice.values) {
        expect(LlmBackendChoice.parse(choice.label), choice);
      }
    });
  });

  test('the wired-up value is reachable and is the default under test', () {
    // Tests carry no --dart-define, so this pins the wiring: if
    // fromEnvironment() ever stopped reading the key, or read a different one,
    // it would still pass - but if it stopped falling back safely, it fails.
    expect(LlmBackendChoice.fromEnvironment(), LlmBackendChoice.shipped);
  });
}
