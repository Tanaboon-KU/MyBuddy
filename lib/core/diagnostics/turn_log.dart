import 'dart:convert';

import 'package:crypto/crypto.dart';

/// How the extraction pass ended.
///
/// Protocol section 1b asks for `VALID` / `REPAIRED` / `FAILED`. The build has
/// no repair step, but it does have three distinct ways to change nothing that
/// were previously indistinguishable — see ROOT_CAUSE_ANALYSIS.md sections 2
/// and 7.5. Splitting them is what lets E1 tell a broken write path apart from
/// a conversation that genuinely held nothing durable.
enum ExtractionParseResult {
  /// Parsed, and at least one patch was applied.
  valid('VALID'),

  /// Parsed, and the model explicitly returned `{"updates":[]}`.
  noChange('NO_CHANGE'),

  /// Parsed, but every patch was rejected. Carries the rejection codes.
  /// This is the signature of RC-2.
  rejected('REJECTED'),

  /// No JSON could be extracted from the model output.
  failed('FAILED'),

  /// The 60 s extraction budget ran out. Previously indistinguishable from
  /// "nothing to change" because the timeout path returns an empty string.
  timedOut('TIMED_OUT'),

  /// Extraction did not run for this turn (debounced, or consent is off).
  notRun('NOT_RUN');

  const ExtractionParseResult(this.csvValue);

  final String csvValue;
}

/// One row of the per-turn log required by protocol section 1b.
///
/// Every field is nullable so a partially-observed turn still produces a row.
/// Losing a whole turn because one probe failed would be worse than a row with
/// blanks in it — section 0 requires logging failures, not hiding them.
class TurnLogEntry {
  const TurnLogEntry({
    required this.sessionId,
    required this.turnIndex,
    required this.timestampMs,
    required this.inputText,
    required this.replyText,
    this.ttftMs,
    this.replyStartMs,
    this.replyEndMs,
    this.sysPromptChars,
    this.sysPromptSha256,
    this.sessionRebuilt,
    this.replayedMessageCount,
    this.toolsExposed = const <String>[],
    this.extractStartMs,
    this.extractEndMs,
    this.extractParseResult = ExtractionParseResult.notRun,
    this.extractRawOutput,
    this.extractRejectionCodes = const <String>[],
    this.memoryChanged,
    this.layersChanged = const <String>[],
    this.prevExtractionStillRunning,
    this.batteryTempC,
    this.batteryPct,
    this.notes,
  });

  final String sessionId;
  final int turnIndex;
  final int timestampMs;
  final String inputText;
  final String replyText;

  /// Submit to first token.
  final int? ttftMs;
  final int? replyStartMs;
  final int? replyEndMs;

  /// Length of the *composed* system prompt — memory block plus tool blocks.
  final int? sysPromptChars;
  final String? sysPromptSha256;

  /// True when the chat session was torn down and rebuilt for this turn.
  ///
  /// Happens whenever the system prompt text changes, i.e. on the turn after
  /// memory is written. The rebuild discards the KV cache and replays history,
  /// so latency spikes here. Without this column that spike looks like an
  /// unexplained outlier.
  final bool? sessionRebuilt;

  /// How many messages were replayed into the rebuilt session. Lower than the
  /// stored history means turns were silently dropped to fit the budget.
  final int? replayedMessageCount;

  /// Tools written into `<tools>` on this turn.
  ///
  /// Protocol §5.8 step 4 requires confirming the memory-update tools were not
  /// exposed while consent is off. It also catches the calendar tool
  /// appearing or vanishing with Google sign-in state, which moves the prompt
  /// by 1,040 characters and invalidates a cross-run prompt comparison.
  final List<String> toolsExposed;

  /// Reply finished and extraction was triggered.
  final int? extractStartMs;

  /// Memory was persisted, or the system determined nothing changed.
  final int? extractEndMs;

  final ExtractionParseResult extractParseResult;

  /// Raw model output, recorded on every non-[ExtractionParseResult.valid]
  /// turn. This is the evidence E1 needs to confirm or rule out RC-2.
  final String? extractRawOutput;

  final List<String> extractRejectionCodes;

  final bool? memoryChanged;

  /// Any of `soul`, `identity`, `user`.
  final List<String> layersChanged;

  final bool? prevExtractionStillRunning;

  final double? batteryTempC;
  final int? batteryPct;

  final String? notes;

  int? get extractTotalMs {
    final start = extractStartMs;
    final end = extractEndMs;
    if (start == null || end == null) return null;
    return end - start;
  }

  TurnLogEntry copyWith({
    int? ttftMs,
    int? replyStartMs,
    int? replyEndMs,
    int? sysPromptChars,
    String? sysPromptSha256,
    bool? sessionRebuilt,
    int? replayedMessageCount,
    List<String>? toolsExposed,
    int? extractStartMs,
    int? extractEndMs,
    ExtractionParseResult? extractParseResult,
    String? extractRawOutput,
    List<String>? extractRejectionCodes,
    bool? memoryChanged,
    List<String>? layersChanged,
    bool? prevExtractionStillRunning,
    double? batteryTempC,
    int? batteryPct,
    String? notes,
    String? replyText,
  }) {
    return TurnLogEntry(
      sessionId: sessionId,
      turnIndex: turnIndex,
      timestampMs: timestampMs,
      inputText: inputText,
      replyText: replyText ?? this.replyText,
      ttftMs: ttftMs ?? this.ttftMs,
      replyStartMs: replyStartMs ?? this.replyStartMs,
      replyEndMs: replyEndMs ?? this.replyEndMs,
      sysPromptChars: sysPromptChars ?? this.sysPromptChars,
      sysPromptSha256: sysPromptSha256 ?? this.sysPromptSha256,
      sessionRebuilt: sessionRebuilt ?? this.sessionRebuilt,
      replayedMessageCount: replayedMessageCount ?? this.replayedMessageCount,
      toolsExposed: toolsExposed ?? this.toolsExposed,
      extractStartMs: extractStartMs ?? this.extractStartMs,
      extractEndMs: extractEndMs ?? this.extractEndMs,
      extractParseResult: extractParseResult ?? this.extractParseResult,
      extractRawOutput: extractRawOutput ?? this.extractRawOutput,
      extractRejectionCodes:
          extractRejectionCodes ?? this.extractRejectionCodes,
      memoryChanged: memoryChanged ?? this.memoryChanged,
      layersChanged: layersChanged ?? this.layersChanged,
      prevExtractionStillRunning:
          prevExtractionStillRunning ?? this.prevExtractionStillRunning,
      batteryTempC: batteryTempC ?? this.batteryTempC,
      batteryPct: batteryPct ?? this.batteryPct,
      notes: notes ?? this.notes,
    );
  }

  /// Column order matches protocol section 1b, with `session_rebuilt`,
  /// `replayed_message_count` and `extract_rejection_codes` appended.
  static const List<String> csvColumns = <String>[
    'session_id',
    'turn_index',
    'timestamp_ms',
    'input_text',
    'reply_text',
    'ttft_ms',
    'reply_start_ms',
    'reply_end_ms',
    'sys_prompt_chars',
    'sys_prompt_sha256',
    'session_rebuilt',
    'replayed_message_count',
    'tools_exposed',
    'extract_start_ms',
    'extract_end_ms',
    'extract_total_ms',
    'extract_parse_result',
    'extract_rejection_codes',
    'extract_raw_output',
    'memory_changed',
    'layers_changed',
    'prev_extraction_still_running',
    'battery_temp_c',
    'battery_pct',
    'notes',
  ];

  static String get csvHeader => csvColumns.map(escapeCsv).join(',');

  String toCsvRow() {
    final values = <Object?>[
      sessionId,
      turnIndex,
      timestampMs,
      inputText,
      replyText,
      ttftMs,
      replyStartMs,
      replyEndMs,
      sysPromptChars,
      sysPromptSha256,
      _boolValue(sessionRebuilt),
      replayedMessageCount,
      toolsExposed.join('|'),
      extractStartMs,
      extractEndMs,
      extractTotalMs,
      extractParseResult.csvValue,
      extractRejectionCodes.join('|'),
      extractRawOutput,
      _boolValue(memoryChanged),
      layersChanged.join('|'),
      _boolValue(prevExtractionStillRunning),
      batteryTempC,
      batteryPct,
      notes,
    ];
    return values.map((v) => escapeCsv(v?.toString() ?? '')).join(',');
  }

  static String? _boolValue(bool? value) {
    if (value == null) return null;
    return value ? 'Y' : 'N';
  }

  /// RFC 4180 quoting.
  ///
  /// Every text column can contain commas, quotes and newlines: `input_text`
  /// and `reply_text` are verbatim, and `extract_raw_output` is raw model
  /// output that is frequently multi-line JSON.
  static String escapeCsv(String value) {
    final needsQuoting =
        value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
    if (!needsQuoting) return value;
    return '"${value.replaceAll('"', '""')}"';
  }

  /// SHA-256 of the exact prompt bytes sent, as protocol section 1b requires.
  static String hashPrompt(String prompt) {
    return sha256.convert(utf8.encode(prompt)).toString();
  }
}
