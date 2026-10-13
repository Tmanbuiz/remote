import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/tv_protocol.dart';

class PairingCodeDialog extends StatefulWidget {
  const PairingCodeDialog({
    super.key,
    required this.tvName,
    required this.length,
    required this.hex,
    required this.submit,
    this.message,
  });
  final String tvName;
  final int length;
  final bool hex;
  final String? message;
  final Future<PairingResult> Function(String) submit;
  @override
  State<PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<PairingCodeDialog> {
  final _field = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _field.text.length != widget.length) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.submit(_field.text.toUpperCase());
    if (!mounted) return;
    if (result.status == PairingStatus.pinRequired) {
      setState(() {
        _busy = false;
        _error = result.message ?? 'Check the code on the TV.';
      });
    } else {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Pair ${widget.tvName}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message ?? 'Enter the code displayed on the TV.'),
          const SizedBox(height: 16),
          TextField(
            controller: _field,
            autofocus: true,
            enabled: !_busy,
            textCapitalization: TextCapitalization.characters,
            keyboardType: widget.hex
                ? TextInputType.text
                : TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp(widget.hex ? r'[0-9a-fA-F]' : r'[0-9]'),
              ),
              LengthLimitingTextInputFormatter(widget.length),
            ],
            decoration: InputDecoration(
              labelText: 'TV pairing code',
              helperText: widget.hex
                  ? 'Six characters, including letters A–F'
                  : 'Four digits',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy || _field.text.length != widget.length
            ? null
            : _submit,
        child: Text(_busy ? 'Verifying…' : 'Pair'),
      ),
    ],
  );
}
