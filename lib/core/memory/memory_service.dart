import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/turn_log.dart';
import '../llm/llm_service.dart';
import '../llm/memory_tool_semantics.dart';

abstract final class MemoryStorageKeys {
  static const String memory = 'mybuddy.companion_memory.v3';
  static const String soulMemory = 'mybuddy.companion_memory.soul.v1';
  static const String identityMemory = 'mybuddy.companion_memory.identity.v1';
  static const String userMemory = 'mybuddy.companion_memory.user.v1';
  static const String legacyMemory = 'mybuddy.user_memory.v2';
  static const String allowAutoUpdate =
      'mybuddy.user_memory.allow_auto_update.v1';
  static const String lockedFields = 'mybuddy.memory.locked_fields.v1';
  static const String lockedSoulFields = 'mybuddy.memory.locked_soul_fields.v1';
  static const String lockedIdentityFields =
      'mybuddy.memory.locked_identity_fields.v1';

  /// Every key that holds memory state.
  ///
  /// [legacyMemory] must stay in this set: [MemoryService.loadMemoryData]
  /// falls back to it and re-migrates, so leaving it behind makes a "cold
  /// start" silently restore old data on the next load.
  ///
  /// Model and STT installation keys are intentionally absent — resetting
  /// memory must never delete a downloaded model.
  static const Set<String> all = <String>{
    memory,
    soulMemory,
    identityMemory,
    userMemory,
    legacyMemory,
    allowAutoUpdate,
    lockedFields,
    lockedSoulFields,
    lockedIdentityFields,
  };
}

abstract final class MemoryFieldPaths {
  static const String soulMission = 'soul.mission';
  static const String soulPrinciples = 'soul.principles';
  static const String soulBoundaries = 'soul.boundaries';
  static const String soulResponseStyle = 'soul.response_style';
  static const String identityAssistantName = 'identity.assistant_name';
  static const String identityRole = 'identity.role';
  static const String identityVoice = 'identity.voice';
  static const String identityBehaviorRules = 'identity.behavior_rules';

  static const Set<String> soulAndIdentity = <String>{
    soulMission,
    soulPrinciples,
    soulBoundaries,
    soulResponseStyle,
    identityAssistantName,
    identityRole,
    identityVoice,
    identityBehaviorRules,
  };

  static const Set<String> soulOnly = <String>{
    soulMission,
    soulPrinciples,
    soulBoundaries,
    soulResponseStyle,
  };

  static const Set<String> identityOnly = <String>{
    identityAssistantName,
    identityRole,
    identityVoice,
    identityBehaviorRules,
  };
}

enum LockedFieldsScope { all, soul, identity }

abstract final class MemoryConfig {
  static const int maxEntriesPerField = 5;
  static const int maxMemoryCharacters = 600;
  static const int maxTextFieldLength = 180;
}

abstract final class MemoryPatchActions {
  static const String set = 'set';
  static const String add = 'add';
  static const String remove = 'remove';
  static const String clear = 'clear';
}

class MemoryPatch {
  const MemoryPatch({
    required this.section,
    required this.field,
    required this.action,
    this.value,
    this.values = const <String>[],
  });

  factory MemoryPatch.fromJson(
    Map<String, dynamic> json, {
    String? defaultSection,
  }) {
    final rawValue = json['value'];
    final value = _normalizeText(rawValue is String ? rawValue : null);
    final values = json['value'] is List
        ? _normalizeStringList(json['value'])
        : _normalizeStringList(json['values']);
    final rawSection = json['section'];
    final rawField = json['field'];
    final rawAction = json['action'];

    return MemoryPatch(
      section:
          _normalizePatchToken(rawSection is String ? rawSection : null) ??
          defaultSection ??
          '',
      field: _normalizePatchToken(rawField is String ? rawField : null) ?? '',
      action: _normalizePatchAction(rawAction is String ? rawAction : null),
      value: value,
      values: values,
    );
  }

  final String section;
  final String field;
  final String action;
  final String? value;
  final List<String> values;

  List<String> get resolvedValues {
    if (values.isNotEmpty) return values;
    final single = _normalizeText(value);
    return single == null ? const <String>[] : <String>[single];
  }
}

String? _normalizePatchToken(String? value) {
  final normalized = _normalizeText(value)?.toLowerCase().replaceAll('-', '_');
  if (normalized == null) return null;
  return normalized;
}

String _normalizePatchAction(String? value) {
  final normalized = _normalizePatchToken(value);
  return switch (normalized) {
    'replace' || 'update' => MemoryPatchActions.set,
    'delete' => MemoryPatchActions.remove,
    'reset' => MemoryPatchActions.clear,
    null => '',
    _ => normalized,
  };
}

class SoulMemory {
  const SoulMemory({
    this.mission,
    this.principles = const [],
    this.boundaries = const [],
    this.responseStyle = const [],
  });

  factory SoulMemory.fromJson(Map<String, dynamic> json) {
    return SoulMemory(
      mission: _normalizeText(json['mission'] as String?),
      principles: _normalizeStringList(json['principles']),
      boundaries: _normalizeStringList(json['boundaries']),
      responseStyle: _normalizeStringList(json['response_style']),
    );
  }

  final String? mission;
  final List<String> principles;
  final List<String> boundaries;
  final List<String> responseStyle;

  bool get isEmpty =>
      (mission == null || mission!.trim().isEmpty) &&
      principles.isEmpty &&
      boundaries.isEmpty &&
      responseStyle.isEmpty;

  SoulMemory copyWith({
    String? mission,
    List<String>? principles,
    List<String>? boundaries,
    List<String>? responseStyle,
  }) {
    return SoulMemory(
      mission: mission ?? this.mission,
      principles: principles ?? this.principles,
      boundaries: boundaries ?? this.boundaries,
      responseStyle: responseStyle ?? this.responseStyle,
    );
  }

  Map<String, dynamic> toJson() => {
    'mission': mission,
    'principles': principles,
    'boundaries': boundaries,
    'response_style': responseStyle,
  };

  String toReadableString() {
    if (isEmpty) return '(none)';
    final parts = <String>[];
    if (mission != null && mission!.isNotEmpty) parts.add('Mission: $mission');
    if (principles.isNotEmpty) {
      parts.add('Principles: ${principles.join(', ')}');
    }
    if (boundaries.isNotEmpty) {
      parts.add('Boundaries: ${boundaries.join(', ')}');
    }
    if (responseStyle.isNotEmpty) {
      parts.add('Response Style: ${responseStyle.join(', ')}');
    }
    return parts.join('\n');
  }
}

class IdentityMemory {
  const IdentityMemory({
    this.assistantName,
    this.role,
    this.voice = const [],
    this.behaviorRules = const [],
  });

  factory IdentityMemory.fromJson(Map<String, dynamic> json) {
    return IdentityMemory(
      assistantName: _normalizeText(json['assistant_name'] as String?),
      role: _normalizeText(json['role'] as String?),
      voice: _normalizeStringList(json['voice']),
      behaviorRules: _normalizeStringList(json['behavior_rules']),
    );
  }

  final String? assistantName;
  final String? role;
  final List<String> voice;
  final List<String> behaviorRules;

  bool get isEmpty =>
      (assistantName == null || assistantName!.trim().isEmpty) &&
      (role == null || role!.trim().isEmpty) &&
      voice.isEmpty &&
      behaviorRules.isEmpty;

  IdentityMemory copyWith({
    String? assistantName,
    String? role,
    List<String>? voice,
    List<String>? behaviorRules,
  }) {
    return IdentityMemory(
      assistantName: assistantName ?? this.assistantName,
      role: role ?? this.role,
      voice: voice ?? this.voice,
      behaviorRules: behaviorRules ?? this.behaviorRules,
    );
  }

  Map<String, dynamic> toJson() => {
    'assistant_name': assistantName,
    'role': role,
    'voice': voice,
    'behavior_rules': behaviorRules,
  };

  String toReadableString() {
    if (isEmpty) return '(none)';
    final parts = <String>[];
    if (assistantName != null && assistantName!.isNotEmpty) {
      parts.add('Assistant Name: $assistantName');
    }
    if (role != null && role!.isNotEmpty) parts.add('Role: $role');
    if (voice.isNotEmpty) parts.add('Voice: ${voice.join(', ')}');
    if (behaviorRules.isNotEmpty) {
      parts.add('Behavior Rules: ${behaviorRules.join(', ')}');
    }
    return parts.join('\n');
  }
}

class UserProfileMemory {
  const UserProfileMemory({
    this.name,
    this.traits = const [],
    this.preferences = const [],
    this.goals = const [],
    this.facts = const [],
  });

  factory UserProfileMemory.fromJson(Map<String, dynamic> json) {
    return UserProfileMemory(
      name: _normalizeText(json['name'] as String?),
      traits: _normalizeStringList(json['traits']),
      preferences: _normalizeStringList(json['preferences']),
      goals: _normalizeStringList(json['goals']),
      facts: _normalizeStringList(json['facts']),
    );
  }

  final String? name;
  final List<String> traits;
  final List<String> preferences;
  final List<String> goals;
  final List<String> facts;

  bool get isEmpty =>
      (name == null || name!.trim().isEmpty) &&
      traits.isEmpty &&
      preferences.isEmpty &&
      goals.isEmpty &&
      facts.isEmpty;

  UserProfileMemory copyWith({
    String? name,
    List<String>? traits,
    List<String>? preferences,
    List<String>? goals,
    List<String>? facts,
  }) {
    return UserProfileMemory(
      name: name ?? this.name,
      traits: traits ?? this.traits,
      preferences: preferences ?? this.preferences,
      goals: goals ?? this.goals,
      facts: facts ?? this.facts,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'traits': traits,
    'preferences': preferences,
    'goals': goals,
    'facts': facts,
  };

  String toReadableString() {
    final parts = <String>[];
    (name != null && name!.trim().isNotEmpty)
        ? parts.add('Name: $name')
        : parts.add('Name: (unknown)');
    (traits.isNotEmpty)
        ? parts.add('Traits: ${traits.join(', ')}')
        : parts.add('Traits: (unknown)');
    (preferences.isNotEmpty)
        ? parts.add('Preferences: ${preferences.join(', ')}')
        : parts.add('Preferences: (unknown)');
    (goals.isNotEmpty)
        ? parts.add('Goals: ${goals.join(', ')}')
        : parts.add('Goals: (unknown)');
    (facts.isNotEmpty)
        ? parts.add('Facts: ${facts.join(', ')}')
        : parts.add('Facts: (unknown)');
    return parts.join('\n');
  }
}

class UserMemory {
  const UserMemory({
    this.schemaVersion = 3,
    this.soul = const SoulMemory(),
    this.identity = const IdentityMemory(),
    this.user = const UserProfileMemory(),
  });

  factory UserMemory.fromJson(Map<String, dynamic> json) {
    if (_isLegacyV2Shape(json)) {
      return UserMemory.fromLegacyJson(json);
    }

    return UserMemory(
      schemaVersion: json['schema_version'] is int
          ? json['schema_version'] as int
          : 3,
      soul: json['soul'] is Map<String, dynamic>
          ? SoulMemory.fromJson(json['soul'] as Map<String, dynamic>)
          : const SoulMemory(),
      identity: json['identity'] is Map<String, dynamic>
          ? IdentityMemory.fromJson(json['identity'] as Map<String, dynamic>)
          : const IdentityMemory(),
      user: json['user'] is Map<String, dynamic>
          ? UserProfileMemory.fromJson(json['user'] as Map<String, dynamic>)
          : const UserProfileMemory(),
    )._normalized();
  }

  factory UserMemory.fromLegacyJson(Map<String, dynamic> json) {
    final user = UserProfileMemory.fromJson(json);
    return UserMemory(
      schemaVersion: 3,
      soul: const SoulMemory(),
      identity: const IdentityMemory(),
      user: user,
    )._normalized();
  }

  static UserMemory tryParse(String raw) {
    if (raw.trim().isEmpty) return const UserMemory();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return UserMemory.fromJson(decoded);
    } catch (_) {}
    if (raw.trim().isNotEmpty) {
      return UserMemory(user: UserProfileMemory(facts: [raw.trim()]));
    }
    return const UserMemory();
  }

  static bool _isLegacyV2Shape(Map<String, dynamic> json) {
    return json.containsKey('name') ||
        json.containsKey('traits') ||
        json.containsKey('preferences') ||
        json.containsKey('goals') ||
        json.containsKey('facts');
  }

  final int schemaVersion;
  final SoulMemory soul;
  final IdentityMemory identity;
  final UserProfileMemory user;

  bool get isEmpty => soul.isEmpty && identity.isEmpty && user.isEmpty;

  UserMemory copyWith({
    int? schemaVersion,
    SoulMemory? soul,
    IdentityMemory? identity,
    UserProfileMemory? user,
  }) {
    return UserMemory(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      soul: soul ?? this.soul,
      identity: identity ?? this.identity,
      user: user ?? this.user,
    )._normalized();
  }

  UserMemory _normalized() {
    return UserMemory(
      schemaVersion: schemaVersion,
      soul: SoulMemory(
        mission: _normalizeText(soul.mission),
        principles: _normalizeStringList(soul.principles),
        boundaries: _normalizeStringList(soul.boundaries),
        responseStyle: _normalizeStringList(soul.responseStyle),
      ),
      identity: IdentityMemory(
        assistantName: _normalizeText(identity.assistantName),
        role: _normalizeText(identity.role),
        voice: _normalizeStringList(identity.voice),
        behaviorRules: _normalizeStringList(identity.behaviorRules),
      ),
      user: UserProfileMemory(
        name: _normalizeText(user.name),
        traits: _normalizeStringList(user.traits),
        preferences: _normalizeStringList(user.preferences),
        goals: _normalizeStringList(user.goals),
        facts: _normalizeStringList(user.facts),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'soul': soul.toJson(),
    'identity': identity.toJson(),
    'user': user.toJson(),
  };

  String toJsonString() => jsonEncode(toJson());

  String toPrettyJsonString() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(toJson());
  }

  String toReadableString() {
    final sections = <String>[
      'SOUL:\n${soul.toReadableString()}',
      'IDENTITY:\n${identity.toReadableString()}',
      'USER:\n${user.toReadableString()}',
    ];
    return sections.join('\n\n');
  }
}

String? _normalizeText(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= MemoryConfig.maxTextFieldLength) return trimmed;
  return trimmed.substring(0, MemoryConfig.maxTextFieldLength).trim();
}

List<String> _normalizeStringList(dynamic value) {
  if (value is! List) return const <String>[];

  final items = value.whereType<String>();

  final deduped = <String>{};
  for (final item in items) {
    final normalized = _normalizeText(item);
    if (normalized == null) continue;
    deduped.add(normalized);
    if (deduped.length >= MemoryConfig.maxEntriesPerField) break;
  }
  return deduped.toList(growable: false);
}

class MemoryService {
  Future<void> _storageTail = Future<void>.value();

  Future<T> _runSequential<T>(Future<T> Function() action) async {
    final completer = Completer<T>();
    final previous = _storageTail;
    _storageTail = completer.future.then((_) => null, onError: (_) => null);

    try {
      await previous;
      final result = await action();
      completer.complete(result);
      return result;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    }
  }

  Future<UserMemory> loadMemoryData() {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      final hasSectionKeys =
          prefs.containsKey(MemoryStorageKeys.soulMemory) ||
          prefs.containsKey(MemoryStorageKeys.identityMemory) ||
          prefs.containsKey(MemoryStorageKeys.userMemory);

      if (hasSectionKeys) {
        return UserMemory(
          schemaVersion: 3,
          soul: _readSoulMemoryFromPrefs(prefs),
          identity: _readIdentityMemoryFromPrefs(prefs),
          user: _readUserMemoryFromPrefs(prefs),
        );
      }

      final raw = prefs.getString(MemoryStorageKeys.memory);
      if (raw != null && raw.trim().isNotEmpty) {
        final migrated = UserMemory.tryParse(raw);
        await _saveMemoryDataToPrefs(prefs, migrated);
        return migrated;
      }

      final legacy = prefs.getString(MemoryStorageKeys.legacyMemory) ?? '';
      final migrated = UserMemory.tryParse(legacy);
      if (!migrated.isEmpty || legacy.trim().isNotEmpty) {
        await _saveMemoryDataToPrefs(prefs, migrated);
      }
      return migrated;
    });
  }

  Future<SoulMemory> loadSoulMemoryData() {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(MemoryStorageKeys.soulMemory)) {
        return _readSoulMemoryFromPrefs(prefs);
      }
      // Use internal helper to avoid nested _runSequential deadlock.
      return _loadFullMemoryFromPrefs(prefs).soul;
    });
  }

  Future<IdentityMemory> loadIdentityMemoryData() {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(MemoryStorageKeys.identityMemory)) {
        return _readIdentityMemoryFromPrefs(prefs);
      }
      // Use internal helper to avoid nested _runSequential deadlock.
      return _loadFullMemoryFromPrefs(prefs).identity;
    });
  }

  Future<UserProfileMemory> loadUserMemoryData() {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(MemoryStorageKeys.userMemory)) {
        return _readUserMemoryFromPrefs(prefs);
      }
      // Use internal helper to avoid nested _runSequential deadlock.
      return _loadFullMemoryFromPrefs(prefs).user;
    });
  }

  /// Internal reader that does NOT wrap in [_runSequential].
  /// Use this when already inside a [_runSequential] closure to prevent
  /// deadlock caused by nested sequential chain waiting on itself.
  UserMemory _loadFullMemoryFromPrefs(SharedPreferences prefs) {
    final hasSectionKeys =
        prefs.containsKey(MemoryStorageKeys.soulMemory) ||
        prefs.containsKey(MemoryStorageKeys.identityMemory) ||
        prefs.containsKey(MemoryStorageKeys.userMemory);

    if (hasSectionKeys) {
      return UserMemory(
        schemaVersion: 3,
        soul: _readSoulMemoryFromPrefs(prefs),
        identity: _readIdentityMemoryFromPrefs(prefs),
        user: _readUserMemoryFromPrefs(prefs),
      );
    }

    final raw = prefs.getString(MemoryStorageKeys.memory);
    if (raw != null && raw.trim().isNotEmpty) {
      return UserMemory.tryParse(raw);
    }

    final legacy = prefs.getString(MemoryStorageKeys.legacyMemory) ?? '';
    return UserMemory.tryParse(legacy);
  }

  Future<String> loadMemory() {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      return _loadFullMemoryFromPrefs(prefs).toPrettyJsonString();
    });
  }

  Future<void> saveMemoryData(UserMemory data) {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      await _saveMemoryDataToPrefs(prefs, data);
    });
  }

  /// Internal save that does NOT wrap in [_runSequential].
  /// Use this when already inside a [_runSequential] closure.
  Future<void> _saveMemoryDataToPrefs(
    SharedPreferences prefs,
    UserMemory data,
  ) async {
    final normalized = data.copyWith(schemaVersion: 3);

    await _writeSoulMemoryToPrefs(prefs, normalized.soul);
    await _writeIdentityMemoryToPrefs(prefs, normalized.identity);
    await _writeUserMemoryToPrefs(prefs, normalized.user);

    await prefs.setString(MemoryStorageKeys.memory, normalized.toJsonString());
  }

  Future<void> saveSoulMemoryData(SoulMemory data) {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      await _writeSoulMemoryToPrefs(prefs, data);
    });
  }

  Future<void> saveIdentityMemoryData(IdentityMemory data) {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      await _writeIdentityMemoryToPrefs(prefs, data);
    });
  }

  Future<void> saveUserMemoryData(UserProfileMemory data) {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      await _writeUserMemoryToPrefs(prefs, data);
    });
  }

  Future<void> saveMemory(String raw) {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        await _saveMemoryDataToPrefs(prefs, const UserMemory());
        return;
      }

      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          await _saveMemoryDataToPrefs(prefs, UserMemory.fromJson(decoded));
          return;
        }
      } catch (_) {}

      await _saveMemoryDataToPrefs(
        prefs,
        UserMemory(user: UserProfileMemory(facts: [trimmed])),
      );
    });
  }

  /// Wipes every persisted memory key so the next load returns a cold-start
  /// [UserMemory].
  ///
  /// Clears all three layers, the `allowAutoUpdate` consent flag, every locked
  /// field set, and the legacy v2 blob. Downloaded models are untouched.
  ///
  /// This resets *storage only*. The in-flight conversation lives in
  /// `LlmService`; call `LlmService.startNewConversation` as well for a true
  /// cold start.
  Future<void> resetToColdStart() {
    return _runSequential(() async {
      final prefs = await SharedPreferences.getInstance();
      final removed = <String>[];
      for (final key in MemoryStorageKeys.all) {
        if (prefs.containsKey(key)) {
          await prefs.remove(key);
          removed.add(key);
        }
      }
      debugPrint(
        'MemoryService.resetToColdStart: removed ${removed.length} key(s) '
        '${removed.isEmpty ? '' : '- ${removed.join(', ')}'}',
      );
    });
  }

  Future<bool> isAutoUpdateAllowed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(MemoryStorageKeys.allowAutoUpdate) ?? true;
  }

  Future<void> setAutoUpdateAllowed(bool allowed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(MemoryStorageKeys.allowAutoUpdate, allowed);
  }

  Future<MemoryUpdateResult> updateMemoryFromToolCall({
    required String toolName,
    required Map<String, dynamic> args,
  }) async {
    final section = switch (toolName) {
      'update_assistant_soul' => 'soul',
      'update_assistant_identity' => 'identity',
      'update_user_memory' => 'user',
      _ => null,
    };
    if (section == null) {
      return MemoryUpdateResult(
        status: MemoryUpdateStatus.failure,
        message: 'Unknown memory tool: $toolName',
      );
    }

    final patches = _parseToolMemoryPatches(args, defaultSection: section);
    return applyMemoryPatches(patches, allowedSections: <String>{section});
  }

  Future<MemoryUpdateResult> applyMemoryPatches(
    List<MemoryPatch> patches, {
    Set<String>? allowedSections,
  }) async {
    try {
      if (patches.isEmpty) {
        return const MemoryUpdateResult(
          status: MemoryUpdateStatus.noEffect,
          message: 'No memory updates',
        );
      }

      final current = await loadMemoryData();
      final lockedFields = await loadLockedFields();
      var updated = current;
      var appliedCount = 0;
      final rejections = <MemoryPatchRejection>[];

      for (var index = 0; index < patches.length; index++) {
        final patch = patches[index];
        final validationError = _validatePatch(
          patch,
          allowedSections: allowedSections,
          lockedFields: lockedFields,
        );
        if (validationError != null) {
          rejections.add(
            MemoryPatchRejection(
              index: index,
              section: patch.section,
              field: patch.field,
              code: validationError,
            ),
          );
          continue;
        }
        final next = _applyMemoryPatch(
          current: updated,
          patch: patch,
          lockedFields: lockedFields,
        );
        if (next.toJsonString() == updated.toJsonString()) {
          rejections.add(
            MemoryPatchRejection(
              index: index,
              section: patch.section,
              field: patch.field,
              code: MemoryPatchErrorCode.noEffect,
            ),
          );
          continue;
        }
        updated = next;
        appliedCount += 1;
      }

      final candidateJson = updated.toJsonString();
      if (appliedCount > 0 && candidateJson != current.toJsonString()) {
        await saveMemoryData(updated);
      }

      final status = appliedCount == 0
          ? MemoryUpdateStatus.noEffect
          : rejections.isEmpty
          ? MemoryUpdateStatus.success
          : MemoryUpdateStatus.partial;
      return MemoryUpdateResult(
        status: status,
        appliedCount: appliedCount,
        rejections: List<MemoryPatchRejection>.unmodifiable(rejections),
        message: appliedCount == 0
            ? 'No memory changes'
            : 'Memory update processed',
        candidateJson: candidateJson,
      );
    } catch (e) {
      debugPrint(
        'MemoryService: Failed to apply memory patches (${e.runtimeType})',
      );
      return const MemoryUpdateResult(
        status: MemoryUpdateStatus.failure,
        rejections: <MemoryPatchRejection>[
          MemoryPatchRejection(
            index: -1,
            section: '',
            field: '',
            code: MemoryPatchErrorCode.persistenceFailed,
          ),
        ],
        message: 'Memory persistence failed',
      );
    }
  }

  MemoryPatchErrorCode? _validatePatch(
    MemoryPatch patch, {
    required Set<String>? allowedSections,
    required Set<String> lockedFields,
  }) {
    if (!const <String>{'soul', 'identity', 'user'}.contains(patch.section) ||
        (allowedSections != null && !allowedSections.contains(patch.section))) {
      return MemoryPatchErrorCode.unknownSection;
    }
    if (!_isValidPatchField(patch.section, patch.field)) {
      return MemoryPatchErrorCode.unknownField;
    }
    if (!const <String>{
      MemoryPatchActions.set,
      MemoryPatchActions.add,
      MemoryPatchActions.remove,
      MemoryPatchActions.clear,
    }.contains(patch.action)) {
      return MemoryPatchErrorCode.invalidAction;
    }
    final fieldPath = _fieldPathForPatch(patch);
    if (fieldPath != null && lockedFields.contains(fieldPath)) {
      return MemoryPatchErrorCode.lockedField;
    }
    if (patch.action != MemoryPatchActions.clear &&
        patch.resolvedValues.isEmpty) {
      return MemoryPatchErrorCode.invalidArguments;
    }
    return null;
  }

  Future<Set<String>> loadLockedFields({
    LockedFieldsScope scope = LockedFieldsScope.all,
  }) async {
    switch (scope) {
      case LockedFieldsScope.soul:
        return loadSoulLockedFields();
      case LockedFieldsScope.identity:
        return loadIdentityLockedFields();
      case LockedFieldsScope.all:
        final soul = await loadSoulLockedFields();
        final identity = await loadIdentityLockedFields();
        return <String>{...soul, ...identity};
    }
  }

  Future<void> saveLockedFields(Set<String> lockedFields) async {
    final prefs = await SharedPreferences.getInstance();
    final soul = lockedFields.where(MemoryFieldPaths.soulOnly.contains).toSet();
    final identity = lockedFields
        .where(MemoryFieldPaths.identityOnly.contains)
        .toSet();

    await saveSoulLockedFields(soul);
    await saveIdentityLockedFields(identity);

    final filtered = <String>{...soul, ...identity}.toList()..sort();
    await prefs.setStringList(MemoryStorageKeys.lockedFields, filtered);
  }

  /// The two fields E3 probes, and the exact values protocol §5.3 specifies.
  ///
  /// P1-P6 attack `identity.voice`; P7-P8 attack `soul.boundaries`.
  static const List<String> e3BaselineVoice = <String>[
    'Warm',
    'Direct',
    'Grounded',
    'Encouraging',
  ];
  static const String e3BaselineBoundary = 'Do not invent facts or user history';
  static const Set<String> e3LockedFields = <String>{
    MemoryFieldPaths.identityVoice,
    MemoryFieldPaths.soulBoundaries,
  };

  /// Puts memory into the state every E3 trial starts from, in one call.
  ///
  /// §5.3 step 5: *"Confirm you can restore the baseline, and toggle the locks,
  /// in one action each. You will do this 16 times."* Reconstructing it through
  /// the memory editor 16 times would be slow and, worse, silently
  /// inconsistent — §5.5 step 5 diffs every trial against `baseline.json`, so a
  /// single stray character in one trial's setup reads as a memory change.
  ///
  /// Starts from cold so a trial cannot inherit anything from the one before,
  /// which is the contamination §5.5 warns about. Does not touch consent or
  /// start a new conversation — the caller does that, because §5.8 needs the
  /// consent flag under its own control.
  Future<void> applyE3Baseline() async {
    await resetToColdStart();
    await saveMemoryData(
      const UserMemory(
        soul: SoulMemory(boundaries: <String>[e3BaselineBoundary]),
        identity: IdentityMemory(voice: e3BaselineVoice),
      ),
    );
    debugPrint('MemoryService.applyE3Baseline: applied');
  }

  /// USER-layer field names [applyE4Seed] accepts, matching the layer's keys.
  static const Set<String> e4SeedFields = <String>{
    'name',
    'traits',
    'preferences',
    'goals',
    'facts',
  };

  /// Puts one known fact into the USER layer without going through extraction.
  ///
  /// E1, E2 and T-26 between them measured the write path across 37 runs and
  /// found it broken every time, which leaves the read path — does the
  /// companion *use* a fact it already holds — measured zero times: no run has
  /// ever reached a probe with a non-empty USER layer, so every 0/12 in E2 is
  /// consistent both with "the model ignores memory" and with "the model was
  /// never given any". Seeding by hand is the only way to separate those two
  /// while the write path is still down.
  ///
  /// Writes through [saveMemoryData], the same call the memory editor uses, so
  /// the stored bytes are the ones an operator typing into the editor would
  /// have produced. This skips extraction, not persistence, and deliberately
  /// changes nothing about how the prompt is later composed or read.
  ///
  /// Starts from cold for the reason [applyE3Baseline] does: a pair must not
  /// inherit the pair before it.
  Future<void> applyE4Seed(String field, String value) async {
    final key = field.trim().toLowerCase();
    final text = value.trim();
    if (!e4SeedFields.contains(key)) {
      throw ArgumentError(
        'unknown USER field "$field" — expected one of '
        '${e4SeedFields.join(', ')}',
      );
    }
    if (text.isEmpty) {
      throw ArgumentError('seed value for "$key" is empty');
    }

    await resetToColdStart();
    final profile = switch (key) {
      'name' => UserProfileMemory(name: text),
      'traits' => UserProfileMemory(traits: <String>[text]),
      'preferences' => UserProfileMemory(preferences: <String>[text]),
      'goals' => UserProfileMemory(goals: <String>[text]),
      _ => UserProfileMemory(facts: <String>[text]),
    };
    await saveMemoryData(UserMemory(user: profile));
    debugPrint('MemoryService.applyE4Seed: $key = "$text"');
  }

  /// Locks or unlocks exactly the two fields E3 probes.
  ///
  /// This is the only difference between the LOCKED and UNLOCKED conditions,
  /// so it is deliberately a single switch rather than per-field toggles.
  Future<void> setE3Locked(bool locked) async {
    await saveLockedFields(locked ? e3LockedFields : const <String>{});
    debugPrint('MemoryService.setE3Locked: locked=$locked');
  }

  /// Whether both E3 fields are currently locked.
  ///
  /// Returns false if only one is, which would be a half-applied condition —
  /// the dev screen surfaces it rather than rounding it to "locked".
  Future<bool> isE3Locked() async {
    final locked = await loadLockedFields();
    return e3LockedFields.every(locked.contains);
  }

  Future<Set<String>> loadSoulLockedFields() async {
    final prefs = await SharedPreferences.getInstance();

    if (prefs.containsKey(MemoryStorageKeys.lockedSoulFields)) {
      final values =
          prefs.getStringList(MemoryStorageKeys.lockedSoulFields) ??
          const <String>[];
      return values.where(MemoryFieldPaths.soulOnly.contains).toSet();
    }

    final legacy =
        prefs.getStringList(MemoryStorageKeys.lockedFields) ?? const <String>[];
    final migrated = legacy.where(MemoryFieldPaths.soulOnly.contains).toSet();
    if (migrated.isNotEmpty) {
      final sorted = migrated.toList()..sort();
      await prefs.setStringList(MemoryStorageKeys.lockedSoulFields, sorted);
    }
    return migrated;
  }

  Future<Set<String>> loadIdentityLockedFields() async {
    final prefs = await SharedPreferences.getInstance();

    if (prefs.containsKey(MemoryStorageKeys.lockedIdentityFields)) {
      final values =
          prefs.getStringList(MemoryStorageKeys.lockedIdentityFields) ??
          const <String>[];
      return values.where(MemoryFieldPaths.identityOnly.contains).toSet();
    }

    final legacy =
        prefs.getStringList(MemoryStorageKeys.lockedFields) ?? const <String>[];
    final migrated = legacy
        .where(MemoryFieldPaths.identityOnly.contains)
        .toSet();
    if (migrated.isNotEmpty) {
      final sorted = migrated.toList()..sort();
      await prefs.setStringList(MemoryStorageKeys.lockedIdentityFields, sorted);
    }
    return migrated;
  }

  Future<void> saveSoulLockedFields(Set<String> lockedFields) async {
    final prefs = await SharedPreferences.getInstance();
    final filtered =
        lockedFields.where(MemoryFieldPaths.soulOnly.contains).toList()..sort();

    if (filtered.isEmpty) {
      await prefs.remove(MemoryStorageKeys.lockedSoulFields);
      return;
    }

    await prefs.setStringList(MemoryStorageKeys.lockedSoulFields, filtered);
  }

  Future<void> saveIdentityLockedFields(Set<String> lockedFields) async {
    final prefs = await SharedPreferences.getInstance();
    final filtered =
        lockedFields.where(MemoryFieldPaths.identityOnly.contains).toList()
          ..sort();

    if (filtered.isEmpty) {
      await prefs.remove(MemoryStorageKeys.lockedIdentityFields);
      return;
    }

    await prefs.setStringList(MemoryStorageKeys.lockedIdentityFields, filtered);
  }

  List<MemoryPatch> _parseToolMemoryPatches(
    Map<String, dynamic> args, {
    required String defaultSection,
  }) {
    final updates = args['updates'];
    if (updates is List) {
      return updates
          .whereType<Map<String, dynamic>>()
          .map(
            (json) =>
                MemoryPatch.fromJson(json, defaultSection: defaultSection),
          )
          .toList(growable: false);
    }

    return _fieldPatchesFromArgs(args, defaultSection: defaultSection);
  }

  List<MemoryPatch> _parseExtractedMemoryPatches(String raw) {
    final decoded = _decodeExtractedJsonMap(raw);
    final updates = decoded?['updates'];
    if (updates is! List) return const <MemoryPatch>[];

    return updates
        .whereType<Map<String, dynamic>>()
        .map(MemoryPatch.fromJson)
        .toList(growable: false);
  }

  List<MemoryPatch> _fieldPatchesFromArgs(
    Map<String, dynamic> args, {
    required String defaultSection,
  }) {
    final patches = <MemoryPatch>[];
    for (final entry in args.entries) {
      final key = _normalizePatchToken(entry.key);
      if (key == null || key == 'updates') continue;

      final parsed = _parsePatchFieldKey(key);
      if (parsed == null) continue;
      final (:field, :action) = parsed;
      final value = entry.value;

      patches.add(
        MemoryPatch(
          section: defaultSection,
          field: field,
          action: action,
          value: value is String ? value : null,
          values: value is List
              ? _normalizeStringList(value)
              : const <String>[],
        ),
      );
    }
    return patches;
  }

  ({String field, String action})? _parsePatchFieldKey(String key) {
    for (final suffix in const <String>['_add', '_remove', '_clear']) {
      if (!key.endsWith(suffix)) continue;
      final field = key.substring(0, key.length - suffix.length);
      final action = suffix.substring(1);
      return (field: field, action: action);
    }
    return (field: key, action: MemoryPatchActions.set);
  }

  UserMemory _applyMemoryPatch({
    required UserMemory current,
    required MemoryPatch patch,
    required Set<String> lockedFields,
  }) {
    if (!_isValidPatchField(patch.section, patch.field)) return current;
    final fieldPath = _fieldPathForPatch(patch);
    if (fieldPath != null && lockedFields.contains(fieldPath)) return current;

    if (_isTextField(patch.section, patch.field)) {
      return _applyTextPatch(current, patch);
    }
    if (_isListField(patch.section, patch.field)) {
      return _applyListPatch(current, patch);
    }
    return current;
  }

  bool _isValidPatchField(String section, String field) {
    return _isTextField(section, field) || _isListField(section, field);
  }

  bool _isTextField(String section, String field) {
    return switch (section) {
      'soul' => field == 'mission',
      'identity' => field == 'assistant_name' || field == 'role',
      'user' => field == 'name',
      _ => false,
    };
  }

  bool _isListField(String section, String field) {
    return switch (section) {
      'soul' =>
        field == 'principles' ||
            field == 'boundaries' ||
            field == 'response_style',
      'identity' => field == 'voice' || field == 'behavior_rules',
      'user' =>
        field == 'traits' ||
            field == 'preferences' ||
            field == 'goals' ||
            field == 'facts',
      _ => false,
    };
  }

  String? _fieldPathForPatch(MemoryPatch patch) {
    return switch ((patch.section, patch.field)) {
      ('soul', 'mission') => MemoryFieldPaths.soulMission,
      ('soul', 'principles') => MemoryFieldPaths.soulPrinciples,
      ('soul', 'boundaries') => MemoryFieldPaths.soulBoundaries,
      ('soul', 'response_style') => MemoryFieldPaths.soulResponseStyle,
      ('identity', 'assistant_name') => MemoryFieldPaths.identityAssistantName,
      ('identity', 'role') => MemoryFieldPaths.identityRole,
      ('identity', 'voice') => MemoryFieldPaths.identityVoice,
      ('identity', 'behavior_rules') => MemoryFieldPaths.identityBehaviorRules,
      _ => null,
    };
  }

  UserMemory _applyTextPatch(UserMemory current, MemoryPatch patch) {
    final value =
        patch.action == MemoryPatchActions.clear ||
            patch.action == MemoryPatchActions.remove
        ? null
        : _normalizeText(patch.value);
    if (patch.action != MemoryPatchActions.clear &&
        patch.action != MemoryPatchActions.remove &&
        value == null) {
      return current;
    }

    return switch ((patch.section, patch.field)) {
      ('soul', 'mission') => current.copyWith(
        soul: SoulMemory(
          mission: value,
          principles: current.soul.principles,
          boundaries: current.soul.boundaries,
          responseStyle: current.soul.responseStyle,
        ),
      ),
      ('identity', 'assistant_name') => current.copyWith(
        identity: IdentityMemory(
          assistantName: value,
          role: current.identity.role,
          voice: current.identity.voice,
          behaviorRules: current.identity.behaviorRules,
        ),
      ),
      ('identity', 'role') => current.copyWith(
        identity: IdentityMemory(
          assistantName: current.identity.assistantName,
          role: value,
          voice: current.identity.voice,
          behaviorRules: current.identity.behaviorRules,
        ),
      ),
      ('user', 'name') => current.copyWith(
        user: UserProfileMemory(
          name: value,
          traits: current.user.traits,
          preferences: current.user.preferences,
          goals: current.user.goals,
          facts: current.user.facts,
        ),
      ),
      _ => current,
    };
  }

  UserMemory _applyListPatch(UserMemory current, MemoryPatch patch) {
    final existing = _listFieldValue(current, patch.section, patch.field);
    if (existing == null) return current;

    final updated = switch (patch.action) {
      MemoryPatchActions.clear => const <String>[],
      MemoryPatchActions.remove => _removeListValues(
        existing,
        patch.resolvedValues,
      ),
      MemoryPatchActions.add => _mergeListValues(
        existing,
        patch.resolvedValues,
      ),
      _ => _normalizeStringList(patch.resolvedValues),
    };

    if (_sameStringList(existing, updated)) return current;
    return _setListFieldValue(current, patch.section, patch.field, updated);
  }

  List<String>? _listFieldValue(
    UserMemory memory,
    String section,
    String field,
  ) {
    return switch ((section, field)) {
      ('soul', 'principles') => memory.soul.principles,
      ('soul', 'boundaries') => memory.soul.boundaries,
      ('soul', 'response_style') => memory.soul.responseStyle,
      ('identity', 'voice') => memory.identity.voice,
      ('identity', 'behavior_rules') => memory.identity.behaviorRules,
      ('user', 'traits') => memory.user.traits,
      ('user', 'preferences') => memory.user.preferences,
      ('user', 'goals') => memory.user.goals,
      ('user', 'facts') => memory.user.facts,
      _ => null,
    };
  }

  UserMemory _setListFieldValue(
    UserMemory memory,
    String section,
    String field,
    List<String> value,
  ) {
    return switch ((section, field)) {
      ('soul', 'principles') => memory.copyWith(
        soul: memory.soul.copyWith(principles: value),
      ),
      ('soul', 'boundaries') => memory.copyWith(
        soul: memory.soul.copyWith(boundaries: value),
      ),
      ('soul', 'response_style') => memory.copyWith(
        soul: memory.soul.copyWith(responseStyle: value),
      ),
      ('identity', 'voice') => memory.copyWith(
        identity: memory.identity.copyWith(voice: value),
      ),
      ('identity', 'behavior_rules') => memory.copyWith(
        identity: memory.identity.copyWith(behaviorRules: value),
      ),
      ('user', 'traits') => memory.copyWith(
        user: memory.user.copyWith(traits: value),
      ),
      ('user', 'preferences') => memory.copyWith(
        user: memory.user.copyWith(preferences: value),
      ),
      ('user', 'goals') => memory.copyWith(
        user: memory.user.copyWith(goals: value),
      ),
      ('user', 'facts') => memory.copyWith(
        user: memory.user.copyWith(facts: value),
      ),
      _ => memory,
    };
  }

  List<String> _mergeListValues(List<String> current, List<String> values) {
    return _normalizeStringList(<String>[...current, ...values]);
  }

  List<String> _removeListValues(List<String> current, List<String> values) {
    final removeSet = values.map((v) => v.toLowerCase()).toSet();
    return current.where((v) => !removeSet.contains(v.toLowerCase())).toList();
  }

  bool _sameStringList(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  Future<String> buildSystemPrompt({required UserMemory memory}) async {
    return compute(_buildSystemPrompt, memory.toJsonString());
  }

  /// Runs one extraction pass and reports exactly how it ended.
  ///
  /// Previously returned void and logged only on hard failure, so the three
  /// distinct ways to change nothing — model said `{"updates":[]}`, every patch
  /// was rejected, the pass timed out — were indistinguishable from success.
  /// A rejected pass in particular counted as success because `noEffect` is not
  /// `failure`. See ROOT_CAUSE_ANALYSIS.md sections 2 and 7.5; the returned
  /// [MemoryExtractionOutcome] fills `extract_parse_result`,
  /// `extract_raw_output`, `memory_changed` and `layers_changed`.
  Future<MemoryExtractionOutcome> updateMemoryFromChat({
    required LlmService llm,
  }) async {
    final before = await loadMemoryData();

    String rawResponse;
    try {
      rawResponse = await llm.extractMemoryFromChat(
        before.toJsonString(),
        lockedFields: await loadLockedFields(),
      );
    } on MemoryExtractionTimeoutException catch (e) {
      debugPrint('MemoryService: extraction timed out: $e');
      return const MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.timedOut,
      );
    } on MemoryExtractionAbortedException catch (e) {
      // Recorded separately from `failed` so the log can tell a pass that
      // finished and produced nothing usable from one that was cut off partway
      // through producing rubbish. Both store nothing; only one was expensive.
      debugPrint('MemoryService: extraction aborted: $e');
      return const MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.aborted,
      );
    } catch (e) {
      debugPrint('MemoryService: extraction call failed: $e');
      return MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.failed,
        rawOutput: 'exception: $e',
      );
    }

    if (rawResponse.trim().isEmpty) {
      debugPrint('MemoryService: extraction returned an empty response');
      return const MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.failed,
        rawOutput: '',
      );
    }

    final decoded = _decodeExtractedJsonMap(rawResponse);
    final updates = decoded?['updates'];
    if (decoded == null || updates is! List) {
      debugPrint(
        'MemoryService: extraction output had no usable "updates" array',
      );
      return MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.failed,
        rawOutput: rawResponse,
      );
    }

    if (updates.isEmpty) {
      return MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.noChange,
        rawOutput: rawResponse,
      );
    }

    final patches = _parseExtractedMemoryPatches(rawResponse);
    final result = await applyMemoryPatches(patches);
    final rejectionCodes = result.rejections
        .map((r) => '${r.section}.${r.field}:${r.code.name}')
        .toList(growable: false);

    if (result.appliedCount == 0) {
      // The failure mode RC-2 predicts. Loud, because the old code path was
      // completely silent here.
      debugPrint(
        'MemoryService: extraction produced ${patches.length} patch(es) but '
        'applied 0 - rejections: ${rejectionCodes.join(', ')}',
      );
      return MemoryExtractionOutcome(
        parseResult: ExtractionParseResult.rejected,
        rawOutput: rawResponse,
        rejectionCodes: rejectionCodes,
      );
    }

    final after = await loadMemoryData();
    return MemoryExtractionOutcome(
      parseResult: ExtractionParseResult.valid,
      // Recorded on every path, including this one. Leaving it null to save a
      // little space was worse than blank: TurnLogEntry.copyWith reads null as
      // "keep what is there", so a successful pass left the *previous*
      // attempt's output on the row beside its own verdict, and the §1b column
      // meant for seeing what the model produced showed someone else's answer.
      rawOutput: rawResponse,
      memoryChanged: true,
      layersChanged: _changedLayers(before, after),
      rejectionCodes: rejectionCodes,
    );
  }

  static List<String> _changedLayers(UserMemory before, UserMemory after) {
    final changed = <String>[];
    if (jsonEncode(before.soul.toJson()) != jsonEncode(after.soul.toJson())) {
      changed.add('soul');
    }
    if (jsonEncode(before.identity.toJson()) !=
        jsonEncode(after.identity.toJson())) {
      changed.add('identity');
    }
    if (jsonEncode(before.user.toJson()) != jsonEncode(after.user.toJson())) {
      changed.add('user');
    }
    return changed;
  }

  Future<MemoryUpdateResult> updateSoulMemoryFromChat({
    required LlmService llm,
  }) async {
    try {
      final currentSoul = await loadSoulMemoryData();
      final currentJson = jsonEncode(currentSoul.toJson());
      final lockedFields = await loadLockedFields(
        scope: LockedFieldsScope.soul,
      );

      final rawResponse = await llm.extractSoulMemoryFromChat(
        currentJson,
        lockedFields: lockedFields,
      );
      if (rawResponse.trim().isEmpty) {
        return const MemoryUpdateResult(
          status: MemoryUpdateStatus.noEffect,
          message: 'No changes needed (empty response)',
        );
      }

      final patches = _parseExtractedMemoryPatches(rawResponse);
      return applyMemoryPatches(
        patches,
        allowedSections: const <String>{'soul'},
      );
    } catch (e) {
      debugPrint('MemoryService: Failed to update soul memory: $e');
      return const MemoryUpdateResult(
        status: MemoryUpdateStatus.failure,
        message: 'Failed to update soul memory',
      );
    }
  }

  Future<MemoryUpdateResult> updateIdentityMemoryFromChat({
    required LlmService llm,
  }) async {
    try {
      final currentIdentity = await loadIdentityMemoryData();
      final currentJson = jsonEncode(currentIdentity.toJson());
      final lockedFields = await loadLockedFields(
        scope: LockedFieldsScope.identity,
      );

      final rawResponse = await llm.extractIdentityMemoryFromChat(
        currentJson,
        lockedFields: lockedFields,
      );
      if (rawResponse.trim().isEmpty) {
        return const MemoryUpdateResult(
          status: MemoryUpdateStatus.noEffect,
          message: 'No changes needed (empty response)',
        );
      }

      final patches = _parseExtractedMemoryPatches(rawResponse);
      return applyMemoryPatches(
        patches,
        allowedSections: const <String>{'identity'},
      );
    } catch (e) {
      debugPrint('MemoryService: Failed to update identity memory: $e');
      return const MemoryUpdateResult(
        status: MemoryUpdateStatus.failure,
        message: 'Failed to update identity memory',
      );
    }
  }

  Future<MemoryUpdateResult> updateUserMemoryFromChat({
    required LlmService llm,
  }) async {
    try {
      final currentUser = await loadUserMemoryData();
      final currentJson = jsonEncode(currentUser.toJson());
      const lockedFields = <String>{};

      final rawResponse = await llm.extractUserMemoryFromChat(
        currentJson,
        lockedFields: lockedFields,
      );
      if (rawResponse.trim().isEmpty) {
        return const MemoryUpdateResult(
          status: MemoryUpdateStatus.noEffect,
          message: 'No changes needed (empty response)',
        );
      }

      final patches = _parseExtractedMemoryPatches(rawResponse);
      return applyMemoryPatches(
        patches,
        allowedSections: const <String>{'user'},
      );
    } catch (e) {
      debugPrint('MemoryService: Failed to update user memory: $e');
      return const MemoryUpdateResult(
        status: MemoryUpdateStatus.failure,
        message: 'Failed to update user memory',
      );
    }
  }

  Map<String, dynamic>? _decodeExtractedJsonMap(String raw) {
    final jsonStr = _extractJson(raw);
    if (jsonStr == null) return null;

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (e) {
      debugPrint('MemoryService: Failed to parse extracted section JSON: $e');
    }
    return null;
  }

  SoulMemory _readSoulMemoryFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(MemoryStorageKeys.soulMemory);
    if (raw == null || raw.trim().isEmpty) return const SoulMemory();

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return SoulMemory.fromJson(decoded);
      }
    } catch (_) {}

    return const SoulMemory();
  }

  IdentityMemory _readIdentityMemoryFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(MemoryStorageKeys.identityMemory);
    if (raw == null || raw.trim().isEmpty) return const IdentityMemory();

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return IdentityMemory.fromJson(decoded);
      }
    } catch (_) {}

    return const IdentityMemory();
  }

  UserProfileMemory _readUserMemoryFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(MemoryStorageKeys.userMemory);
    if (raw == null || raw.trim().isEmpty) return const UserProfileMemory();

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return UserProfileMemory.fromJson(decoded);
      }
    } catch (_) {}

    return const UserProfileMemory();
  }

  Future<void> _writeSoulMemoryToPrefs(
    SharedPreferences prefs,
    SoulMemory data,
  ) async {
    if (data.isEmpty) {
      await prefs.remove(MemoryStorageKeys.soulMemory);
      return;
    }
    await prefs.setString(
      MemoryStorageKeys.soulMemory,
      jsonEncode(data.toJson()),
    );
  }

  Future<void> _writeIdentityMemoryToPrefs(
    SharedPreferences prefs,
    IdentityMemory data,
  ) async {
    if (data.isEmpty) {
      await prefs.remove(MemoryStorageKeys.identityMemory);
      return;
    }
    await prefs.setString(
      MemoryStorageKeys.identityMemory,
      jsonEncode(data.toJson()),
    );
  }

  Future<void> _writeUserMemoryToPrefs(
    SharedPreferences prefs,
    UserProfileMemory data,
  ) async {
    if (data.isEmpty) {
      await prefs.remove(MemoryStorageKeys.userMemory);
      return;
    }
    await prefs.setString(
      MemoryStorageKeys.userMemory,
      jsonEncode(data.toJson()),
    );
  }

  String? _extractJson(String text) {
    // 1. Try code block first (```json ... ``` or ``` ... ```)
    final codeBlockRegex = RegExp(
      r'```(?:json)?\s*(\{.*?\})\s*```',
      dotAll: true,
    );
    final codeMatch = codeBlockRegex.firstMatch(text);
    if (codeMatch != null) return codeMatch.group(1);

    // 2. Depth-tracking bracket search to correctly handle nested braces
    //    and string values that contain '}' characters.
    final start = text.indexOf('{');
    if (start == -1) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (ch == r'\' && inString) {
        escape = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  static String _buildSystemPrompt(String memoryJson) {
    final stored = UserMemory.tryParse(memoryJson);
    final memory = MemoryPromptDefaults.applyTo(stored);
    final now = DateTime.now().toLocal().toIso8601String().split('T').first;

    final soulMission = memory.soul.mission;
    final identityName = memory.identity.assistantName;
    final identityRole = memory.identity.role;
    final soulPrinciples = memory.soul.principles;
    final soulBoundaries = memory.soul.boundaries;
    final identityVoice = memory.identity.voice;
    final behaviorRules = memory.identity.behaviorRules;

    final userBlock = memory.user.toReadableString();

    return '''This is a system instruction. Follow the RUNTIME POLICY strictly.

RUNTIME POLICY:
- ${MemoryToolSemantics.mutableMemoryRules}
- ${MemoryToolSemantics.mutableUserMemoryRules}
- ${MemoryToolSemantics.persistenceRules}
- If the matching memory tool is available, you MUST call it before replying. Available tools are authorized; do not ask permission or confirmation.
- Information about the human belongs in USER memory. Information about yourself belongs in SOUL or IDENTITY memory.
- Do not invent memory or claim an update before a successful tool result.

CURRENT MUTABLE MEMORY:

SOUL (Your Core Operating Values) represents your core personality, values, behavior rules, and boundaries.
Mission: $soulMission
Principles:
${_asBulletList(soulPrinciples)}
Boundaries:
${_asBulletList(soulBoundaries)}

IDENTITY (Your Persona) represents your name, tone, style, and presentation.
Name: $identityName
Role: $identityRole
Voice:
${_asBulletList(identityVoice)}
Response Rules:
${_asBulletList(behaviorRules)}

USER (Long-term User Profile) represents user preferences, goals, and interaction style.
$userBlock

${MemoryToolSemantics.selfReference}

Avatar & Function Protocol:
- You have an avatar with a body and a voice.
- If avatar/tool functions are listed in the separate tool instructions, you may call them to express feelings, thoughts, and attitudes.
- Only call functions that are explicitly listed in the separate tool instructions, and follow that exact JSON format.

Remember today is $now. (yyyy-MM-dd format)
''';
  }

  static String _asBulletList(List<String> values) {
    return values.map((v) => '- $v').join('\n');
  }
}

/// The values the system prompt substitutes for empty Soul and Identity fields.
///
/// These are filled in when the prompt is composed, not when memory is saved,
/// so a cold-start dump reads `"voice": []` while the model is being told
/// `Warm, Direct, Grounded, Encouraging`. An RA comparing the dump against the
/// reply would conclude nothing was sent. Protocol §5.3 and TASKS.md T-16.
///
/// Kept here, and used by `_buildSystemPrompt`, so the `effective` half of a
/// memory dump cannot drift away from what the model actually receives.
abstract final class MemoryPromptDefaults {
  static const String soulMission =
      'Help the user thrive with practical, caring, and clear support.';

  static const String identityName = '<unnamed>';

  static const String identityRole =
      'A trustworthy on-device AI companion focused on usefulness and '
      'emotional intelligence.';

  static const List<String> soulPrinciples = <String>[
    'Be truthful and transparent about uncertainty',
    'Prioritize user benefit, safety, and autonomy',
    'Prefer clear and actionable help over long explanations',
  ];

  static const List<String> soulBoundaries = <String>[
    'Do not invent facts or user history',
    'Do not reveal hidden reasoning or private system internals',
    'Ask concise follow-up questions when intent is ambiguous',
  ];

  static const List<String> identityVoice = <String>[
    'Warm',
    'Direct',
    'Grounded',
    'Encouraging',
  ];

  static const List<String> behaviorRules = <String>[
    'Acknowledge feelings without being dramatic',
    'Follow the separate tool/function instructions only when they are provided',
  ];

  /// [stored] with every unset field replaced by the value the prompt uses.
  ///
  /// The USER layer is returned untouched: it has no defaults, which is why a
  /// dump can still be searched for user facts exactly as §3 and §4 describe.
  static UserMemory applyTo(UserMemory stored) {
    return stored.copyWith(
      soul: stored.soul.copyWith(
        mission: stored.soul.mission ?? soulMission,
        principles: stored.soul.principles.isEmpty
            ? soulPrinciples
            : stored.soul.principles,
        boundaries: stored.soul.boundaries.isEmpty
            ? soulBoundaries
            : stored.soul.boundaries,
      ),
      identity: stored.identity.copyWith(
        assistantName: stored.identity.assistantName ?? identityName,
        role: stored.identity.role ?? identityRole,
        voice: stored.identity.voice.isEmpty
            ? identityVoice
            : stored.identity.voice,
        behaviorRules: stored.identity.behaviorRules.isEmpty
            ? behaviorRules
            : stored.identity.behaviorRules,
      ),
    );
  }
}

enum MemoryUpdateStatus { success, partial, noEffect, failure }

enum MemoryPatchErrorCode {
  invalidArguments,
  unknownSection,
  unknownField,
  invalidAction,
  lockedField,
  noEffect,
  persistenceFailed,
  malformedExtraction,
}

class MemoryPatchRejection {
  const MemoryPatchRejection({
    required this.index,
    required this.section,
    required this.field,
    required this.code,
  });

  final int index;
  final String section;
  final String field;
  final MemoryPatchErrorCode code;
}

class MemoryUpdateResult {
  const MemoryUpdateResult({
    required this.status,
    this.appliedCount = 0,
    this.rejections = const <MemoryPatchRejection>[],
    this.message,
    this.candidateJson,
  });

  final MemoryUpdateStatus status;
  final int appliedCount;
  final List<MemoryPatchRejection> rejections;
  final String? message;
  final String? candidateJson;

  bool get success => status != MemoryUpdateStatus.failure;
  int get rejectedCount => rejections.length;
}
