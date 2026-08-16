import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/assistant_runtime_controller.dart';
import '../../app/model_controller.dart';
import '../audio/audio_recorder_service.dart';
import '../stt/stt_service.dart';

class OverlayAppProxy extends AssistantRuntimeController {
  OverlayAppProxy({required this.models});

  final ModelController models;

  StreamSubscription<dynamic>? _responseSubscription;
  final Map<String, Completer<String>> _chatPending = {};
  final Map<String, Completer<String?>> _sttPending = {};
  final Map<String, Completer<String>> _recordingPending = {};
  final Map<String, Completer<void>> _modelSwitchPending = {};
  final Map<String, Completer<void>> _newConversationPending = {};
  bool _isListening = false;

  bool _llmInstalled = false;
  bool _installingLlm = false;
  String? _llmError;
  bool _generatingResponse = false;
  bool _transcribingAudio = false;
  final List<Map<String, String>> _conversation = [];

  @override
  bool get llmInstalled => _llmInstalled;
  @override
  bool get installingLlm => _installingLlm;
  @override
  String? get llmError => _llmError;
  @override
  bool get generatingResponse => _generatingResponse;
  @override
  bool get transcribingAudio => _transcribingAudio;
  @override
  List<Map<String, String>> get conversation =>
      List.unmodifiable(_conversation);

  void startListening(Stream<dynamic> overlayStream) {
    _responseSubscription?.cancel();
    _isListening = true;
    _responseSubscription = overlayStream.listen(
      _onPayload,
      onError: (e) => debugPrint('OverlayAppProxy: stream error: $e'),
    );
  }

  void _onPayload(dynamic raw) {
    try {
      final map = _parsePayload(raw);
      if (map == null) return;

      final type = map['type'] as String?;
      if (type == 'chat_response') {
        _handleChatResponse(map);
      } else if (type == 'stt_response') {
        _handleSttResponse(map);
      } else if (type == 'recording_response') {
        _handleRecordingResponse(map);
      } else if (type == 'model_switch_response') {
        _handleModelSwitchResponse(map);
      } else if (type == 'new_conversation_response') {
        _handleNewConversationResponse(map);
      } else if (type == 'runtime_status') {
        _handleRuntimeStatus(map);
      }
    } catch (e) {
      debugPrint('OverlayAppProxy: failed to parse response: $e');
    }
  }

  static Map<String, dynamic>? _parsePayload(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  void _handleChatResponse(Map<String, dynamic> map) {
    final requestId = '${map['requestId'] ?? ''}';
    final completer = _chatPending.remove(requestId);
    if (completer == null) {
      debugPrint('OverlayAppProxy: no pending chat for requestId=$requestId');
      return;
    }

    final error = map['error'] as String?;
    if (error != null) {
      completer.completeError(Exception(error));
    } else {
      completer.complete((map['reply'] as String?) ?? '');
    }
  }

  void _handleSttResponse(Map<String, dynamic> map) {
    final requestId = '${map['requestId'] ?? ''}';
    final completer = _sttPending.remove(requestId);
    if (completer == null) {
      debugPrint('OverlayAppProxy: no pending STT for requestId=$requestId');
      return;
    }

    final error = map['error'] as String?;
    if (error != null) {
      completer.completeError(Exception(error));
    } else {
      completer.complete(map['text'] as String?);
    }
  }

  void _handleRecordingResponse(Map<String, dynamic> map) {
    final requestId = '${map['requestId'] ?? ''}';
    final completer = _recordingPending.remove(requestId);
    if (completer == null) {
      debugPrint(
        'OverlayAppProxy: no pending recording for requestId=$requestId',
      );
      return;
    }

    final error = map['error'] as String?;
    if (error != null) {
      completer.completeError(Exception(error));
    } else {
      completer.complete((map['path'] as String?) ?? '');
    }
  }

  void _handleModelSwitchResponse(Map<String, dynamic> map) {
    final requestId = '${map['requestId'] ?? ''}';
    final completer = _modelSwitchPending.remove(requestId);
    if (completer == null) {
      debugPrint(
        'OverlayAppProxy: no pending model_switch for requestId=$requestId',
      );
      return;
    }

    final error = map['error'] as String?;
    if (error != null) {
      completer.completeError(Exception(error));
    } else {
      completer.complete();
    }
  }

  void _handleNewConversationResponse(Map<String, dynamic> map) {
    final requestId = '${map['requestId'] ?? ''}';
    final completer = _newConversationPending.remove(requestId);
    if (completer == null) {
      debugPrint(
        'OverlayAppProxy: no pending new_conversation for requestId=$requestId',
      );
      return;
    }

    final error = map['error'] as String?;
    if (error != null) {
      completer.completeError(Exception(error));
    } else {
      completer.complete();
    }
  }

  void _handleRuntimeStatus(Map<String, dynamic> map) {
    _llmInstalled = map['llmInstalled'] as bool? ?? _llmInstalled;
    _installingLlm = map['installingLlm'] as bool? ?? _installingLlm;
    _llmError = map['llmError'] as String?;
    _generatingResponse =
        map['generatingResponse'] as bool? ?? _generatingResponse;
    _transcribingAudio =
        map['transcribingAudio'] as bool? ?? _transcribingAudio;
    if (map['conversation'] != null) {
      _conversation.clear();
      for (final item in map['conversation']) {
        _conversation.add(Map<String, String>.from(item));
      }
    }
    notifyListeners();
  }

  @override
  Future<String> chatOnce(String userText) async {
    if (!_isListening) {
      throw StateError('Overlay channel is not ready yet. Please try again.');
    }

    final id = _createRequestId();
    final completer = Completer<String>();
    _chatPending[id] = completer;

    final payload = <String, Object>{
      'type': 'chat_request',
      'text': userText,
      'requestId': id,
    };

    debugPrint('OverlayAppProxy.chatOnce: sending chat_request id=$id');

    try {
      await FlutterOverlayWindow.shareData(jsonEncode(payload));
    } catch (e) {
      _chatPending.remove(id);
      debugPrint('OverlayAppProxy.chatOnce: shareData failed: $e');
      rethrow;
    }

    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        _chatPending.remove(id);
        debugPrint('OverlayAppProxy.chatOnce: timed out id=$id');
        throw TimeoutException('LLM response timed out');
      },
    );
  }

  @override
  Future<void> startNewConversation() async {
    if (!_isListening) {
      throw StateError('Overlay channel is not ready yet. Please try again.');
    }

    final id = _createRequestId();
    final completer = Completer<void>();
    _newConversationPending[id] = completer;

    final payload = <String, Object>{
      'type': 'new_conversation_request',
      'requestId': id,
    };

    debugPrint(
      'OverlayAppProxy.startNewConversation: sending request id=$id',
    );

    try {
      await FlutterOverlayWindow.shareData(jsonEncode(payload));
    } catch (e) {
      _newConversationPending.remove(id);
      debugPrint('OverlayAppProxy.startNewConversation: shareData failed: $e');
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _newConversationPending.remove(id);
        debugPrint('OverlayAppProxy.startNewConversation: timed out id=$id');
        throw TimeoutException('Starting a new conversation timed out');
      },
    );
  }

  Future<String?> transcribeAudio({
    required String modelPath,
    required String audioPath,
    required String lang,
    required bool isTranslate,
  }) async {
    if (!_isListening) {
      throw StateError('Overlay channel is not ready yet.');
    }

    final id = _createRequestId();
    final completer = Completer<String?>();
    _sttPending[id] = completer;

    final payload = <String, Object>{
      'type': 'stt_request',
      'requestId': id,
      'audioPath': audioPath,
      'modelPath': modelPath,
      'lang': lang,
      'isTranslate': isTranslate,
    };

    debugPrint('OverlayAppProxy.transcribeAudio: sending stt_request id=$id');

    try {
      await FlutterOverlayWindow.shareData(jsonEncode(payload));
    } catch (e) {
      _sttPending.remove(id);
      debugPrint('OverlayAppProxy.transcribeAudio: shareData failed: $e');
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _sttPending.remove(id);
        debugPrint('OverlayAppProxy.transcribeAudio: timed out id=$id');
        throw TimeoutException('STT transcription timed out');
      },
    );
  }

  Future<String> startRecording() async {
    if (!_isListening) {
      throw StateError('Overlay channel is not ready yet.');
    }

    final id = _createRequestId();
    final completer = Completer<String>();
    _recordingPending[id] = completer;

    final payload = <String, Object>{
      'type': 'recording_start_request',
      'requestId': id,
    };

    debugPrint('OverlayAppProxy.startRecording: sending request id=$id');

    try {
      await FlutterOverlayWindow.shareData(jsonEncode(payload));
    } catch (e) {
      _recordingPending.remove(id);
      debugPrint('OverlayAppProxy.startRecording: shareData failed: $e');
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _recordingPending.remove(id);
        debugPrint('OverlayAppProxy.startRecording: timed out id=$id');
        throw TimeoutException('Recording start timed out');
      },
    );
  }

  Future<String> stopRecording() async {
    if (!_isListening) {
      throw StateError('Overlay channel is not ready yet.');
    }

    final id = _createRequestId();
    final completer = Completer<String>();
    _recordingPending[id] = completer;

    final payload = <String, Object>{
      'type': 'recording_stop_request',
      'requestId': id,
    };

    debugPrint('OverlayAppProxy.stopRecording: sending request id=$id');

    try {
      await FlutterOverlayWindow.shareData(jsonEncode(payload));
    } catch (e) {
      _recordingPending.remove(id);
      debugPrint('OverlayAppProxy.stopRecording: shareData failed: $e');
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _recordingPending.remove(id);
        debugPrint('OverlayAppProxy.stopRecording: timed out id=$id');
        throw TimeoutException('Recording stop timed out');
      },
    );
  }

  Future<void> cancelRecording() async {
    if (!_isListening) return;

    final payload = <String, Object>{'type': 'recording_cancel_request'};

    debugPrint('OverlayAppProxy.cancelRecording: sending cancel');

    try {
      await FlutterOverlayWindow.shareData(jsonEncode(payload));
    } catch (e) {
      debugPrint('OverlayAppProxy.cancelRecording: shareData failed: $e');
    }
  }

  String _createRequestId() {
    final micros = DateTime.now().microsecondsSinceEpoch;
    final hash = identityHashCode(this);
    return '$micros-$hash';
  }

  @override
  Future<void> activateSelectedModel() async {
    final selected = models.selectedModelId;
    if (selected == null) return;
    await switchModel(selected);
  }

  @override
  void beginTranscribing() {
    _transcribingAudio = true;
    notifyListeners();
  }

  @override
  void endTranscribing() {
    _transcribingAudio = false;
    notifyListeners();
  }

  Future<void> switchModel(String modelId) async {
    if (!_isListening) {
      throw StateError('Overlay channel is not ready yet.');
    }

    final id = _createRequestId();
    final completer = Completer<void>();
    _modelSwitchPending[id] = completer;

    final payload = <String, Object>{
      'type': 'model_switch_request',
      'requestId': id,
      'modelId': modelId,
    };

    debugPrint(
      'OverlayAppProxy.switchModel: sending request id=$id model=$modelId',
    );

    try {
      await FlutterOverlayWindow.shareData(jsonEncode(payload));
    } catch (e) {
      _modelSwitchPending.remove(id);
      debugPrint('OverlayAppProxy.switchModel: shareData failed: $e');
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _modelSwitchPending.remove(id);
        debugPrint('OverlayAppProxy.switchModel: timed out id=$id');
        throw TimeoutException('Model switch timed out');
      },
    );
  }

  void disposeRelay() {
    _responseSubscription?.cancel();
    _responseSubscription = null;
    _isListening = false;
    for (final c in _chatPending.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('Overlay closed'));
      }
    }
    _chatPending.clear();
    for (final c in _sttPending.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('Overlay closed'));
      }
    }
    _sttPending.clear();
    for (final c in _recordingPending.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('Overlay closed'));
      }
    }
    _recordingPending.clear();
    for (final c in _modelSwitchPending.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('Overlay closed'));
      }
    }
    _modelSwitchPending.clear();
    for (final c in _newConversationPending.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('Overlay closed'));
      }
    }
    _newConversationPending.clear();
  }
}

class OverlaySttService extends SttService {
  const OverlaySttService(this._proxy);

  final OverlayAppProxy _proxy;

  @override
  Future<String?> transcribe({
    required String modelPath,
    required String audioPath,
    required String lang,
    required bool isTranslate,
    int? threads,
  }) {
    return _proxy.transcribeAudio(
      modelPath: modelPath,
      audioPath: audioPath,
      lang: lang,
      isTranslate: isTranslate,
    );
  }
}

class OverlayAudioRecorderService extends AudioRecorderService {
  OverlayAudioRecorderService(OverlayAppProxy _);

  static const MethodChannel _overlayChannel = MethodChannel(
    'x-slayer/overlay',
  );

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<String> start() async {
    debugPrint(
      'OverlayAudioRecorderService.start: calling native recording in service',
    );
    final temp = await getTemporaryDirectory();
    final dir = '${temp.path}/stt_recordings';
    final fileName = 'rec_${DateTime.now().toUtc().millisecondsSinceEpoch}.wav';
    final outPath = '$dir/$fileName';

    final result = await _overlayChannel.invokeMethod<String>(
      'startRecording',
      {'path': outPath},
    );
    debugPrint('OverlayAudioRecorderService.start: native returned $result');
    return result ?? outPath;
  }

  @override
  Future<String?> stop() async {
    debugPrint(
      'OverlayAudioRecorderService.stop: calling native stop in service',
    );
    final result = await _overlayChannel.invokeMethod<String>('stopRecording');
    debugPrint('OverlayAudioRecorderService.stop: native returned $result');
    return result;
  }

  @override
  Future<void> cancelAndDelete() async {
    await _overlayChannel.invokeMethod<void>('cancelRecording');
  }

  @override
  Future<void> dispose() async {
    // No local resources to dispose; the service owns the recorder.
  }
}
