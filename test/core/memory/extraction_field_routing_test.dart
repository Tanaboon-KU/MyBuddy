import 'package:flutter_test/flutter_test.dart';
import 'package:mybuddy/core/memory/extraction_field_routing.dart';

/// The model finds the fact and files it in the wrong drawer.
///
/// Eighteen runs of the line format captured "allergic to peanuts" every time
/// and put it under `preferences` every time - six of those after the prompt
/// was changed to say, in as many words, "An allergy is a fact, not a
/// preference. So is a job, a home and a pet." The instruction changed nothing,
/// which is the same result T-26 reached about wording three configs earlier.
///
/// So the routing moves out of the prompt and into code. The model is left
/// doing the part it demonstrably does - noticing the fact is there.
void main() {
  const routing = ExtractionFieldRouting();

  test('an allergy is a fact wherever the model filed it', () {
    // Verbatim from the handset, six runs out of six.
    expect(routing.fieldFor('preferences', 'allergic to peanuts'), 'facts');
  });

  test('an allergy already filed correctly stays put', () {
    expect(routing.fieldFor('facts', 'allergic to peanuts'), 'facts');
  });

  test('other ways of saying it are caught too', () {
    expect(routing.fieldFor('preferences', 'has a peanut allergy'), 'facts');
    expect(routing.fieldFor('traits', 'Allergic to shellfish'), 'facts');
    expect(routing.fieldFor('preferences', 'allergies: peanuts'), 'facts');
  });

  test('a real preference is left alone', () {
    expect(routing.fieldFor('preferences', 'likes tea in the afternoons'), 'preferences');
    expect(routing.fieldFor('preferences', 'works best early'), 'preferences');
    expect(routing.fieldFor('traits', 'very detail-oriented'), 'traits');
  });

  test('nothing else is moved', () {
    // Only the case there is evidence for. "I work as a software engineer" was
    // never captured at all across eighteen runs - it is missing, not misfiled,
    // and a routing rule cannot fix a value that was never produced.
    expect(routing.fieldFor('preferences', 'works as a software engineer'), 'preferences');
    expect(routing.fieldFor('facts', 'lives in Chiang Mai'), 'facts');
    expect(routing.fieldFor('name', 'Nott'), 'name');
    expect(routing.fieldFor('goals', 'running a half marathon'), 'goals');
  });

  test('an unknown field is returned unchanged', () {
    expect(routing.fieldFor('mission', 'allergic to peanuts'), 'mission');
  });
}
