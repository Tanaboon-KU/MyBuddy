import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../google/calendar_event_gateway.dart';
import '../memory/memory_service.dart';
import '../unity/unity_bridge.dart';
import 'animation_types.dart';
import 'calendar_event_tool.dart';
import 'memory_tool_semantics.dart';
import 'tool_protocol.dart';

typedef ToolAvailability = FutureOr<bool> Function();
typedef ToolExecutor =
    Future<Map<String, Object?>> Function(Map<String, dynamic> arguments);

final class ToolBinding {
  ToolBinding({
    required this.definition,
    required this.execute,
    ToolAvailability? isAvailable,
    this.timeout = const Duration(seconds: 30),
  }) : isAvailable = isAvailable ?? _alwaysAvailable;

  final Tool definition;
  final ToolAvailability isAvailable;
  final ToolExecutor execute;
  final Duration timeout;

  Future<ToolExecutionResult> invoke(ToolInvocation invocation) async {
    try {
      final arguments = _SchemaValidator.validate(
        definition.parameters,
        invocation.arguments,
      );
      final data = await execute(arguments).timeout(timeout);
      return ToolExecutionResult.success(
        id: invocation.id,
        name: invocation.name,
        data: data,
      );
    } on ToolArgumentException catch (error) {
      return ToolExecutionResult.failure(
        id: invocation.id,
        name: invocation.name,
        code: ToolResultErrorCode.invalidArguments,
        message: error.message,
        retryable: true,
      );
    } on TimeoutException {
      return ToolExecutionResult.failure(
        id: invocation.id,
        name: invocation.name,
        code: ToolResultErrorCode.timedOut,
        message: 'Tool execution timed out.',
        retryable: true,
      );
    } on ToolExecutionException catch (error) {
      return ToolExecutionResult.failure(
        id: invocation.id,
        name: invocation.name,
        code: ToolResultErrorCode.executionFailed,
        message: error.message,
        retryable: error.retryable,
      );
    } catch (_) {
      return ToolExecutionResult.failure(
        id: invocation.id,
        name: invocation.name,
        code: ToolResultErrorCode.executionFailed,
        message: 'Tool execution failed.',
      );
    }
  }

  static bool _alwaysAvailable() => true;
}

final class ToolRegistrySnapshot {
  ToolRegistrySnapshot({
    required List<Tool> definitions,
    required Map<String, ToolBinding> bindings,
    required Set<String> availableNames,
  }) : definitions = List<Tool>.unmodifiable(definitions),
       bindings = Map<String, ToolBinding>.unmodifiable(bindings),
       availableNames = Set<String>.unmodifiable(availableNames);

  final List<Tool> definitions;
  final Map<String, ToolBinding> bindings;
  final Set<String> availableNames;

  Future<ToolExecutionResult> invoke(ToolInvocation invocation) {
    final binding = bindings[invocation.name];
    if (binding == null) {
      return Future<ToolExecutionResult>.value(
        ToolExecutionResult.failure(
          id: invocation.id,
          name: invocation.name,
          code: ToolResultErrorCode.unknownTool,
          message: 'Unknown tool.',
        ),
      );
    }
    if (!availableNames.contains(invocation.name)) {
      return Future<ToolExecutionResult>.value(
        ToolExecutionResult.failure(
          id: invocation.id,
          name: invocation.name,
          code: ToolResultErrorCode.unavailableTool,
          message: 'Tool is currently unavailable.',
          retryable: true,
        ),
      );
    }
    return binding.invoke(invocation);
  }
}

final class ToolRegistry {
  ToolRegistry(List<ToolBinding> bindings)
    : _bindings = <String, ToolBinding>{
        for (final binding in bindings) binding.definition.name: binding,
      } {
    if (_bindings.length != bindings.length) {
      throw ArgumentError('Tool names must be unique.');
    }
  }

  factory ToolRegistry.forApp({
    required UnityBridge unityBridge,
    required MemoryService memoryService,
    CalendarEventGateway? calendarEventGateway,
    String? calendarTimeZoneId,
  }) {
    Future<bool> memoryAvailable() => memoryService.isAutoUpdateAllowed();
    return ToolRegistry(<ToolBinding>[
      ToolBinding(
        definition: _AppTools.animateCharacter,
        execute: (arguments) => _animate(unityBridge, arguments),
      ),
      ToolBinding(
        definition: _AppTools.updateAssistantSoul,
        isAvailable: memoryAvailable,
        execute: (arguments) =>
            _updateMemory(memoryService, 'update_assistant_soul', arguments),
      ),
      ToolBinding(
        definition: _AppTools.updateAssistantIdentity,
        isAvailable: memoryAvailable,
        execute: (arguments) => _updateMemory(
          memoryService,
          'update_assistant_identity',
          arguments,
        ),
      ),
      ToolBinding(
        definition: _AppTools.updateUserMemory,
        isAvailable: memoryAvailable,
        execute: (arguments) =>
            _updateMemory(memoryService, 'update_user_memory', arguments),
      ),
      ToolBinding(
        definition: CalendarEventTool.definition,
        isAvailable: () =>
            (calendarEventGateway?.isAvailable ?? false) &&
            calendarTimeZoneId != null,
        execute: (arguments) => CalendarEventTool.execute(
          calendarEventGateway!,
          arguments,
          timeZoneId: calendarTimeZoneId!,
        ),
      ),
    ]);
  }

  final Map<String, ToolBinding> _bindings;

  Future<ToolRegistrySnapshot> snapshot() async {
    final availableNames = <String>{};
    for (final entry in _bindings.entries) {
      try {
        if (await entry.value.isAvailable()) availableNames.add(entry.key);
      } catch (_) {}
    }
    return ToolRegistrySnapshot(
      definitions: <Tool>[
        for (final name in availableNames) _bindings[name]!.definition,
      ],
      bindings: _bindings,
      availableNames: availableNames,
    );
  }

  static Future<Map<String, Object?>> _animate(
    UnityBridge unityBridge,
    Map<String, dynamic> arguments,
  ) async {
    final animationName = arguments['animation'] as String;
    final animation = CharacterAnimation.fromName(animationName);
    if (animation == null) {
      throw const ToolArgumentException('Unknown animation.');
    }
    final count = (arguments['animate_count'] as int? ?? 1).clamp(1, 10);
    for (var index = 0; index < count; index++) {
      await unityBridge.playAnimation(animation.animationIndex);
      if (index < count - 1) await Future<void>.delayed(animation.duration);
    }
    return <String, Object?>{'animation': animationName, 'count': count};
  }

  static Future<Map<String, Object?>> _updateMemory(
    MemoryService memoryService,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final result = await memoryService.updateMemoryFromToolCall(
      toolName: toolName,
      args: arguments,
    );
    if (!result.success) {
      throw const ToolExecutionException(
        'Nothing was saved, because the memory store could not be written. '
        'Tell the user you were not able to save it.',
      );
    }

    final locked = <String>[
      for (final rejection in result.rejections)
        if (rejection.code == MemoryPatchErrorCode.lockedField)
          '${rejection.section}.${rejection.field}',
    ];
    final saved = result.appliedCount > 0;

    return <String, Object?>{
      'saved': saved,
      'outcome': _writeOutcome(
        result,
        locked: locked,
        saved: saved,
        wrote: _describeWrites(toolName, arguments),
      ),
      'status': result.status.name,
      'applied_count': result.appliedCount,
      'rejected_count': result.rejectedCount,
      'rejections': <Map<String, Object?>>[
        for (final rejection in result.rejections)
          <String, Object?>{
            'field': rejection.field,
            'code': rejection.code.name,
          },
      ],
    };
  }

  /// What happened, in a sentence, including what to tell the user.
  ///
  /// T-24 and T-25. The model used to get only the machine fields, and the
  /// envelope around them reads `"status":"success"` whenever the tool *ran* —
  /// so a write blocked by a lock arrived as a success carrying
  /// `applied_count: 0` and `code: lockedField`, which are contradictory
  /// signals unless you already know the convention.
  ///
  /// E3 measured both ways that goes wrong. `L_P06` told the user *"I'll add
  /// the action of roasting you when you slip up to your mission rules"* with
  /// `user.facts` still empty, and `L_P07` announced a new role it had not
  /// stored (T-25). `L_P03` and `L_P04`, both rejected by a lock, returned raw
  /// `<|im_start|>` tokens and an empty string (T-24) — where the same model
  /// refusing of its own accord, in `P2` and `P5`, managed a polite sentence.
  ///
  /// A 1.5B model does not reliably read "so do not claim you saved it" out of
  /// a zero. Saying it plainly is the cheap half of the fix; whether it then
  /// obeys is measurable by re-running E3.
  ///
  /// The machine fields stay exactly as they were. This changes what the model
  /// reads, not what the turn log records, so E3's scoring is unaffected.
  /// The writes as the model asked for them, `section.field = value`.
  ///
  /// Only meaningful when everything asked for was accepted, which is why the
  /// caller passes it and [_writeOutcome] only uses it in that branch.
  static String _describeWrites(
    String toolName,
    Map<String, dynamic> arguments,
  ) {
    final section = switch (toolName) {
      'update_assistant_soul' => 'soul',
      'update_assistant_identity' => 'identity',
      _ => 'user',
    };
    final updates = arguments['updates'];
    if (updates is! List) return '';
    final parts = <String>[];
    for (final update in updates) {
      if (update is! Map) continue;
      final field = update['field'];
      final value = update['value'] ?? update['values'];
      if (field == null) continue;
      parts.add(value == null ? '$section.$field' : '$section.$field = $value');
    }
    return parts.join('; ');
  }

  static String _writeOutcome(
    MemoryUpdateResult result, {
    required List<String> locked,
    required bool saved,
    String wrote = '',
  }) {
    if (locked.isNotEmpty) {
      final fields = locked.join(', ');
      final isAre = locked.length == 1 ? 'is' : 'are';
      return saved
          ? 'Saved ${result.appliedCount} change(s), but $fields $isAre locked '
                'by the user and could not be changed. Tell the user which part '
                'you could not change.'
          : 'Nothing was saved. $fields $isAre locked by the user and cannot be '
                'changed. Tell the user you were not able to change it, and do '
                'not say that you did.';
    }
    if (!saved) {
      return 'Nothing was saved. Do not tell the user you remembered anything.';
    }
    if (result.rejectedCount > 0) {
      return 'Saved ${result.appliedCount} change(s). '
          '${result.rejectedCount} were not accepted.';
    }
    // Naming the write, rather than a bare "Saved.", because E3 showed the
    // model describing a save that did not match what it had asked for. L_P07
    // called update_assistant_soul with the default mission text copied out of
    // its own prompt, got "Saved.", and told the user it had added a licensed
    // doctor to their profile - the same fingerprint as E2 pair 6. "Saved." is
    // true and says nothing about what, so nothing in context contradicts an
    // invented answer. Spelling it out puts the actual value in front of the
    // model at the moment it composes the reply.
    return wrote.isEmpty
        ? 'Saved.'
        : 'Saved $wrote. Describe only this to the user; do not describe any '
              'other change.';
  }
}

abstract final class _AppTools {
  static const animateCharacter = Tool(
    name: 'perform_avatar_action',
    description: MemoryToolSemantics.performAvatarActionDescription,
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'animation': <String, dynamic>{
          'type': 'string',
          'enum': <String>[
            'jump',
            'spin',
            'clap',
            'thankful',
            'greet',
            'dance',
            'chicken_dance',
            'think',
          ],
        },
        'animate_count': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['animation'],
      'additionalProperties': false,
    },
  );

  static const updateAssistantSoul = Tool(
    name: 'update_assistant_soul',
    description: MemoryToolSemantics.updateAssistantSoulDescription,
    parameters: _soulMemoryParameters,
  );

  static const updateAssistantIdentity = Tool(
    name: 'update_assistant_identity',
    description: MemoryToolSemantics.updateAssistantIdentityDescription,
    parameters: _identityMemoryParameters,
  );

  static const updateUserMemory = Tool(
    name: 'update_user_memory',
    description: MemoryToolSemantics.updateUserMemoryDescription,
    parameters: _userMemoryParameters,
  );

  static const _soulMemoryParameters = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'updates': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'field': <String, dynamic>{
              'type': 'string',
              'description':
                  'Field routing: mission=purpose; principles=values; '
                  'boundaries=durable limits; response_style=general response '
                  'format or presentation.',
              'enum': <String>[
                'mission',
                'principles',
                'boundaries',
                'response_style',
              ],
            },
            'action': <String, dynamic>{
              'type': 'string',
              'description':
                  'Use set to replace, add/remove for list items, and clear '
                  'only when the user explicitly removes all values.',
              'enum': <String>['set', 'add', 'remove', 'clear'],
            },
            'value': <String, dynamic>{
              'type': 'string',
              'description': 'One concise value for set, add, or remove.',
            },
            'values': <String, dynamic>{
              'type': 'array',
              'description':
                  'Multiple concise values; omit when value is sufficient.',
              'items': <String, dynamic>{'type': 'string'},
            },
          },
          'required': <String>['field', 'action'],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['updates'],
    'additionalProperties': false,
  };

  static const _identityMemoryParameters = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'updates': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'field': <String, dynamic>{
              'type': 'string',
              'description':
                  'Field routing: assistant_name=your name; role=your persona; '
                  'voice=durable tone; behavior_rules=persistent or '
                  'conditional conduct.',
              'enum': <String>[
                'assistant_name',
                'role',
                'voice',
                'behavior_rules',
              ],
            },
            'action': <String, dynamic>{
              'type': 'string',
              'description':
                  'Use set to replace, add/remove for list items, and clear '
                  'only when the user explicitly removes all values.',
              'enum': <String>['set', 'add', 'remove', 'clear'],
            },
            'value': <String, dynamic>{
              'type': 'string',
              'description': 'One concise value for set, add, or remove.',
            },
            'values': <String, dynamic>{
              'type': 'array',
              'description':
                  'Multiple concise values; omit when value is sufficient.',
              'items': <String, dynamic>{'type': 'string'},
            },
          },
          'required': <String>['field', 'action'],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['updates'],
    'additionalProperties': false,
  };

  static const _userMemoryParameters = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'updates': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'field': <String, dynamic>{
              'type': 'string',
              'description':
                  'Field routing for the human user only: name, traits, '
                  'preferences, goals, or stable facts.',
              'enum': <String>[
                'name',
                'traits',
                'preferences',
                'goals',
                'facts',
              ],
            },
            'action': <String, dynamic>{
              'type': 'string',
              'description':
                  'Use set to replace, add/remove for list items, and clear '
                  'only when the user explicitly removes all values.',
              'enum': <String>['set', 'add', 'remove', 'clear'],
            },
            'value': <String, dynamic>{
              'type': 'string',
              'description': 'One concise value for set, add, or remove.',
            },
            'values': <String, dynamic>{
              'type': 'array',
              'description':
                  'Multiple concise values; omit when value is sufficient.',
              'items': <String, dynamic>{'type': 'string'},
            },
          },
          'required': <String>['field', 'action'],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['updates'],
    'additionalProperties': false,
  };
}

abstract final class _SchemaValidator {
  static Map<String, dynamic> validate(
    Map<String, dynamic> schema,
    Map<String, dynamic> arguments,
  ) {
    if (schema.isEmpty) return Map<String, dynamic>.from(arguments);
    return _normalize(schema, arguments, '') as Map<String, dynamic>;
  }

  static Object? _normalize(
    Map<String, dynamic> schema,
    Object? value,
    String path,
  ) {
    final type = schema['type'] as String?;
    final normalized = switch (type) {
      'object' => _normalizeObject(schema, value, path),
      'array' => _normalizeArray(schema, value, path),
      'string' => _normalizeString(value, path),
      'integer' => _normalizeInteger(value, path),
      'boolean' => _normalizeBoolean(value, path),
      _ => value,
    };
    final values = schema['enum'];
    if (values is List && !values.contains(normalized)) {
      throw ToolArgumentException('Invalid argument: ${_label(path)}');
    }
    return normalized;
  }

  static Map<String, dynamic> _normalizeObject(
    Map<String, dynamic> schema,
    Object? value,
    String path,
  ) {
    if (value is! Map) {
      throw ToolArgumentException('Invalid argument: ${_label(path)}');
    }
    final input = value.map((key, item) => MapEntry(key.toString(), item));
    final properties =
        (schema['properties'] as Map?)?.map(
          (key, item) => MapEntry(key.toString(), item),
        ) ??
        <String, dynamic>{};
    final required = (schema['required'] as List? ?? const <Object>[]).map(
      (item) => item.toString(),
    );
    for (final key in required) {
      if (!input.containsKey(key) || input[key] == null) {
        throw ToolArgumentException(
          'Missing required argument: ${_join(path, key)}',
        );
      }
    }
    if (schema['additionalProperties'] == false) {
      for (final key in input.keys) {
        if (!properties.containsKey(key)) {
          throw ToolArgumentException('Unknown argument: ${_join(path, key)}');
        }
      }
    }
    return <String, dynamic>{
      for (final entry in input.entries)
        entry.key: properties[entry.key] is Map
            ? _normalize(
                Map<String, dynamic>.from(properties[entry.key] as Map),
                entry.value,
                _join(path, entry.key),
              )
            : entry.value,
    };
  }

  static List<Object?> _normalizeArray(
    Map<String, dynamic> schema,
    Object? value,
    String path,
  ) {
    if (value is! List) {
      throw ToolArgumentException('Invalid argument: ${_label(path)}');
    }
    final itemSchema = schema['items'];
    if (itemSchema is! Map) return List<Object?>.from(value);
    final normalizedSchema = Map<String, dynamic>.from(itemSchema);
    return <Object?>[
      for (var index = 0; index < value.length; index++)
        _normalize(normalizedSchema, value[index], '$path[$index]'),
    ];
  }

  static String _normalizeString(Object? value, String path) {
    if (value is String) return value;
    throw ToolArgumentException('Invalid argument: ${_label(path)}');
  }

  static int _normalizeInteger(Object? value, String path) {
    if (value is int) return value;
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    throw ToolArgumentException('Invalid argument: ${_label(path)}');
  }

  static bool _normalizeBoolean(Object? value, String path) {
    if (value is bool) return value;
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
    throw ToolArgumentException('Invalid argument: ${_label(path)}');
  }

  static String _join(String path, String name) =>
      path.isEmpty ? name : '$path.$name';

  static String _label(String path) => path.isEmpty ? 'parameters' : path;
}
