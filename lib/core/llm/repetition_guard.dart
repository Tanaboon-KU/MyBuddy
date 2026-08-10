/// Spots the degenerate output both generation paths on this build fall into.
///
/// Measured twice, on different paths:
///
/// * **T-28, extraction.** After the T-07 fix removed the schema template the
///   model used to copy, a failing pass went from 6.7s and 25 characters to
///   178s and 5,438 - three minutes of compute for a result that failed to
///   parse either way.
/// * **T-30, the reply the user reads.** Two of E4's twenty-four replies ended
///   this way with no tool call involved, so it is not the rejected-tool-call
///   breakage of T-24.
///
/// ## Why not periodicity
///
/// The obvious detector - is the tail an exact repeat of some short block -
/// was tried against the real 5,438-character sample first and finds nothing:
/// no period under 60 repeats even three times. The collapse is not a clean
/// loop, it is one motif drowning everything else while junk keeps landing
/// between the copies:
///
/// ```
/// !%!%!%!% 200!%!%izing%!%!%!%-11%!!!%!%!%!%!%! !!%!%!%!!%!%!%!%!%!%!%!%-11!%
/// ```
///
/// What does separate it is diversity: count the distinct trigrams in the tail
/// and divide by how many there are. Degenerate text keeps reusing a few.
///
/// ## Where the threshold comes from
///
/// Calibrated against every sample of both kinds this project has, not chosen
/// by eye. Distinct-trigram ratio over the last 200 characters:
///
/// | sample | ratio |
/// |---|---|
/// | E1 extraction runaway (5,438 chars) | **0.56** |
/// | E4 pair 10 reply (1,244 chars) | **0.60** |
/// | 22 replies scored as ordinary text | 0.77 - 1.00 |
///
/// 0.70 sits in the gap, catching both collapses with no false positive on any
/// of the 22. The margin either side is about 0.1.
///
/// **It does not catch everything.** E4 pair 6 collapsed into incoherence
/// rather than repetition - *"the afternoon might befits when you might find.
/// This can be when you have 360 your energy levels and."* - and scores 0.79,
/// inside the ordinary range. Nothing here will flag it, and a threshold moved
/// far enough to would start flagging real replies. Two of the three known
/// collapses is what this is, and the sample behind the number is 3 positives
/// against 22 negatives, so it is worth re-deriving if more are collected.
final class RepetitionGuard {
  const RepetitionGuard({
    this.window = 200,
    this.gram = 3,
    this.minLength = 120,
    this.minDistinctRatio = 0.70,
  });

  /// How much of the tail to judge. The collapse can start well into an
  /// otherwise sound reply, so judging the whole string would let the healthy
  /// beginning outvote the broken end.
  final int window;

  /// n-gram length. 3 separates the samples; 1 counts only the alphabet and 2
  /// scores the `!%` motif too generously.
  final int gram;

  /// Below this, no judgement is made at all. Short text has few trigrams and
  /// a legitimately low ratio - "Your name is Nott." is 18 characters. Every
  /// measured collapse ran past 800.
  final int minLength;

  /// Distinct trigrams over total, under which the tail counts as collapsed.
  final double minDistinctRatio;

  /// Distinct-trigram ratio of [text]'s tail, or null when it is too short to
  /// judge. Exposed so a caller can log the number it decided on rather than
  /// only the verdict.
  double? distinctRatio(String text) {
    if (text.length < minLength) return null;
    final tail = text.length > window
        ? text.substring(text.length - window)
        : text;
    if (tail.length <= gram) return null;

    final seen = <String>{};
    final total = tail.length - gram + 1;
    for (var i = 0; i < total; i++) {
      seen.add(tail.substring(i, i + gram));
    }
    return seen.length / total;
  }

  /// Whether [text] has collapsed. False for anything shorter than
  /// [minLength], so a caller may check on every token without special-casing
  /// the start of a stream.
  bool hasCollapsed(String text) {
    final ratio = distinctRatio(text);
    return ratio != null && ratio < minDistinctRatio;
  }
}
