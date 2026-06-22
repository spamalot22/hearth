import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Tenor (Google) API key, supplied at build/run time and never committed:
/// `flutter run --dart-define=TENOR_KEY=your_key`. Free key from the Google
/// Cloud console (enable the Tenor API). Empty (the default) disables search.
const String _tenorKey = String.fromEnvironment('TENOR_KEY');

bool get gifSearchEnabled => _tenorKey.isNotEmpty;

class _Gif {
  const _Gif(this.url, this.preview);
  final String url; // full GIF to send
  final String preview; // small GIF for the grid
}

Future<List<_Gif>> _searchTenor(String query) async {
  final res = await http.get(
    Uri.parse('https://tenor.googleapis.com/v2/search').replace(
      queryParameters: {
        'key': _tenorKey,
        'q': query,
        'limit': '24',
        'media_filter': 'gif,tinygif',
        'contentfilter': 'medium',
      },
    ),
  );
  if (res.statusCode != 200) {
    throw Exception('Tenor error ${res.statusCode}');
  }
  final results = (jsonDecode(res.body) as Map)['results'] as List;
  return results.map((r) {
    final formats = (r as Map)['media_formats'] as Map;
    final full = formats['gif'] as Map;
    final preview = (formats['tinygif'] ?? formats['gif']) as Map;
    return _Gif(full['url'] as String, preview['url'] as String);
  }).toList();
}

/// Shows a Giphy search sheet; resolves to the chosen GIF's URL, or null.
Future<String?> pickGif(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _GifSearchSheet(),
  );
}

class _GifSearchSheet extends StatefulWidget {
  const _GifSearchSheet();

  @override
  State<_GifSearchSheet> createState() => _GifSearchSheetState();
}

class _GifSearchSheetState extends State<_GifSearchSheet> {
  final _query = TextEditingController();
  Future<List<_Gif>>? _results;

  void _search() {
    final q = _query.text.trim();
    if (q.isNotEmpty) setState(() => _results = _searchTenor(q));
  }

  @override
  void dispose() {
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
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'Search GIFs',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _search,
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
    return FutureBuilder<List<_Gif>>(
      future: results,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const Center(child: Text('Search failed'));
        }
        final gifs = snapshot.data ?? const <_Gif>[];
        if (gifs.isEmpty) return const Center(child: Text('No results'));
        return GridView.count(
          crossAxisCount: 3,
          padding: const EdgeInsets.all(8),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final gif in gifs)
              GestureDetector(
                onTap: () => Navigator.pop(context, gif.url),
                child: Image.network(gif.preview, fit: BoxFit.cover),
              ),
          ],
        );
      },
    );
  }
}
