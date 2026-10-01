import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';

import '../core/remote_controller.dart';
import '../core/remote_key.dart';
import '../storage/preferences.dart';
import 'voice_sheet.dart';
import 'tools_page.dart';
import 'activities_page.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key});
  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  bool _touchpad = false;
  int _tab = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<RemoteController>().refreshApps();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    final prefs = context.watch<Preferences>();
    final device = c.activeDevice;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(device?.name ?? 'Room Remote'),
            Text(
              device == null ? 'Choose a TV' : prefs.room(device.id),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const ToolsPage())),
            icon: const Icon(Icons.tune),
            tooltip: 'Settings and connection doctor',
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.settings_remote_outlined),
            label: 'Remote',
          ),
          NavigationDestination(icon: Icon(Icons.apps), label: 'Apps & inputs'),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            label: 'Activities',
          ),
        ],
      ),
      body: SafeArea(
        child: _tab == 2
            ? const ActivitiesPage(embedded: true)
            : _tab == 1
            ? const AppsPanel()
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Card(
                    child: ListTile(
                      leading: Icon(
                        c.state == RemoteConnectionState.connected
                            ? Icons.wifi
                            : Icons.wifi_off,
                      ),
                      title: Text(switch (c.state) {
                        RemoteConnectionState.connected =>
                          'Control session ready',
                        RemoteConnectionState.connecting => 'Connecting…',
                        RemoteConnectionState.failed =>
                          'Connection needs attention',
                        _ => 'Not connected',
                      }),
                      subtitle: Text(
                        c.lastResult?.message ??
                            'Choose an action. The TV stays in your control.',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.medical_services_outlined),
                        tooltip: 'Connection doctor',
                        onPressed: () {
                          c.diagnose();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ToolsPage(),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  if (c.error != null)
                    MaterialBanner(
                      content: Text(c.error!),
                      actions: [
                        TextButton(
                          onPressed: c.clearError,
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                  if (c.activityRunning)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'An activity is running. Stop it in Activities before using manual controls.',
                      ),
                    ),
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.spaceEvenly,
                    spacing: 12,
                    runSpacing: 12,
                    children: const [
                      RemoteButton(
                        RemoteKey.power,
                        Icons.power_settings_new,
                        'Power',
                      ),
                      RemoteButton(RemoteKey.home, Icons.home_outlined, 'Home'),
                      RemoteButton(RemoteKey.back, Icons.arrow_back, 'Back'),
                      RemoteButton(
                        RemoteKey.mute,
                        Icons.volume_off_outlined,
                        'Mute',
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  if (!prefs.simple)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ChoiceChip(
                          label: const Text('Buttons'),
                          selected: !_touchpad,
                          onSelected: (_) => setState(() => _touchpad = false),
                        ),
                        const SizedBox(width: 10),
                        ChoiceChip(
                          label: const Text('Touchpad'),
                          selected: _touchpad,
                          onSelected: (_) => setState(() => _touchpad = true),
                        ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  if (_touchpad && !prefs.simple)
                    const Touchpad()
                  else
                    const DirectionPad(),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    textDirection: prefs.leftHanded
                        ? TextDirection.rtl
                        : TextDirection.ltr,
                    children: [
                      const Column(
                        children: [
                          RemoteButton(
                            RemoteKey.volumeUp,
                            Icons.add,
                            'Volume up',
                            repeat: true,
                          ),
                          SizedBox(height: 10),
                          RemoteButton(
                            RemoteKey.volumeDown,
                            Icons.remove,
                            'Volume down',
                            repeat: true,
                          ),
                        ],
                      ),
                      Column(
                        children: [
                          if (c.supportedKeys.contains(RemoteKey.playPause))
                            const RemoteButton(
                              RemoteKey.playPause,
                              Icons.play_arrow,
                              'Play / pause',
                            )
                          else ...[
                            const RemoteButton(
                              RemoteKey.play,
                              Icons.play_arrow,
                              'Play',
                            ),
                            const SizedBox(height: 10),
                            const RemoteButton(
                              RemoteKey.pause,
                              Icons.pause,
                              'Pause',
                            ),
                          ],
                        ],
                      ),
                      if (!prefs.simple)
                        const Column(
                          children: [
                            RemoteButton(
                              RemoteKey.channelUp,
                              Icons.keyboard_arrow_up,
                              'Channel up',
                              repeat: true,
                            ),
                            SizedBox(height: 10),
                            RemoteButton(
                              RemoteKey.channelDown,
                              Icons.keyboard_arrow_down,
                              'Channel down',
                              repeat: true,
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: c.capabilities.text && !c.activityRunning
                            ? () => _input(true)
                            : null,
                        icon: const Icon(Icons.mic_none),
                        label: const Text('Voice search'),
                      ),
                      OutlinedButton.icon(
                        onPressed: c.capabilities.text && !c.activityRunning
                            ? () => _input(false)
                            : null,
                        icon: const Icon(Icons.keyboard_outlined),
                        label: const Text('Keyboard'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            c.capabilities.audioState && !c.activityRunning
                            ? () async {
                                if (c.quietActive) {
                                  final restore = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Restore the sound?'),
                                      content: const Text(
                                        'Only restore if nobody else is intentionally keeping the TV muted.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Keep quiet'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Restore'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (restore != true) return;
                                }
                                await c.quietMoment();
                              }
                            : null,
                        icon: const Icon(Icons.nights_stay_outlined),
                        label: Text(
                          c.quietActive ? 'Restore sound' : 'Quiet moment',
                        ),
                      ),
                    ],
                  ),
                  if (!prefs.simple) ...[
                    const SizedBox(height: 20),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: const [
                        RemoteButton(
                          RemoteKey.rewind,
                          Icons.fast_rewind,
                          'Rewind',
                        ),
                        RemoteButton(
                          RemoteKey.fastForward,
                          Icons.fast_forward,
                          'Forward',
                        ),
                        RemoteButton(
                          RemoteKey.info,
                          Icons.info_outline,
                          'Info',
                        ),
                        RemoteButton(RemoteKey.menu, Icons.menu, 'Menu'),
                      ],
                    ),
                    if (c.supportedKeys.contains(RemoteKey.digit1))
                      ExpansionTile(
                        title: const Text('Number pad'),
                        children: [
                          Wrap(
                            spacing: 8,
                            children: [
                              for (var n = 0; n < 10; n++)
                                TextButton(
                                  onPressed: c.activityRunning
                                      ? null
                                      : () => c.sendKey(RemoteKey.digit(n)),
                                  child: Text('$n'),
                                ),
                            ],
                          ),
                        ],
                      ),
                  ],
                  const SizedBox(height: 24),
                  const Text('FAVOURITES'),
                  const SizedBox(height: 10),
                  const FavouriteRow(),
                ],
              ),
      ),
    );
  }

  void _input(bool voice) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => VoiceSheet(voice: voice),
  );
}

class RemoteButton extends StatefulWidget {
  const RemoteButton(
    this.tvKey,
    this.icon,
    this.label, {
    super.key,
    this.repeat = false,
  });
  final RemoteKey tvKey;
  final IconData icon;
  final String label;
  final bool repeat;
  @override
  State<RemoteButton> createState() => _RemoteButtonState();
}

class _RemoteButtonState extends State<RemoteButton>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _held = false;
  }

  bool _held = false, _sending = false;
  static final _tts = FlutterTts();
  Future<void> _press() async {
    if (_sending || !mounted) return;
    final c = context.read<RemoteController>();
    final p = context.read<Preferences>();
    if (c.activityRunning) return;
    _sending = true;
    try {
      if (p.haptics) unawaited(HapticFeedback.selectionClick());
      if (p.spoken && !_held) {
        await _tts.stop();
        unawaited(_tts.speak(widget.label));
      }
      await c.sendKey(widget.tvKey);
    } finally {
      _sending = false;
    }
  }

  Future<void> _repeat() async {
    _held = true;
    final controller = context.read<RemoteController>();
    final device = controller.activeDevice?.id;
    for (var count = 0; _held && mounted && count < 30; count++) {
      if (controller.activeDevice?.id != device ||
          controller.state == RemoteConnectionState.failed) {
        break;
      }
      await _press();
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    _held = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _held = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    final enabled =
        c.supportedKeys.contains(widget.tvKey) && !c.activityRunning;
    if (!c.supportedKeys.contains(widget.tvKey)) return const SizedBox.shrink();
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: enabled ? _press : null,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 88,
          height: 82,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: Listener(
              onPointerUp: (_) => _held = false,
              onPointerCancel: (_) => _held = false,
              child: InkWell(
                onTap: enabled ? _press : null,
                onLongPress: enabled && widget.repeat ? _repeat : null,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon, size: 28),
                    const SizedBox(height: 5),
                    Text(
                      widget.label,
                      style: Theme.of(context).textTheme.labelSmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DirectionPad extends StatelessWidget {
  const DirectionPad({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(36),
        ),
        child: const Column(
          children: [
            RemoteButton(
              RemoteKey.up,
              Icons.keyboard_arrow_up,
              'Up',
              repeat: true,
            ),
            SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RemoteButton(
                  RemoteKey.left,
                  Icons.keyboard_arrow_left,
                  'Left',
                  repeat: true,
                ),
                SizedBox(width: 8),
                RemoteButton(RemoteKey.select, Icons.check, 'OK'),
                SizedBox(width: 8),
                RemoteButton(
                  RemoteKey.right,
                  Icons.keyboard_arrow_right,
                  'Right',
                  repeat: true,
                ),
              ],
            ),
            SizedBox(height: 8),
            RemoteButton(
              RemoteKey.down,
              Icons.keyboard_arrow_down,
              'Down',
              repeat: true,
            ),
          ],
        ),
      ),
    ),
  );
}

class Touchpad extends StatefulWidget {
  const Touchpad({super.key});
  @override
  State<Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<Touchpad> {
  Offset _delta = Offset.zero;
  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Touchpad. Swipe to move; tap to select. Use Buttons mode for labelled controls.',
    child: GestureDetector(
      onTap: () => context.read<RemoteController>().sendKey(RemoteKey.select),
      onPanStart: (_) => _delta = Offset.zero,
      onPanUpdate: (d) => _delta += d.delta,
      onPanEnd: (_) {
        if (_delta.distance < 20) return;
        final key = _delta.dx.abs() > _delta.dy.abs()
            ? (_delta.dx > 0 ? RemoteKey.right : RemoteKey.left)
            : (_delta.dy > 0 ? RemoteKey.down : RemoteKey.up);
        context.read<RemoteController>().sendKey(key);
      },
      child: Container(
        height: 260,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(32),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.touch_app_outlined, size: 42),
              SizedBox(height: 12),
              Text('Swipe to move · Tap to select'),
            ],
          ),
        ),
      ),
    ),
  );
}

class FavouriteRow extends StatelessWidget {
  const FavouriteRow({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    final p = context.watch<Preferences>();
    final id = c.activeDevice?.id ?? '';
    final favourites = c.apps.where((a) => p.favourites(id).contains(a.id));
    if (favourites.isEmpty) {
      return const Text('Star apps or inputs in the Apps & inputs tab.');
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: favourites
          .map(
            (a) => ActionChip(
              label: Text(p.alias(id, a.id, a.name)),
              onPressed: c.activityRunning ? null : () => c.launchApp(a.id),
            ),
          )
          .toList(),
    );
  }
}

class AppsPanel extends StatelessWidget {
  const AppsPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    final p = context.watch<Preferences>();
    final id = c.activeDevice?.id ?? '';
    if (!c.capabilities.apps) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This adapter does not expose an app list yet. Use Home and the direction buttons on your TV.',
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: c.refreshApps,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Your apps & inputs',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                onPressed: c.refreshApps,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh apps',
              ),
            ],
          ),
          const Text(
            'Tap to open. Star a favourite. Hold a name to give it a friendly label.',
          ),
          if (c.error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(c.error!)),
          if (c.apps.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No app list loaded. Tap refresh to try again.'),
            ),
          for (final app in c.apps)
            Card(
              child: ListTile(
                leading: Icon(
                  app.isInput ? Icons.input : Icons.play_circle_outline,
                ),
                title: Text(p.alias(id, app.id, app.name)),
                subtitle: Text(app.isInput ? 'TV input' : 'App'),
                trailing: IconButton(
                  icon: Icon(
                    p.favourites(id).contains(app.id)
                        ? Icons.star
                        : Icons.star_border,
                  ),
                  tooltip: 'Toggle favourite',
                  onPressed: () => p.favourite(id, app.id),
                ),
                onTap: c.activityRunning
                    ? null
                    : () async {
                        if (await c.launchApp(app.id)) {
                          await p.recordLaunch(id, app.id);
                        }
                      },
                onLongPress: () async {
                  final value = await askText(
                    context,
                    'Name this app or input',
                    p.alias(id, app.id, app.name),
                  );
                  if (value != null && value.trim().isNotEmpty) {
                    await p.setAlias(id, app.id, value);
                  }
                },
              ),
            ),
          if (p.learn)
            for (final app in c.apps.where(
              (a) =>
                  p.launches(id, a.id) >= 3 && !p.favourites(id).contains(a.id),
            ))
              Card(
                child: ListTile(
                  title: Text('Make ${app.name} easier to reach?'),
                  subtitle: const Text(
                    'You opened it several times. Save it as a favourite.',
                  ),
                  trailing: TextButton(
                    onPressed: () => p.favourite(id, app.id),
                    child: const Text('Save'),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

Future<String?> askText(
  BuildContext context,
  String title,
  String value,
) async {
  final input = TextEditingController(text: value);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: input, autofocus: true, maxLength: 60),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, input.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // Wait for the route transition before disposing its field controller.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  input.dispose();
  return result;
}
