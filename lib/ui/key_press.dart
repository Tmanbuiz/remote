import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/remote_controller.dart';
import '../core/remote_key.dart';

/// Sends a key with a haptic tick.
///
/// Shared by every control so the feel is identical wherever a key comes from.
/// Selection click is the lightest tick available; a remote pressed twenty
/// times in a row should not buzz like a notification.
Future<void> pressKey(BuildContext context, RemoteKey key) async {
  final controller = context.read<RemoteController>();
  unawaited(HapticFeedback.selectionClick());
  await controller.sendKey(key);
}
