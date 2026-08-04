import '../../../../core/diagnostics/turn_log.dart';

/// Pure formatting for the operator readouts in [ExperimentToolsSheet].
///
/// Kept out of the widget so the wording the RA reads off the screen can be
/// asserted in a unit test. Getting these strings wrong is not cosmetic: the
/// countdown is what tells the RA when it is safe to dump memory (protocol
/// section 3 step 4), and the last-turn line is where `sys_prompt_chars` is
/// read from.
abstract final class ExperimentStatusFormat {
  /// `mm:ss` remaining until the pending extraction fires.
  ///
  /// Returns `due now` once the deadline has passed — the timer has fired and
  /// the phase is about to flip to running, so a negative number would only
  /// confuse.
  static String countdown(DateTime scheduledFor, DateTime now) {
    final remaining = scheduledFor.difference(now);
    if (remaining.isNegative || remaining.inMilliseconds == 0) return 'due now';
    // Round up: with 900 ms left "in 0:00" reads as though it already fired.
    final seconds = (remaining.inMilliseconds / 1000).ceil();
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return 'in $minutes:${rest.toString().padLeft(2, '0')}';
  }

  static String clockTime(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  /// First 12 hex characters of a prompt hash.
  ///
  /// Section 1b wants the full hash in the CSV; on screen the RA is only
  /// comparing "did this change between turns", and a 64-character string
  /// wraps over three lines on a phone.
  static String shortHash(String? sha256) {
    if (sha256 == null || sha256.isEmpty) return '—';
    return sha256.length <= 12 ? sha256 : sha256.substring(0, 12);
  }

  /// Headline for the last recorded turn, e.g. `turn 2 · 7104 chars`.
  static String lastTurnHeadline(TurnLogEntry? entry, {int? fallbackChars}) {
    if (entry == null) {
      final chars = fallbackChars ?? 0;
      return chars > 0
          ? 'No turn logged yet · prompt $chars chars'
          : 'No turn logged yet';
    }
    final chars = entry.sysPromptChars ?? fallbackChars;
    return 'turn ${entry.turnIndex} · '
        '${chars == null ? 'prompt size unknown' : '$chars chars'}';
  }

  /// Second line of the last-turn readout: the columns worth watching live.
  ///
  /// Omits anything still unmeasured rather than printing `null`, so a turn
  /// whose extraction has not resolved yet shows a short line instead of a
  /// misleading one.
  static String lastTurnDetail(TurnLogEntry? entry) {
    if (entry == null) return 'run one turn to populate the log';

    final parts = <String>['sha ${shortHash(entry.sysPromptSha256)}'];

    final ttft = entry.ttftMs;
    if (ttft != null) parts.add('ttft ${ttft}ms');

    if (entry.sessionRebuilt ?? false) {
      final replayed = entry.replayedMessageCount;
      parts.add(
        replayed == null ? 'session rebuilt' : 'session rebuilt ($replayed msg)',
      );
    }

    final extractTotal = entry.extractTotalMs;
    if (extractTotal != null) parts.add('extract ${extractTotal}ms');

    if (entry.extractParseResult != ExtractionParseResult.notRun) {
      parts.add(entry.extractParseResult.csvValue);
    }

    // Only meaningful once extraction has actually run for this turn.
    final changed = entry.memoryChanged;
    if (changed != null) {
      parts.add(
        changed
            ? 'memory changed'
                '${entry.layersChanged.isEmpty ? '' : ' [${entry.layersChanged.join(',')}]'}'
            : 'memory unchanged',
      );
    }

    return parts.join(' · ');
  }
}
