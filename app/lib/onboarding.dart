// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

/// First-run onboarding: 3 swipeable pages explaining what Hearth is, why
/// there's a recovery phrase, and how the trust model works. Shown once before
/// the enrollment screen. Calls [onComplete] when the user taps "Get started".
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({required this.onComplete, super.key});
  final VoidCallback onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    _OnboardingPage(
      icon: Icons.lock_outline,
      iconLabel: 'Encryption',
      title: 'Your messages, your keys',
      body:
          'Hearth encrypts everything end-to-end. Messages travel '
          'peer-to-peer — no server can read them, and no account is '
          'needed. Your identity lives on your device — not on a server.',
    ),
    _OnboardingPage(
      icon: Icons.devices,
      iconLabel: 'Multiple devices',
      title: 'Multi-device, no cloud',
      body:
          'Use Hearth on multiple devices simultaneously. Each device '
          'holds its own key, certified by your root identity. Lose a '
          'device? Revoke it — it can\'t read future messages.',
    ),
    _OnboardingPage(
      icon: Icons.shield_outlined,
      iconLabel: 'Recovery phrase',
      title: 'Your 24-word backup',
      body:
          'You\'ll get a 24-word recovery phrase — the only way to '
          'restore your identity if you lose all devices. Write it down '
          'and keep it safe. There\'s no "forgot password" — no one else '
          'holds your keys.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Skip button (top-right).
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onComplete,
                child: const Text('Skip'),
              ),
            ),
            // Pages.
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => _pages[i],
              ),
            ),
            // Dots + button.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Row(
                children: [
                  // Page dots.
                  Row(
                    children: List.generate(
                      _pages.length,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: i == _page ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: i == _page
                              ? theme.colorScheme.primary
                              : theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Next / Get started button.
                  FilledButton(
                    onPressed: () {
                      if (isLast) {
                        widget.onComplete();
                      } else {
                        _controller.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      }
                    },
                    child: Text(isLast ? 'Get started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single onboarding page with an icon, title, and description.
class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.icon,
    required this.iconLabel,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String iconLabel;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 80,
            color: theme.colorScheme.primary,
            semanticLabel: iconLabel,
          ),
          const SizedBox(height: 32),
          Text(
            title,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
