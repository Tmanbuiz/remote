import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/home_monitor.dart';
import '../core/remote_controller.dart';
import 'theme.dart';

/// "Listen to home": one screen, two roles.
///
/// The same app is installed on both phones, so which one this phone is
/// becomes a choice made here. The talking side is written to be unmissable —
/// the state is spelled out in words, in colour, and in the persistent
/// notification — because the one thing this feature must never be is easy to
/// forget about. It is for monitoring your own home with your own phone.
class HomeMonitorPage extends StatefulWidget {
  const HomeMonitorPage({super.key});

  @override
  State<HomeMonitorPage> createState() => _HomeMonitorPageState();
}

class _HomeMonitorPageState extends State<HomeMonitorPage> {
  late final TextEditingController _host;

  @override
  void initState() {
    super.initState();
    // The home phone's VPN address is the same one "Listen from away" uses
    // for the TV relay, so it is remembered rather than asked for twice.
    _host = TextEditingController(
      text: context.read<RemoteController>().relayHost ?? '',
    );
  }

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _listen(HomeMonitor monitor) async {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    await context.read<RemoteController>().setRelayHost(host);
    await monitor.startListening(host);
  }

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<HomeMonitor>();

    return Scaffold(
      appBar: AppBar(title: const Text('Listen to home')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (monitor.error != null) _ErrorBanner(monitor: monitor),
            _TalkCard(monitor: monitor),
            const SizedBox(height: 16),
            _ListenCard(monitor: monitor, host: _host, onListen: () => _listen(monitor)),
            const SizedBox(height: 20),
            const _Caveats(),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.monitor});

  final HomeMonitor monitor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: RemoteTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RemoteTheme.danger),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              monitor.error!,
              style: const TextStyle(color: RemoteTheme.text, fontSize: 13),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: monitor.clearError,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The phone left at home.
class _TalkCard extends StatelessWidget {
  const _TalkCard({required this.monitor});

  final HomeMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final on = monitor.isTalking;
    final busy = monitor.isListening;
    final String status;
    if (!on) {
      status = 'Microphone off';
    } else if (monitor.talkerHasListener) {
      status = 'Microphone ON — streaming to your other device';
    } else {
      status = 'Microphone ON — waiting for your other device';
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: RemoteTheme.surface,
        borderRadius: BorderRadius.circular(18),
        // A lit border is the in-app counterpart of the notification: when the
        // microphone is open the whole card says so.
        border: Border.all(
          color: on ? RemoteTheme.danger : RemoteTheme.hairline,
          width: on ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(on ? Icons.mic : Icons.mic_off,
                  color: on ? RemoteTheme.danger : RemoteTheme.textMuted),
              const SizedBox(width: 10),
              const Text('This phone is at home',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            status,
            style: TextStyle(
              color: on ? RemoteTheme.danger : RemoteTheme.textMuted,
              fontWeight: on ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Shares this phone\'s microphone with your other phone. A '
            '"Microphone on" notification stays up the whole time, and the '
            'microphone closes when you turn this off or close the app. '
            'Nothing is recorded or saved on this phone.',
            style: TextStyle(color: RemoteTheme.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: on
                ? OutlinedButton.icon(
                    onPressed: monitor.stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Turn microphone off'),
                  )
                : FilledButton.icon(
                    onPressed: busy ? null : monitor.startTalking,
                    icon: const Icon(Icons.mic),
                    label: const Text('Listen from here'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The phone somewhere else.
class _ListenCard extends StatelessWidget {
  const _ListenCard({
    required this.monitor,
    required this.host,
    required this.onListen,
  });

  final HomeMonitor monitor;
  final TextEditingController host;
  final VoidCallback onListen;

  @override
  Widget build(BuildContext context) {
    final on = monitor.isListening;
    final busy = monitor.isTalking;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: RemoteTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: RemoteTheme.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(on ? Icons.hearing : Icons.hearing_disabled_outlined,
                  color: on ? RemoteTheme.accent : RemoteTheme.textMuted),
              const SizedBox(width: 10),
              const Text('This phone is away',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            on
                ? (monitor.listenerIsHearing
                    ? 'Hearing home (${monitor.packetsReceived} packets)'
                    : 'Connected — no sound arriving yet')
                : 'Not listening',
            style: TextStyle(color: on ? RemoteTheme.accent : RemoteTheme.textMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: host,
            enabled: !on && !busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Home phone\'s Tailscale address',
              hintText: '100.95.6.24',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: on
                ? OutlinedButton.icon(
                    onPressed: monitor.stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop listening'),
                  )
                : FilledButton.icon(
                    onPressed: busy ? null : onListen,
                    icon: const Icon(Icons.hearing),
                    label: const Text('Listen to home'),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Caveats extends StatelessWidget {
  const _Caveats();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Good to know\n'
      '• Expect roughly a tenth to half a second of delay over the internet. '
      'It is for listening, not for talking back.\n'
      '• There is no smoothing yet, so a weak connection will cause dropouts.\n'
      '• The phone at home must stay powered and connected, with Tailscale '
      'running. On Samsung, add this app and Tailscale to Settings → Battery → '
      'Background usage limits → Never auto sleeping apps.\n'
      '• Only use this in your own home, and tell people who live there.',
      style: TextStyle(color: RemoteTheme.textMuted, fontSize: 12, height: 1.5),
    );
  }
}
