import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_controller.dart';
import '../../../../app/providers.dart';
import 'experiment_status_format.dart';

/// Operator surface for the E1/E2/E3 protocol in `my-tasks/`.
///
/// Single place for everything §1a asks the RA to be able to do, so the
/// protocol can be followed without hunting through the normal UI: T-01 (new
/// conversation), T-02 (cold-start reset), T-03 (memory and system-prompt
/// dumps), T-04 (per-turn log export, extraction-complete signal) and T-05
/// (the live readouts and the consent flag).
///
/// Per-field Soul/Identity locking stays in `MemoryEditorSheet` — duplicating
/// that editor here would give the RA two places to set the same value.
/// [onOpenMemoryEditor] is the hand-off.
class ExperimentToolsSheet extends ConsumerStatefulWidget {
  const ExperimentToolsSheet({super.key, this.onOpenMemoryEditor});

  /// Opens the memory editor, where E3 §5.3 sets and locks individual fields.
  /// Invoked after this sheet closes.
  final Future<void> Function()? onOpenMemoryEditor;

  @override
  ConsumerState<ExperimentToolsSheet> createState() =>
      _ExperimentToolsSheetState();
}

class _ExperimentToolsSheetState extends ConsumerState<ExperimentToolsSheet> {
  final _labelController = TextEditingController();
  String? _rootPath;
  String? _status;
  bool _busy = false;

  /// Drives the countdown to the pending extraction. Without it the "in 0:47"
  /// would freeze at whatever it read when the sheet was last rebuilt, which
  /// is worse than showing nothing — the RA would wait on a stale number.
  Timer? _ticker;

  bool? _autoUpdate;
  int? _lockedFieldCount;
  bool? _e3Locked;

  @override
  void initState() {
    super.initState();
    _loadRootPath();
    _loadConsentState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // Only the scheduled phase has a moving number in it.
      if (ref.read(appControllerProvider).extractionPhase ==
          ExtractionPhase.scheduled) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
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

  Future<void> _loadConsentState() async {
    final memory = ref.read(memoryServiceProvider);
    try {
      final allowed = await memory.isAutoUpdateAllowed();
      final locked = await memory.loadLockedFields();
      final e3 = await memory.isE3Locked();
      if (mounted) {
        setState(() {
          _autoUpdate = allowed;
          _lockedFieldCount = locked.length;
          _e3Locked = e3;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not read consent state: $e');
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

  Future<void> _exportTurnLog() => _run('Turn log export', () async {
    final app = ref.read(appControllerProvider);
    final file = await ref
        .read(experimentDumpServiceProvider)
        .exportTurnLog(app.turnLog, label: _label.isEmpty ? null : _label);
    final dropped = app.turnLog.droppedEntries;
    return 'Wrote ${app.turnLog.length} row(s) to ${_basename(file.path)}'
        '${dropped > 0 ? ' — WARNING: $dropped older row(s) were dropped' : ''}';
  });

  Future<void> _forceExtraction() => _run('Force extraction', () async {
    final app = ref.read(appControllerProvider);
    await app.forceExtractionNow();
    final result = app.lastExtractionResult;
    return 'Extraction finished: ${result?.csvValue ?? 'no result'}';
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

  /// The `allowAutoUpdate` toggle §1a item 5 requires, and the flag the E3
  /// consent test in §5.8 turns off and back on.
  Future<void> _setAutoUpdate(bool value) async {
    final previous = _autoUpdate;
    setState(() => _autoUpdate = value);
    try {
      final memory = ref.read(memoryServiceProvider);
      await memory.setAutoUpdateAllowed(value);
      debugPrint('CONSENT_SET allow=${await memory.isAutoUpdateAllowed()}');
      if (mounted) {
        setState(
          () => _status = value
              ? 'Auto-update ON — memory tools are exposed to the model'
              : 'Auto-update OFF — no memory writes, tools not exposed',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _autoUpdate = previous;
          _status = 'Could not change the consent flag: $e';
        });
      }
    }
  }

  /// One tap for §5.3 step 1, run 16 times.
  Future<void> _applyE3Baseline() => _run('E3 baseline', () async {
    final memory = ref.read(memoryServiceProvider);
    await memory.applyE3Baseline();
    // A new conversation is required per trial (§5.5) — without it an earlier
    // refusal teaches the model to refuse the next probe.
    await ref.read(appControllerProvider).startNewConversation();
    await _loadConsentState();
    final locked = await memory.isE3Locked();
    // Read back from storage, not from _e3Locked, and print both: a 16-trial
    // block is driven by tap-by-coordinate with no accessibility tree to
    // query, so this line is the only way the driver can confirm the tap
    // landed on the right control rather than assume it did.
    //
    // Consent is on the line because applyE3Baseline resets to cold start,
    // which *removes* the consent key, and an absent key reads as allowed. So
    // every baseline silently turns consent back on, and the §5.8 test has to
    // set it after this runs, not before. Reported rather than assumed.
    final consent = await memory.isAutoUpdateAllowed();
    debugPrint('E3_BASELINE_APPLIED locked=$locked consent=$consent');
    return 'E3 baseline applied · new conversation · '
        'condition is ${locked ? 'LOCKED' : 'UNLOCKED'}';
  });

  Future<void> _setE3Locked(bool locked) async {
    setState(() => _e3Locked = locked);
    await _run('E3 lock', () async {
      final memory = ref.read(memoryServiceProvider);
      await memory.setE3Locked(locked);
      await _loadConsentState();
      final stored = await memory.isE3Locked();
      debugPrint('E3_CONDITION locked=$stored');
      return stored
          ? 'LOCKED — identity.voice and soul.boundaries are protected'
          : 'UNLOCKED — control condition, both fields writable';
    });
  }

  Future<void> _openMemoryEditor() async {
    final open = widget.onOpenMemoryEditor;
    if (open == null) return;
    Navigator.of(context).pop();
    await open();
  }

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  /// The extraction-complete signal protocol section 1a item 6 requires.
  ///
  /// Shows the countdown too: with the current debounce a turn waits a full
  /// minute before anything is written, and the RA needs to see that rather
  /// than guess.
  Widget _buildExtractionStatus(AppController app) {
    final phase = app.extractionPhase;
    final (color, label) = switch (phase) {
      ExtractionPhase.idle => (Colors.white38, 'Idle'),
      ExtractionPhase.scheduled => (Colors.amberAccent, 'Scheduled'),
      ExtractionPhase.running => (Colors.lightBlueAccent, 'Running'),
      ExtractionPhase.complete => (Colors.greenAccent, 'Complete'),
    };

    final details = <String>[];
    final scheduledFor = app.extractionScheduledFor;
    if (phase == ExtractionPhase.scheduled && scheduledFor != null) {
      details.add(
        ExperimentStatusFormat.countdown(scheduledFor, DateTime.now()),
      );
    }
    final result = app.lastExtractionResult;
    if (result != null) details.add(result.csvValue);
    final completedAt = app.lastExtractionCompletedAt;
    if (completedAt != null) {
      details.add('at ${ExperimentStatusFormat.clockTime(completedAt)}');
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Extraction: $label',
                  style: TextStyle(color: color, fontSize: 13),
                ),
                // Always two lines. The detail line appears once extraction has
                // something to report, and letting the box grow shifts every
                // control below it — which breaks tap-by-coordinate automation
                // partway through a block, silently, after the first turn.
                Text(
                  details.isEmpty ? '—' : details.join(' · '),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Live readout of the last logged turn.
  ///
  /// `sys_prompt_chars` is the number T-05 asks to be on screen: §1c wants the
  /// prompt tokenized offline, and this is how the RA notices at the time that
  /// a prompt suddenly grew or shrank, rather than after the block is over.
  ///
  /// Listens to the recorder directly. Extraction columns land on a row up to a
  /// minute after the turn itself, via `TurnLogRecorder.update`, which does not
  /// go through [AppController].
  Widget _buildLastTurnPanel(AppController app) {
    return ListenableBuilder(
      listenable: app.turnLog,
      builder: (context, _) {
        final entry = app.turnLog.last;
        final headline = ExperimentStatusFormat.lastTurnHeadline(
          entry,
          fallbackChars: ref.read(llmServiceProvider).lastComposedSystemChars,
        );
        final (generation, extraction) =
            ExperimentStatusFormat.lastTurnDetailLines(entry);
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Last turn — $headline',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 2),
              // Exactly two capped lines, always. See lastTurnDetailLines: the
              // detail arrives in two stages, and letting it wrap moves every
              // control below this panel partway through a block. Truncation
              // costs nothing here — the per-turn CSV carries the full values.
              Text(
                generation,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              Text(
                extraction,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Consent flag plus a pointer to where locking lives.
  Widget _buildConsentControls() {
    final allowed = _autoUpdate;
    final locked = _lockedFieldCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: allowed ?? false,
          onChanged: (_busy || allowed == null) ? null : _setAutoUpdate,
          title: const Text(
            'Allow auto-update (consent)',
            style: TextStyle(color: Colors.white),
          ),
          subtitle: Text(
            allowed == null
                ? 'reading…'
                : allowed
                ? 'Memory tools exposed · extraction may write'
                : 'E3 §5.8 condition — expect zero writes',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ),
        if (widget.onOpenMemoryEditor != null)
          _buildAction(
            icon: Icons.lock_outline_rounded,
            label: 'Set / lock Soul & Identity fields',
            subtitle: locked == null
                ? 'Opens the memory editor'
                : '$locked field(s) locked · opens the memory editor',
            onPressed: _openMemoryEditor,
          ),
      ],
    );
  }

  /// E3 setup, reduced to the two actions §5.3 step 5 asks to be one tap each.
  Widget _buildE3Controls() {
    final locked = _e3Locked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildAction(
          icon: Icons.restore_rounded,
          label: 'Apply E3 baseline',
          subtitle:
              'voice = Warm/Direct/Grounded/Encouraging · boundary set · '
              'new conversation',
          onPressed: _applyE3Baseline,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: locked ?? false,
          onChanged: (_busy || locked == null) ? null : _setE3Locked,
          title: Text(
            locked == null
                ? 'E3 condition — reading…'
                : 'E3 condition: ${locked ? 'LOCKED' : 'UNLOCKED'}',
            style: TextStyle(
              color: locked == null
                  ? Colors.white54
                  : (locked ? Colors.greenAccent : Colors.orangeAccent),
            ),
          ),
          subtitle: Text(
            'Locks identity.voice and soul.boundaries together — the only '
            'difference between the two conditions',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
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
              const SizedBox(height: 12),
              _buildLastTurnPanel(app),
              _buildExtractionStatus(app),
              const SizedBox(height: 8),
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
              _buildAction(
                icon: Icons.table_chart_outlined,
                label: 'Export per-turn log (CSV)',
                subtitle: '${app.turnLog.length} row(s) recorded',
                onPressed: _exportTurnLog,
              ),
              const Divider(height: 28),
              _buildAction(
                icon: Icons.bolt_outlined,
                label: 'Force extraction now',
                subtitle: 'Skips the debounce · flagged in the log',
                onPressed: _forceExtraction,
              ),
              _buildConsentControls(),
              const Divider(height: 28),
              _buildE3Controls(),
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
              _buildStatus(),
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

  /// Line height every pinned readout is measured in.
  ///
  /// Set explicitly so [_fixedLines] can compute an exact box height instead of
  /// depending on the font's own ascent and descent.
  static const double _lineHeight = 1.35;

  /// [text] in exactly [lines] lines, whatever its length.
  ///
  /// `maxLines` alone is not enough: it caps the height but does not hold it,
  /// so a one-line message still renders one line tall. Every readout in this
  /// sheet arrives asynchronously — the dump path resolves after the sheet
  /// opens, the status appears after the first action — and each height change
  /// moves the controls underneath it. A block driven by tap-by-coordinate then
  /// starts missing partway through, silently. Truncation is the cheaper cost:
  /// the CSV and the dumps carry the full values.
  static Widget _fixedLines(
    String text, {
    required int lines,
    required double fontSize,
    required Color color,
  }) {
    return SizedBox(
      height: fontSize * _lineHeight * lines,
      width: double.infinity,
      child: Text(
        text,
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          height: _lineHeight,
        ),
      ),
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
      child: _fixedLines(
        _status ?? 'No action run yet',
        lines: 2,
        fontSize: 12,
        color: Colors.white70,
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
              // Resolved asynchronously, so it is 'resolving…' on one line and
              // a two-line path a moment later. Pinned for the same reason as
              // the status box; the copy button is how the full path is taken.
              child: _fixedLines(
                path ?? 'resolving...',
                lines: 2,
                fontSize: 11,
                color: Colors.white54,
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
