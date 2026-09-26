// SPDX-License-Identifier: AGPL-3.0-or-later
import 'content.dart';

/// Metadata from a verified message, not a voter identity supplied in JSON.
class PollEvent {
  const PollEvent(this.id, this.author, this.content);
  final String id;
  final String author;
  final Content content;
}

class PollResults {
  PollResults(this.poll, Map<String, int> votes)
    : votes = Map.unmodifiable(votes),
      counts = List.unmodifiable(
        List.generate(
          poll.options.length,
          (option) => votes.values.where((vote) => vote == option).length,
        ),
      );

  final PollContent poll;
  final Map<String, int> votes;
  final List<int> counts;
  int get total => votes.length;
}

/// Rebuild from the channel's deterministic causal order, not arrival order.
/// A second pass handles votes whose poll arrived later, including cache eviction.
Map<String, PollResults> buildPollResults(Iterable<PollEvent> ordered) {
  final polls = <String, PollContent>{};
  for (final event in ordered) {
    if (event.content case final PollContent poll) polls[event.id] = poll;
  }
  final votes = <String, Map<String, int>>{};
  for (final event in ordered) {
    final content = event.content;
    if (content is! PollVoteContent || !content.isValid) continue;
    final poll = polls[content.targetId];
    if (poll == null) continue;
    final option = content.option;
    if (option != null && option >= poll.options.length) continue;
    final tally = votes.putIfAbsent(content.targetId, () => {});
    if (option == null) {
      tally.remove(event.author);
    } else {
      tally[event.author] = option;
    }
  }
  return Map.unmodifiable({
    for (final entry in polls.entries)
      entry.key: PollResults(entry.value, votes[entry.key] ?? {}),
  });
}
