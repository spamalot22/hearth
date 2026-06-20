import 'package:core/core.dart';
import 'package:flutter/material.dart';

import 'key_store.dart';

void main() {
  runApp(HearthApp(keyStore: SecureKeyStore()));
}

class HearthApp extends StatelessWidget {
  const HearthApp({required this.keyStore, super.key});

  final KeyStore keyStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hearth',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFE25822), // ember orange
      ),
      home: IdentityScreen(keyStore: keyStore),
    );
  }
}

/// First screen: loads (or creates) this device's identity and shows it.
class IdentityScreen extends StatefulWidget {
  const IdentityScreen({required this.keyStore, super.key});

  final KeyStore keyStore;

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  late final Future<Identity> _identity = Identity.loadOrCreate(
    widget.keyStore,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hearth')),
      body: Center(
        child: FutureBuilder<Identity>(
          future: _identity,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const CircularProgressIndicator();
            }
            if (snapshot.hasError) {
              return Text('Failed to load identity: ${snapshot.error}');
            }
            return _IdentityCard(identity: snapshot.data!);
          },
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.identity});

  final Identity identity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department, size: 64),
          const SizedBox(height: 16),
          Text('Your identity', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'hearth#${identity.fingerprint}',
            key: const Key('identity-fingerprint'),
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          Text('Public key', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          SelectableText(
            identity.publicKeyHex,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
