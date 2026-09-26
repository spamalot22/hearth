// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'content.dart';
import 'polls.dart';

Future<void> showCreatePollDialog(
  BuildContext context, {
  required Future<bool> Function(PollContent) onCreate,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _CreatePollDialog(onCreate: onCreate),
);

class _CreatePollDialog extends StatefulWidget {
  const _CreatePollDialog({required this.onCreate});
  final Future<bool> Function(PollContent) onCreate;
  @override
  State<_CreatePollDialog> createState() => _CreatePollDialogState();
}

class _CreatePollDialogState extends State<_CreatePollDialog> {
  final _question = TextEditingController();
  final _options = [TextEditingController(), TextEditingController()];
  // Keep removed controllers alive until their text fields have unmounted.
  final _removed = <TextEditingController>[];
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _question.dispose();
    for (final controller in [..._options, ..._removed]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final question = _question.text.trim();
    final options = _options
        .map((controller) => controller.text.trim())
        .toList();
    final error = PollContent.validationError(question, options);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var saved = false;
    try {
      saved = await widget.onCreate(PollContent(question, options));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() => _error = 'Poll not saved. Your draft is still here.');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Create poll'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('poll-question'),
                controller: _question,
                enabled: !_saving,
                maxLines: 3,
                minLines: 1,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(
                    PollContent.maxQuestionLength,
                  ),
                ],
                decoration: const InputDecoration(labelText: 'Question'),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _options.length; i++)
                Row(
                  key: ObjectKey(_options[i]),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        key: Key('poll-option-$i'),
                        controller: _options[i],
                        enabled: !_saving,
                        minLines: 1,
                        maxLines: 3,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(
                            PollContent.maxOptionLength,
                          ),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Option ${i + 1}',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove option ${i + 1}',
                      onPressed: _saving || _options.length <= 2
                          ? null
                          : () => setState(() {
                              _removed.add(_options.removeAt(i));
                            }),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed:
                      _saving || _options.length >= PollContent.maxOptions
                      ? null
                      : () => setState(
                          () => _options.add(TextEditingController()),
                        ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add option'),
                ),
              ),
              const Text(
                'Single choice. Votes are visible to channel members.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: const Icon(Icons.poll_outlined),
          label: Text(_saving ? 'Posting...' : 'Post poll'),
        ),
      ],
    ),
  );
}

class PollBubble extends StatefulWidget {
  const PollBubble({
    required this.results,
    required this.self,
    required this.onVote,
    required this.voterName,
    this.enabled = true,
    super.key,
  });
  final PollResults results;
  final String self;
  final Future<bool> Function(int?) onVote;
  final String Function(String) voterName;
  final bool enabled;
  @override
  State<PollBubble> createState() => _PollBubbleState();
}

class _PollBubbleState extends State<PollBubble> {
  bool _saving = false;
  bool _failed = false;

  Future<void> _vote(int? option) async {
    if (_saving ||
        !widget.enabled ||
        widget.results.votes[widget.self] == option) {
      return;
    }
    setState(() {
      _saving = true;
      _failed = false;
    });
    var saved = false;
    try {
      saved = await widget.onVote(option);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _saving = false;
        _failed = !saved;
      });
    }
  }

  void _showVotes() {
    final results = widget.results;
    final voters = results.votes.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Votes'),
        content: SizedBox(
          width: 360,
          height: 320,
          child: voters.isEmpty
              ? const Center(child: Text('No votes yet'))
              : ListView.builder(
                  itemCount: voters.length,
                  itemBuilder: (context, index) {
                    final vote = voters[index];
                    return ListTile(
                      title: Text(widget.voterName(vote.key)),
                      subtitle: Text(results.poll.options[vote.value]),
                      leading: const Icon(Icons.how_to_vote_outlined),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.results;
    final choice = results.votes[widget.self];
    final theme = Theme.of(context);
    return SizedBox(
      width: 340,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(results.poll.question, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Single choice - visible votes',
              style: theme.textTheme.labelSmall,
            ),
            RadioGroup<int>(
              groupValue: choice,
              onChanged: _vote,
              child: Column(
                children: [
                  for (var i = 0; i < results.poll.options.length; i++)
                    RadioListTile<int>(
                      key: Key('poll-choice-$i'),
                      value: i,
                      enabled: !_saving && widget.enabled,
                      contentPadding: EdgeInsets.zero,
                      title: Text(results.poll.options[i]),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${results.counts[i]} votes - ${results.total == 0 ? 0 : (results.counts[i] * 100 / results.total).round()}%',
                          ),
                          LinearProgressIndicator(
                            value: results.total == 0
                                ? 0
                                : results.counts[i] / results.total,
                            minHeight: 3,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Text(
                  '${results.total} ${results.total == 1 ? 'vote' : 'votes'}',
                ),
                IconButton(
                  tooltip: 'View votes',
                  onPressed: _showVotes,
                  icon: const Icon(Icons.people_outline),
                ),
                if (choice != null)
                  TextButton.icon(
                    onPressed: _saving || !widget.enabled
                        ? null
                        : () => _vote(null),
                    icon: const Icon(Icons.undo),
                    label: const Text('Remove vote'),
                  ),
                if (_saving)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_failed)
              Text(
                'Vote not saved. Try again.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
