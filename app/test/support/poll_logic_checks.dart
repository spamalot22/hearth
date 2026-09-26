// SPDX-License-Identifier: AGPL-3.0-or-later
// Pure Dart checks: also runnable outside the Flutter package/native hooks.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:math';

import '../../lib/content.dart';
import '../../lib/polls.dart';

int checkPollLogic() {
  var checks = 0;
  void check(bool value, String label) {
    checks++;
    if (!value) throw StateError(label);
  }

  final id = 'ab' * 34;
  final poll = PollContent(' Lunch? ', [' Pizza ', 'Soup']);
  final decoded = parseContent(poll.encode()) as PollContent;
  check(decoded.question == 'Lunch?', 'trim question');
  check(decoded.options.join(',') == 'Pizza,Soup', 'option round trip');
  for (final option in [null, 0, 1]) {
    final vote = parseContent(PollVoteContent(id, option).encode());
    check(
      vote is PollVoteContent && vote.option == option && vote.targetId == id,
      'vote round trip',
    );
    check(vote.isBookkeeping, 'votes hidden from timeline');
  }
  final bad = <Map<String, Object?>>[
    {
      't': 'poll',
      'question': '',
      'options': ['A', 'B'],
    },
    {
      't': 'poll',
      'question': 'Q',
      'options': ['A'],
    },
    {
      't': 'poll',
      'question': 'Q',
      'options': ['A', 'a'],
    },
    {
      't': 'poll',
      'question': 'Q',
      'options': ['A', ' '],
    },
    {
      't': 'poll',
      'question': 'Q',
      'options': ['A', 1],
    },
    {
      't': 'poll',
      'question': true,
      'options': ['A', 'B'],
    },
    {
      't': 'poll',
      'question': 'Q' * 241,
      'options': ['A', 'B'],
    },
    {
      't': 'poll',
      'question': 'Q',
      'options': ['A' * 101, 'B'],
    },
    {'t': 'poll', 'question': 'Q', 'options': List.generate(11, (i) => '$i')},
    {'t': 'poll', 'question': 'Q', 'options': {}},
    {'t': 'poll_vote', 'target': id},
    {'t': 'poll_vote', 'target': id, 'option': -1},
    {'t': 'poll_vote', 'target': id, 'option': 10},
    {'t': 'poll_vote', 'target': id, 'option': 1.5},
    {'t': 'poll_vote', 'target': id, 'option': true},
    {'t': 'poll_vote', 'target': id, 'option': '0'},
    {'t': 'poll_vote', 'target': 'not-an-id', 'option': 0},
  ];
  for (final data in bad) {
    final content = parseContent(utf8.encode(jsonEncode(data)));
    check(
      content is InvalidPollContent && content.isBookkeeping,
      'reject malformed $data',
    );
  }
  final sourceOptions = ['A', 'B'];
  final immutable = PollContent('Q', sourceOptions);
  sourceOptions[0] = 'changed';
  check(immutable.options[0] == 'A', 'definition copies options');
  try {
    immutable.options[0] = 'changed';
    throw StateError('options were mutable');
  } on UnsupportedError {
    checks++;
  }

  final events = [
    PollEvent(id, 'creator', poll),
    PollEvent('v1', 'alice', PollVoteContent(id, 0)),
    PollEvent('v2', 'bob', PollVoteContent(id, 1)),
    PollEvent('v3', 'alice', PollVoteContent(id, 1)),
    PollEvent('bad', 'alice', PollVoteContent(id, 9)),
    PollEvent('foreign', 'bob', PollVoteContent('cd' * 34, 0)),
  ];
  var results = buildPollResults(events)[id]!;
  check(
    results.total == 2 && results.counts.join(',') == '0,2',
    'one vote per author, invalid cannot overwrite',
  );
  events.add(PollEvent('withdraw', 'alice', PollVoteContent(id, null)));
  results = buildPollResults(events)[id]!;
  check(
    results.total == 1 && !results.votes.containsKey('alice'),
    'withdraw vote',
  );
  final spoof = parseContent(
    utf8.encode(
      jsonEncode({'t': 'poll_vote', 'target': id, 'option': 0, 'voter': 'bob'}),
    ),
  );
  events.add(PollEvent('spoof', 'mallory', spoof));
  results = buildPollResults(events)[id]!;
  check(
    results.votes['bob'] == 1 && results.votes['mallory'] == 0,
    'payload cannot choose voter',
  );
  check(
    buildPollResults(events.skip(1)).isEmpty,
    'orphan votes do not create polls',
  );

  // Compare replay against an independent one-choice-per-author reference.
  final random = Random(42);
  final reference = <String, int>{};
  final replay = <PollEvent>[PollEvent(id, 'creator', poll)];
  for (var i = 0; i < 500; i++) {
    final author = 'root-${random.nextInt(30)}';
    final choice = random.nextInt(4);
    final int? option = choice == 2 ? null : choice;
    replay.add(PollEvent('vote-$i', author, PollVoteContent(id, option)));
    if (option == null) {
      reference.remove(author);
    } else if (option < 2) {
      reference[author] = option;
    }
    final tally = buildPollResults(replay)[id]!;
    check(tally.total == reference.length, 'replay voter count $i');
    check(
      tally.votes.entries.every((e) => reference[e.key] == e.value),
      'replay choices $i',
    );
    check(
      tally.counts.reduce((a, b) => a + b) == tally.total,
      'replay total $i',
    );
  }
  return checks;
}
