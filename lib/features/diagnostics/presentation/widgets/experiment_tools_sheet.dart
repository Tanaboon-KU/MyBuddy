import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';

/// Operator surface for the E1/E2/E3 protocol in `my-tasks/`.
///
/// Groups the capabilities protocol §1a requires the RA to have. Currently
/// covers T-01 (new conversation), T-02 (cold-start reset) and T-03 (memory
/// and system-prompt dumps). T-04 will add the per-turn log export and the
/// extraction-complete indicator here.
class ExperimentToolsSheet extends ConsumerStatefulWidget {
  const ExperimentToolsSheet({super.key});

  @override
  ConsumerState<ExperimentToolsSheet> createState() =>
      _ExperimentToolsSheetState();
}

class _ExperimentToolsSheetState extends ConsumerState<ExperimentToolsSheet> {
  final _labelController = TextEditingController();
  String? _rootPath;
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadRootPath();
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _loadRootPath() async {
    try {
      final dir = await ref
          .read(experimentDumpServiceProvider)
          .resolveRootDirectory();
      if (mounted) setState(() => _rootPath = dir.path);
    } catch (e) {
      if (mounted) setState(() => _rootPath = 'unavailable: $e');
    }
  }

  Future<void> _run(String action, Future<String> Function() body) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final message = await body();
      if (mounted) setState(() => _status = message);
    } on StateError catch (e) {
      if (mounted) setState(() => _status = '$action failed: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _status = '$action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _label => _labelController.text.trim();

  Future<void> _dumpMemory() => _run('Memory dump', () async {
    final file = await ref
        .read(experimentDumpServiceProvider)
        .dumpMemory(label: _label.isEmpty ? null : _label);
    return 'Memory written to ${_basename(file.path)}';
  });

  Future<void> _dumpPrompt() => _run('Prompt dump', () async {
    final file = await ref
        .read(experimentDumpServiceProvider)
        .dumpSystemPrompt(label: _label.isEmpty ? null : _label);
    final chars = ref.read(llmServiceProvider).lastComposedSystemChars;
    return 'Prompt written to ${_basename(file.path)} ($chars chars)';
  });

  Future<void> _newConversation() => _run('New conversation', () async {
    final app = ref.read(appControllerProvider);
    final discarded = app.conversation.length;
    await app.startNewConversation();
    return 'New conversation started ($discarded message(s) cleared)';
  });

  Future<void> _resetColdStart() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset to cold start?'),
        content: const Text(
          'Wipes all three memory layers, the auto-update consent flag and '
          'every locked field, then starts a new conversation.\n\n'
          'Downloaded models are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _run('Reset', () async {
      await ref.read(appControllerProvider).resetMemoryToColdStart();
      return 'Memory reset to cold start';
    });
  }

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        margin: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              const SizedBox(height: 16),
              _buildLabelField(),
              const SizedBox(height: 12),
              _buildAction(
                icon: Icons.save_alt_rounded,
                label: 'Dump memory',
                subtitle: 'Canonical JSON of all three layers',
                onPressed: _dumpMemory,
              ),
              _buildAction(
                icon: Icons.description_outlined,
                label: 'Dump system prompt',
                subtitle: 'Exact text sent to the model, tool blocks included',
                onPressed: _dumpPrompt,
              ),
              const Divider(height: 28),
              _buildAction(
                icon: Icons.add_comment_outlined,
                label: 'New conversation',
                subtitle: 'Clears the session · memory and model untouched',
                onPressed: _newConversation,
              ),
              _buildAction(
                icon: Icons.restart_alt_rounded,
                label: 'Reset to cold start',
                subtitle: 'Wipes stored memory and starts a new conversation',
                destructive: true,
                onPressed: _resetColdStart,
              ),
              const SizedBox(height: 16),
              if (_status != null) _buildStatus(),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const Icon(Icons.science_outlined, color: Colors.white70, size: 20),
        const SizedBox(width: 8),
        Text(
          'Experiment tools',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (_busy)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildLabelField() {
    return TextField(
      controller: _labelController,
      decoration: InputDecoration(
        labelText: 'File label',
        hintText: 'run01_after_input_a',
        helperText: 'Leave empty to use a timestamp',
        helperMaxLines: 2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
    );
  }

  Widget _buildAction({
    required IconData icon,
    required String label,
    required String subtitle,
    required Future<void> Function() onPressed,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.redAccent : Colors.white;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color.withValues(alpha: 0.85), size: 20),
      title: Text(label, style: TextStyle(color: color)),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 12,
        ),
      ),
      enabled: !_busy,
      onTap: _busy ? null : onPressed,
    );
  }

  Widget _buildStatus() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _status!,
        style: const TextStyle(fontSize: 12, color: Colors.white70),
      ),
    );
  }

  Widget _buildFooter() {
    final path = _rootPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dump folder',
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                path ?? 'resolving...',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
            if (path != null)
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 16),
                tooltip: 'Copy path',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: path));
                  if (mounted) setState(() => _status = 'Path copied');
                },
              ),
          ],
        ),
      ],
    );
  }
}
