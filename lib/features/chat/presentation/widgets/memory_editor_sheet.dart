import 'package:flutter/material.dart';

import '../../../../core/memory/memory_service.dart';

class MemoryEditorSheet extends StatefulWidget {
  const MemoryEditorSheet({
    super.key,
    required this.initialMemory,
    required this.initialAutoUpdate,
    required this.initialLockedFields,
    required this.memoryService,
    this.onResetToColdStart,
  });

  final UserMemory initialMemory;
  final bool initialAutoUpdate;
  final Set<String> initialLockedFields;
  final MemoryService memoryService;

  /// Wipes stored memory and the live conversation together. Supplied by the
  /// host page, which owns the `AppController` needed to clear the session.
  /// When null the reset control is hidden.
  final Future<void> Function()? onResetToColdStart;

  @override
  State<MemoryEditorSheet> createState() => _MemoryEditorSheetState();
}

class _MemoryEditorSheetState extends State<MemoryEditorSheet> {
  late final TextEditingController _soulMissionController;
  late final TextEditingController _identityNameController;
  late final TextEditingController _identityRoleController;
  late final TextEditingController _userNameController;

  late List<String> _soulPrinciples;
  late List<String> _soulBoundaries;
  late List<String> _soulStyle;
  late List<String> _identityVoice;
  late List<String> _identityRules;
  late List<String> _userTraits;
  late List<String> _userPreferences;
  late List<String> _userGoals;
  late List<String> _userFacts;

  late bool _autoUpdate;
  late Set<String> _lockedFields;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final memory = widget.initialMemory;

    _soulMissionController = TextEditingController(
      text: memory.soul.mission ?? '',
    );
    _identityNameController = TextEditingController(
      text: memory.identity.assistantName ?? '',
    );
    _identityRoleController = TextEditingController(
      text: memory.identity.role ?? '',
    );
    _userNameController = TextEditingController(text: memory.user.name ?? '');

    _soulPrinciples = List<String>.from(memory.soul.principles);
    _soulBoundaries = List<String>.from(memory.soul.boundaries);
    _soulStyle = List<String>.from(memory.soul.responseStyle);
    _identityVoice = List<String>.from(memory.identity.voice);
    _identityRules = List<String>.from(memory.identity.behaviorRules);
    _userTraits = List<String>.from(memory.user.traits);
    _userPreferences = List<String>.from(memory.user.preferences);
    _userGoals = List<String>.from(memory.user.goals);
    _userFacts = List<String>.from(memory.user.facts);

    _autoUpdate = widget.initialAutoUpdate;
    _lockedFields = Set<String>.from(widget.initialLockedFields);
  }

  @override
  void dispose() {
    _soulMissionController.dispose();
    _identityNameController.dispose();
    _identityRoleController.dispose();
    _userNameController.dispose();
    super.dispose();
  }

  UserMemory _buildMemory() {
    final userName = _userNameController.text.trim();
    final assistantName = _identityNameController.text.trim();
    final role = _identityRoleController.text.trim();
    final mission = _soulMissionController.text.trim();

    return UserMemory(
      soul: SoulMemory(
        mission: mission.isEmpty ? null : mission,
        principles: _soulPrinciples,
        boundaries: _soulBoundaries,
        responseStyle: _soulStyle,
      ),
      identity: IdentityMemory(
        assistantName: assistantName.isEmpty ? null : assistantName,
        role: role.isEmpty ? null : role,
        voice: _identityVoice,
        behaviorRules: _identityRules,
      ),
      user: UserProfileMemory(
        name: userName.isEmpty ? null : userName,
        traits: _userTraits,
        preferences: _userPreferences,
        goals: _userGoals,
        facts: _userFacts,
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.memoryService.saveMemoryData(_buildMemory());
      await widget.memoryService.setAutoUpdateAllowed(_autoUpdate);
      await widget.memoryService.saveLockedFields(_lockedFields);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _isLocked(String fieldPath) => _lockedFields.contains(fieldPath);

  void _setLocked(String fieldPath, bool locked) {
    setState(() {
      if (locked) {
        _lockedFields.add(fieldPath);
      } else {
        _lockedFields.remove(fieldPath);
      }
    });
  }

  void _clearAll() {
    setState(() {
      _soulMissionController.clear();
      _identityNameController.clear();
      _identityRoleController.clear();
      _userNameController.clear();

      _soulPrinciples.clear();
      _soulBoundaries.clear();
      _soulStyle.clear();
      _identityVoice.clear();
      _identityRules.clear();
      _userTraits.clear();
      _userPreferences.clear();
      _userGoals.clear();
      _userFacts.clear();
    });
  }

  void _addToList(List<String> list, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    if (list.length >= MemoryConfig.maxEntriesPerField) return;
    if (list.contains(trimmed)) return;
    setState(() => list.add(trimmed));
  }

  void _removeFromList(List<String> list, int index) {
    setState(() => list.removeAt(index));
  }

  Future<void> _showAddDialog({
    required String fieldLabel,
    required List<String> targetList,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _AddEntryDialog(fieldLabel: fieldLabel, controller: controller),
    );
    controller.dispose();

    if (result == null || result.trim().isEmpty) return;
    _addToList(targetList, result);
  }

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
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: _buildHeader(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: _buildTabs(),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildSoulTabView(),
                    _buildIdentityTabView(),
                    _buildUserTabView(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: _buildAutoUpdateToggle(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: _buildSaveButton(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return TabBar(
      labelColor: Colors.white,
      unselectedLabelColor: Colors.white.withValues(alpha: 0.6),
      indicatorColor: Colors.white,
      indicatorSize: TabBarIndicatorSize.tab,
      tabs: const [
        Tab(text: 'SOUL'),
        Tab(text: 'IDENTITY'),
        Tab(text: 'USER'),
      ],
    );
  }

  Widget _buildSoulTabView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: _buildSectionCard(
        title: 'SOUL',
        icon: Icons.auto_awesome_rounded,
        children: [
          _buildTextField(
            controller: _soulMissionController,
            label: 'Mission',
            hint: 'Core mission for this assistant',
            lockPath: MemoryFieldPaths.soulMission,
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.rule_rounded,
            label: 'Principles',
            lockPath: MemoryFieldPaths.soulPrinciples,
            items: _soulPrinciples,
            color: const Color(0xFF64B5F6),
            onAdd: () => _showAddDialog(
              fieldLabel: 'Principle',
              targetList: _soulPrinciples,
            ),
            onRemove: (i) => _removeFromList(_soulPrinciples, i),
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.shield_rounded,
            label: 'Boundaries',
            lockPath: MemoryFieldPaths.soulBoundaries,
            items: _soulBoundaries,
            color: const Color(0xFFE57373),
            onAdd: () => _showAddDialog(
              fieldLabel: 'Boundary',
              targetList: _soulBoundaries,
            ),
            onRemove: (i) => _removeFromList(_soulBoundaries, i),
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.record_voice_over_rounded,
            label: 'Response Style',
            lockPath: MemoryFieldPaths.soulResponseStyle,
            items: _soulStyle,
            color: const Color(0xFF81C784),
            onAdd: () => _showAddDialog(
              fieldLabel: 'Response style',
              targetList: _soulStyle,
            ),
            onRemove: (i) => _removeFromList(_soulStyle, i),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityTabView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: _buildSectionCard(
        title: 'IDENTITY',
        icon: Icons.badge_rounded,
        children: [
          _buildTextField(
            controller: _identityNameController,
            label: 'Assistant Name',
            hint: 'How the assistant identifies itself',
            lockPath: MemoryFieldPaths.identityAssistantName,
          ),
          const SizedBox(height: 10),
          _buildTextField(
            controller: _identityRoleController,
            label: 'Role',
            hint: 'Role description and purpose',
            lockPath: MemoryFieldPaths.identityRole,
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.graphic_eq_rounded,
            label: 'Voice',
            lockPath: MemoryFieldPaths.identityVoice,
            items: _identityVoice,
            color: const Color(0xFFBA68C8),
            onAdd: () => _showAddDialog(
              fieldLabel: 'Voice trait',
              targetList: _identityVoice,
            ),
            onRemove: (i) => _removeFromList(_identityVoice, i),
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.assignment_turned_in_rounded,
            label: 'Behavior Rules',
            lockPath: MemoryFieldPaths.identityBehaviorRules,
            items: _identityRules,
            color: const Color(0xFFFFD54F),
            onAdd: () => _showAddDialog(
              fieldLabel: 'Behavior rule',
              targetList: _identityRules,
            ),
            onRemove: (i) => _removeFromList(_identityRules, i),
          ),
        ],
      ),
    );
  }

  Widget _buildUserTabView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: _buildSectionCard(
        title: 'USER',
        icon: Icons.person_rounded,
        children: [
          _buildTextField(
            controller: _userNameController,
            label: 'Name',
            hint: 'User name',
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.emoji_emotions_rounded,
            label: 'Traits',
            items: _userTraits,
            color: const Color(0xFF64B5F6),
            onAdd: () =>
                _showAddDialog(fieldLabel: 'Trait', targetList: _userTraits),
            onRemove: (i) => _removeFromList(_userTraits, i),
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.favorite_rounded,
            label: 'Preferences',
            items: _userPreferences,
            color: const Color(0xFFE57373),
            onAdd: () => _showAddDialog(
              fieldLabel: 'Preference',
              targetList: _userPreferences,
            ),
            onRemove: (i) => _removeFromList(_userPreferences, i),
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.flag_rounded,
            label: 'Goals',
            items: _userGoals,
            color: const Color(0xFF81C784),
            onAdd: () =>
                _showAddDialog(fieldLabel: 'Goal', targetList: _userGoals),
            onRemove: (i) => _removeFromList(_userGoals, i),
          ),
          const SizedBox(height: 12),
          _buildTagSection(
            icon: Icons.lightbulb_rounded,
            label: 'Facts',
            items: _userFacts,
            color: const Color(0xFFFFD54F),
            onAdd: () =>
                _showAddDialog(fieldLabel: 'Fact', targetList: _userFacts),
            onRemove: (i) => _removeFromList(_userFacts, i),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Icon(
          Icons.psychology_rounded,
          color: Colors.white.withValues(alpha: 0.85),
          size: 22,
        ),
        const SizedBox(width: 8),
        Text(
          'Memory Profile',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        IconButton(
          icon: Icon(
            Icons.delete_outline_rounded,
            color: Colors.redAccent.withValues(alpha: 0.8),
            size: 20,
          ),
          tooltip: 'Clear all fields (still needs Save)',
          onPressed: _clearAll,
        ),
        if (widget.onResetToColdStart != null)
          IconButton(
            icon: Icon(
              Icons.restart_alt_rounded,
              color: Colors.redAccent.withValues(alpha: 0.8),
              size: 20,
            ),
            tooltip: 'Reset to cold start',
            onPressed: _saving ? null : _resetToColdStart,
          ),
      ],
    );
  }

  /// Full cold start: wipes every stored key *and* the live conversation.
  ///
  /// Distinct from [_clearAll], which only empties the on-screen fields and
  /// leaves the consent flag, the locked-field sets and the current
  /// conversation untouched until Save is pressed.
  Future<void> _resetToColdStart() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset to cold start?'),
        content: const Text(
          'Wipes all three memory layers, the auto-update consent flag and '
          'every locked field, then starts a new conversation.\n\n'
          'Downloaded models are not affected. This cannot be undone.',
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

    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await widget.onResetToColdStart!();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reset failed: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: Colors.white.withValues(alpha: 0.75)),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  color: Colors.white.withValues(alpha: 0.82),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    String? lockPath,
  }) {
    final isLockable = lockPath != null;
    final isLocked = isLockable && _isLocked(lockPath);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
            if (isLockable) ...[
              const SizedBox(width: 6),
              _LockButton(
                locked: isLocked,
                onChanged: (value) => _setLocked(lockPath, value),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: TextField(
            controller: controller,
            readOnly: isLocked,
            maxLength: MemoryConfig.maxTextFieldLength,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: isLocked ? 'Locked by policy' : hint,
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 14,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              counterText: '',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTagSection({
    required IconData icon,
    required String label,
    String? lockPath,
    required List<String> items,
    required Color color,
    required VoidCallback onAdd,
    required void Function(int) onRemove,
  }) {
    final isLockable = lockPath != null;
    final isLocked = isLockable && _isLocked(lockPath);
    final atLimit = items.length >= MemoryConfig.maxEntriesPerField;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color.withValues(alpha: 0.8)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
            if (isLockable) ...[
              const SizedBox(width: 6),
              _LockButton(
                locked: isLocked,
                onChanged: (value) => _setLocked(lockPath, value),
              ),
            ],
            const SizedBox(width: 4),
            Text(
              '${items.length}/${MemoryConfig.maxEntriesPerField}',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.15)),
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < items.length; i++)
                _MemoryChip(
                  label: items[i],
                  color: color,
                  onDelete: isLocked ? null : () => onRemove(i),
                ),
              if (!atLimit)
                _AddChipButton(
                  color: color,
                  onPressed: isLocked ? null : onAdd,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAutoUpdateToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Auto-update from conversation',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'Locked SOUL/IDENTITY fields are never auto-updated',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 28,
            child: FittedBox(
              child: Switch(
                value: _autoUpdate,
                onChanged: (v) => setState(() => _autoUpdate = v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton(
      onPressed: _saving ? null : _save,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: _saving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

class _MemoryChip extends StatelessWidget {
  const _MemoryChip({
    required this.label,
    required this.color,
    required this.onDelete,
  });

  final String label;
  final Color color;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color.withValues(alpha: 0.9),
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 2),
          if (onDelete != null)
            GestureDetector(
              onTap: onDelete,
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: color.withValues(alpha: 0.6),
              ),
            ),
        ],
      ),
    );
  }
}

class _AddChipButton extends StatelessWidget {
  const _AddChipButton({required this.color, required this.onPressed});

  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add_rounded,
              size: 14,
              color: Colors.white.withValues(
                alpha: onPressed == null ? 0.22 : 0.5,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'Add',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(
                  alpha: onPressed == null ? 0.22 : 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockButton extends StatelessWidget {
  const _LockButton({required this.locked, required this.onChanged});

  final bool locked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!locked),
      child: Icon(
        locked ? Icons.lock_rounded : Icons.lock_open_rounded,
        size: 14,
        color: locked
            ? Colors.amberAccent.withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.45),
      ),
    );
  }
}

class _AddEntryDialog extends StatelessWidget {
  const _AddEntryDialog({required this.fieldLabel, required this.controller});

  final String fieldLabel;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'Add $fieldLabel',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 60,
        style: const TextStyle(fontSize: 14),
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.of(context).pop(value),
        decoration: InputDecoration(
          hintText: 'Enter $fieldLabel…',
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
          counterText: '',
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.07),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
