import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/remote_controller.dart';

/// Keyboard and voice entry.
///
/// Both routes end at [RemoteController.sendText], which every protocol
/// implements, so this works on Roku, Samsung and LG alike. Text goes to
/// whatever field the TV currently has focused, so open a search box there
/// first — on Roku the Search chip does that for you.
class TextEntryBar extends StatelessWidget {
  const TextEntryBar({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();
    final enabled = controller.state == RemoteConnectionState.connected;

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        ActionChip(
          avatar: const Icon(Icons.keyboard, size: 18),
          label: const Text('Keyboard'),
          onPressed: enabled ? () => _showKeyboard(context) : null,
        ),
        ActionChip(
          avatar: const Icon(Icons.mic, size: 18),
          label: const Text('Voice search'),
          onPressed: enabled ? () => _showVoice(context) : null,
        ),
      ],
    );
  }

  static Future<void> _showKeyboard(BuildContext context) async {
    final controller = context.read<RemoteController>();
    await showDialog<void>(
      context: context,
      builder: (_) => _KeyboardDialog(controller: controller),
    );
  }

  static Future<void> _showVoice(BuildContext context) async {
    final controller = context.read<RemoteController>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _VoiceSheet(controller: controller),
    );
  }
}

class _KeyboardDialog extends StatefulWidget {
  const _KeyboardDialog({required this.controller});

  final RemoteController controller;

  @override
  State<_KeyboardDialog> createState() => _KeyboardDialogState();
}

class _KeyboardDialogState extends State<_KeyboardDialog> {
  final TextEditingController _field = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _field.text;
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    await widget.controller.sendText(text);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Keyboard'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Goes to the box your TV has selected, one letter at a time. '
            'Open a search field on the TV first.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _field,
            autofocus: true,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: const InputDecoration(
              hintText: 'Type here',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: _sending
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Send'),
        ),
      ],
    );
  }
}

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet({required this.controller});

  final RemoteController controller;

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  final SpeechToText _speech = SpeechToText();
  String _heard = '';
  String? _problem;
  bool _listening = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_speech.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    // initialize() is what triggers the microphone and speech permission
    // prompts; it returns false if either is refused or no recognizer exists.
    final ready = await _speech.initialize(
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          _problem = 'Did not catch that. Try again.';
        });
      },
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'done' || status == 'notListening') {
          setState(() => _listening = false);
        }
      },
    );
    if (!mounted) return;
    if (!ready) {
      setState(() {
        _listening = false;
        _problem = 'Voice search needs microphone and speech permission, '
            'and a speech recognizer on this phone.';
      });
      return;
    }
    setState(() {
      _problem = null;
      _listening = true;
      _heard = '';
    });
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _heard = result.recognizedWords);
      },
      listenOptions: SpeechListenOptions(partialResults: true),
    );
  }

  Future<void> _sendHeard() async {
    if (_heard.isEmpty || _sending) return;
    setState(() => _sending = true);
    await _speech.stop();
    await widget.controller.sendText(_heard);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24, 24, 24, 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_listening ? Icons.mic : Icons.mic_off,
                  color: _listening ? theme.colorScheme.primary : theme.disabledColor),
              const SizedBox(width: 12),
              Text(
                _listening ? 'Listening…' : 'Voice search',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_problem != null)
            Text(_problem!, style: TextStyle(color: theme.colorScheme.error))
          else
            Text(
              _heard.isEmpty ? 'Say what to search for on the TV' : _heard,
              style: _heard.isEmpty
                  ? theme.textTheme.bodyMedium?.copyWith(color: theme.disabledColor)
                  : theme.textTheme.headlineSmall,
            ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              if (_problem != null || !_listening)
                TextButton(
                  onPressed: _sending ? null : _start,
                  child: const Text('Try again'),
                ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _heard.isEmpty || _sending ? null : _sendHeard,
                child: _sending
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send to TV'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
