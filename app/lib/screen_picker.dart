// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'screen_share.dart';

/// What the picker returns: the chosen capture source + resolution.
typedef ScreenShareChoice = ({
  DesktopCapturerSource source,
  ScreenResolution resolution,
});

/// Shows the Discord-style "share your screen" picker: a grid of screens and
/// open windows (with thumbnails) plus a resolution selector. Resolves to the
/// chosen source + resolution, or null if cancelled.
Future<ScreenShareChoice?> showScreenSharePicker(BuildContext context) {
  return showDialog<ScreenShareChoice>(
    context: context,
    builder: (_) => const _ScreenSharePicker(),
  );
}

class _ScreenSharePicker extends StatefulWidget {
  const _ScreenSharePicker();

  @override
  State<_ScreenSharePicker> createState() => _ScreenSharePickerState();
}

class _ScreenSharePickerState extends State<_ScreenSharePicker> {
  late Future<List<DesktopCapturerSource>> _sources;
  ScreenResolution _resolution = ScreenResolution.fhd;

  @override
  void initState() {
    super.initState();
    _sources = _load();
  }

  Future<List<DesktopCapturerSource>> _load() async {
    // Brief delay lets the OS release the previous capture session so
    // thumbnails are available again (Windows clears them mid-capture).
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return desktopCapturer.getSources(
      types: const [SourceType.Screen, SourceType.Window],
      thumbnailSize: ThumbnailSize(320, 180),
    );
  }

  void _refresh() => setState(() => _sources = _load());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Share your screen', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: 'Cancel',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Resolution', style: theme.textTheme.labelLarge),
                  const SizedBox(width: 12),
                  DropdownButton<ScreenResolution>(
                    value: _resolution,
                    onChanged: (r) {
                      if (r != null) setState(() => _resolution = r);
                    },
                    items: [
                      for (final r in ScreenResolution.values)
                        DropdownMenuItem(value: r, child: Text(r.label)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: FutureBuilder<List<DesktopCapturerSource>>(
                  future: _sources,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Text(
                          "Couldn't list windows: ${snap.error}",
                          style: TextStyle(color: theme.colorScheme.error),
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    final sources = snap.data ?? const [];
                    final screens = sources
                        .where((s) => s.type == SourceType.Screen)
                        .toList();
                    final windows = sources
                        .where((s) => s.type == SourceType.Window)
                        .toList();
                    if (sources.isEmpty) {
                      return const Center(child: Text('Nothing to share'));
                    }
                    return ListView(
                      children: [
                        if (screens.isNotEmpty) ...[
                          _sectionLabel(theme, 'SCREENS'),
                          _grid(screens),
                        ],
                        if (windows.isNotEmpty) ...[
                          _sectionLabel(theme, 'WINDOWS'),
                          _grid(windows),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Text(text, style: theme.textTheme.labelSmall),
  );

  Widget _grid(List<DesktopCapturerSource> sources) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [for (final s in sources) _SourceCard(source: s, onPick: _pick)],
  );

  void _pick(DesktopCapturerSource source) =>
      Navigator.of(context).pop((source: source, resolution: _resolution));
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.source, required this.onPick});

  final DesktopCapturerSource source;
  final void Function(DesktopCapturerSource source) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumb = source.thumbnail;
    final isScreen = source.type == SourceType.Screen;
    return SizedBox(
      width: 210,
      child: InkWell(
        onTap: () => onPick(source),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: thumb != null && thumb.isNotEmpty
                      ? Image.memory(thumb, fit: BoxFit.cover)
                      : Icon(
                          isScreen ? Icons.desktop_windows : Icons.web_asset,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  isScreen ? Icons.desktop_windows : Icons.web_asset,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    source.name.isEmpty ? 'Untitled' : source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
