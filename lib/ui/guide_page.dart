import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const String kWianTribeUrl = 'https://wiantribe.com';

/// How to use the remote, plus who made it.
///
/// Written for someone holding the phone in front of a TV, so it leads with
/// the thing that goes wrong most often — the phone and the TV being on
/// different networks — rather than with a feature list.
class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How to use')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: const [
          _Section(
            icon: Icons.wifi,
            title: 'Getting connected',
            body: 'Your phone and your TV have to be on the same Wi-Fi network. '
                'That is the cause of almost every "no TVs found".\n\n'
                'Tap Scan to search, or add the TV by its IP address if your '
                'router blocks discovery. Guest networks and some mesh setups '
                'hide devices from each other and will never find a TV.',
          ),
          _Section(
            icon: Icons.tv,
            title: 'Which TVs work',
            body: 'Roku, Samsung and LG smart TVs.\n\n'
                'Roku needs nothing set up — the app uses the TV\'s own '
                'authenticated channel. Samsung and LG ask you to accept a '
                'prompt on the TV the first time, and that approval is '
                'remembered.',
          ),
          _Section(
            icon: Icons.keyboard,
            title: 'Typing and voice',
            body: 'Keyboard types into whatever box the TV has selected, so '
                'open a search field on the TV first. On Roku the Search '
                'button does that for you.\n\n'
                'Voice search listens while the sheet is open, shows what it '
                'heard, and sends it only when you tap Send to TV — so a '
                'misheard word never reaches the TV by surprise.',
          ),
          _Section(
            icon: Icons.power_settings_new,
            title: 'Turning the TV on',
            body: 'A TV that is fully off has no network, so nothing can reach '
                'it over Wi-Fi. Two things change that.\n\n'
                'On Roku, turn on Fast TV Start (Settings > System > Power). '
                'The TV then stays reachable while asleep and the power button '
                'wakes it.\n\n'
                'Otherwise the app sends a wake-on-LAN packet, which the TV\'s '
                'network adapter answers even while the set sleeps. This needs '
                'the TV to have been found on the network at least once, and '
                'it only works over Wi-Fi or Ethernet on the same network.',
          ),
          _Section(
            icon: Icons.apps,
            title: 'Channels and shortcuts',
            body: 'Channels lists what is actually installed on the TV, read '
                'live from the set rather than guessed. Tap any entry to open '
                'it. TV inputs such as HDMI appear in the same list.',
          ),
          _Section(
            icon: Icons.help_outline,
            title: 'If a button does nothing',
            body: 'Not every TV implements every key. Keys the connected TV '
                'does not support are greyed out rather than hidden, so the '
                'layout does not reshuffle when you switch TVs.\n\n'
                'If everything stops responding, the TV probably changed IP '
                'address. Scan again, or re-add it.',
          ),
          SizedBox(height: 8),
          _WianTribeBanner(),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
        ],
      ),
    );
  }
}

/// Credit, as a card rather than fine print.
class _WianTribeBanner extends StatelessWidget {
  const _WianTribeBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.primaryContainer,
      child: InkWell(
        onTap: openWianTribe,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Built by',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.75),
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'wiaTribe',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.link, size: 16, color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    'wiantribe.com',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Not affiliated with, endorsed by, or sponsored by Roku, '
                'Samsung or LG.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the wiaTribe site in the phone's browser.
Future<void> openWianTribe() async {
  final uri = Uri.parse(kWianTribeUrl);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
