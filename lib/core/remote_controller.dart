import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../discovery/ssdp_discovery.dart';
import '../discovery/subnet_scanner.dart';
import '../features/activity.dart';
import '../services/serial_executor.dart';
import '../services/wake_service.dart';
import '../services/lan_address.dart';
import '../storage/device_store.dart';
import 'capabilities.dart';
import 'protocol_factory.dart';
import 'remote_key.dart';
import 'tv_device.dart';
import 'tv_protocol.dart';

enum RemoteConnectionState { idle, connecting, connected, failed }

class RemoteController extends ChangeNotifier {
  RemoteController(this._store, {TvProtocol Function(TvDevice)? factory})
    : _factory = factory ?? ProtocolFactory.create;
  final DeviceStore _store;
  final TvProtocol Function(TvDevice) _factory;
  final SerialExecutor _queue = SerialExecutor();
  final SsdpDiscovery _discovery = SsdpDiscovery();
  final SubnetScanner _scanner = SubnetScanner();
  List<TvDevice> _saved = [], _discovered = [];
  TvProtocol? _active;
  RemoteConnectionState _state = RemoteConnectionState.idle;
  String? _error;
  bool _scanning = false, _disposed = false;
  final List<String> _diagnostics = [];
  ActionResult? lastResult;
  List<RemoteApp> apps = [];
  bool activityRunning = false;
  int _runGeneration = 0;
  int _commandGeneration = 0;
  final List<String> activityLog = [];
  String? _quietDevice;
  AudioState? _quietOriginal;
  Timer? _sleepTimer;
  DateTime? sleepAt;
  String? sleepDevice;

  List<TvDevice> get savedDevices => List.unmodifiable(_saved);
  List<TvDevice> get discoveredDevices => List.unmodifiable(_discovered);
  List<String> get diagnostics => List.unmodifiable(_diagnostics);
  TvDevice? get activeDevice => _active?.device;
  RemoteConnectionState get state => _state;
  String? get error => _error;
  bool get isScanning => _scanning;
  bool get quietActive => _quietDevice != null;
  Set<RemoteKey> get supportedKeys => _active?.supportedKeys ?? {};
  RemoteCapabilities get capabilities =>
      _active?.capabilities ?? const RemoteCapabilities();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _record(String message) {
    _diagnostics.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (_diagnostics.length > 40) _diagnostics.removeLast();
    _notify();
  }

  String _friendly(Object e) {
    if (e is RemoteAuthException) {
      return 'TV permission needs attention. Re-pair and accept the prompt on the TV.';
    }
    if (e is UnsupportedError) {
      return e.message?.toString() ?? 'This action is unavailable on this TV.';
    }
    return 'Could not communicate with the TV. Check its power, Wi-Fi and mobile-control permission.';
  }

  void loadSaved() {
    _saved = _store.loadAll();
    _notify();
  }

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    _error = null;
    _notify();
    try {
      final results = await Future.wait([
        _discovery.discover().catchError((Object _) => <TvDevice>[]),
        _scanner.scan().catchError((Object _) => <TvDevice>[]),
      ]);
      final byHost = <String, TvDevice>{};
      for (final d in results.expand((l) => l)) {
        byHost.putIfAbsent(d.host, () => d);
      }
      await _queue.run(() async {
        for (final d in byHost.values) {
          final old = _saved.where((s) => s.id == d.id).firstOrNull;
          if (old != null && old.host != d.host) {
            await _store.save(old.copyWith(host: d.host));
            // Drop any session whose address is now stale.
            if (_active?.device.id == old.id) {
              await _active?.disconnect();
              _active = _factory(old.copyWith(host: d.host));
              _state = RemoteConnectionState.idle;
            }
            _record('Updated a saved TV address.');
          }
        }
        _saved = _store.loadAll();
        _discovered = byHost.values
            .where((d) => !_saved.any((s) => s.id == d.id || s.host == d.host))
            .toList();
      });
      if (byHost.isEmpty) {
        _error =
            'No TV found. Check local-network permission, turn on the TV, or add its IP address manually.';
      }
      _record('Discovery finished: ${byHost.length} device(s).');
    } finally {
      _scanning = false;
      _notify();
    }
  }

  Future<PairingResult> pairAndSave(TvDevice device) => _queue.run(() async {
    if (activityRunning) {
      return const PairingResult(
        PairingStatus.failed,
        message: 'Stop the activity before pairing.',
      );
    }
    if (!ProtocolFactory.supported.contains(device.brand) ||
        !isPrivateV4(device.host)) {
      return const PairingResult(
        PairingStatus.failed,
        message: 'Choose a supported TV with a private IPv4 address.',
      );
    }
    await _active?.disconnect();
    _active = null;
    apps = [];
    _state = RemoteConnectionState.connecting;
    _error = null;
    _notify();
    final p = _factory(device);
    try {
      final result = await p.pair();
      if (!result.isSuccess) {
        await p.disconnect();
        _state = RemoteConnectionState.failed;
        _error = result.message;
        _notify();
        return result;
      }
      // Roku pair() only reads identity. The socket must be live before ready.
      if (!p.isConnected) await p.connect();
      await _store.save(p.device);
      await _store.setLastUsed(p.device.id);
      _active = p;
      _saved = _store.loadAll();
      _discovered.removeWhere(
        (d) => d.id == p.device.id || d.host == p.device.host,
      );
      _state = RemoteConnectionState.connected;
      _record('Pairing and control connection completed.');
      return PairingResult(PairingStatus.success, device: p.device);
    } catch (e) {
      await p.disconnect();
      _state = RemoteConnectionState.failed;
      _error = _friendly(e);
      _notify();
      return PairingResult(PairingStatus.failed, message: _error);
    }
  });
  Future<void> _select(TvDevice device) async {
    if (_active?.device.id == device.id && _active!.isConnected) return;
    await _active?.disconnect();
    apps = [];
    lastResult = null;
    final p = _factory(device);
    _active = p;
    _state = RemoteConnectionState.connecting;
    _error = null;
    _notify();
    try {
      await p.connect();
      await _store.save(p.device);
      await _store.setLastUsed(device.id);
      _saved = _store.loadAll();
      _state = RemoteConnectionState.connected;
      _record('Control session connected.');
    } catch (e) {
      await p.disconnect();
      _state = RemoteConnectionState.failed;
      _error = _friendly(e);
      _notify();
      rethrow;
    }
  }

  Future<void> select(TvDevice device) => _queue.run(() async {
    if (activityRunning) return;
    try {
      await _select(device);
    } catch (_) {
      /* State contains recovery guidance. */
    }
  });
  Future<void> reconnectLastUsed() async {
    final d = _store.loadLastUsed();
    if (d != null) await select(d);
  }

  Future<void> _ready(TvProtocol p) async {
    if (!p.isConnected) {
      _state = RemoteConnectionState.connecting;
      _notify();
      await p.disconnect();
      await p.connect();
      await _store.save(p.device);
    }
    _state = RemoteConnectionState.connected;
  }

  Future<ActionResult> _perform(
    Future<void> Function(TvProtocol) action, {
    bool acknowledged = false,
  }) async {
    final p = _active;
    if (p == null || _disposed) {
      return const ActionResult(Delivery.failed, 'Select a TV first.');
    }
    try {
      await _ready(p);
    } catch (e) {
      _state = RemoteConnectionState.failed;
      _error = _friendly(e);
      _notify();
      return ActionResult(Delivery.failed, _error!);
    }
    try {
      await action(p);
      _error = null;
      lastResult = ActionResult(
        acknowledged ? Delivery.acknowledged : Delivery.sent,
        acknowledged
            ? 'TV acknowledged the command; screen result is not verified.'
            : 'Command sent; screen result is not verified.',
      );
    } on UnsupportedError catch (e) {
      lastResult = ActionResult(Delivery.failed, _friendly(e));
    } catch (_) {
      // Never replay an uncertain toggle or typed text after delivery started.
      await p.disconnect();
      _state = RemoteConnectionState.failed;
      lastResult = const ActionResult(
        Delivery.uncertain,
        'No confirmation received. The TV may have acted. Check before trying again.',
      );
    }
    _error = lastResult!.succeeded ? null : lastResult!.message;
    _record(lastResult!.message);
    return lastResult!;
  }

  // Capture the target before enqueueing: never send a stale tap to another TV.
  Future<bool> _manualCommand(Future<bool> Function() action) {
    final target = _active;
    final generation = _commandGeneration;
    if (activityRunning || _disposed || target == null) {
      return Future.value(false);
    }
    return _queue.run(() async {
      if (_disposed ||
          activityRunning ||
          generation != _commandGeneration ||
          !identical(target, _active)) {
        return false;
      }
      return action();
    });
  }

  Future<bool> sendKey(RemoteKey key) => _manualCommand(() async {
    if (!supportedKeys.contains(key)) {
      _error = 'This button is unavailable on this TV.';
      _notify();
      return false;
    }
    return (await _perform(
      (p) => p.sendKey(key),
      acknowledged: capabilities.acknowledgesKeys,
    )).succeeded;
  });
  Future<void> refreshApps() => _queue.run(() async {
    final p = _active;
    if (p == null || !p.capabilities.apps) {
      apps = [];
      _notify();
      return;
    }
    try {
      await _ready(p);
      apps = await p.listApps();
      _error = null;
    } catch (e) {
      _error = _friendly(e);
    }
    _notify();
  });
  Future<bool> launchApp(String id) => _manualCommand(() async {
    return (await _perform(
      (p) => p.openApp(id),
      acknowledged: capabilities.acknowledgesKeys,
    )).succeeded;
  });
  Future<bool> sendText(String text, {bool search = false}) =>
      _manualCommand(() async {
        if (text.trim().isEmpty || text.length > 500) {
          return false;
        }
        return (await _perform(
          (p) => search ? p.search(text) : p.sendText(text),
          acknowledged: capabilities.acknowledgesKeys,
        )).succeeded;
      });
  Future<void> rename(TvDevice d, String name, {String? mac}) =>
      _queue.run(() async {
        if (activityRunning) return;
        final updated = d.copyWith(
          name: name.trim().isEmpty ? d.name : name.trim(),
          macAddress: mac,
        );
        await _store.save(updated);
        if (_active?.device.id == d.id) _active!.device = updated;
        _saved = _store.loadAll();
        _notify();
      });
  Future<void> forget(TvDevice d) => _queue.run(() async {
    if (activityRunning) return;
    if (_active?.device.id == d.id) {
      await _active?.disconnect();
      _active = null;
      apps = [];
      _state = RemoteConnectionState.idle;
    }
    if (_quietDevice == d.id) {
      _quietDevice = null;
      _quietOriginal = null;
    }
    if (sleepDevice == d.id) cancelSleep();
    await _store.remove(d.id);
    _saved = _store.loadAll();
    _notify();
  });
  Future<void> repairPairing(TvDevice d) async {
    await forget(d);
    await pairAndSave(
      TvDevice(
        id: d.id,
        name: d.name,
        host: d.host,
        brand: d.brand,
        port: d.port,
        model: d.model,
        macAddress: d.macAddress,
      ),
    );
  }

  Future<void> diagnose() => _queue.run(() async {
    final p = _active;
    if (p == null) {
      _record('Select a saved TV or add one manually.');
      return;
    }
    final reachable = await p.ping();
    _record(
      reachable
          ? 'TV endpoint responds. Next check the control session.'
          : 'Endpoint did not respond. Check TV power, Wi-Fi, guest-network isolation and its address.',
    );
    if (reachable) {
      try {
        await _ready(p);
        _record(
          'Control session ready. A sent command still requires screen confirmation.',
        );
      } catch (e) {
        _record(_friendly(e));
      }
    }
  });
  Future<bool> wake(TvDevice d) async {
    try {
      await WakeService.send(d.host, d.macAddress ?? '');
      _record(
        'Wake packet sent. TV wake is not verified; network standby must be enabled.',
      );
      return true;
    } catch (_) {
      _error =
          'Add the TV MAC address in room settings. Wake support depends on TV network standby.';
      _notify();
      return false;
    }
  }

  Future<void> quietMoment() => _queue.run(() async {
    if (activityRunning) return;
    final p = _active;
    if (p == null || !p.capabilities.audioState) {
      _error =
          'Verified quiet mode needs readable audio state. Use the regular mute button on this TV.';
      _notify();
      return;
    }
    try {
      await _ready(p);
      if (_quietDevice != null && _quietDevice != p.device.id) {
        _error = 'Return to the TV where Quiet moment started.';
        _notify();
        return;
      }
      if (_quietDevice == null) {
        final before = await p.readAudio();
        if (before.muted) {
          _record('TV is already muted; nothing changed.');
          return;
        }
        await p.setMuted(true);
        final after = await p.readAudio();
        if (!after.muted) throw StateError('Mute was not verified');
        _quietDevice = p.device.id;
        _quietOriginal = before;
        lastResult = const ActionResult(
          Delivery.verified,
          'TV reports muted audio.',
        );
      } else {
        final now = await p.readAudio();
        final original = _quietOriginal!;
        // Even with readable state we cannot detect every external action.
        // Restore is always explicit, and skip it if observable state changed.
        if (now.muted && now.volume == original.volume) {
          await p.setMuted(original.muted);
          final restored = await p.readAudio();
          if (restored.muted != original.muted) {
            throw StateError('Restore was not verified');
          }
          lastResult = const ActionResult(
            Delivery.verified,
            'TV reports restored mute state.',
          );
        } else {
          lastResult = const ActionResult(
            Delivery.uncertain,
            'Audio changed during the break. Left it unchanged.',
          );
        }
        _quietDevice = null;
        _quietOriginal = null;
      }
      _error = null;
      _record(lastResult!.message);
    } catch (_) {
      _error = 'Could not verify audio. Check the TV before changing it again.';
      _notify();
    }
  });
  void cancelActivity() {
    if (!activityRunning) return;
    _runGeneration++;
    activityRunning = false;
    activityLog.add('Stopped. Commands already sent are not reversed.');
    _notify();
  }

  Future<void> runActivity(Activity activity) async {
    if (activityRunning || _disposed) return;
    _commandGeneration++;
    final generation = ++_runGeneration;
    activityRunning = true;
    activityLog.clear();
    _notify();
    try {
      for (final step in activity.steps) {
        if (generation != _runGeneration) break;
        final result = await _queue.run(() async {
          if (generation != _runGeneration) {
            return const ActionResult(Delivery.failed, 'Cancelled');
          }
          final d = _saved.where((d) => d.id == step.deviceId).firstOrNull;
          if (d == null) {
            return const ActionResult(
              Delivery.failed,
              'An activity TV was removed.',
            );
          }
          if (step.kind == StepKind.wait) {
            final seconds = int.tryParse(step.value) ?? 0;
            if (seconds < 1 || seconds > 30) {
              return const ActionResult(
                Delivery.failed,
                'Wait must be 1–30 seconds.',
              );
            }
            for (
              var i = 0;
              i < seconds * 10 && generation == _runGeneration;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            return const ActionResult(Delivery.verified, 'Wait completed.');
          }
          if (step.kind == StepKind.wake) {
            return ActionResult(
              await wake(d) ? Delivery.sent : Delivery.failed,
              'Wake packet requested; verify on the TV.',
            );
          }
          try {
            await _select(d);
          } catch (_) {
            return ActionResult(Delivery.failed, _error ?? 'Connection failed');
          }
          if (generation != _runGeneration) {
            return const ActionResult(Delivery.failed, 'Cancelled');
          }
          return _perform(
            (p) => step.kind == StepKind.app
                ? p.openApp(step.value)
                : p.sendKey(step.key),
            acknowledged: capabilities.acknowledgesKeys,
          );
        });
        if (generation != _runGeneration) break;
        activityLog.add('${activityLog.length + 1}. ${result.message}');
        _notify();
        if (!result.succeeded) break;
      }
    } finally {
      if (generation == _runGeneration) activityRunning = false;
      _notify();
    }
  }

  void scheduleSleep(Duration duration) {
    cancelSleep();
    if (activityRunning || duration <= Duration.zero) return;
    final d = activeDevice;
    if (d == null || !supportedKeys.contains(RemoteKey.powerOff)) return;
    sleepDevice = d.id;
    sleepAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () async {
      final target = _saved.where((v) => v.id == d.id).firstOrNull;
      cancelSleep();
      if (target == null || activityRunning) {
        _record('Sleep skipped: TV unavailable or activity running.');
        return;
      }
      final generation = _commandGeneration;
      await _queue.run(() async {
        if (_disposed || activityRunning || generation != _commandGeneration) {
          return;
        }
        try {
          await _select(target);
          await _perform((p) => p.sendKey(RemoteKey.powerOff));
        } catch (_) {
          _record('Sleep command failed; check TV power.');
        }
      });
    });
    _notify();
  }

  void cancelSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAt = null;
    sleepDevice = null;
    _notify();
  }

  void onBackground() {
    _commandGeneration++;
    if (sleepAt != null) {
      cancelSleep();
      _record('Sleep timer cancelled because the app left the foreground.');
    }
    if (activityRunning) cancelActivity();
  }

  String compatibilityReport({
    String observation = '',
  }) => const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'brand': activeDevice?.brand.label,
    'model': activeDevice?.model,
    'adapter': activeDevice?.brand.name,
    'hardwareValidation': 'User observation; not independently verified',
    'capabilities': {
      'text': capabilities.text,
      'apps': capabilities.apps,
      'search': capabilities.search,
      'audioState': capabilities.audioState,
    },
    'lastDelivery': lastResult?.delivery.name,
    'userObservation': observation,
    'privacy':
        'No address, device ID, token, voice transcript or viewing history included',
  });
  void clearError() {
    _error = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _commandGeneration++;
    _runGeneration++;
    _sleepTimer?.cancel();
    unawaited(_active?.disconnect());
    super.dispose();
  }
}
