import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_controller.dart';
import '../../../../app/my_app.dart';
import '../../../../app/providers.dart';
import '../../../../core/audio/audio_recorder_service.dart';
import '../../../../core/tts/tts_service.dart';
import '../../../../core/unity/unity_bridge.dart';
import '../../../../shared/widgets/glass/glass.dart';
import '../../../diagnostics/presentation/widgets/experiment_tools_sheet.dart';
import '../../../google_calendar/presentation/pages/google_calendar_page.dart';
import '../../../settings/presentation/pages/settings_page.dart';
import '../controllers/chat_session_controller.dart';
import '../widgets/chat_composer.dart';
import '../widgets/chat_transcript.dart';
import '../widgets/memory_editor_sheet.dart';

class BuddyHomePage extends ConsumerStatefulWidget {
  const BuddyHomePage({super.key});

  @override
  ConsumerState<BuddyHomePage> createState() => _BuddyHomePageState();
}

class _BuddyHomePageState extends ConsumerState<BuddyHomePage> {
  late final UnityBridge _unity;
  final TtsService _tts = TtsService();
  final AudioRecorderService _recorder = AudioRecorderService();
  late final ChatSessionController _session;

  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  int _lastChatCount = 0;

  @override
  void initState() {
    super.initState();
    final appController = ref.read(appControllerProvider);
    _unity = ref.read(unityBridgeProvider);

    _session = ChatSessionController(
      appController: appController,
      sttModelController: ref.read(sttModelControllerProvider),
      sttService: ref.read(sttServiceProvider),
      recorder: _recorder,
      onSpeak: _speakInUnity,
      onStopSpeaking: _stopUnitySpeaking,
      onError: _showSnack,
    )..addListener(_onSessionUpdated);

    appController.addListener(_onAppConversationUpdated);
    _onAppConversationUpdated();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final stt = ref.read(sttModelControllerProvider);
      await stt.loadLocalState();
      await stt.refreshInstalled();
    });
  }

  @override
  void dispose() {
    ref.read(appControllerProvider).removeListener(_onAppConversationUpdated);
    _session.removeListener(_onSessionUpdated);
    _tts.dispose();
    unawaited(_recorder.dispose());
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSessionUpdated() {
    final chatCount = _session.chat.length;
    if (chatCount == _lastChatCount) return;

    _lastChatCount = chatCount;
    if (chatCount > 0 && _session.chat.last.isAssistant) {
      _scrollToBottom();
    }
  }

  Future<void> _openSettings() {
    return _pushFullscreenPage(const SettingsPage());
  }

  Future<void> _openCalendar() {
    return _pushFullscreenPage(const GoogleCalendarPage());
  }

  Future<void> _pushFullscreenPage(Widget page) {
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 0),
        reverseTransitionDuration: const Duration(milliseconds: 0),
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, animation, __, child) {
          final fade = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );

          return FadeTransition(opacity: fade, child: child);
        },
      ),
    );
  }

  /// Clears the conversation without touching stored memory or the loaded
  /// model. No confirmation prompt: the transcript is in-memory only and is
  /// already lost on every app restart.
  Future<void> _startNewConversation() async {
    final appController = ref.read(appControllerProvider);
    final discarded = appController.conversation.length;

    try {
      await appController.startNewConversation();
    } on StateError catch (e) {
      _showSnack(e.message);
      return;
    } catch (e) {
      _showSnack('Could not start a new conversation: $e');
      return;
    }

    _showSnack(
      discarded == 0
          ? 'New conversation started'
          : 'New conversation started — $discarded message(s) cleared',
    );
  }

  Future<void> _openExperimentTools() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ExperimentToolsSheet(
        onOpenMemoryEditor: _openMemoryEditor,
      ),
    );
  }

  Future<void> _openMemoryEditor() async {
    final memoryService = ref.read(memoryServiceProvider);
    final currentMemory = await memoryService.loadMemoryData();
    final autoUpdate = await memoryService.isAutoUpdateAllowed();
    final lockedFields = await memoryService.loadLockedFields();

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryEditorSheet(
        initialMemory: currentMemory,
        initialAutoUpdate: autoUpdate,
        initialLockedFields: lockedFields,
        memoryService: memoryService,
        onResetToColdStart: () async {
          await ref.read(appControllerProvider).resetMemoryToColdStart();
          _showSnack('Memory reset to cold start');
        },
      ),
    );
  }

  Future<void> _openOverlayChat() async {
    final overlay = ref.read(overlayServiceProvider);
    await overlay.showOverlay();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _unity.moveAppToBackground();
  }

  void _onAppConversationUpdated() {
    _session.syncFromAppConversation();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: _session,
                  builder: (_, _) => _buildTopActions(),
                ),
                const SizedBox(height: 10),
                Expanded(child: _buildTranscript(context, controller)),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: _session,
                  builder: (_, _) => _buildComposerStatus(controller),
                ),
                const SizedBox(height: 6),
                ListenableBuilder(
                  listenable: _session,
                  builder: (_, _) => _buildComposer(controller),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopActions() {
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _buildCalendarButton(),
          GlassIconButton.pill(
            tooltip: 'New conversation',
            icon: Icons.add_comment_outlined,
            onPressed: _startNewConversation,
          ),
          GlassIconButton.pill(
            tooltip: 'Experiment tools',
            icon: Icons.science_outlined,
            onPressed: _openExperimentTools,
          ),
          GlassIconButton.pill(
            tooltip: 'Memory',
            icon: Icons.psychology_rounded,
            onPressed: _openMemoryEditor,
          ),
          GlassIconButton.pill(
            tooltip: 'Settings',
            icon: Icons.settings,
            onPressed: _openSettings,
          ),
          GlassIconButton.pill(
            tooltip: 'Overlay',
            icon: Icons.picture_in_picture_rounded,
            onPressed: _openOverlayChat,
          ),
        ],
      ),
    );
  }

  Widget _buildComposerStatus(AppController controller) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          _getStatusText(controller),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: Colors.black.withValues(alpha: 0.86),
          ),
        ),
      ),
    );
  }

  Widget _buildCalendarButton() {
    final authService = ref.watch(googleAuthServiceProvider);
    final isSignedIn = authService.isSignedIn;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        GlassIconButton.pill(
          tooltip: 'Calendar',
          icon: Icons.calendar_month_rounded,
          onPressed: _openCalendar,
        ),
        Positioned(
          top: -2,
          right: -2,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: isSignedIn
                  ? AppColors.statusOnline
                  : AppColors.statusOffline,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.surface, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  String _getStatusText(AppController controller) {
    if (_session.recording) return 'Listening… release to send';
    if (_session.transcribing || controller.transcribingAudio) {
      return 'Transcribing…';
    }
    if (_session.sending || controller.generatingResponse) {
      return 'Generating response…';
    }
    if (controller.installingLlm) return 'Preparing model…';
    if (controller.llmInstalled) return 'MyBuddy';
    return 'Select a model in Settings';
  }

  Widget _buildTranscript(BuildContext context, AppController controller) {
    if (controller.installingLlm || controller.hideChatLog) {
      return const SizedBox.shrink();
    }

    if (!controller.llmInstalled) {
      return Center(
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                controller.llmError ?? 'No model selected.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _openSettings,
                child: const Text('Open Settings'),
              ),
            ],
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: _session,
      builder: (_, _) => ChatTranscript(
        chat: _session.chat,
        scrollController: _scrollController,
        sending: _session.sending || controller.generatingResponse,
        hideChatLog: controller.hideChatLog,
        pendingUserText: _session.pendingUserText,
      ),
    );
  }

  Widget _buildComposer(AppController controller) {
    final globallyBusy = controller.generatingResponse;
    final globallyTranscribing = controller.transcribingAudio;
    final canSend =
        controller.llmInstalled &&
        !_session.sending &&
        !globallyBusy &&
        !globallyTranscribing;
    final stt = ref.watch(sttModelControllerProvider);

    final llmIdle =
        controller.llmInstalled &&
        !_session.sending &&
        !globallyBusy &&
        !globallyTranscribing &&
        !controller.installingLlm;
    final hasSttModel = stt.selectedInstalledModel != null;
    final micEnabled = llmIdle && hasSttModel;

    return ChatComposer(
      textController: _textController,
      canSend: canSend,
      sending: _session.sending || globallyBusy,
      speaking: _session.speaking,
      isModelReady: controller.llmInstalled,
      micEnabled: micEnabled,
      isRecording: _session.recording,
      isTranscribing: _session.transcribing || globallyTranscribing,
      onMicHoldStart: () {
        unawaited(HapticFeedback.selectionClick());
        unawaited(_session.startMicHold());
      },
      onMicHoldEnd: () {
        unawaited(_session.endMicHoldAndSend());
      },
      onMicHoldCancel: () {
        unawaited(_session.cancelMicHold());
      },
      onSend: _onSend,
      onStopSpeaking: () {
        unawaited(_session.stopSpeaking());
      },
    );
  }

  Future<void> _onSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    await _session.sendText(text);
  }

  Future<void> _speakInUnity(String text) async {
    await _stopUnitySpeaking();
    final wavPath = await _tts.synthesizeToWavFile(
      text: text,
      fileNameBase: 'reply_${DateTime.now().millisecondsSinceEpoch}',
    );
    await _unity.speak(wavPath);
  }

  Future<void> _stopUnitySpeaking() async {
    await _tts.stop();
    await _unity.stopSpeak();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }
}
