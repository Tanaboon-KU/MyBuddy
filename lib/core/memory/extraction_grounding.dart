/// Whether a value the extraction pass produced came from the user at all.
///
/// T-26 measured the pass writing `Explore new hiking trails in Chiang Mai.`
/// into `user.goals` on three runs of a conversation where the user never
/// mentioned a goal. The sentence was assembled out of the assistant's own
/// question ("trails ... you'd like to explore?") and two things the user said
/// in two different turns. It then persisted, because the user layer is read
/// back into the prompt on every turn after that.
///
/// This does not make extraction work. It decides one narrower question - did
/// the words come from the user - and it is worth having on its own, because a
/// fact the companion invents about someone is worse than a fact it fails to
/// keep.
///
/// What it does not do:
///
///  * It checks provenance, not truth. Negation words are stopwords, so
///    "does not eat spicy food" and "eats spicy food" ground identically. A
///    pass that inverts the user's meaning is a different failure.
///  * A value recombined entirely out of one turn's own words would pass. The
///    ng case is caught because most of it came from elsewhere, not because
///    recombination is detected.
final class ExtractionGrounding {
  const ExtractionGrounding({this.threshold = defaultThreshold});

  /// Measured, not chosen. Every value the pass got right across the T-26 runs
  /// scores 1.00; the invented goal scores 0.33; the twelve values a person
  /// wrote by hand as E4's seeds - what a working extraction would produce -
  /// score 0.75 to 1.00. 0.6 sits in the gap with room on both sides.
  ///
  /// The sample behind that is small and repetitive: 18 extracted values but
  /// only two distinct sentences between them, against 12 hand-written
  /// paraphrases. Recompute this before trusting it further.
  static const double defaultThreshold = 0.6;

  final double threshold;

  /// Words that carry no evidence of where a value came from. Only entries of
  /// three characters or more are listed; anything shorter is already dropped.
  /// A word wrongly listed here can only make an invented value look more
  /// grounded, so the list is kept short.
  static const Set<String> _stopwords = <String>{
    'and', 'are', 'but', 'does', 'for', 'from', 'had', 'has', 'have', 'its',
    'not', 'that', 'the', 'this', 'was', 'will', 'with', 'you', 'your',
  };

  static final RegExp _word = RegExp(r"[a-z0-9']+");

  /// The share of the value's content words that appear in a single thing the
  /// user said. 0.0 when there is nothing to check.
  ///
  /// Scored against each turn separately and the best taken, rather than
  /// against the turns joined together. That is the difference between 0.33 and
  /// 0.50 on the ng case: every content word of the invented goal is somewhere
  /// in that conversation, but no one sentence the user typed holds them
  /// together.
  double score(String value, Iterable<String> userTurns) {
    final wanted = _contentWords(value);
    if (wanted.isEmpty) return 0.0;

    var best = 0.0;
    for (final turn in userTurns) {
      final said = _words(turn).map(_stem).toSet();
      if (said.isEmpty) continue;
      final found = wanted.where((w) => _wasSaid(_stem(w), said)).length;
      final fraction = found / wanted.length;
      if (fraction > best) best = fraction;
    }
    return best;
  }

  bool isGrounded(String value, Iterable<String> userTurns) =>
      score(value, userTurns) >= threshold;

  static List<String> _words(String text) =>
      _word.allMatches(text.toLowerCase()).map((m) => m[0]!).toList();

  static List<String> _contentWords(String value) => _words(
    value,
  ).where((w) => w.length >= 3 && !_stopwords.contains(w)).toList();

  /// Two words count as the same when they reduce to the same stem.
  ///
  /// The first version compared whole words and allowed one to be a prefix of
  /// the other. Six runs on the handset showed what that misses: the user said
  /// "I love hiking on weekends", the pass wrote "loving to hike on weekends",
  /// and neither `love`/`loving` nor `hike`/`hiking` is a prefix of the other -
  /// so a true statement by the user was refused, three times out of three.
  ///
  /// The threshold could not absorb it: the invented goal scores 0.33 and would
  /// have come back in. Reducing both sides first fixes the case and widens the
  /// margin instead of narrowing it - every value the pass has produced now
  /// scores 1.00, the twelve hand-written paraphrases 0.83 or better, and the
  /// invented goal is unmoved at 0.33.
  static bool _wasSaid(String wanted, Set<String> said) =>
      said.contains(wanted);

  /// Crude on purpose: enough English suffixes to match how the model rewords
  /// what it read, and no more. A real stemmer would be a dependency and a much
  /// larger behaviour change to justify against 30-odd measured values.
  static String _stem(String word) {
    var stem = word;
    for (final suffix in const <String>['ings', 'ing', 'ed', 'es', 's', 'e']) {
      if (stem.endsWith(suffix) && stem.length - suffix.length >= 3) {
        stem = stem.substring(0, stem.length - suffix.length);
        break;
      }
    }
    // run -> running doubles the consonant before the suffix, so undo it.
    if (stem.length >= 4 &&
        stem[stem.length - 1] == stem[stem.length - 2] &&
        !'aeiou'.contains(stem[stem.length - 1])) {
      stem = stem.substring(0, stem.length - 1);
    }
    return stem;
  }
}
