import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../protocols/mic_monitor.dart';

/// Which end of "Listen to home" this phone is playing.
enum MonitorRole { idle, talking, listening }

/// Owns the microphone monitor on this phone, in whichever role.
///
/// The talking side is the sensitive one, so the rules for it are stated here
/// where they cannot be skipped:
///
///  1. The microphone is never opened unless a visible, persistent
///     notification is up first. On Android that is a foreground service of
///     type "microphone"; if the user has blocked notifications the monitor
///     refuses to start and says why, rather than running without one.
///  2. The notification and the in-app screen both state the real condition —
///     whether anyone is actually listening — instead of a generic "running".
///  3. Stopping from the notification stops the capture, and closing the app
///     stops the service. The notification can never outlive the microphone
///     or the reverse.
///
/// iOS draws its own microphone indicator and keeps the app alive through
/// UIBackgroundModes audio, so there is no service to manage there.
class HomeMonitor extends ChangeNotifier {
  HomeMonitor({AudioRecorder? recorder, MethodChannel? channel})
      : _recorder = recorder ?? AudioRecorder(),
        _channel = channel ?? const MethodChannel(channelName) {
    // The notification's "Turn off" button lands here.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') await stop();
    });
  }

  static const String channelName = 'com.wiantribe.universal_remote/mic_service';

  final AudioRecorder _recorder;
  final MethodChannel _channel;

  MicTalker? _talker;
  MicListener? _listener;
  MonitorRole _role = MonitorRole.idle;
  String? _error;

  MonitorRole get role => _role;
  String? get error => _error;
  bool get isTalking => _role == MonitorRole.talking;
  bool get isListening => _role == MonitorRole.listening;

  /// Whether a far-end phone is currently registered with this one.
  bool get talkerHasListener => _talker?.hasListener ?? false;
  int get packetsSent => _talker?.packetsSent ?? 0;

  /// Whether sound is actually arriving at this phone right now.
  bool get listenerIsHearing => _listener?.isHearing ?? false;
  int get packetsReceived => _listener?.packetsReceived ?? 0;

  /// The wording shown in the notification, which mirrors the on-screen state
  /// so the two can never disagree about what the microphone is doing.
  static String notificationText({required bool hasListener}) => hasListener
      ? 'Microphone on — streaming to your other device'
      : 'Microphone on — waiting for your other device to connect';

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  // --- The phone left at home ---------------------------------------------

  /// Starts capturing and offering the stream to a listener.
  Future<void> startTalking() async {
    if (_role != MonitorRole.idle) return;
    _error = null;
    if (!(Platform.isAndroid || Platform.isIOS)) {
      _fail('Listen to home needs a phone with a microphone.');
      return;
    }

    try {
      // Permission first, so a refusal costs nothing and shows no notification.
      if (!await _recorder.hasPermission()) {
        _fail(
          'Microphone permission was declined, so there is nothing to share. '
          'You can allow it in the phone\'s app settings.',
        );
        return;
      }

      // The notification goes up before the microphone opens, and a phone that
      // will not show it does not get to capture.
      if (Platform.isAndroid) {
        final shown = await _channel.invokeMethod<bool>('start', {
          'text': notificationText(hasListener: false),
        });
        if (shown != true) {
          _fail(
            'Notifications are blocked for this app. The monitor only runs '
            'with its "Microphone on" notification visible — allow '
            'notifications in the phone\'s app settings and try again.',
          );
          return;
        }
      }

      final pcm = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: MicStream.sampleRate,
          numChannels: MicStream.channels,
          // Leave the signal alone: a room monitor wants the room, and the
          // phone's voice-call processing would gate out quiet sounds.
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );

      final talker = MicTalker()..onChanged = _talkerChanged;
      await talker.start(pcm);
      _talker = talker;
      _role = MonitorRole.talking;
    } catch (e) {
      await _teardownTalker();
      _error = '$e';
    }
    notifyListeners();
  }

  void _talkerChanged() {
    // Keep the notification honest about whether anyone can hear the room.
    if (Platform.isAndroid && _talker != null) {
      _channel.invokeMethod<void>('update', {
        'text': notificationText(hasListener: _talker!.hasListener),
      });
    }
    notifyListeners();
  }

  Future<void> _teardownTalker() async {
    final talker = _talker;
    _talker = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // Stopping a recorder that never started is not an error worth raising.
    }
    await talker?.stop();
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {
        // The service may already be gone, which is the desired end state.
      }
    }
  }

  // --- The phone at work --------------------------------------------------

  Future<void> startListening(String host) async {
    if (_role != MonitorRole.idle) return;
    _error = null;
    final listener = MicListener()
      ..onChanged = notifyListeners
      ..onFailure = (reason) {
        _error = reason;
        notifyListeners();
      };
    try {
      await listener.start(host);
      _listener = listener;
      _role = MonitorRole.listening;
    } catch (e) {
      _error = '$e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _teardownTalker();
    await _listener?.stop();
    _listener = null;
    _role = MonitorRole.idle;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _recorder.dispose();
    super.dispose();
  }
}
