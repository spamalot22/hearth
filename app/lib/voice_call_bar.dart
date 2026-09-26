// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

enum VoiceCallState {
  waiting,
  connecting,
  connected,
  reconnecting,
  disconnecting,
}

/// Persistent call controls, independent of the channel currently being viewed.
class VoiceCallBar extends StatelessWidget {
  const VoiceCallBar({
    required this.channelName,
    required this.state,
    required this.connectedPeers,
    required this.muted,
    required this.deafened,
    required this.onOpenChannel,
    required this.onMute,
    required this.onDeafen,
    required this.onDisconnect,
    required this.onDiagnostics,
    super.key,
  });

  final String channelName;
  final VoiceCallState state;
  final int connectedPeers;
  final bool muted;
  final bool deafened;
  final VoidCallback? onOpenChannel;
  final VoidCallback? onMute;
  final VoidCallback? onDeafen;
  final VoidCallback? onDisconnect;
  final VoidCallback? onDiagnostics;

  String get status {
    final label = switch (state) {
      VoiceCallState.waiting => 'Waiting for others',
      VoiceCallState.connecting => 'Connecting',
      VoiceCallState.connected => 'Connected',
      VoiceCallState.reconnecting => 'Reconnecting',
      VoiceCallState.disconnecting => 'Disconnecting',
    };
    return connectedPeers == 0
        ? label
        : '$label - $connectedPeers ${connectedPeers == 1 ? 'peer' : 'peers'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = switch (state) {
      VoiceCallState.waiting => Icons.headset_outlined,
      VoiceCallState.connecting => Icons.settings_ethernet,
      VoiceCallState.connected => Icons.call,
      VoiceCallState.reconnecting => Icons.sync_problem_outlined,
      VoiceCallState.disconnecting => Icons.call_end_outlined,
    };
    final color = state == VoiceCallState.reconnecting
        ? scheme.error
        : state == VoiceCallState.connected
        ? scheme.secondary
        : scheme.onSurfaceVariant;
    final title = Tooltip(
      message: 'Return to $channelName',
      child: InkWell(
        key: const Key('voice-call-channel'),
        onTap: onOpenChannel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        channelName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('voice-call-mute'),
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          tooltip: deafened
              ? 'Microphone muted while deafened'
              : muted
              ? 'Unmute microphone'
              : 'Mute microphone',
          isSelected: muted,
          onPressed: deafened ? null : onMute,
          icon: const Icon(Icons.mic),
          selectedIcon: const Icon(Icons.mic_off),
        ),
        IconButton(
          key: const Key('voice-call-deafen'),
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          tooltip: deafened ? 'Undeafen audio' : 'Deafen audio',
          isSelected: deafened,
          onPressed: onDeafen,
          icon: const Icon(Icons.headset),
          selectedIcon: const Icon(Icons.headset_off),
        ),
        IconButton(
          key: const Key('voice-call-diagnostics'),
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          tooltip: 'Voice connection details',
          onPressed: onDiagnostics,
          icon: const Icon(Icons.info_outline),
        ),
        IconButton(
          key: const Key('voice-call-disconnect'),
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          tooltip: 'Disconnect voice',
          color: scheme.error,
          onPressed: onDisconnect,
          icon: const Icon(Icons.call_end),
        ),
      ],
    );
    return Material(
      color: scheme.surfaceContainerHigh,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 480 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20;
              return compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        title,
                        Align(
                          alignment: Alignment.centerRight,
                          child: controls,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: title),
                        controls,
                      ],
                    );
            },
          ),
        ),
      ),
    );
  }
}
