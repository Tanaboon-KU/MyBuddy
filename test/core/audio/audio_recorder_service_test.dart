import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/audio/audio_recorder_service.dart';
import 'package:record/record.dart';

/// An [AudioRecorder] whose `start` does not complete until released.
///
/// Reproduces the real timing: on the device the native start took ~390 ms
/// (`calling _recorder.start()` at 23:14:45.688, `STT recording started` at
/// 23:14:46.079), and a mic tap released inside that window.
final class _GatedRecorder extends AudioRecorder {
  final Completer<void> startGate = Completer<void>();
  bool running = false;
  String? path;
  int startCalls = 0;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCalls += 1;
    await startGate.future;
    this.path = path;
    running = true;
  }

  @override
  Future<String?> stop() async {
    if (!running) return null;
    running = false;
    return path;
  }

  @override
  Future<bool> isRecording() async => running;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory') {
          return Directory.systemTemp.createTempSync('stt_test').path;
        }
        return null;
      },
    );

    // `AudioRecorder`'s constructor calls `create` on this channel, so even a
    // subclass that overrides every method still needs it stubbed.
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (_) async => null,
    );
  });

  group('stop arriving while start is still in flight', () {
    test('does not leave the recorder running', () async {
      final recorder = _GatedRecorder();
      final service = AudioRecorderService(recorder: recorder);

      final starting = service.start();
      final stopping = service.stop();

      recorder.startGate.complete();
      await starting;
      await stopping;

      expect(
        recorder.running,
        isFalse,
        reason:
            'the release handler ran before the native start resolved, so the '
            'recording it started is never stopped by anyone',
      );
    });

    test('leaves the recorder usable for the next hold', () async {
      final recorder = _GatedRecorder();
      final service = AudioRecorderService(recorder: recorder);

      final starting = service.start();
      final stopping = service.stop();
      recorder.startGate.complete();
      await starting;
      await stopping;

      // This is what the user sees: every later tap throws
      // "Bad state: Recorder is already running" until the app is restarted.
      await expectLater(service.start(), completes);
    });

    test('returns the path of the recording it stopped', () async {
      final recorder = _GatedRecorder();
      final service = AudioRecorderService(recorder: recorder);

      final starting = service.start();
      final stopping = service.stop();
      recorder.startGate.complete();
      final started = await starting;

      expect(await stopping, started);
    });
  });

  test('a normal start then stop still round-trips', () async {
    final recorder = _GatedRecorder()..startGate.complete();
    final service = AudioRecorderService(recorder: recorder);

    final path = await service.start();
    expect(recorder.running, isTrue);

    expect(await service.stop(), path);
    expect(recorder.running, isFalse);
  });

  test('start still rejects a genuine double start', () async {
    final recorder = _GatedRecorder()..startGate.complete();
    final service = AudioRecorderService(recorder: recorder);

    await service.start();

    await expectLater(service.start(), throwsStateError);
  });
}
