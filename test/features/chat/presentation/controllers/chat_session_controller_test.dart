import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/app/assistant_runtime_controller.dart';
import 'package:mybuddy/app/stt_model_controller.dart';
import 'package:mybuddy/core/audio/audio_recorder_service.dart';
import 'package:mybuddy/core/llm/llm_errors.dart';
import 'package:mybuddy/core/stt/stt_service.dart';
import 'package:mybuddy/features/chat/presentation/controllers/chat_session_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
  });

  test('shows safe LLM runtime message without Error prefix', () async {
    final runtime = _FakeRuntime(
      error: const LlmRuntimeException(
        LlmErrorCode.toolProtocolFailed,
        'Some requested actions may already have completed.',
      ),
    );
    final controller = _controller(runtime);

    await controller.sendText('hello');

    expect(
      controller.chat.last.text,
      'Some requested actions may already have completed.',
    );
  });

  test('hides unexpected exception details', () async {
    final controller = _controller(
      _FakeRuntime(error: StateError('secret implementation detail')),
    );

    await controller.sendText('hello');

    expect(
      controller.chat.last.text,
      'The assistant could not complete the request. Please try again.',
    );
  });
}

ChatSessionController _controller(AssistantRuntimeController runtime) {
  return ChatSessionController(
    appController: runtime,
    sttModelController: SttModelController(),
    sttService: const SttService(),
    recorder: AudioRecorderService(),
  );
}

final class _FakeRuntime extends AssistantRuntimeController {
  _FakeRuntime({required this.error});

  final Object error;

  @override
  bool get generatingResponse => false;
  @override
  bool get installingLlm => false;
  @override
  bool get llmInstalled => true;
  @override
  String? get llmError => null;
  @override
  bool get transcribingAudio => false;
  @override
  List<Map<String, String>> get conversation => const <Map<String, String>>[];

  @override
  Future<void> activateSelectedModel() async {}
  @override
  void beginTranscribing() {}
  @override
  Future<String> chatOnce(String userText) => Future<String>.error(error);
  @override
  Future<void> startNewConversation() async {}
  @override
  void endTranscribing() {}
}
