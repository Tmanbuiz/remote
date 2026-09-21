import 'dart:async';

import 'package:flutter/foundation.dart';

import '../discovery/ssdp_discovery.dart';
import '../discovery/subnet_scanner.dart';
import '../storage/device_store.dart';
import 'protocol_factory.dart';
import 'remote_key.dart';
import 'tv_device.dart';
import 'tv_protocol.dart';

enum RemoteConnectionState { idle, connecting, connected, failed }

/// Owns the active TV session and the saved-device list.
///
/// The one piece of real logic here is [sendKey]'s recovery path: phones drop
/// sockets constantly — screen off, Wi-Fi roam, app backgrounded — so a key
/// press that fails on a stale socket silently reconnects and retries once
/// before it is reported as an error. Without that, the app feels broken every
/// time it comes back from the background.
class RemoteController extends ChangeNotifier {
  RemoteController(this._store);

  final DeviceStore _store;
  final SsdpDiscovery _discovery = SsdpDiscovery();
  final SubnetScanner _scanner = SubnetScanner();

  List<TvDevice> _saved = [];
  List<TvDevice> _discovered = [];
  TvProtocol? _active;
  RemoteConnectionState _state = RemoteConnectionState.idle;
  String? _error;
  bool _scanning = false;

  List<TvDevice> get savedDevices => List.unmodifiable(_saved);
  List<TvDevice> get discoveredDevices => List.unmodifiable(_discovered);
  TvDevice? get activeDevice => _active?.device;
  RemoteConnectionState get state => _state;
  String? get error => _error;
  bool get isScanning => _scanning;

  Set<RemoteKey> get supportedKeys => _active?.supportedKeys ?? const {};

  void loadSaved() {
    _saved = _store.loadAll();
    notifyListeners();
  }

  /// Sweeps the network, hiding sets already saved so the list stays short.
  ///
  /// Both discovery paths run together and their results are merged: SSDP is
  /// faster and richer when multicast works, but on iOS it is usually dropped
  /// outright (see [SubnetScanner]), so the unicast sweep is what actually
  /// finds anything there. Neither failing is fatal on its own.
  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    _error = null;
    notifyListeners();

    try {
      final results = await Future.wait([
        _discovery.discover().catchError((_) => <TvDevice>[]),
        _scanner.scan().catchError((_) => <TvDevice>[]),
      ]);

      // Keyed by host: one address is one TV, and the two paths often report
      // the same set under different ids.
      final byHost = <String, TvDevice>{};
      for (final device in results.expand((list) => list)) {
        byHost.putIfAbsent(device.host, () => device);
      }

      final savedHosts = _saved.map((d) => d.host).toSet();
      _discovered = byHost.values
          .where((d) => !savedHosts.contains(d.host))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      if (byHost.isEmpty) {
        _error = await SubnetScanner.localAddress() == null
            ? 'Not on Wi-Fi. Connect to the same network as the TV.'
            : 'No TVs found. Check the TV is on and on this Wi-Fi.';
      }
    } catch (e) {
      _error = 'Scan failed: $e';
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// Pairs, persists the resulting token, and leaves the device connected.
  Future<PairingResult> pairAndSave(TvDevice device) async {
    if (!ProtocolFactory.supported.contains(device.brand)) {
      return PairingResult(
        PairingStatus.failed,
        message: '${device.brand.label} is not supported yet',
      );
    }

    _state = RemoteConnectionState.connecting;
    _error = null;
    notifyListeners();

    final protocol = ProtocolFactory.create(device);
    PairingResult result;
    try {
      result = await protocol.pair();
    } catch (e) {
      result = PairingResult(PairingStatus.failed, message: '$e');
    }

    if (result.isSuccess) {
      final paired = result.device ?? protocol.device;
      await _store.save(paired);
      await _store.setLastUsed(paired.id);
      _saved = _store.loadAll();
      _discovered = _discovered.where((d) => d.id != paired.id).toList();
      _active = protocol;
      _state = RemoteConnectionState.connected;
    } else {
      _state = RemoteConnectionState.failed;
      _error = result.message;
      await protocol.disconnect();
    }
    notifyListeners();
    return result;
  }

  Future<void> select(TvDevice device) async {
    if (_active?.device.id == device.id && _state == RemoteConnectionState.connected) {
      return;
    }
    await _active?.disconnect();
    _state = RemoteConnectionState.connecting;
    _error = null;
    notifyListeners();

    final protocol = ProtocolFactory.create(device);
    _active = protocol;
    try {
      await protocol.connect();
      _state = RemoteConnectionState.connected;
      await _store.setLastUsed(device.id);
      // Adapters may refresh the token on reconnect; keep the stored copy current.
      await _store.save(protocol.device);
      _saved = _store.loadAll();
    } catch (e) {
      _state = RemoteConnectionState.failed;
      _error = '$e';
    }
    notifyListeners();
  }

  Future<void> reconnectLastUsed() async {
    final last = _store.loadLastUsed();
    if (last != null) await select(last);
  }

  /// Sends a key, transparently recovering from a socket that died while the
  /// app was backgrounded. Returns false if the press could not be delivered.
  Future<bool> sendKey(RemoteKey key) async {
    final protocol = _active;
    if (protocol == null) {
      _error = 'No TV selected';
      notifyListeners();
      return false;
    }

    try {
      await protocol.sendKey(key);
      return true;
    } on UnsupportedError {
      _error = '${protocol.device.brand.label} has no $key key';
      notifyListeners();
      return false;
    } catch (_) {
      // First failure is almost always a stale socket. Rebuild it and retry.
      try {
        await protocol.disconnect();
        await protocol.connect();
        await protocol.sendKey(key);
        _state = RemoteConnectionState.connected;
        _error = null;
        notifyListeners();
        return true;
      } catch (e) {
        _state = RemoteConnectionState.failed;
        _error = 'Lost connection to ${protocol.device.name}';
        notifyListeners();
        return false;
      }
    }
  }

  Future<void> sendText(String text) async {
    final protocol = _active;
    if (protocol == null) return;
    try {
      await protocol.sendText(text);
    } catch (e) {
      _error = '$e';
      notifyListeners();
    }
  }

  Future<void> forget(TvDevice device) async {
    if (_active?.device.id == device.id) {
      await _active?.disconnect();
      _active = null;
      _state = RemoteConnectionState.idle;
    }
    await _store.remove(device.id);
    _saved = _store.loadAll();
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _active?.disconnect();
    super.dispose();
  }
}
