import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/core/diagnostics/turn_log_recorder.dart';

/// Covers the log format for T-04 (protocol section 1b).
TurnLogEntry _entry({
  String sessionId = 's1',
  int turnIndex = 0,
  String inputText = 'hello',
  String replyText = 'hi',
}) {
  return TurnLogEntry(
    sessionId: sessionId,
    turnIndex: turnIndex,
    timestampMs: 1000,
    inputText: inputText,
    replyText: replyText,
  );
}

void main() {
  group('csv format', () {
    test('header lists every column section 1b asks for', () {
      const required = <String>[
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
        'extract_start_ms',
        'extract_end_ms',
        'extract_total_ms',
        'extract_parse_result',
        'extract_raw_output',
        'memory_changed',
        'layers_changed',
        'prev_extraction_still_running',
        'battery_temp_c',
        'battery_pct',
        'notes',
      ];

      for (final column in required) {
        expect(
          TurnLogEntry.csvColumns,
          contains(column),
          reason: '$column is required by protocol section 1b',
        );
      }
    });

    test('a row has exactly as many fields as the header', () {
      final row = _entry().toCsvRow();
      // Nothing quoted in this row, so a plain split is a valid count.
      expect(row.split(',').length, TurnLogEntry.csvColumns.length);
    });

    test('quotes commas, quotes and newlines', () {
      expect(TurnLogEntry.escapeCsv('plain'), 'plain');
      expect(TurnLogEntry.escapeCsv('a,b'), '"a,b"');
      expect(TurnLogEntry.escapeCsv('say "hi"'), '"say ""hi"""');
      expect(TurnLogEntry.escapeCsv('line1\nline2'), '"line1\nline2"');
    });

    test('survives a raw extraction output full of JSON and newlines', () {
      const raw = '{\n  "updates": [{"section":"user","value":"a,b"}]\n}';
      final row = _entry()
          .copyWith(extractRawOutput: raw, extractRejectionCodes: ['a:b'])
          .toCsvRow();

      // The whole field is quoted and every inner quote is doubled, so the
      // embedded commas and newlines cannot create extra fields.
      expect(row, contains(TurnLogEntry.escapeCsv(raw)));
      expect(TurnLogEntry.escapeCsv(raw).startsWith('"'), true);
      expect(TurnLogEntry.escapeCsv(raw), contains('""updates""'));
      expect(row.startsWith('s1,0,1000,hello,hi,'), true);
    });

    test('booleans render as Y/N and null as empty', () {
      final row = _entry()
          .copyWith(memoryChanged: true, sessionRebuilt: false)
          .toCsvRow()
          .split(',');

      expect(row[TurnLogEntry.csvColumns.indexOf('memory_changed')], 'Y');
      expect(row[TurnLogEntry.csvColumns.indexOf('session_rebuilt')], 'N');
      expect(row[TurnLogEntry.csvColumns.indexOf('ttft_ms')], '');
    });

    test('extract_total_ms is derived, not stored', () {
      final entry = _entry().copyWith(
        extractStartMs: 5000,
        extractEndMs: 5850,
      );
      expect(entry.extractTotalMs, 850);
      expect(_entry().extractTotalMs, isNull);
    });

    test('layers and rejection codes are pipe-joined', () {
      final row = _entry()
          .copyWith(
            layersChanged: const ['user', 'identity'],
            extractRejectionCodes: const ['user.name:lockedField'],
          )
          .toCsvRow()
          .split(',');

      expect(
        row[TurnLogEntry.csvColumns.indexOf('layers_changed')],
        'user|identity',
      );
      expect(
        row[TurnLogEntry.csvColumns.indexOf('extract_rejection_codes')],
        'user.name:lockedField',
      );
    });

    test('parse result defaults to NOT_RUN', () {
      final row = _entry().toCsvRow().split(',');
      expect(
        row[TurnLogEntry.csvColumns.indexOf('extract_parse_result')],
        'NOT_RUN',
      );
    });

    test('every parse result has a distinct csv value', () {
      final values = ExtractionParseResult.values
          .map((v) => v.csvValue)
          .toList();
      expect(values.toSet().length, values.length);
    });
  });

  group('hashPrompt', () {
    test('is stable and differs when the prompt differs', () {
      expect(
        TurnLogEntry.hashPrompt('abc'),
        TurnLogEntry.hashPrompt('abc'),
      );
      expect(
        TurnLogEntry.hashPrompt('abc'),
        isNot(TurnLogEntry.hashPrompt('abd')),
      );
    });

    test('matches the known SHA-256 of "abc"', () {
      expect(
        TurnLogEntry.hashPrompt('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('TurnLogRecorder', () {
    test('emits a header even when empty', () {
      final csv = TurnLogRecorder().toCsv().trim();
      expect(csv, TurnLogEntry.csvHeader);
    });

    test('update rewrites the matching row in place', () {
      final recorder = TurnLogRecorder()
        ..add(_entry(turnIndex: 0))
        ..add(_entry(turnIndex: 1));

      recorder.update(
        's1',
        0,
        (e) => e.copyWith(
          extractParseResult: ExtractionParseResult.rejected,
          memoryChanged: false,
        ),
      );

      expect(
        recorder.entries[0].extractParseResult,
        ExtractionParseResult.rejected,
      );
      expect(
        recorder.entries[1].extractParseResult,
        ExtractionParseResult.notRun,
      );
    });

    test('update on a missing row is a no-op, not a crash', () {
      final recorder = TurnLogRecorder()..add(_entry(turnIndex: 0));
      recorder.update('other-session', 99, (e) => e);
      expect(recorder.length, 1);
    });

    test('rows from different sessions do not collide on turn_index', () {
      final recorder = TurnLogRecorder()
        ..add(_entry(sessionId: 'a', turnIndex: 0))
        ..add(_entry(sessionId: 'b', turnIndex: 0));

      recorder.update('a', 0, (e) => e.copyWith(notes: 'from a'));

      expect(recorder.entries[0].notes, 'from a');
      expect(recorder.entries[1].notes, isNull);
    });

    test('drops the oldest rows past the cap and counts the loss', () {
      final recorder = TurnLogRecorder(maxEntries: 3);
      for (var i = 0; i < 5; i++) {
        recorder.add(_entry(turnIndex: i));
      }

      expect(recorder.length, 3);
      expect(recorder.droppedEntries, 2);
      expect(recorder.entries.first.turnIndex, 2);
    });

    test('toCsv emits one line per row plus the header', () {
      final recorder = TurnLogRecorder()
        ..add(_entry(turnIndex: 0))
        ..add(_entry(turnIndex: 1));

      final lines = recorder.toCsv().trim().split('\n');
      expect(lines.length, 3);
      expect(lines.first, TurnLogEntry.csvHeader);
    });
  });

  group('tools_exposed', () {
    test('is a column, positioned with the other prompt columns', () {
      expect(TurnLogEntry.csvColumns, contains('tools_exposed'));
      expect(
        TurnLogEntry.csvColumns.indexOf('tools_exposed'),
        TurnLogEntry.csvColumns.indexOf('replayed_message_count') + 1,
      );
    });

    test('joins names with a pipe, like the other list columns', () {
      const entry = TurnLogEntry(
        sessionId: 's1',
        turnIndex: 0,
        timestampMs: 0,
        inputText: 'hi',
        replyText: 'hello',
        toolsExposed: <String>['update_user_memory', 'create_calendar_event'],
      );

      expect(
        entry.toCsvRow(),
        contains('update_user_memory|create_calendar_event'),
      );
    });

    test('is empty rather than absent when no tool was exposed', () {
      // Protocol section 5.8 step 4 reads this to confirm the memory tools
      // were withheld while consent is off. An absent column and a genuinely
      // empty one have to stay distinguishable.
      const entry = TurnLogEntry(
        sessionId: 's1',
        turnIndex: 0,
        timestampMs: 0,
        inputText: 'hi',
        replyText: 'hello',
      );

      final cells = entry.toCsvRow().split(',');
      final index = TurnLogEntry.csvColumns.indexOf('tools_exposed');
      expect(cells[index], '');
    });

    test('survives copyWith when extraction fills the row in later', () {
      const entry = TurnLogEntry(
        sessionId: 's1',
        turnIndex: 0,
        timestampMs: 0,
        inputText: 'hi',
        replyText: 'hello',
        toolsExposed: <String>['update_user_memory'],
      );

      final updated = entry.copyWith(
        extractParseResult: ExtractionParseResult.noChange,
      );

      expect(updated.toolsExposed, <String>['update_user_memory']);
    });
  });
}
