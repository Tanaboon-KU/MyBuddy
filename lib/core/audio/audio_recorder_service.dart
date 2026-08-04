import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioRecorderService {
  AudioRecorderService({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  String? _currentPath;

  Future<void> _operationTail = Future<void>.value();

  /// Runs [action] after every operation queued before it.
  ///
  /// [start] and [stop] are driven by a press and a release that the UI fires
  /// without awaiting either, so the two overlap whenever the tap is shorter
  /// than the native start. Unserialised, the release calls [stop] while
  /// `isRecording()` is still false, that stop does nothing, and the start
  /// then succeeds into a recording nobody owns - after which every later
  /// [start] throws `Recorder is already running` until the app is restarted.
  ///
  /// Same shape as `LlmService._runExclusive`.
  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final result = _operationTail.then((_) => action());
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  Future<String> start() => _runExclusive(_start);

  Future<String> _start() async {
    if (await _recorder.isRecording()) {
      throw StateError('Recorder is already running');
    }

    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, 'stt_recordings'));
    await dir.create(recursive: true);

    final fileName = 'rec_${DateTime.now().toUtc().millisecondsSinceEpoch}.wav';
    final outPath = p.join(dir.path, fileName);

    const config = RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
      bitRate: 128000,
    );

    try {
      await _recorder.start(config, path: outPath);
    } on PlatformException catch (e) {
      if (_isMicrophonePermissionError(e)) {
        throw const MicrophonePermissionException();
      }
      rethrow;
    } catch (e) {
      if (_isMicrophonePermissionError(e)) {
        throw const MicrophonePermissionException();
      }
      rethrow;
    }

    _currentPath = outPath;

    debugPrint('STT recording started: $outPath');
    return outPath;
  }

  Future<String?> stop() => _runExclusive(_stop);

  Future<String?> _stop() async {
    if (!await _recorder.isRecording()) {
      return _currentPath;
    }

    final stoppedPath = await _recorder.stop();
    final path = stoppedPath ?? _currentPath;
    _currentPath = null;

    if (path != null) {
      debugPrint('STT recording stopped: $path');
    }

    return path;
  }

  Future<void> cancelAndDelete() async {
    final path = await stop();
    if (path == null) return;

    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> dispose() async {
    await _recorder.dispose();
  }

  bool _isMicrophonePermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission') ||
        text.contains('not granted') ||
        text.contains('denied') ||
        text.contains('record_audio');
  }
}

class MicrophonePermissionException implements Exception {
  const MicrophonePermissionException();

  @override
  String toString() =>
      'Microphone permission is not granted. Please allow microphone access in Android app permissions.';
}
