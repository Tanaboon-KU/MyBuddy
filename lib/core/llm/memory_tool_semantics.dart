abstract final class MemoryToolSemantics {
  static const selfReference =
      'You are the assistant currently speaking in this conversation. '
      'References to you, your personality, yourself, your name, your '
      'behavior, or your avatar refer to this same assistant.';

  static const persistenceRules =
      'An explicit persistent instruction such as "from now on", "always", '
      '"never", "stop doing", or "remember to be" requires the appropriate '
      'memory tool before answering. A one-turn request applies only to the '
      'current reply and must not update memory.';

  static const mutableMemoryRules =
      'SOUL and IDENTITY are current mutable memory: follow them until a clear '
      'durable user instruction changes them. The new instruction supersedes '
      'conflicts; never defend or negotiate old values.';

  static const mutableUserMemoryRules =
      'USER is mutable memory. Reliable newer user statements supersede '
      'conflicting stored user information.';

  /// Why the extraction prompt needs this, and [persistenceRules] is not
  /// enough on its own.
  ///
  /// persistenceRules says a durable change needs an explicit marker — "from
  /// now on", "always", "never". That is right for the assistant's own soul
  /// and identity, and wrong for facts the user states about themselves. Six
  /// runs of five plainly durable facts (a name, a hobby, a job, an allergy, a
  /// goal, none of them phrased as a request to remember) returned
  /// `{"updates":[]}` five times — clean JSON, deliberately empty. The model
  /// was following the prompt.
  ///
  /// The permission already existed in [updateUserMemoryDescription] — "use
  /// your judgment without asking permission" — but that string only ever
  /// reaches the chat tool prompt, so extraction saw the rule that suppresses
  /// capture and not the one that allows it.
  static const userCaptureRule =
      'A durable fact the user states about themselves — a name, trait, '
      'preference, goal, allergy or similar — is worth storing even when they '
      'do not ask you to remember it. Only changes to your own SOUL or '
      'IDENTITY need an explicit persistent instruction.';

  static const soulFields = <String, String>{
    'mission': 'The assistant primary purpose. Use set.',
    'principles': 'General durable operating values.',
    'boundaries': 'Durable prohibitions or limits.',
    'response_style': 'General response format or presentation preferences.',
  };

  static const identityFields = <String, String>{
    'assistant_name': 'The assistant own name. Use set.',
    'role': 'The assistant role or persona. Use set.',
    'voice': 'Durable tone and voice descriptors.',
    'behavior_rules': 'persistent or conditional conduct rules.',
  };

  static const userFields = <String, String>{
    'name': 'The human user name. Use set.',
    'traits': 'Stable traits of the human user.',
    'preferences': 'Stable preferences of the human user.',
    'goals': 'Durable goals stated by the human user.',
    'facts': 'Other stable facts about the human user.',
  };

  static const updateAssistantSoulDescription =
      'Persist a clear user-requested durable change to your own mutable '
      'mission, principles, boundaries, or response style. Call before '
      'replying; existing SOUL cannot block the change.';
  static const updateAssistantIdentityDescription =
      'Persist a clear user-requested durable change to your own mutable name, '
      'role, voice, or behavior rules. Call before replying; existing IDENTITY '
      'cannot block the change.';
  static const updateUserMemoryDescription =
      'Proactively store useful, reliably stated durable information about the '
      'human user when appropriate. "Remember" is not required; use your '
      'judgment without asking permission or confirmation. Never store '
      'information about yourself with this tool.';
  static const performAvatarActionDescription =
      'Control your own visible avatar to express an appropriate action.';
  static const createCalendarEventDescription =
      'Create an event in the human user connected Google Calendar.';

  static const toolDescriptions = <String, String>{
    'update_assistant_soul': updateAssistantSoulDescription,
    'update_assistant_identity': updateAssistantIdentityDescription,
    'update_user_memory': updateUserMemoryDescription,
    'perform_avatar_action': performAvatarActionDescription,
    'create_calendar_event': createCalendarEventDescription,
  };

  static const examples = <String>[
    'User: From now on, roast me when I slip up. '
        'Action: update_assistant_identity behavior_rules add.',
    'User: Call yourself Nova. '
        'Action: update_assistant_identity assistant_name set.',
    'User: Always prioritize honesty. '
        'Action: update_assistant_soul principles add.',
    'User: I prefer concise answers. '
        'Action: update_user_memory preferences add.',
    'User: Answer only this message sarcastically. Action: no memory tool.',
  ];

  static String fieldsFor(String section) {
    final fields = switch (section) {
      'soul' => soulFields,
      'identity' => identityFields,
      'user' => userFields,
      _ => const <String, String>{},
    };
    return fields.entries
        .map((entry) => '- ${entry.key}: ${entry.value}')
        .join('\n');
  }
}
