// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

/// A small curated set of common emoji for the quick picker. Emoji are just
/// Unicode text, so they already send and render — this is only fast insertion.
/// A full searchable picker can come later via a package.
const List<String> kQuickEmoji = [
  '😀',
  '😂',
  '🤣',
  '😊',
  '😍',
  '😘',
  '😎',
  '🤔',
  '😅',
  '😭',
  '😢',
  '😡',
  '🥺',
  '😴',
  '🤯',
  '🥳',
  '😉',
  '😜',
  '🤪',
  '😏',
  '🙃',
  '😬',
  '😱',
  '🤩',
  '👍',
  '👎',
  '👏',
  '🙏',
  '🙌',
  '💪',
  '🤝',
  '✌️',
  '🤙',
  '👀',
  '🫡',
  '🫶',
  '❤️',
  '🧡',
  '💛',
  '💚',
  '💙',
  '💜',
  '🖤',
  '🤍',
  '💔',
  '💯',
  '🔥',
  '✨',
  '⭐',
  '🌟',
  '⚡',
  '💥',
  '🎉',
  '🎊',
  '🎁',
  '🎂',
  '🍾',
  '🥂',
  '☕',
  '🍕',
  '🚀',
  '💀',
  '👻',
  '🤖',
  '👾',
  '🎮',
  '🕹️',
  '🎧',
  '🎵',
  '🎶',
  '⚽',
  '🏆',
  '✅',
  '❌',
  '❓',
  '❗',
  '💬',
  '👌',
  '🤞',
  '🫠',
  '🤌',
  '👋',
  '🎯',
  '🎲',
];

/// In-memory recent emoji list (persists for the session; could be backed by
/// Hive for cross-session persistence later).
final List<String> _recentEmoji = [];
const int _maxRecent = 8;

/// Records an emoji as recently used.
void recordEmojiUse(String emoji) {
  _recentEmoji.remove(emoji);
  _recentEmoji.insert(0, emoji);
  if (_recentEmoji.length > _maxRecent) _recentEmoji.removeLast();
}

/// Shows a bottom-sheet emoji grid and resolves to the chosen emoji (or null).
Future<String?> pickEmoji(BuildContext context, {String? title}) async {
  final result = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
          GridView.count(
            crossAxisCount: 8,
            shrinkWrap: true,
            padding: const EdgeInsets.all(8),
            children: [
              // Recent row first (if any).
              for (final emoji in _recentEmoji)
                InkWell(
                  onTap: () => Navigator.pop(context, emoji),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              // Pad the recent row to a full 8-wide line.
              if (_recentEmoji.isNotEmpty)
                for (var i = 0; i < (8 - _recentEmoji.length % 8) % 8; i++)
                  const SizedBox.shrink(),
              // Full emoji set.
              for (final emoji in kQuickEmoji)
                InkWell(
                  onTap: () => Navigator.pop(context, emoji),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
  if (result != null) recordEmojiUse(result);
  return result;
}
