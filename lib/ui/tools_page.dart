import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/remote_controller.dart';
import '../core/remote_key.dart';
import '../storage/preferences.dart';
import 'remote_page.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    final p = context.watch<Preferences>();
    final d = c.activeDevice;
    return Scaffold(
      appBar: AppBar(title: const Text('Make it yours')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Comfort & access',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          SwitchListTile(
            title: const Text('Simple mode'),
            subtitle: const Text(
              'Keep the essential controls, with stable positions.',
            ),
            value: p.simple,
            onChanged: (v) => p.setBool('simple', v),
          ),
          SwitchListTile(
            title: const Text('Left-handed layout'),
            value: p.leftHanded,
            onChanged: (v) => p.setBool('leftHanded', v),
          ),
          SwitchListTile(
            title: const Text('Button vibration'),
            value: p.haptics,
            onChanged: (v) => p.setBool('haptics', v),
          ),
          SwitchListTile(
            title: const Text('Speak button names'),
            subtitle: const Text('Uses your phone’s text-to-speech engine.'),
            value: p.spoken,
            onChanged: (v) => p.setBool('spoken', v),
          ),
          SwitchListTile(
            title: const Text('Suggest favourites'),
            subtitle: const Text(
              'Count app launches on this phone. Turning this off clears those counts. Voice text is never counted or saved.',
            ),
            value: p.learn,
            onChanged: (v) => p.setBool('learn', v),
          ),
          ListTile(
            leading: const Icon(Icons.school_outlined),
            title: const Text('Practise using the remote'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const PracticePage()),
            ),
          ),
          if (d != null) ...[
            const Divider(height: 32),
            Text('This room', style: Theme.of(context).textTheme.headlineSmall),
            ListTile(
              title: const Text('Room name'),
              subtitle: Text(p.room(d.id)),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final name = await askText(context, 'Room name', p.room(d.id));
                if (name != null) await p.setRoom(d.id, name);
              },
            ),
            ListTile(
              title: const Text('TV name'),
              subtitle: Text(d.name),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final name = await askText(context, 'TV name', d.name);
                if (name != null) await c.rename(d, name);
              },
            ),
            ListTile(
              title: const Text('TV MAC address'),
              subtitle: Text(
                d.macAddress?.isNotEmpty == true
                    ? d.macAddress!
                    : 'Needed for Wake-on-LAN',
              ),
              onTap: () async {
                final mac = await askText(
                  context,
                  'MAC address (AA:BB:CC:DD:EE:FF)',
                  d.macAddress ?? '',
                );
                if (mac != null) await c.rename(d, d.name, mac: mac);
              },
            ),
            OutlinedButton.icon(
              onPressed: c.activityRunning ? null : () => c.wake(d),
              icon: const Icon(Icons.power),
              label: const Text('Send wake packet'),
            ),
            const Text(
              'Wake requires a compatible TV with network standby enabled. Sending a packet does not prove the TV turned on.',
            ),
            const SizedBox(height: 16),
            if (c.sleepAt != null)
              ListTile(
                title: const Text('Foreground sleep timer active'),
                subtitle: Text(
                  'Due ${c.sleepAt!.hour}:${c.sleepAt!.minute.toString().padLeft(2, '0')}',
                ),
                trailing: TextButton(
                  onPressed: c.cancelSleep,
                  child: const Text('Cancel'),
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: c.supportedKeys.contains(RemoteKey.powerOff)
                    ? () async {
                        final minutes = await showDialog<int>(
                          context: context,
                          builder: (ctx) => SimpleDialog(
                            title: const Text('Foreground sleep timer'),
                            children: [
                              const Padding(
                                padding: EdgeInsets.all(20),
                                child: Text(
                                  'Keep this app open and the phone awake. The timer is cancelled when the app leaves the foreground. For unattended sleep, use the TV’s own timer.',
                                ),
                              ),
                              for (final m in [15, 30, 60])
                                SimpleDialogOption(
                                  onPressed: () => Navigator.pop(ctx, m),
                                  child: Text('$m minutes'),
                                ),
                            ],
                          ),
                        );
                        if (minutes != null)
                          c.scheduleSleep(Duration(minutes: minutes));
                      }
                    : null,
                icon: const Icon(Icons.timer_outlined),
                label: const Text('Sleep timer'),
              ),
            const Divider(height: 32),
            Text(
              'Connection doctor',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const Text(
              'Check TV power, local-network permission, the same home network, guest-network isolation and the TV’s mobile-control setting.',
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: c.diagnose,
                  child: const Text('Run checks'),
                ),
                TextButton(
                  onPressed: c.activityRunning
                      ? null
                      : () async {
                          final yes = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Pair this TV again?'),
                              content: const Text(
                                'Check that this is your TV, then accept its pairing prompt. This also resets trust in its local certificate.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Pair again'),
                                ),
                              ],
                            ),
                          );
                          if (yes == true) await c.repairPairing(d);
                        },
                  child: const Text('Pair again'),
                ),
              ],
            ),
            for (final line in c.diagnostics.take(8))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(line),
              ),
            if (c.error != null)
              Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const Divider(height: 32),
            Text(
              'Compatibility record',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text('${d.brand.label} · ${d.model ?? 'Model unknown'}'),
            const Text(
              'Adapter available does not mean this model has been independently tested. Confirm actions on the TV and record your observation. Reports stay here until you copy and share them.',
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final capability in [
                  ('Keyboard', c.capabilities.text),
                  ('Apps', c.capabilities.apps),
                  ('Search navigation', c.capabilities.search),
                  ('Audio state', c.capabilities.audioState),
                ])
                  Chip(
                    label: Text(
                      '${capability.$1}: ${capability.$2 ? 'adapter supports' : 'unavailable'}',
                    ),
                  ),
              ],
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final report = c.compatibilityReport();
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Review compatibility report'),
                    content: SingleChildScrollView(
                      child: SelectableText(report),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Close'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: report));
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('Copy report'),
                      ),
                    ],
                  ),
                );
              },
              icon: const Icon(Icons.content_copy),
              label: const Text('Review and copy report'),
            ),
          ],
          const Divider(height: 32),
          const Text(
            'Local control. No account required.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'TV credentials are stored using protected platform storage. Speech recognition and text-to-speech use your phone’s services and may need an internet connection. No analytics or automatic report uploads are included.',
          ),
        ],
      ),
    );
  }
}

class PracticePage extends StatefulWidget {
  const PracticePage({super.key});
  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
  int _step = 0;
  final _steps = const [
    (RemoteKey.home, 'Find Home', 'This opens the TV’s home screen.'),
    (RemoteKey.right, 'Move right', 'Use an arrow to move the selection.'),
    (RemoteKey.select, 'Choose OK', 'OK opens the selected item.'),
    (RemoteKey.back, 'Go back', 'Back returns to the previous screen.'),
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Practice remote')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Practice mode does not send commands to your TV.'),
          const SizedBox(height: 24),
          Text(
            _step == _steps.length ? 'You have the basics.' : _steps[_step].$2,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            _step == _steps.length
                ? 'You can practise again or return to your TV.'
                : _steps[_step].$3,
          ),
          const SizedBox(height: 24),
          for (final s in _steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: FilledButton.tonal(
                onPressed: () {
                  if (_step < _steps.length && s.$1 == _steps[_step].$1) {
                    setState(() => _step++);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Try the button named in the instruction.',
                        ),
                      ),
                    );
                  }
                },
                child: Text(s.$1.name),
              ),
            ),
          if (_step == _steps.length)
            TextButton(
              onPressed: () => setState(() => _step = 0),
              child: const Text('Practise again'),
            ),
        ],
      ),
    ),
  );
}
