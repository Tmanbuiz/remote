import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/remote_controller.dart';
import '../core/remote_key.dart';
import '../features/activity.dart';
import '../storage/preferences.dart';

class ActivitiesPage extends StatelessWidget {
  const ActivitiesPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    final p = context.watch<Preferences>();
    final body = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Make the room ready',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Build explicit steps across your saved TVs. Each result reports what the adapter knows. Stop at any time; completed commands cannot be undone.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: c.activityRunning || c.savedDevices.isEmpty
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ActivityEditor(),
                  ),
                ),
          icon: const Icon(Icons.add),
          label: const Text('Create activity'),
        ),
        if (p.activities.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Try “Watch a film”: wake the TV, wait a few seconds, then open your favourite app.',
            ),
          ),
        for (final a in p.activities)
          Card(
            child: ListTile(
              title: Text(a.name),
              subtitle: Text('${a.steps.length} steps'),
              leading: IconButton(
                icon: const Icon(Icons.play_circle),
                tooltip: 'Run activity',
                onPressed: c.activityRunning ? null : () => c.runActivity(a),
              ),
              trailing: PopupMenuButton<String>(
                enabled: !c.activityRunning,
                onSelected: (v) {
                  if (v == 'delete') {
                    p.removeActivity(a.id);
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ActivityEditor(activity: a),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          ),
        if (c.activityRunning)
          OutlinedButton.icon(
            onPressed: c.cancelActivity,
            icon: const Icon(Icons.stop),
            label: const Text('Stop activity'),
          ),
        if (c.activityLog.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('ACTIVITY RESULTS'),
          for (final line in c.activityLog)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(line),
            ),
        ],
      ],
    );
    return embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('Activities')),
            body: body,
          );
  }
}

class ActivityEditor extends StatefulWidget {
  const ActivityEditor({super.key, this.activity});
  final Activity? activity;
  @override
  State<ActivityEditor> createState() => _ActivityEditorState();
}

class _ActivityEditorState extends State<ActivityEditor> {
  late final TextEditingController _name;
  late final List<ActivityStep> _steps;
  String? _device;
  StepKind _kind = StepKind.key;
  String _value = RemoteKey.home.name;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: widget.activity?.name ?? 'Watch a film',
    );
    _steps = [...?widget.activity?.steps];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    _device ??= c.activeDevice?.id ?? c.savedDevices.firstOrNull?.id;
    final choices = switch (_kind) {
      StepKind.key =>
        c.activeDevice?.id == _device
            ? c.supportedKeys.map((k) => (k.name, k.name)).toList()
            : <(String, String)>[],
      StepKind.app =>
        c.activeDevice?.id == _device
            ? c.apps.map((a) => (a.id, a.name)).toList()
            : <(String, String)>[],
      StepKind.wait => [
        ('1', '1 second'),
        ('3', '3 seconds'),
        ('5', '5 seconds'),
        ('10', '10 seconds'),
        ('20', '20 seconds'),
      ],
      StepKind.wake => [('wake', 'Send Wake-on-LAN packet')],
    };
    if (!choices.any((v) => v.$1 == _value)) {
      _value = choices.firstOrNull?.$1 ?? '';
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Activity builder')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Activity name'),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _device,
            decoration: const InputDecoration(
              labelText: 'TV for the next step',
            ),
            isExpanded: true,
            items: c.savedDevices
                .map((d) => DropdownMenuItem(value: d.id, child: Text(d.name)))
                .toList(),
            onChanged: (v) async {
              setState(() {
                _device = v;
              });
              final d = c.savedDevices.where((d) => d.id == v).firstOrNull;
              if (d != null) {
                await c.select(d);
                await c.refreshApps();
              }
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<StepKind>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Action'),
            items: const [
              DropdownMenuItem(
                value: StepKind.key,
                child: Text('Press a button'),
              ),
              DropdownMenuItem(
                value: StepKind.app,
                child: Text('Open app / input'),
              ),
              DropdownMenuItem(value: StepKind.wait, child: Text('Wait')),
              DropdownMenuItem(value: StepKind.wake, child: Text('Wake TV')),
            ],
            onChanged: (v) => setState(() => _kind = v!),
          ),
          const SizedBox(height: 12),
          if (choices.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey('$_device:$_kind:$_value'),
              initialValue: _value,
              isExpanded: true,
              items: choices
                  .map((v) => DropdownMenuItem(value: v.$1, child: Text(v.$2)))
                  .toList(),
              onChanged: (v) => setState(() => _value = v!),
            )
          else
            const Text(
              'Connect to this TV and refresh its apps to choose supported actions.',
            ),
          TextButton.icon(
            onPressed: () => c.refreshApps(),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh app choices'),
          ),
          FilledButton.tonalIcon(
            onPressed: _device == null || _value.isEmpty || _steps.length >= 20
                ? null
                : () => setState(
                    () => _steps.add(
                      ActivityStep(
                        deviceId: _device!,
                        kind: _kind,
                        value: _value,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.add),
            label: const Text('Add step'),
          ),
          const SizedBox(height: 20),
          for (var i = 0; i < _steps.length; i++)
            Card(
              child: ListTile(
                title: Text(
                  '${i + 1}. ${_steps[i].kind.name}: ${_steps[i].value}',
                ),
                subtitle: Text(
                  c.savedDevices
                          .where((d) => d.id == _steps[i].deviceId)
                          .firstOrNull
                          ?.name ??
                      'Removed TV',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: 'Move step up',
                      onPressed: i == 0
                          ? null
                          : () => setState(() {
                              final s = _steps.removeAt(i);
                              _steps.insert(i - 1, s);
                            }),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove step',
                      onPressed: () => setState(() => _steps.removeAt(i)),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _steps.isEmpty
                ? null
                : () async {
                    if (_name.text.trim().isEmpty) return;
                    await context.read<Preferences>().saveActivity(
                      Activity(
                        id:
                            widget.activity?.id ??
                            DateTime.now().microsecondsSinceEpoch.toString(),
                        name: _name.text.trim(),
                        steps: List.of(_steps),
                      ),
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
            child: const Text('Save activity'),
          ),
        ],
      ),
    );
  }
}
