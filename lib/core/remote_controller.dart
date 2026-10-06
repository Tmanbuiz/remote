import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../discovery/ssdp_discovery.dart';
import '../protocols/roku_ecp2_session.dart';
import '../protocols/roku_protocol.dart';
import '../discovery/subnet_scanner.dart';
import '../storage/device_store.dart';
import 'protocol_factory.dart';
import 'remote_key.dart';
import 'tv_device.dart';
import 'tv_protocol.dart';
import 'wake_on_lan.dart';

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

  /// Whether the connected set can list and launch channels. Only Roku's
  /// ECP-2 exposes this today, so the shortcut row hides itself elsewhere.
  bool get supportsChannels => _active is RokuProtocol;

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
        // On iOS a refused Local Network permission looks exactly like an
        // empty network: the sweep runs, every connection is blocked, and
        // nothing answers. Saying so beats letting someone check the TV, the
        // router and the Wi-Fi first.
        _error = await SubnetScanner.localAddress() == null
            ? 'Not on Wi-Fi. Connect to the same network as the TV.'
            : Platform.isIOS
                ? 'No TVs found. Check Local Network is allowed for this app '
                    'in Settings, and that the TV is on this Wi-Fi.'
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
  /// Looks for a TV at an address the user typed.
  ///
  /// Discovery cannot reach every network — client isolation, separate VLANs,
  /// and iOS without the multicast entitlement all hide TVs that are otherwise
  /// perfectly reachable. A typed address bypasses discovery entirely.
  Future<TvDevice?> probe(String host) async {
    final cleaned = host.trim();
    if (cleaned.isEmpty) return null;
    try {
      final found = await _scanner.probeHost(cleaned);
      if (found == null) return null;
      // Prefer the saved record if this TV is already known, so a typed
      // address does not create a second entry without its pairing token.
      return _saved.firstWhere(
        (d) => d.host == found.host,
        orElse: () => found,
      );
    } catch (_) {
      return null;
    }
  }

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

  /// The TV's installed channels and inputs, or an empty list on a set whose
  /// protocol has no concept of them.
  ///
  /// Not cached: channels change when the user installs one, and the list is a
  /// single cheap request on an already-open session.
  Future<List<RokuChannel>> fetchChannels() async {
    final protocol = _active;
    if (protocol is! RokuProtocol) return const [];
    try {
      return await protocol.fetchChannels();
    } catch (e) {
      _error = 'Could not read the channel list';
      notifyListeners();
      return const [];
    }
  }

  Future<bool> launchChannel(String channelId) async {
    final protocol = _active;
    if (protocol is! RokuProtocol) return false;
    try {
      await protocol.launchChannel(channelId);
      return true;
    } catch (e) {
      _error = 'Could not open that channel';
      notifyListeners();
      return false;
    }
  }

  /// Opens a channel by name, for the fixed shortcut buttons.
  ///
  /// Resolved against the live list rather than a hardcoded id, because a
  /// channel's id is not guaranteed to be the same on every set and a wrong
  /// one fails silently.
  Future<bool> launchChannelNamed(String name) async {
    final channels = await fetchChannels();
    final wanted = name.toLowerCase();
    for (final channel in channels) {
      if (channel.name.toLowerCase() == wanted) {
        return launchChannel(channel.id);
      }
    }
    for (final channel in channels) {
      if (channel.name.toLowerCase().contains(wanted)) {
        return launchChannel(channel.id);
      }
    }
    _error = '$name is not installed on this TV';
    notifyListeners();
    return false;
  }

  /// Opens the TV's own search screen, where [sendText] can then type.
  Future<void> openSearch() async {
    final protocol = _active;
    if (protocol is! RokuProtocol) return;
    try {
      await protocol.openSearch();
    } catch (e) {
      _error = 'Could not open search';
      notifyListeners();
    }
  }

  /// True while TV audio is playing through this phone.
  bool get isListening {
    final protocol = _active;
    return protocol is RokuProtocol && protocol.privateListening.isRunning;
  }

  /// Only Roku implements private listening; Samsung and LG have no
  /// equivalent, so the button is hidden rather than shown broken.
  bool get supportsPrivateListening => _active is RokuProtocol;

  /// Routes TV audio to this phone's headphones, or hands it back.
  ///
  /// Failure here is mostly silent at the protocol level — the TV accepts the
  /// request and then simply may not stream — so the session reports back
  /// through onFailure rather than by throwing.
  Future<void> toggleListening() async {
    final protocol = _active;
    if (protocol is! RokuProtocol) return;
    final session = protocol.privateListening;
    try {
      if (session.isRunning) {
        await session.stop();
      } else {
        session.onFailure = (reason) {
          _error = reason;
          notifyListeners();
          session.stop();
        };
        session.onFirstAudio = notifyListeners;
        await session.start(protocol.device.host);
      }
    } catch (e) {
      _error = '$e';
    }
    notifyListeners();
  }

  /// Powers on a TV that may be asleep.
  ///
  /// Order matters. A set that kept its network alive in standby — Roku with
  /// "Fast TV Start", most Samsung and LG sets — answers a normal power key,
  /// and that is the reliable path. Only when nothing answers is the set truly
  /// off, and then the magic packet is the only thing its adapter will hear.
  ///
  /// Returns true when something was actually sent.
  Future<bool> wake([TvDevice? device]) async {
    final target = device ?? activeDevice ?? (_saved.isNotEmpty ? _saved.first : null);
    if (target == null) {
      _error = 'No TV saved to turn on';
      notifyListeners();
      return false;
    }

    final protocol = _active;
    if (protocol != null && protocol.device.host == target.host && protocol.isConnected) {
      try {
        await protocol.sendKey(RemoteKey.power);
        return true;
      } catch (_) {
        // Fall through to the magic packet.
      }
    }

    final sent = await WakeOnLan.wake(target.macAddress);
    if (!sent) {
      _error = target.macAddress == null
          ? '${target.name} did not record a MAC address, so it cannot be woken while it is off'
          : 'Could not send the wake packet';
      notifyListeners();
    }
    return sent;
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

  /// Renames a saved TV, or restores its reported name when [nickname] is
  /// blank. The name is what Siri matches on, so this is also how someone
  /// makes "turn on the bedroom TV" work.
  Future<void> rename(TvDevice device, String nickname) async {
    final trimmed = nickname.trim();
    final updated = trimmed.isEmpty
        ? device.copyWith(clearNickname: true)
        : device.copyWith(nickname: trimmed);
    await _store.save(updated);
    _saved = _store.loadAll();
    if (_active?.device.id == device.id) {
      _active?.device = updated;
    }
    notifyListeners();
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
