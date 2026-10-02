import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol_factory.dart';
import '../core/remote_controller.dart';
import '../core/tv_device.dart';
import '../core/tv_protocol.dart';
import 'guide_page.dart';
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
        title: Text('Pairing with ${device.name}'),
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
              if (value == 'guide') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const GuidePage()),
                );
              } else if (value == 'wiantribe') {
                openWianTribe();
              }
            },
            itemBuilder: (_) => const [
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
  const _DeviceTile({required this.device, required this.onTap, this.onForget});

  final TvDevice device;
  final VoidCallback onTap;
  final VoidCallback? onForget;

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
                        device.name,
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
                    onSelected: (_) => onForget!(),
                    itemBuilder: (_) => const [
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
