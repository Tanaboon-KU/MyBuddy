/// Reads the extraction pass's answer when it is asked for lines, not JSON.
///
/// T-26 measured 32 runs of asking Qwen2.5-1.5B q8 for a JSON patch. Across
/// three promptings it reproduced whatever JSON sat nearest the generation
/// point, could not keep its instructions apart from the conversation it was
/// analysing, and succeeded or failed on the *shape* of the conversation rather
/// than its content - the same sentence extracted from a five-turn chat and
/// failed alone, byte for byte. Nothing in the stack can constrain the output:
/// `flutter_gemma` as vendored exposes no grammar or schema hook.
///
/// The same model answers questions about a conversation perfectly well - E4
/// retrieved the right fact 7 times in 12 asked directly, and E2's re-run
/// applied one unprompted 8 times in 12. That is the ability this format uses.
/// Emitting `goals: run a half marathon` needs no balanced braces, no quoting
/// and no schema, so there is far less to get wrong.
///
/// Everything unrecognised is skipped rather than treated as an error. A model
/// that opens with "Sure! Here is what I found" should still have its answer
/// read; that preamble is the single most common thing it adds.
final class ExtractionLineFormat {
  const ExtractionLineFormat();

  /// The user-layer fields, and the only keys [parse] will return. A line
  /// naming `mission` or `assistant_name` - the config C failure - is dropped
  /// here rather than travelling further as a patch nobody will apply.
  static const List<String> fields = <String>[
    'name',
    'traits',
    'preferences',
    'goals',
    'facts',
  ];

  /// Ways of saying "the user did not tell me this".
  static const Set<String> _absent = <String>{
    'none',
    '(none)',
    'n/a',
    'na',
    'null',
    'nothing',
    'unknown',
    '-',
    '--',
  };

  static final RegExp _line = RegExp(
    r'^[\s\-*#>\d.)]*\**\s*(' +
        'name|traits|preferences|goals|facts' +
        r')\**\s*[:=]\s*(.*)$',
    caseSensitive: false,
  );

  /// Field name to the values given for it, in the order they appeared.
  ///
  /// A field named twice yields two values rather than one overwriting the
  /// other: the model listing two facts is the case that would silently lose
  /// one.
  Map<String, List<String>> parse(String raw) {
    final out = <String, List<String>>{};
    for (final rawLine in raw.split('\n')) {
      final match = _line.firstMatch(rawLine.trimRight());
      if (match == null) continue;
      final field = match[1]!.toLowerCase();
      final value = _clean(match[2]!);
      if (value == null) continue;
      out.putIfAbsent(field, () => <String>[]).add(value);
    }
    return out;
  }

  /// Whether the answer is in this format at all, whatever it says.
  ///
  /// [parse] returns nothing both for a model that answered NONE to every field
  /// and for one that ignored the format entirely, and those are different
  /// outcomes: the first is an ordinary turn where the user revealed nothing,
  /// the second is a failed pass. Only this can tell them apart.
  bool hasFieldLines(String raw) {
    for (final line in raw.split('\n')) {
      if (_line.hasMatch(line.trimRight())) return true;
    }
    return false;
  }

  /// Strips the decoration a chat model puts round a short answer, and returns
  /// null when what is left says nothing.
  static String? _clean(String raw) {
    var value = raw.trim();
    // Markdown emphasis around the whole value, e.g. **Nott**.
    while (value.length > 4 && value.startsWith('**') && value.endsWith('**')) {
      value = value.substring(2, value.length - 2).trim();
    }
    // One layer of quotes, then a full stop that belongs to the sentence the
    // model thought it was writing rather than to the value.
    if (value.length > 1 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    value = value.replaceFirst(RegExp(r'[.,;]+$'), '').trim();
    if (value.length > 1 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.isEmpty) return null;
    if (_absent.contains(value.toLowerCase())) return null;
    return value;
  }
}
