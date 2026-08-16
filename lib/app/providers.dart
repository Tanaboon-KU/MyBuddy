import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/diagnostics/experiment_dump_service.dart';
import '../core/google/google_auth_service.dart';
import '../core/google/google_calendar_service.dart';
import '../core/llm/llm_platform.dart';
import '../core/llm/llm_service.dart';
import '../core/memory/memory_service.dart';
import '../core/overlay/overlay_service.dart';
import '../core/stt/stt_service.dart';
import '../core/unity/unity_bridge.dart';
import 'app_controller.dart';
import 'assistant_runtime_controller.dart';
import 'model_controller.dart';
import 'stt_model_controller.dart';

final unityBridgeProvider = Provider<UnityBridge>((ref) {
  const channel = MethodChannel('unity_bridge');
  return UnityBridge(channel: channel);
});

final memoryServiceProvider = Provider<MemoryService>((ref) {
  return MemoryService();
});

final googleAuthServiceProvider = ChangeNotifierProvider<GoogleAuthService>((
  ref,
) {
  return GoogleAuthService();
});

final googleCalendarServiceProvider =
    ChangeNotifierProvider<GoogleCalendarService>((ref) {
      final authService = ref.watch(googleAuthServiceProvider);
      return GoogleCalendarService(authService: authService);
    });

final modelControllerProvider = ChangeNotifierProvider<ModelController>((ref) {
  return ModelController();
});

final sttModelControllerProvider = ChangeNotifierProvider<SttModelController>((
  ref,
) {
  return SttModelController();
});

final sttServiceProvider = Provider<SttService>((ref) {
  return const SttService();
});

final overlayServiceProvider = ChangeNotifierProvider<OverlayService>((ref) {
  final service = OverlayService();
  service.initialize();
  return service;
});

final llmPlatformProvider = Provider<LlmPlatform>((ref) {
  return const FlutterGemmaLlmPlatform();
});

final llmServiceProvider = Provider<LlmService>((ref) {
  final unityBridge = ref.read(unityBridgeProvider);
  final memoryService = ref.read(memoryServiceProvider);
  final platform = ref.read(llmPlatformProvider);

  return LlmService(
    platform: platform,
    unityBridge: unityBridge,
    memoryService: memoryService,
    calendarEventGateway: () => ref.read(googleCalendarServiceProvider),
  );
});

final experimentDumpServiceProvider = Provider<ExperimentDumpService>((ref) {
  return ExperimentDumpService(
    memoryService: ref.read(memoryServiceProvider),
    llmService: ref.read(llmServiceProvider),
  );
});

final appControllerProvider = ChangeNotifierProvider<AppController>((ref) {
  final models = ref.read(modelControllerProvider);
  final memory = ref.read(memoryServiceProvider);
  final llm = ref.read(llmServiceProvider);

  return AppController(models: models, llm: llm, memory: memory);
});

final assistantRuntimeProvider = Provider<AssistantRuntimeController>((ref) {
  return ref.watch(appControllerProvider);
});
