import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/remote_controller.dart';

/// One recognizer instance per application process, initialized with callbacks
/// that are routed only to the currently mounted sheet.
class VoiceSession {
  static final speech = SpeechToText();
  static void Function(String)? status;
  static void Function(String)? error;
  static Future<bool> initialize() => speech.initialize(
    onStatus: (s) => status?.call(s),
    onError: (e) => error?.call(e.errorMsg),
  );
}

class VoiceSheet extends StatefulWidget {
  const VoiceSheet({super.key, this.voice = false});
  final bool voice;
  @override
  State<VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<VoiceSheet> with WidgetsBindingObserver {
  final _text = TextEditingController();
  String? _message, _locale;
  List<LocaleName> _locales = [];
  bool _busy = false, _listening = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VoiceSession.status = (s) {
      if (mounted)
        setState(() => _listening = s == SpeechToText.listeningStatus);
    };
    VoiceSession.error = (_) {
      if (mounted)
        setState(() {
          _message =
              'Speech recognition stopped. Try again or type your search.';
          _listening = false;
        });
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) VoiceSession.speech.cancel();
  }

  Future<void> _listen() async {
    if (_listening) {
      await VoiceSession.speech.stop();
      return;
    }
    try {
      if (!await VoiceSession.initialize()) {
        if (mounted)
          setState(
            () => _message = 'Microphone or speech permission is unavailable. Enable it in phone settings, or use the keyboard.',
          );
        return;
      }
      final locales = await VoiceSession.speech.locales();
      if (!mounted) return;
      setState(() {
        _locales = locales;
        _message = null;
        _listening = true;
      });
      await VoiceSession.speech.listen(
        localeId: _locale,
        listenFor: const Duration(seconds: 25),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.search,
        ),
        onResult: (r) {
          if (mounted)
            setState(() {
              _text.text = r.recognizedWords;
              _text.selection = TextSelection.collapsed(
                offset: _text.text.length,
              );
            });
        },
      );
    } catch (_) {
      if (mounted)
        setState(() {
          _listening = false;
          _message = 'Voice is unavailable on this phone. You can still type.';
        });
    }
  }

  Future<void> _send(bool search) async {
    final controller = context.read<RemoteController>();
    final id = controller.activeDevice?.id;
    await VoiceSession.speech.stop();
    if (!mounted || _text.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final ok =
        id == controller.activeDevice?.id &&
        await controller.sendText(_text.text.trim(), search: search);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok
          ? 'Text sent. Check the TV screen.'
          : controller.error ?? 'Text could not be sent.';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VoiceSession.status = null;
    VoiceSession.error = null;
    VoiceSession.speech.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RemoteController>();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.voice ? 'Say what you want to find' : 'Type on your TV',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Review the words before sending. Your phone’s speech service may process audio online. This app does not save your recordings or search text.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Search or text',
                border: OutlineInputBorder(),
              ),
            ),
            if (_locales.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: _locale,
                decoration: const InputDecoration(
                  labelText: 'Recognition language',
                ),
                items: _locales
                    .map(
                      (l) => DropdownMenuItem(
                        value: l.localeId,
                        child: Text(l.name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                isExpanded: true,
                onChanged: _listening
                    ? null
                    : (v) => setState(() => _locale = v),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _listen,
              icon: Icon(_listening ? Icons.stop_circle : Icons.mic_none),
              label: Text(_listening ? 'Stop listening' : 'Start voice input'),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_message!, semanticsLabel: _message),
              ),
            if (c.capabilities.search)
              FilledButton.icon(
                onPressed: _busy || _listening ? null : () => _send(true),
                icon: const Icon(Icons.search),
                label: const Text('Open TV search and send'),
              ),
            FilledButton.tonal(
              onPressed: _busy || _listening || !c.capabilities.text
                  ? null
                  : () => _send(false),
              child: const Text('Send to the focused TV text field'),
            ),
            if (!c.capabilities.search)
              const Text(
                'Open the search field on your TV first. Automatic search navigation is not available for this adapter.',
              ),
          ],
        ),
      ),
    );
  }
}
