import 'package:flutter_gemma/flutter_gemma.dart';

/// Which backend the inference engine runs on, chosen at build time.
///
/// Added 2026-08-18, because a block could not be collected without it. An E2
/// block on Gemma 4 E2B died at pair 5 with the app taking SIGSEGV inside
/// `/vendor/lib64/libCB.so` - Qualcomm's OpenCL driver - on the `AdrenoOsLib`
/// thread, part-way through an extraction pass:
///
/// ```
/// #00 libCB.so  cl_command_set_status+400
/// #01 libCB.so  cl_a6x_wait_for_timestamp_thread+232
/// #02 libgsl.so os_thread_launcher+48
/// ```
///
/// `a6x` is Adreno 6xx, which is the Adreno 650 in the handset every block runs
/// on. The fault address was a dereferenced poison pattern and the process was
/// gone before any Dart code could see it, so this is not something the app can
/// catch and retry - it can only be avoided.
///
/// [LlmService] already had a GPU->CPU fallback and it could not help. That
/// fallback fires when the *initial* model load throws; this load had succeeded
/// an hour earlier and thousands of tokens ago. The backend was a constructor
/// default with no override anywhere in the app, so reaching CPU meant editing
/// the source, which is not something a block should require.
///
/// Spelled the same way the write path and the experiment tools are, so a run
/// is identified by a `--dart-define` rather than by what somebody edited:
///
/// ```
/// fvm flutter build apk --debug --dart-define-from-file=env.json \
///     --dart-define=LLM_BACKEND=cpu
/// ```
///
/// The choice is reported per turn next to `EXTRACTION_ARM`, so a block reads
/// it back off the handset instead of trusting that the intended APK is the
/// one installed.
enum LlmBackendChoice {
  /// What the app ships and what every block before 2026-08-18 ran on. Faster,
  /// and on this handset it is also where the driver fault lives.
  gpu('gpu', PreferredBackend.gpu),

  /// The backend Gemma 4 E2B's own model card benchmarks - 557 tok/s prefill,
  /// 40.7 tok/s decode, 1,362-1,733 MB peak, against the 2.64 GB PSS measured
  /// for the same model on GPU here. Slower per token, and it does not go
  /// through `libCB.so` at all.
  cpu('cpu', PreferredBackend.cpu);

  const LlmBackendChoice(this.label, this.backend);

  /// Goes in the per-turn log line. A block whose rows do not name their
  /// backend cannot be compared with one that ran on the other, which is what
  /// §4.1 asks for about builds.
  final String label;

  /// What flutter_gemma is handed.
  final PreferredBackend backend;

  static const String _key = 'LLM_BACKEND';

  /// The backend a build with no `--dart-define` runs.
  ///
  /// It has to stay GPU. Every block collected before this flag existed ran on
  /// it, and a default that quietly moved to CPU would reinterpret all of them
  /// - the same reason [ExtractionArm.shipped] is the arm the system ships
  /// rather than the arm that scores best.
  static const LlmBackendChoice shipped = LlmBackendChoice.gpu;

  static LlmBackendChoice fromEnvironment() =>
      parse(const String.fromEnvironment(_key));

  /// Anything unrecognised falls back rather than throwing. A typo in a build
  /// script should produce a run that measures documented behaviour, not a
  /// crash on startup and not an undocumented configuration.
  static LlmBackendChoice parse(String name) {
    for (final choice in LlmBackendChoice.values) {
      if (choice.label == name) return choice;
    }
    return shipped;
  }
}
