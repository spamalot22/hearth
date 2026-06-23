import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Sound search goes through the relay's `/sound/search` proxy (Freesound, CC0),
/// so the API token lives on the relay — never in the client. The chosen clip's
/// preview bytes are fetched and stored as a blob on send, like GIFs.

class _Sound {
  const _Sound(this.url, this.name);
  final String url; // preview clip to fetch + store
  final String name;
}

class _SoundResult {
  const _SoundResult.ok(this.sounds) : unavailable = null;
  const _SoundResult.unavailable(this.unavailable) : sounds = const [];

  final List<_Sound> sounds;
  final String? unavailable;
}

Future<_SoundResult> _search(Uri relayUrl, String query) async {
  final http.Response res;
  try {
    res = await http.get(
      relayUrl.replace(path: '/sound/search', queryParameters: {'q': query}),
    );
  } catch (_) {
    return const _SoundResult.unavailable(
      "Can't reach the relay — it may be offline.",
    );
  }
  if (res.statusCode != 200) {
    return const _SoundResult.unavailable('Sound search is unavailable now.');
  }
  final body = jsonDecode(res.body) as Map;
  if (body['configured'] == false) {
    return const _SoundResult.unavailable('This relay has no sound provider.');
  }
  final sounds = (body['sounds'] as List)
      .map((s) => _Sound((s as Map)['preview'] as String, s['name'] as String))
      .toList();
  return _SoundResult.ok(sounds);
}

/// Shows a sound search sheet; resolves to the chosen clip (url + name), or null.
Future<({String url, String name})?> pickSound(
  BuildContext context,
  Uri relayUrl,
) {
  return showModalBottomSheet<({String url, String name})>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _SoundSearchSheet(relayUrl: relayUrl),
  );
}

class _SoundSearchSheet extends StatefulWidget {
  const _SoundSearchSheet({required this.relayUrl});

  final Uri relayUrl;

  @override
  State<_SoundSearchSheet> createState() => _SoundSearchSheetState();
}

class _SoundSearchSheetState extends State<_SoundSearchSheet> {
  final _query = TextEditingController();
  Future<_SoundResult>? _results;
  Timer? _debounce;

  // Search as you type, debounced so we don't fire on every keystroke.
  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  void _runSearch() {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    // Block body: an arrow here would *return* the Future to setState, which
    // throws "callback returned a Future".
    setState(() {
      _results = _search(widget.relayUrl, q);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 440,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (_) => _onChanged(),
                onSubmitted: (_) => _runSearch(),
                decoration: InputDecoration(
                  hintText: 'Search sounds (Freesound, CC0)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _runSearch,
                  ),
                ),
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final results = _results;
    if (results == null) {
      return const Center(child: Text('Search for a sound'));
    }
    return FutureBuilder<_SoundResult>(
      future: results,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final result = snapshot.data;
        if (result == null || result.unavailable != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(result?.unavailable ?? 'Sound search failed.'),
            ),
          );
        }
        if (result.sounds.isEmpty) {
          return const Center(child: Text('No results'));
        }
        return ListView(
          children: [
            for (final sound in result.sounds)
              ListTile(
                leading: const Icon(Icons.music_note_outlined),
                title: Text(sound.name),
                onTap: () =>
                    Navigator.pop(context, (url: sound.url, name: sound.name)),
              ),
          ],
        );
      },
    );
  }
}
