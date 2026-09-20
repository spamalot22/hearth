// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:core/core.dart';
import 'package:flutter/material.dart';

import 'nearby_messaging.dart';

Future<void> showProximityScanner(
  BuildContext context,
  NearbyMessaging nearby,
) => showDialog<void>(
  context: context,
  builder: (_) => ProximityScanner(messaging: nearby),
);

class ProximityScanner extends StatefulWidget {
  const ProximityScanner({super.key, required this.messaging});
  final NearbyMessaging messaging;
  @override
  State<ProximityScanner> createState() => _ProximityScannerState();
}

class _ProximityScannerState extends State<ProximityScanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  String? _selected;
  bool _busy = false;
  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  static String _band(ProximityBand band) => switch (band) {
    ProximityBand.near => 'Close signal',
    ProximityBand.nearby => 'Moderate signal',
    ProximityBand.weak => 'Distant / obstructed',
    ProximityBand.unknown => 'Range unknown',
  };
  static Color _color(ProximityBand band) => switch (band) {
    ProximityBand.near => const Color(0xff39dba0),
    ProximityBand.nearby => const Color(0xff57c7f3),
    ProximityBand.weak => const Color(0xfff1c65c),
    ProximityBand.unknown => const Color(0xffabb5bc),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.messaging,
    builder: (context, _) {
      final nearby = widget.messaging;
      final scanning = nearby.scannerEnabled && nearby.active;
      final animate = scanning && !MediaQuery.disableAnimationsOf(context);
      if (animate && !_sweep.isAnimating) _sweep.repeat();
      if (!animate && _sweep.isAnimating) _sweep.stop();
      final signals = nearby.observations;
      final unknown = nearby.connectedPeers.keys
          .where((id) => nearby.signalFor(id) == null)
          .toList();
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(context).height * .9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.radar),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Proximity scanner',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close scanner',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    nearby.scannerEnabled ? nearby.status : 'Scanner off',
                  ),
                  value: nearby.scannerEnabled,
                  onChanged: _busy
                      ? null
                      : (value) async {
                          setState(() => _busy = true);
                          try {
                            await nearby.setScanner(value);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Could not change scanner settings',
                                  ),
                                ),
                              );
                            }
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                ),
                AspectRatio(
                  aspectRatio: 1,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final extent = math.min(box.maxWidth, box.maxHeight);
                      final center = Offset(extent / 2, extent / 2);
                      final plotted =
                          <
                            ({
                              ProximityObservation signal,
                              double angle,
                              double radius,
                            })
                          >[];
                      for (final band in [
                        ProximityBand.near,
                        ProximityBand.nearby,
                        ProximityBand.weak,
                      ]) {
                        final fraction = switch (band) {
                          ProximityBand.near => .28,
                          ProximityBand.nearby => .58,
                          _ => .88,
                        };
                        final radius = extent * .44 * fraction;
                        final slots = (2 * math.pi * radius / 36).floor().clamp(
                          1,
                          24,
                        );
                        final group = signals
                            .where((s) => s.band == band)
                            .take(slots)
                            .toList();
                        for (var i = 0; i < group.length; i++) {
                          plotted.add((
                            signal: group[i],
                            angle: i * math.pi * 2 / group.length,
                            radius: radius,
                          ));
                        }
                      }
                      return ClipOval(
                        child: ColoredBox(
                          color: const Color(0xff101c1a),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: AnimatedBuilder(
                                  animation: _sweep,
                                  builder: (_, _) => CustomPaint(
                                    painter: _RadarPainter(
                                      _sweep.value,
                                      scanning,
                                    ),
                                  ),
                                ),
                              ),
                              Center(
                                child: Tooltip(
                                  message: 'This device',
                                  child: Icon(
                                    Icons.my_location,
                                    size: 22,
                                    color: scanning
                                        ? Colors.white
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                              for (final dot in plotted)
                                Builder(
                                  builder: (context) {
                                    final signal = dot.signal;
                                    // Angular slots are layout only: ordinary RSSI has no bearing.
                                    final angle = dot.angle;
                                    final radius = dot.radius;
                                    final point =
                                        center +
                                        Offset(
                                              math.cos(angle),
                                              math.sin(angle),
                                            ) *
                                            radius;
                                    return Positioned(
                                      left: point.dx - 16,
                                      top: point.dy - 16,
                                      width: 32,
                                      height: 32,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 32,
                                              height: 32,
                                            ),
                                        tooltip:
                                            '${nearby.labelFor(signal.id)}: ${_band(signal.band)}',
                                        onPressed: () => setState(
                                          () => _selected = signal.id,
                                        ),
                                        icon: Icon(
                                          _selected == signal.id
                                              ? Icons.radio_button_checked
                                              : Icons.circle,
                                          size: _selected == signal.id
                                              ? 22
                                              : 13,
                                          color: _color(signal.band),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Signal-based proximity. Distance and direction unverified.',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    for (final band in [
                      ProximityBand.near,
                      ProximityBand.nearby,
                      ProximityBand.weak,
                    ])
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 8, color: _color(band)),
                          const SizedBox(width: 6),
                          Flexible(child: Text(_band(band))),
                        ],
                      ),
                  ],
                ),
                const Divider(height: 28),
                if (signals.isEmpty && unknown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      scanning
                          ? 'No nearby devices detected'
                          : 'Scanner inactive',
                    ),
                  ),
                for (final signal in signals)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    selected: _selected == signal.id,
                    onTap: () => setState(() => _selected = signal.id),
                    leading: Icon(Icons.bluetooth, color: _color(signal.band)),
                    title: Text(nearby.labelFor(signal.id)),
                    subtitle: Text(
                      '${_band(signal.band)}${nearby.peerFor(signal.id) == null ? ' / unverified beacon' : ' / nearby link'}',
                    ),
                    trailing: signal.band == ProximityBand.unknown
                        ? null
                        : Text('${signal.rssi} dBm'),
                  ),
                for (final peer in unknown)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.wifi),
                    title: Text(nearby.labelFor(peer)),
                    subtitle: const Text('Nearby link / range unknown'),
                  ),
                if (nearby.scannerEnabled &&
                    Theme.of(context).platform == TargetPlatform.iOS)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Background scanning is limited by iOS.'),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.phase, this.active);
  final double phase;
  final bool active;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * .44;
    final grid = Paint()
      ..color = const Color(0xff31554b)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final fraction in [.33, .66, 1.0]) {
      canvas.drawCircle(center, radius * fraction, grid);
    }
    canvas.drawLine(
      center - Offset(radius, 0),
      center + Offset(radius, 0),
      grid,
    );
    canvas.drawLine(
      center - Offset(0, radius),
      center + Offset(0, radius),
      grid,
    );
    if (active) {
      final angle = phase * math.pi * 2;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        angle - .35,
        .35,
        true,
        Paint()..color = const Color(0x184ad9a5),
      );
      canvas.drawLine(
        center,
        center + Offset(math.cos(angle), math.sin(angle)) * radius,
        Paint()
          ..color = const Color(0xff4ad9a5)
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) =>
      phase != oldDelegate.phase || active != oldDelegate.active;
}
