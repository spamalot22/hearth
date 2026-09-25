// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> showErrorDetails(
  BuildContext context, {
  required String message,
  required String diagnostics,
  Future<void> Function()? onRetry,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ErrorDetails(
    message: message,
    diagnostics: diagnostics,
    onRetry: onRetry,
  ),
);

class _ErrorDetails extends StatefulWidget {
  const _ErrorDetails({
    required this.message,
    required this.diagnostics,
    this.onRetry,
  });
  final String message;
  final String diagnostics;
  final Future<void> Function()? onRetry;

  @override
  State<_ErrorDetails> createState() => _ErrorDetailsState();
}

class _ErrorDetailsState extends State<_ErrorDetails> {
  bool _copying = false;
  String _copyLabel = 'Copy diagnostics';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Error details'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            const SizedBox(height: 16),
            SelectableText(widget.diagnostics),
          ],
        ),
      ),
    ),
    actions: [
      TextButton.icon(
        icon: const Icon(Icons.copy_outlined),
        label: Text(_copyLabel),
        onPressed: _copying
            ? null
            : () async {
                setState(() => _copying = true);
                try {
                  // Copy only the privacy-safe report, not arbitrary error strings
                  // from a server or native plugin displayed in the message.
                  await Clipboard.setData(
                    ClipboardData(text: widget.diagnostics),
                  );
                  if (mounted) setState(() => _copyLabel = 'Copied');
                } catch (_) {
                  if (mounted) setState(() => _copyLabel = 'Copy failed');
                } finally {
                  if (mounted) setState(() => _copying = false);
                }
              },
      ),
      if (widget.onRetry != null)
        TextButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Retry connection'),
          onPressed: () async {
            final retry = widget.onRetry!;
            Navigator.pop(context);
            await retry();
          },
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
