import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol_factory.dart';
import '../core/remote_controller.dart';
import '../core/tv_device.dart';
import '../core/tv_protocol.dart';
import 'remote_page.dart';

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
        ],
      ),
      body: RefreshIndicator(
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

    return ListTile(
      leading: Icon(_icons[device.brand] ?? Icons.tv),
      title: Text(device.name),
      subtitle: Text(subtitle),
      enabled: supported,
      trailing: supported
          ? (onForget == null
              ? const Icon(Icons.chevron_right)
              : PopupMenuButton<String>(
                  onSelected: (_) => onForget!(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'forget', child: Text('Forget this TV')),
                  ],
                ))
          : const Chip(label: Text('Not yet supported')),
      onTap: supported ? onTap : null,
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
