import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/remote_controller.dart';
import '../core/remote_key.dart';
import '../protocols/roku_ecp2_session.dart';
import 'dpad.dart';
import 'guide_page.dart';
import 'key_press.dart';
import 'theme.dart';
import 'text_entry_bar.dart';

/// The remote itself.
///
/// Every button routes through [_press], which does the haptic tick and the
/// disabled-key check in one place. Keys the connected TV does not implement
/// are rendered greyed out rather than hidden, so the layout does not reshuffle
/// when you switch between a Roku and a Samsung.
class RemotePage extends StatelessWidget {
  const RemotePage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();
    final device = controller.activeDevice;

    return Scaffold(
      appBar: AppBar(
        title: Text(device?.displayName ?? 'Remote'),
        actions: [
          _ConnectionDot(state: controller.state),
          IconButton(
            tooltip: 'How to use',
            icon: const Icon(Icons.help_outline),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const GuidePage())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            children: [
              if (controller.error != null)
                _ErrorBanner(
                  message: controller.error!,
                  onDismiss: controller.clearError,
                ),
              const _TopRow(),
              const SizedBox(height: 20),
              const DPad(),
              const SizedBox(height: 20),
              const _RockerRow(),
              const SizedBox(height: 20),
              const _TransportRow(),
              const SizedBox(height: 16),
              if (controller.supportsTextInput) const TextEntryBar(),
              const SizedBox(height: 16),
              const _ShortcutBar(),
              const _NumberPad(),
            ],
          ),
        ),
      ),
    );
  }
}

/// One round key.
///
/// Every key shares the pad's surface treatment — a soft top-left highlight
/// and a hairline — so the remote reads as one moulded object rather than a
/// grid of unrelated circles. Keys the TV does not implement stay in place but
/// recede, because a layout that reshuffles between TVs is harder to learn.
class _RemoteButton extends StatelessWidget {
  const _RemoteButton({
    required this.icon,
    required this.tvKey,
    this.label,
    this.size = 60,
    this.tone,
  });

  final IconData icon;
  final RemoteKey tvKey;
  final String? label;
  final double size;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();
    final enabled = controller.supportedKeys.contains(tvKey);
    final accented = tone != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label ?? tvKey.name,
      child: Tooltip(
        message: label ?? tvKey.name,
        child: PressFeedback(
          onTap: enabled ? () => pressKey(context, tvKey) : null,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: accented
                    ? [tone!, Color.lerp(tone!, Colors.black, 0.32)!]
                    : const [Color(0xFF17262A), Color(0xFF0D171A)],
              ),
              border: Border.all(
                color: accented ? Colors.transparent : RemoteTheme.hairline,
                width: 1,
              ),
              boxShadow: accented
                  ? [
                      BoxShadow(
                        color: tone!.withValues(alpha: 0.28),
                        blurRadius: 18,
                      ),
                    ]
                  : null,
            ),
            child: Opacity(
              opacity: enabled ? 1 : 0.32,
              child: Icon(
                icon,
                size: size * 0.42,
                color: accented ? Colors.white : RemoteTheme.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopRow extends StatelessWidget {
  const _TopRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RemoteButton(
          icon: Icons.power_settings_new,
          tvKey: RemoteKey.power,
          label: 'Power',
          tone: const Color(0xFFD9414E),
        ),
        const _RemoteButton(
          icon: Icons.input,
          tvKey: RemoteKey.input,
          label: 'Source',
        ),
        const _RemoteButton(
          icon: Icons.home_outlined,
          tvKey: RemoteKey.home,
          label: 'Home',
        ),
        const _RemoteButton(
          icon: Icons.volume_off,
          tvKey: RemoteKey.mute,
          label: 'Mute',
        ),
      ],
    );
  }
}

/// The directional cluster. Laid out as a square so the thumb can find OK
/// without looking — the whole point of a phone remote used in the dark.
class _RockerRow extends StatelessWidget {
  const _RockerRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _Rocker(
          upKey: RemoteKey.volumeUp,
          downKey: RemoteKey.volumeDown,
          label: 'VOL',
          upIcon: Icons.add,
          downIcon: Icons.remove,
        ),
        _Rocker(
          upKey: RemoteKey.channelUp,
          downKey: RemoteKey.channelDown,
          label: 'CH',
          upIcon: Icons.keyboard_arrow_up,
          downIcon: Icons.keyboard_arrow_down,
        ),
      ],
    );
  }
}

/// Volume and channel as a single rocker.
///
/// On a physical remote these are one piece that tilts, and the label sits
/// between the ends. Two separate round keys lose that relationship and cost
/// twice the width, which matters on a page the thumb has to cover one-handed.
class _Rocker extends StatelessWidget {
  const _Rocker({
    required this.upKey,
    required this.downKey,
    required this.label,
    required this.upIcon,
    required this.downIcon,
  });

  final RemoteKey upKey;
  final RemoteKey downKey;
  final String label;
  final IconData upIcon;
  final IconData downIcon;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();

    return Container(
      width: 84,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(42),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF17262A), Color(0xFF0D171A)],
        ),
        border: Border.all(color: RemoteTheme.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RockerEnd(
            icon: upIcon,
            tvKey: upKey,
            label: '$label up',
            enabled: controller.supportedKeys.contains(upKey),
          ),
          Text(
            label,
            style: const TextStyle(
              color: RemoteTheme.textMuted,
              fontSize: 10,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w600,
            ),
          ),
          _RockerEnd(
            icon: downIcon,
            tvKey: downKey,
            label: '$label down',
            enabled: controller.supportedKeys.contains(downKey),
          ),
        ],
      ),
    );
  }
}

class _RockerEnd extends StatelessWidget {
  const _RockerEnd({
    required this.icon,
    required this.tvKey,
    required this.label,
    required this.enabled,
  });

  final IconData icon;
  final RemoteKey tvKey;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: PressFeedback(
        scale: 0.88,
        onTap: enabled ? () => pressKey(context, tvKey) : null,
        child: SizedBox(
          width: 84,
          height: 64,
          child: Opacity(
            opacity: enabled ? 1 : 0.32,
            child: Icon(icon, size: 26, color: RemoteTheme.text),
          ),
        ),
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RemoteButton(
          icon: Icons.fast_rewind,
          tvKey: RemoteKey.rewind,
          label: 'Rewind',
          size: 54,
        ),
        _RemoteButton(
          icon: Icons.play_arrow,
          tvKey: RemoteKey.play,
          label: 'Play',
          size: 54,
        ),
        _RemoteButton(
          icon: Icons.pause,
          tvKey: RemoteKey.pause,
          label: 'Pause',
          size: 54,
        ),
        _RemoteButton(
          icon: Icons.fast_forward,
          tvKey: RemoteKey.fastForward,
          label: 'Forward',
          size: 54,
        ),
      ],
    );
  }
}

/// Search plus the three channels worth a dedicated button, and a way into the
/// full list. Hidden entirely on sets whose protocol cannot launch channels.
class _ShortcutBar extends StatelessWidget {
  const _ShortcutBar();

  /// Resolved by name against the TV's live list rather than by hardcoded id,
  /// so a set that numbers its channels differently still works.
  static const List<String> _quick = ['Netflix', 'YouTube', 'Prime Video'];

  /// Runs a launch and reports failure as a snack bar.
  ///
  /// The error banner lives at the top of a scrolling page, so a failure
  /// triggered from these controls — which sit at the bottom — used to leave no
  /// visible trace at all. A snack bar shows wherever the user is looking.
  static Future<void> _launch(
    BuildContext context,
    Future<bool> Function() action,
    String failureMessage,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await action();
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();
    if (!controller.supportsChannels) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.search, size: 18),
              label: const Text('Search'),
              onPressed: controller.openSearch,
            ),
            for (final name in _quick)
              ActionChip(
                label: Text(name),
                onPressed: () => _launch(
                  context,
                  () => controller.launchChannelNamed(name),
                  '$name did not open',
                ),
              ),
            ActionChip(
              avatar: const Icon(Icons.grid_view, size: 18),
              label: const Text('Channels'),
              onPressed: () => _showChannels(context),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _showChannels(BuildContext context) {
    final controller = context.read<RemoteController>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (_, scrollController) => FutureBuilder<List<RokuChannel>>(
          // Fetched on open rather than cached: the list changes whenever a
          // channel is installed, and it is one request on a live session.
          future: controller.fetchChannels(),
          builder: (_, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final channels = snapshot.data ?? const <RokuChannel>[];
            if (channels.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('The TV did not return a channel list.'),
                ),
              );
            }
            return ListView.builder(
              controller: scrollController,
              itemCount: channels.length,
              itemBuilder: (_, i) {
                final channel = channels[i];
                return ListTile(
                  leading: Icon(
                    channel.isInput ? Icons.input : Icons.play_circle_outline,
                  ),
                  title: Text(channel.name),
                  // Inputs sit in the same list as channels but are a
                  // different kind of thing, so they are labelled.
                  subtitle: channel.isInput ? const Text('TV input') : null,
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.of(sheetContext).pop();
                    final ok = await controller.launchChannel(channel.id);
                    if (!ok) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('${channel.name} did not open')),
                      );
                    }
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// Collapsed by default — most sessions never need it, and it doubles the
/// height of the page when open.
class _NumberPad extends StatefulWidget {
  const _NumberPad();

  @override
  State<_NumberPad> createState() => _NumberPadState();
}

class _NumberPadState extends State<_NumberPad> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();
    final hasDigits = controller.supportedKeys.contains(RemoteKey.digit1);
    if (!hasDigits) return const SizedBox.shrink();

    return Column(
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(_open ? Icons.expand_less : Icons.dialpad),
          label: Text(_open ? 'Hide keypad' : 'Channel keypad'),
        ),
        if (_open)
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.6,
            children: [
              for (var n = 1; n <= 9; n++) _DigitButton(n),
              const SizedBox.shrink(),
              const _DigitButton(0),
              const SizedBox.shrink(),
            ],
          ),
      ],
    );
  }
}

class _DigitButton extends StatelessWidget {
  const _DigitButton(this.digit);
  final int digit;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: () => pressKey(context, RemoteKey.digit(digit)),
      child: Text('$digit', style: const TextStyle(fontSize: 20)),
    );
  }
}

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.state});
  final RemoteConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (color, tip) = switch (state) {
      RemoteConnectionState.connected => (Colors.greenAccent, 'Connected'),
      RemoteConnectionState.connecting => (Colors.amber, 'Connecting…'),
      RemoteConnectionState.failed => (Colors.redAccent, 'Disconnected'),
      RemoteConnectionState.idle => (Colors.grey, 'Idle'),
    };
    return Tooltip(
      message: tip,
      child: Icon(Icons.circle, size: 12, color: color),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
