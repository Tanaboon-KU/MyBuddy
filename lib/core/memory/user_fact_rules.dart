/// Catches the handful of user facts the extraction pass demonstrably cannot.
///
/// Two measured failures motivate this, and neither is reachable from the
/// prompt - which this project has now established three separate times.
///
///  * `"I work as a software engineer."` was stored correctly in 0 of 57 runs.
///    The only three runs where those words reached memory at all filed them as
///    the user's *name* (`T26_lines/v7lines1_after.json`).
///  * An identity fact reaches `user.facts` only when the user says it in the
///    final turn before the pass runs. The same allergy sentence is lost at
///    position 3 and stored at position 4 (T26_lines §14, and §16 for what that
///    comparison does and does not control).
///
/// A rule reads the sentence when the user types it, which is the one moment
/// neither failure applies. It needs no model call, no session, and no prompt.
///
/// Scope is deliberately small: `name` and identity facts - an allergy, a job, a
/// home, a pet. `traits`, `preferences` and `goals` stay with the model, which
/// has measured wins on all three and which no rule is going to beat at reading
/// "I'm a very detail-oriented person."
///
/// The frames below are anchored at the start of the sentence on purpose. The
/// corpus contains `"You remember I told you I'm allergic to shellfish, right?"`
/// - a false premise the user never asserted - and an unanchored match on
/// `allergic to X` writes a shellfish allergy into a memory that is read back
/// into every prompt afterwards. Anchoring is what separates a disclosure from
/// a sentence that merely contains one.
///
/// What this cannot do: every sentence it has been tested against was written by
/// this project. The corpus is 52 distinct user sentences across 199 recorded
/// runs and contains no natural user text at all, so passing its tests is a
/// floor and not a generalisation. See `user_fact_rules_test.dart`.
final class UserFactRules {
  const UserFactRules();

  /// Everything the sentence discloses, or nothing. Never throws.
  List<RuleCapture> capture(String userTurn) {
    final text = userTurn.trim();
    if (text.isEmpty) return const <RuleCapture>[];

    // A question is a request for what is stored, not a statement of it. The
    // corpus has six of them naming the exact fields these rules write.
    if (text.endsWith('?')) return const <RuleCapture>[];

    final captures = <RuleCapture>[];
    for (final clause in _clauses(text)) {
      for (final rule in _rules) {
        final match = rule.pattern.firstMatch(clause);
        if (match == null) continue;
        final value = _tidy(match.group(1) ?? '');
        if (value.isEmpty) continue;
        captures.add(RuleCapture(rule.field, rule.render(value)));
        break;
      }
    }
    return captures;
  }

  /// Splits on `and` so one sentence can disclose twice, and on a comma so a
  /// trailing request - `"..., roasting me would cheer me up"` - cannot drag a
  /// mood into a frame that would otherwise not match it.
  static Iterable<String> _clauses(String text) =>
      text.split(RegExp(r',|\band\b')).map((c) => c.trim()).where((c) => c.isNotEmpty);

  static String _tidy(String raw) => raw
      .trim()
      .replaceFirst(RegExp(r'[.!,;]+$'), '')
      .trim();

  /// Anchored at the start of a clause, so a frame quoted inside a longer
  /// sentence does not fire. `(?:i am|i'm)` covers both spellings the corpus
  /// uses.
  static final List<_Rule> _rules = <_Rule>[
    // "My name is Nott." Not "I'm X": the corpus shows that frame carrying a
    // trait, a mood and a job.
    _Rule(
      field: 'name',
      pattern: RegExp(r"^(?:my name is|call me)\s+(.+)$", caseSensitive: false),
      render: (v) => v,
    ),
    _Rule(
      field: 'facts',
      pattern: RegExp(
        r"^(?:i am|i'm)\s+allergic\s+to\s+(.+)$",
        caseSensitive: false,
      ),
      render: (v) => 'allergic to $v',
    ),
    _Rule(
      field: 'facts',
      pattern: RegExp(
        r"^i\s+(?:work|working)\s+as\s+(?:an?\s+)?(.+)$",
        caseSensitive: false,
      ),
      render: (v) => 'works as a $v',
    ),
    _Rule(
      field: 'facts',
      pattern: RegExp(r"^i\s+live\s+in\s+(.+)$", caseSensitive: false),
      render: (v) => 'lives in $v',
    ),
    _Rule(
      field: 'facts',
      pattern: RegExp(
        r"^i\s+have\s+(?:a|an|two|three)\s+((?:dog|cat|pet|bird|rabbit)\b.*)$",
        caseSensitive: false,
      ),
      render: (v) => 'has a $v',
    ),
  ];
}

class RuleCapture {
  const RuleCapture(this.field, this.value);

  /// A user-layer field name: `name` or `facts`.
  final String field;

  /// The value to store, in the user's own words so that
  /// `ExtractionGrounding` accepts it.
  final String value;

  @override
  String toString() => '$field: $value';
}

class _Rule {
  const _Rule({
    required this.field,
    required this.pattern,
    required this.render,
  });

  final String field;
  final RegExp pattern;
  final String Function(String) render;
}
