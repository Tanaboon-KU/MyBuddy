/// Corrects which user-layer field a value belongs in.
///
/// The extraction pass finds facts and files them badly. Eighteen runs of the
/// line format captured "allergic to peanuts" from "I'm allergic to peanuts"
/// every single time - the fact the JSON pass never once managed to extract -
/// and put it under `preferences` every single time. Six of those runs were
/// after the prompt was changed to say outright that an allergy is a fact and
/// not a preference. The instruction made no difference at all, which is the
/// conclusion T-26 had already reached about prompt wording on this model.
///
/// So the work is split along the line the measurements actually draw: the
/// model notices the fact, and code decides where it goes. That is a much
/// smaller claim than the pattern-rule proposal in T-26 item 2 - this does not
/// have to find anything, only correct a label on something already found.
///
/// Deliberately one rule. `preferences` swallowing an allergy is the only
/// misrouting there is evidence for. "I work as a software engineer" is a
/// different problem: across those eighteen runs it was never captured at all,
/// and no routing rule can move a value that was never produced.
final class ExtractionFieldRouting {
  const ExtractionFieldRouting();

  /// Matches the ways the pass has been seen to word an allergy, and the
  /// ordinary ways a person states one. Bounded on the left so "allergic" is
  /// not found inside another word.
  static final RegExp _allergy = RegExp(
    r'\ballerg(y|ic|ies)\b',
    caseSensitive: false,
  );

  /// Fields this may move a value between. A name outside this set is left
  /// alone rather than pulled into the user layer, which would change what
  /// section the value belongs to rather than which drawer of one.
  static const Set<String> _userFields = <String>{
    'name',
    'traits',
    'preferences',
    'goals',
    'facts',
  };

  /// The field this value belongs in, given the one the model named.
  ///
  /// Returns [declaredField] unchanged when there is no rule for the value,
  /// including for fields this class knows nothing about.
  String fieldFor(String declaredField, String value) {
    if (!_userFields.contains(declaredField)) return declaredField;
    if (_allergy.hasMatch(value)) return 'facts';
    return declaredField;
  }
}
