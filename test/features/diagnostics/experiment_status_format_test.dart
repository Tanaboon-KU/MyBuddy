import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/diagnostics/turn_log.dart';
import 'package:mybuddy/features/diagnostics/presentation/widgets/experiment_status_format.dart';

TurnLogEntry _entry({
  int turnIndex = 1,
  int? sysPromptChars,
  String? sysPromptSha256,
  int? ttftMs,
  bool? sessionRebuilt,
  int? replayedMessageCount,
  int? extractStartMs,
  int? extractEndMs,
  ExtractionParseResult extractParseResult = ExtractionParseResult.notRun,
  bool? memoryChanged,
  List<String> layersChanged = const <String>[],
}) {
  return TurnLogEntry(
    sessionId: 's1',
    turnIndex: turnIndex,
    timestampMs: 0,
    inputText: 'in',
    replyText: 'out',
    ttftMs: ttftMs,
    sysPromptChars: sysPromptChars,
    sysPromptSha256: sysPromptSha256,
    sessionRebuilt: sessionRebuilt,
    replayedMessageCount: replayedMessageCount,
    extractStartMs: extractStartMs,
    extractEndMs: extractEndMs,
    extractParseResult: extractParseResult,
    memoryChanged: memoryChanged,
    layersChanged: layersChanged,
  );
}

void main() {
  final now = DateTime(2026, 8, 4, 10, 30, 0);

  group('countdown', () {
    test('renders mm:ss', () {
      expect(
        ExperimentStatusFormat.countdown(
          now.add(const Duration(seconds: 47)),
          now,
        ),
        'in 0:47',
      );
      expect(
        ExperimentStatusFormat.countdown(
          now.add(const Duration(minutes: 1)),
          now,
        ),
        'in 1:00',
      );
    });

    test('rounds up so a sub-second remainder never reads as zero', () {
      expect(
        ExperimentStatusFormat.countdown(
          now.add(const Duration(milliseconds: 900)),
          now,
        ),
        'in 0:01',
      );
    });

    test('collapses a passed deadline instead of going negative', () {
      expect(
        ExperimentStatusFormat.countdown(
          now.subtract(const Duration(seconds: 3)),
          now,
        ),
        'due now',
      );
      expect(ExperimentStatusFormat.countdown(now, now), 'due now');
    });
  });

  group('clockTime', () {
    test('zero-pads every component', () {
      expect(
        ExperimentStatusFormat.clockTime(DateTime(2026, 8, 4, 9, 5, 3)),
        '09:05:03',
      );
    });
  });

  group('shortHash', () {
    test('truncates to 12 characters', () {
      expect(
        ExperimentStatusFormat.shortHash('0123456789abcdef0123'),
        '0123456789ab',
      );
    });

    test('falls back to a dash when the hash is missing', () {
      expect(ExperimentStatusFormat.shortHash(null), '—');
      expect(ExperimentStatusFormat.shortHash(''), '—');
    });
  });

  group('lastTurnHeadline', () {
    test('reports sys_prompt_chars from the logged row', () {
      expect(
        ExperimentStatusFormat.lastTurnHeadline(
          _entry(turnIndex: 2, sysPromptChars: 7104),
        ),
        'turn 2 · 7104 chars',
      );
    });

    test('prefers the logged value over the live fallback', () {
      expect(
        ExperimentStatusFormat.lastTurnHeadline(
          _entry(sysPromptChars: 7104),
          fallbackChars: 12,
        ),
        'turn 1 · 7104 chars',
      );
    });

    test('uses the live prompt size before any turn is logged', () {
      expect(
        ExperimentStatusFormat.lastTurnHeadline(null, fallbackChars: 7104),
        'No turn logged yet · prompt 7104 chars',
      );
      expect(
        ExperimentStatusFormat.lastTurnHeadline(null, fallbackChars: 0),
        'No turn logged yet',
      );
    });
  });

  group('lastTurnDetail', () {
    test('omits columns that have not been measured yet', () {
      expect(
        ExperimentStatusFormat.lastTurnDetail(_entry(sysPromptSha256: 'abcdef')),
        'sha abcdef',
      );
    });

    test('shows the replayed count when the session was rebuilt', () {
      expect(
        ExperimentStatusFormat.lastTurnDetail(
          _entry(
            sysPromptSha256: '0123456789abcdef',
            ttftMs: 5180,
            sessionRebuilt: true,
            replayedMessageCount: 8,
          ),
        ),
        'sha 0123456789ab · ttft 5180ms · session rebuilt (8 msg)',
      );
    });

    test('does not mention a rebuild that did not happen', () {
      expect(
        ExperimentStatusFormat.lastTurnDetail(
          _entry(sysPromptSha256: 'abcdef', sessionRebuilt: false),
        ),
        isNot(contains('rebuilt')),
      );
    });

    test('reports extraction timing, parse result and changed layers', () {
      expect(
        ExperimentStatusFormat.lastTurnDetail(
          _entry(
            sysPromptSha256: 'abcdef',
            extractStartMs: 1000,
            extractEndMs: 4200,
            extractParseResult: ExtractionParseResult.valid,
            memoryChanged: true,
            layersChanged: <String>['user'],
          ),
        ),
        'sha abcdef · extract 3200ms · VALID · memory changed [user]',
      );
    });

    test('distinguishes an unchanged memory from an unresolved extraction', () {
      expect(
        ExperimentStatusFormat.lastTurnDetail(
          _entry(
            sysPromptSha256: 'abcdef',
            extractParseResult: ExtractionParseResult.rejected,
            memoryChanged: false,
          ),
        ),
        'sha abcdef · REJECTED · memory unchanged',
      );
      expect(
        ExperimentStatusFormat.lastTurnDetail(_entry(sysPromptSha256: 'abcdef')),
        isNot(contains('memory')),
      );
    });

    test('prompts the RA when nothing has been logged', () {
      expect(
        ExperimentStatusFormat.lastTurnDetail(null),
        'run one turn to populate the log',
      );
    });
  });
}
