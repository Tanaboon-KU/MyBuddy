import 'package:flutter/foundation.dart';

import 'turn_log.dart';

/// Collects one [TurnLogEntry] per turn and renders them as CSV.
///
/// Protocol section 1b. Rows are held in memory and exported on demand rather
/// than appended to disk per turn: a file write between the reply and the
/// extraction pass would land inside the window `extract_start_ms` measures.
///
/// A turn is recorded in two phases. [beginTurn] opens a row as soon as the
/// reply is complete; [completeExtraction] fills in the extraction columns
/// when the write path finishes, which can be a minute later. Rows are
/// therefore mutable until their extraction resolves.
class TurnLogRecorder extends ChangeNotifier {
  TurnLogRecorder({this.maxEntries = 2000});

  /// Safety cap. A protocol block is at most a few hundred turns, so this only
  /// matters if the app is left running; oldest rows are dropped first and the
  /// drop is logged rather than silent.
  final int maxEntries;

  final List<TurnLogEntry> _entries = <TurnLogEntry>[];
  int _droppedEntries = 0;

  List<TurnLogEntry> get entries => List<TurnLogEntry>.unmodifiable(_entries);
  int get length => _entries.length;
  int get droppedEntries => _droppedEntries;

  TurnLogEntry? get last => _entries.isEmpty ? null : _entries.last;

  void add(TurnLogEntry entry) {
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      final overflow = _entries.length - maxEntries;
      _entries.removeRange(0, overflow);
      _droppedEntries += overflow;
      debugPrint(
        'TurnLogRecorder: dropped $overflow oldest row(s) '
        '($_droppedEntries total) - export more often',
      );
    }
    notifyListeners();
  }

  /// Replaces the row for [sessionId]/[turnIndex]. No-op when the row is gone.
  void update(
    String sessionId,
    int turnIndex,
    TurnLogEntry Function(TurnLogEntry current) transform,
  ) {
    final index = _entries.lastIndexWhere(
      (e) => e.sessionId == sessionId && e.turnIndex == turnIndex,
    );
    if (index < 0) {
      debugPrint(
        'TurnLogRecorder: no row for $sessionId/turn $turnIndex to update',
      );
      return;
    }
    _entries[index] = transform(_entries[index]);
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    _droppedEntries = 0;
    notifyListeners();
  }

  /// CSV with a header row. Always includes the header, even when empty, so an
  /// exported file is never ambiguous about which columns it holds.
  String toCsv() {
    final buffer = StringBuffer()..writeln(TurnLogEntry.csvHeader);
    for (final entry in _entries) {
      buffer.writeln(entry.toCsvRow());
    }
    return buffer.toString();
  }
}
