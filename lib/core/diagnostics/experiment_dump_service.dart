import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../llm/llm_service.dart';
import '../memory/memory_service.dart';

/// Writes the artefacts the experiment protocol in `my-tasks/` asks for:
/// a memory dump and the exact composed system prompt, both as files that can
/// be pulled off the device with `adb pull`.
///
/// See `my-tasks/TASKS.md` T-03. Referenced by protocol §1a items 1-2 and by
/// the E1 checkpoints (`c1_stored`, `c1_field`, `c2_in_prompt`) and the E2
/// `write` / `write_field` columns.
class ExperimentDumpService {
  ExperimentDumpService({required this.memoryService, required this.llmService});

  final MemoryService memoryService;
  final LlmService llmService;

  /// Root folder name, mirroring the layout in protocol §0.
  static const String rootFolderName = 'mybuddy-experiments';
  static const String memoryFolderName = 'memory_dumps';
  static const String promptFolderName = 'prompts';

  /// Where dumps land.
  ///
  /// Prefers external storage so `adb pull` works without root. Falls back to
  /// the app documents directory on platforms that have no external storage
  /// (and on Android when the call unexpectedly returns null).
  Future<Directory> resolveRootDirectory() async {
    Directory? base;
    if (Platform.isAndroid) {
      try {
        base = await getExternalStorageDirectory();
      } catch (e) {
        debugPrint('ExperimentDumpService: external storage unavailable: $e');
      }
    }
    base ??= await getApplicationDocumentsDirectory();

    final root = Directory('${base.path}/$rootFolderName');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  /// Writes the full three-layer memory as canonical JSON.
  ///
  /// [label] becomes the file name, e.g. `run01_after_input_a` produces
  /// `memory_dumps/run01_after_input_a.json`. Protocol §3 step 5 and §4 step 3
  /// specify these names.
  Future<File> dumpMemory({String? label}) async {
    final memory = await memoryService.loadMemoryData();
    final content = canonicalJson(memory.toJson());
    final file = await _fileFor(
      folder: memoryFolderName,
      label: label,
      fallbackPrefix: 'memory',
      extension: 'json',
    );
    await file.writeAsString(content, flush: true);
    debugPrint(
      'ExperimentDumpService: memory dump -> ${file.path} '
      '(${content.length} chars)',
    );
    return file;
  }

  /// Writes the exact system instruction last sent to the model.
  ///
  /// Throws [StateError] before the first turn — there is no prompt to dump
  /// yet, and writing an empty file would silently produce a token count of
  /// zero in §1c.
  Future<File> dumpSystemPrompt({String? label}) async {
    final prompt = llmService.lastComposedSystemText;
    if (prompt == null || prompt.isEmpty) {
      throw StateError(
        'No system prompt has been composed yet. Send one message first, '
        'then dump.',
      );
    }

    final file = await _fileFor(
      folder: promptFolderName,
      label: label,
      fallbackPrefix: 'system_prompt',
      extension: 'txt',
    );
    await file.writeAsString(prompt, flush: true);
    debugPrint(
      'ExperimentDumpService: prompt dump -> ${file.path} '
      '(${prompt.length} chars)',
    );
    return file;
  }

  Future<File> _fileFor({
    required String folder,
    required String? label,
    required String fallbackPrefix,
    required String extension,
  }) async {
    final root = await resolveRootDirectory();
    final dir = Directory('${root.path}/$folder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final name = sanitizeLabel(label) ?? _timestampedName(fallbackPrefix);
    return File('${dir.path}/$name.$extension');
  }

  /// Trims a caller-supplied label down to characters that are safe in a file
  /// name on every platform. Returns null when nothing usable is left.
  @visibleForTesting
  static String? sanitizeLabel(String? label) {
    final trimmed = label?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    final cleaned = trimmed
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_{2,}'), '_')
        .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');

    if (cleaned.isEmpty) return null;
    return cleaned.length <= 100 ? cleaned : cleaned.substring(0, 100);
  }

  static String _timestampedName(String prefix) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix'
        '_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// Encodes [value] with keys sorted at every level and a stable two-space
  /// indent.
  ///
  /// Protocol §5.5 step 5 requires sorting keys before diffing dumps.
  /// Producing the file in canonical form means a plain `diff` is already
  /// correct and the RA cannot forget the step.
  @visibleForTesting
  static String canonicalJson(Object? value) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(_sortKeys(value));
  }

  static Object? _sortKeys(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _sortKeys(value[key]),
      };
    }
    if (value is List) {
      // List order is meaningful for memory fields (entry order decides what
      // survives the 5-entry cap), so items are not sorted.
      return value.map(_sortKeys).toList();
    }
    return value;
  }
}
