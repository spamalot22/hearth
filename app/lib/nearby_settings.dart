// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import 'nearby_messaging.dart';
import 'proximity_scanner.dart';

class NearbySettings extends StatefulWidget {
  const NearbySettings({super.key, required this.messaging});
  final NearbyMessaging messaging;
  @override
  State<NearbySettings> createState() => _NearbySettingsState();
}

class _NearbySettingsState extends State<NearbySettings> {
  bool _busy = false;
  Future<void> _change({required bool enabled, required bool automatic}) async {
    setState(() => _busy = true);
    try {
      await widget.messaging.configure(enabled: enabled, automatic: automatic);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not change nearby settings')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.messaging,
    builder: (context, _) {
      final nearby = widget.messaging;
      if (!nearby.supported) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Nearby text messaging'),
            subtitle: Text(nearby.status),
            value: nearby.enabled,
            onChanged: _busy
                ? null
                : (v) => _change(enabled: v, automatic: nearby.automatic),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Only activate without Internet'),
            value: nearby.automatic,
            onChanged: _busy || !nearby.enabled
                ? null
                : (v) => _change(enabled: nearby.enabled, automatic: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.radar),
            title: const Text('Proximity scanner'),
            value: nearby.scannerEnabled,
            onChanged: _busy
                ? null
                : (value) async {
                    setState(() => _busy = true);
                    try {
                      await nearby.setScanner(value);
                      if (value && context.mounted) {
                        await showProximityScanner(context, nearby);
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not start proximity scanner'),
                          ),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
          ),
          if (nearby.scannerEnabled)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => showProximityScanner(context, nearby),
                icon: const Icon(Icons.radar),
                label: const Text('Open scanner'),
              ),
            ),
          if (nearby.awarePairingAvailable &&
              (nearby.enabled || nearby.scannerEnabled))
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Pair Wi-Fi Aware device'),
                onPressed: _busy || !nearby.canPairAware
                    ? null
                    : () async {
                        try {
                          await nearby.pairAware();
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Wi-Fi Aware pairing unavailable',
                                ),
                              ),
                            );
                          }
                        }
                      },
              ),
            ),
          if (nearby.enabled)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${nearby.queuedCount} encrypted envelopes queued',
                  ),
                ),
                IconButton(
                  tooltip: 'Clear nearby queue',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _busy || nearby.queuedCount == 0
                      ? null
                      : () async {
                          final clear = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Clear nearby queue?'),
                              content: const Text(
                                'Remove queued nearby copies? Your chat history will be kept.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Clear'),
                                ),
                              ],
                            ),
                          );
                          if (clear == true && mounted) {
                            try {
                              await nearby.clearQueue();
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Could not clear nearby queue',
                                    ),
                                  ),
                                );
                              }
                            }
                          }
                        },
                ),
              ],
            ),
        ],
      );
    },
  );
}
