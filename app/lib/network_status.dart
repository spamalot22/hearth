import 'dart:math';

import 'package:flutter/material.dart';

/// Animated network status indicator showing the relay and connected peers
/// as a mini mesh visualization.
class NetworkStatus extends StatefulWidget {
  const NetworkStatus({
    required this.relayUp,
    required this.checkingRelay,
    required this.peerCount,
    required this.channelCount,
    required this.relayUrl,
    required this.onTapRelay,
    required this.onRefresh,
    super.key,
  });

  final bool? relayUp;
  final bool checkingRelay;
  final int peerCount;
  final int channelCount;
  final String relayUrl;
  final VoidCallback onTapRelay;
  final VoidCallback onRefresh;

  @override
  State<NetworkStatus> createState() => _NetworkStatusState();
}

class _NetworkStatusState extends State<NetworkStatus>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connected = widget.peerCount > 0;
    final relayOk = widget.relayUp == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Mini mesh visualization
        SizedBox(
          height: 80,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => CustomPaint(
              size: const Size(double.infinity, 80),
              painter: _MeshPainter(
                relayUp: relayOk,
                peerCount: widget.peerCount,
                pulse: _pulse.value,
                nodeColor: scheme.primary,
                relayColor: relayOk ? Colors.green : Colors.red.shade300,
                lineColor: scheme.outlineVariant,
                activeLineColor: scheme.primary.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Status summary
        Row(
          children: [
            _statusChip(
              icon: Icons.hub,
              label: connected
                  ? '${widget.peerCount} peer${widget.peerCount == 1 ? "" : "s"}'
                  : 'no peers',
              color: connected ? Colors.green : Colors.orange,
            ),
            const SizedBox(width: 8),
            _statusChip(
              icon: Icons.dns,
              label: widget.checkingRelay
                  ? 'checking…'
                  : relayOk
                  ? 'relay up'
                  : 'relay down',
              color: widget.checkingRelay
                  ? Colors.grey
                  : relayOk
                  ? Colors.green
                  : Colors.red,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Connection health message
        Text(
          _healthMessage(connected, relayOk),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // Relay URL + actions
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: widget.onTapRelay,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    widget.relayUrl,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: 'Re-check',
              onPressed: widget.checkingRelay ? null : widget.onRefresh,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ],
    );
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 11)),
        ],
      ),
    );
  }

  String _healthMessage(bool connected, bool relayOk) {
    if (connected && relayOk) return 'Fully connected — messages flow P2P.';
    if (connected && !relayOk) {
      return 'P2P active — relay down, but messages still flow directly.';
    }
    if (!connected && relayOk) {
      return 'Waiting for peers — relay is brokering connections.';
    }
    return 'Offline — no relay or peers reachable.';
  }
}

/// Paints a mini animated mesh: a center node (you), peer nodes arranged around
/// you, and the relay as a distinct shape. Lines pulse between connected nodes.
class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.relayUp,
    required this.peerCount,
    required this.pulse,
    required this.nodeColor,
    required this.relayColor,
    required this.lineColor,
    required this.activeLineColor,
  });

  final bool relayUp;
  final int peerCount;
  final double pulse; // 0..1
  final Color nodeColor;
  final Color relayColor;
  final Color lineColor;
  final Color activeLineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) * 0.35;
    final peers = min(peerCount, 6); // cap visual nodes

    // Draw peer-to-peer lines
    final peerPositions = <Offset>[];
    for (var i = 0; i < peers; i++) {
      final angle = (2 * pi * i / max(peers, 1)) - pi / 2;
      final pos = center + Offset(cos(angle) * radius, sin(angle) * radius);
      peerPositions.add(pos);
    }

    final linePaint = Paint()
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Lines from center to peers (pulsing opacity)
    for (final pos in peerPositions) {
      linePaint.color = activeLineColor.withValues(alpha: 0.3 + 0.4 * pulse);
      canvas.drawLine(center, pos, linePaint);
    }

    // Relay node (top-right, square-ish)
    final relayPos = Offset(size.width - 20, 16);
    if (relayUp) {
      linePaint.color = lineColor.withValues(alpha: 0.3 + 0.2 * pulse);
      canvas.drawLine(center, relayPos, linePaint);
    }
    final relayPaint = Paint()..color = relayColor.withValues(alpha: 0.8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: relayPos, width: 10, height: 10),
        const Radius.circular(2),
      ),
      relayPaint,
    );

    // Draw peer nodes
    final peerPaint = Paint()..color = nodeColor.withValues(alpha: 0.8);
    for (final pos in peerPositions) {
      canvas.drawCircle(pos, 5, peerPaint);
    }

    // Draw center node (you) — larger, with a pulse ring
    final selfPaint = Paint()..color = nodeColor;
    canvas.drawCircle(center, 7, selfPaint);
    final ringPaint = Paint()
      ..color = nodeColor.withValues(alpha: 0.3 * (1 - pulse))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, 7 + 6 * pulse, ringPaint);

    // "You" label
    final tp = TextPainter(
      text: TextSpan(
        text: 'you',
        style: TextStyle(color: nodeColor.withValues(alpha: 0.7), fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center + const Offset(-8, 10));

    // Extra peers indicator
    if (peerCount > 6) {
      final extra = TextPainter(
        text: TextSpan(
          text: '+${peerCount - 6}',
          style: TextStyle(
            color: nodeColor.withValues(alpha: 0.6),
            fontSize: 9,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      extra.paint(canvas, Offset(size.width - 30, size.height - 14));
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.pulse != pulse ||
      old.peerCount != peerCount ||
      old.relayUp != relayUp;
}
