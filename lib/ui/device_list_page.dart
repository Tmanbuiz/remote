import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol_factory.dart';
import '../core/remote_controller.dart';
import '../core/tv_device.dart';
import '../core/tv_protocol.dart';
import 'guide_page.dart';
import 'home_monitor_page.dart';
import 'remote_page.dart';
import 'theme.dart';

class DeviceListPage extends StatefulWidget {
  const DeviceListPage({super.key});

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  @override
  void initState() {
    super.initState();
    // Scan on open: the common case is "I just want to change the channel".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RemoteController>().scan();
    });
  }

  /// Adds a TV by typing its address.
  ///
  /// Necessary wherever discovery cannot reach: routers with client isolation,
  /// separate VLANs, and iOS, where multicast needs an entitlement Apple grants
  /// only on request. Without this the app is unusable on those networks even
  /// though the TV is perfectly reachable.
  Future<void> _addByAddress() async {
    final controller = context.read<RemoteController>();
    final field = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);

    final host = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add TV by address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "On the TV: Settings, Network, About. Use the IP address shown "
              "there, for example 192.168.1.20.",
              style: TextStyle(color: RemoteTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                hintText: '192.168.1.20',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(field.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    field.dispose();
    if (host == null || host.isEmpty || !mounted) return;

    final found = await controller.probe(host);
    if (!mounted) return;
    if (found == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Nothing answered at $host')),
      );
      return;
    }
    await _connect(found);
  }

  /// Renames a saved TV to something sayable.
  ///
  /// Sets report names like `70" Hisense Roku TV`, which nobody says out loud
  /// and Siri transcribes unpredictably. "bedroom TV" is both what the user
  /// calls it and what the voice phrase can match.
  /// Where to collect TV audio from when this phone is not on the TV's network.
  ///
  /// Private listening is one-way: the TV fires audio at an address and never
  /// checks whether anything is there. A phone on the far end of a VPN has an
  /// address the TV cannot route to, so the stream has to be collected by
  /// something at home and forwarded. This is where each end is told its part.
  Future<void> _relaySettings() async {
    final controller = context.read<RemoteController>();
    final field = TextEditingController(text: controller.relayHost ?? '');
    field.selection = TextSelection.collapsed(offset: field.text.length);

    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Listen from away'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'On the phone you leave at home: open the TV, then Relay audio. '
              'On this phone: enter the VPN address of that phone below.',
              style: TextStyle(color: RemoteTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                hintText: '100.95.6.24',
                helperText: 'Leave empty to receive the audio directly',
                helperStyle: TextStyle(color: RemoteTheme.textMuted, fontSize: 11),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (saved == null || !mounted) return;
    await controller.setRelayHost(saved);
  }

  Future<void> _rename(TvDevice device) async {
    final controller = context.read<RemoteController>();
    final field = TextEditingController(text: device.nickname ?? '');
    // Put the caret at the end rather than selecting everything, so typing
    // appends to an existing name instead of wiping it.
    field.selection = TextSelection.collapsed(offset: field.text.length);

    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename TV'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Reported as "${device.name}". Give it a name you would say out '
              'loud — "living room TV", "bedroom TV" — and Siri will match it.',
              style: const TextStyle(color: RemoteTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: field,
              autofocus: true,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                hintText: 'living room TV',
                helperText: 'Leave empty to restore the original name',
                helperStyle: TextStyle(color: RemoteTheme.textMuted, fontSize: 11),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    // Null is Cancel; empty string is a deliberate "use the reported name".
    if (chosen == null || !mounted) return;
    await controller.rename(device, chosen);
  }

  Future<void> _connect(TvDevice device) async {
    final controller = context.read<RemoteController>();
    final messenger = ScaffoldMessenger.of(context);

    if (device.isPaired) {
      await controller.select(device);
      if (!mounted) return;
      if (controller.state == RemoteConnectionState.connected) {
        _openRemote();
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text(controller.error ?? 'Could not connect')),
        );
      }
      return;
    }

    _showPairingDialog(device);
    final result = await controller.pairAndSave(device);
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss the pairing dialog

    if (result.isSuccess) {
      _openRemote();
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(_pairingMessage(result))),
      );
    }
  }

  String _pairingMessage(PairingResult result) {
    switch (result.status) {
      case PairingStatus.rejected:
        return 'The TV declined. Accept the prompt on screen and try again.';
      case PairingStatus.timeout:
        return 'The TV did not answer. Make sure it is on and on this Wi-Fi.';
      default:
        return result.message ?? 'Pairing failed';
    }
  }

  void _showPairingDialog(TvDevice device) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('Pairing with ${device.displayName}'),
        content: const Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Text('Look at the TV and accept the permission prompt.'),
            ),
          ],
        ),
      ),
    );
  }

  void _openRemote() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RemotePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('My TVs'),
        actions: [
          IconButton(
            onPressed: controller.isScanning ? null : controller.scan,
            icon: controller.isScanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Scan again',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'address') {
                _addByAddress();
              } else if (value == 'relay') {
                _relaySettings();
              } else if (value == 'monitor') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const HomeMonitorPage()),
                );
              } else if (value == 'guide') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const GuidePage()),
                );
              } else if (value == 'wiantribe') {
                openWianTribe();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'address', child: Text('Add TV by address')),
              PopupMenuItem(value: 'relay', child: Text('Listen from away')),
              PopupMenuItem(value: 'monitor', child: Text('Listen to home')),
              PopupMenuItem(value: 'guide', child: Text('How to use')),
              PopupMenuItem(value: 'wiantribe', child: Text('About wiaTribe')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
        onRefresh: controller.scan,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (controller.savedDevices.isNotEmpty) ...[
              const _SectionHeader('Paired'),
              ...controller.savedDevices.map(
                (d) => _DeviceTile(
                  device: d,
                  onTap: () => _connect(d),
                  onForget: () => controller.forget(d),
                  onRename: () => _rename(d),
                ),
              ),
            ],
            const _SectionHeader('Found on this network'),
            if (controller.discoveredDevices.isEmpty)
              _EmptyState(
                scanning: controller.isScanning,
                message: controller.error,
              )
            else
              ...controller.discoveredDevices.map(
                (d) => _DeviceTile(device: d, onTap: () => _connect(d)),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.onTap,
    this.onForget,
    this.onRename,
  });

  final TvDevice device;
  final VoidCallback onTap;
  final VoidCallback? onForget;
  final VoidCallback? onRename;

  static const Map<TvBrand, IconData> _icons = {
    TvBrand.roku: Icons.cast,
    TvBrand.samsung: Icons.tv,
    TvBrand.lg: Icons.tv,
    TvBrand.sony: Icons.tv,
    TvBrand.vizio: Icons.tv,
    TvBrand.androidTv: Icons.android,
    TvBrand.appleTv: Icons.apple,
    TvBrand.unknown: Icons.device_unknown,
  };

  @override
  Widget build(BuildContext context) {
    final supported = ProtocolFactory.supported.contains(device.brand);
    final subtitle = [
      device.brand.label,
      if (device.model != null && device.model!.isNotEmpty) device.model!,
      device.host,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: PressFeedback(
        scale: 0.985,
        onTap: supported ? onTap : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF142024), Color(0xFF0C1518)],
            ),
            border: Border.all(color: RemoteTheme.hairline),
          ),
          child: Opacity(
            opacity: supported ? 1 : 0.45,
            child: Row(
              children: [
                // A tinted square rather than a bare icon: at a glance the
                // list reads as a set of devices, not a column of text.
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    color: RemoteTheme.accent.withValues(alpha: 0.12),
                  ),
                  child: Icon(_icons[device.brand] ?? Icons.tv,
                      color: RemoteTheme.accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.displayName,
                        style: const TextStyle(
                          color: RemoteTheme.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            color: RemoteTheme.textMuted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (!supported)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Text('Not yet supported',
                        style: TextStyle(color: RemoteTheme.textMuted, fontSize: 11)),
                  )
                else if (onForget == null)
                  const Icon(Icons.chevron_right, color: RemoteTheme.textMuted)
                else
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, color: RemoteTheme.textMuted),
                    onSelected: (value) {
                      if (value == 'rename') {
                        onRename?.call();
                      } else {
                        onForget!();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'forget', child: Text('Forget this TV')),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.scanning, this.message});

  final bool scanning;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        children: [
          Icon(
            scanning ? Icons.wifi_find : Icons.tv_off,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            scanning
                ? 'Looking for TVs…'
                : (message ?? 'No new TVs found on this network.'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
