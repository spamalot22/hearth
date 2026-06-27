// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// GIF search goes through the relay's `/gif/search` proxy, so the Tenor API key
/// lives on the relay — never in the client. When the relay is unreachable or
/// has no key, the sheet falls back to pasting a GIF URL, with an explanation.

class _Gif {
  const _Gif(this.url, this.preview);
  final String url; // full GIF to send
  final String preview; // small GIF for the grid
}

/// A search outcome: results, or a reason it's [unavailable] (→ URL fallback).
class _GifResult {
  const _GifResult.ok(this.gifs) : unavailable = null;
  const _GifResult.unavailable(this.unavailable) : gifs = const [];

  final List<_Gif> gifs;
  final String? unavailable;
}

Future<_GifResult> _search(Uri relayUrl, String query) async {
  final http.Response res;
  try {
    res = await http.get(
      relayUrl.replace(path: '/gif/search', queryParameters: {'q': query}),
    );
  } catch (_) {
    return const _GifResult.unavailable(
      "Can't reach the relay — it may be offline.",
    );
  }
  if (res.statusCode != 200) {
    return const _GifResult.unavailable(
      'GIF search is unavailable on this relay right now.',
    );
  }
  final body = jsonDecode(res.body) as Map;
  if (body['configured'] == false) {
    return const _GifResult.unavailable(
      'This relay has no GIF provider set up.',
    );
  }
  final gifs = (body['gifs'] as List)
      .map((g) => _Gif((g as Map)['url'] as String, g['preview'] as String))
      .toList();
  return _GifResult.ok(gifs);
}

/// Shows a GIF search sheet; resolves to the chosen GIF's URL, or null.
Future<String?> pickGif(BuildContext context, Uri relayUrl) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _GifSearchSheet(relayUrl: relayUrl),
  );
}

class _GifSearchSheet extends StatefulWidget {
  const _GifSearchSheet({required this.relayUrl});

  final Uri relayUrl;

  @override
  State<_GifSearchSheet> createState() => _GifSearchSheetState();
}

class _GifSearchSheetState extends State<_GifSearchSheet> {
  final _query = TextEditingController();
  final _url = TextEditingController();
  Future<_GifResult>? _results;
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

  void _sendUrl() {
    final url = _url.text.trim();
    if (url.isNotEmpty) Navigator.pop(context, url);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _url.dispose();
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
                  hintText: 'Search GIFs',
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
      return const Center(child: Text('Search for a GIF'));
    }
    return FutureBuilder<_GifResult>(
      future: results,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final result = snapshot.data;
        if (result == null) return _fallback('GIF search failed.');
        if (result.unavailable != null) return _fallback(result.unavailable!);
        if (result.gifs.isEmpty) {
          return const Center(child: Text('No results'));
        }
        return GridView.count(
          crossAxisCount: 3,
          padding: const EdgeInsets.all(8),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final gif in result.gifs)
              GestureDetector(
                onTap: () => Navigator.pop(context, gif.url),
                child: Image.network(
                  gif.preview,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const ColoredBox(color: Colors.black12),
                  errorBuilder: (context, error, stack) => const ColoredBox(
                    color: Colors.black26,
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Shown when search isn't available — explain, and offer a URL paste.
  Widget _fallback(String reason) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_off_outlined),
              const SizedBox(width: 8),
              Expanded(child: Text(reason)),
            ],
          ),
          const SizedBox(height: 16),
          const Text('Paste a GIF URL instead:'),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _sendUrl(),
            decoration: const InputDecoration(
              hintText: 'https://…/something.gif',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: _sendUrl, child: const Text('Send')),
          ),
        ],
      ),
    );
  }
}
