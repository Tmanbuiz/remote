import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/tv_device.dart';

/// Persists paired TVs, and with them the pairing tokens.
///
/// Losing a token is the worst non-crash failure this app has: Samsung and LG
/// only issue one on an explicit on-screen accept, so the user has to get up
/// and walk to the TV. Every mutation writes through immediately rather than
/// batching on app exit, which iOS does not reliably deliver anyway.
class DeviceStore {
  DeviceStore(this._prefs);

  final SharedPreferences _prefs;

  static const _devicesKey = 'paired_devices_v1';
  static const _lastUsedKey = 'last_used_device_id';

  static Future<DeviceStore> open() async =>
      DeviceStore(await SharedPreferences.getInstance());

  List<TvDevice> loadAll() {
    final raw = _prefs.getStringList(_devicesKey) ?? const [];
    final devices = <TvDevice>[];
    for (final entry in raw) {
      try {
        devices.add(TvDevice.fromJson(jsonDecode(entry) as Map<String, dynamic>));
      } catch (_) {
        // A single corrupt record should not take the whole list with it.
      }
    }
    return devices;
  }

  Future<void> save(TvDevice device) async {
    final devices = loadAll();
    final idx = devices.indexWhere((d) => d.id == device.id);
    if (idx >= 0) {
      // A record arriving from discovery or a re-pair carries no nickname,
      // and overwriting blindly would throw away the name the user chose
      // without ever telling them. Only an explicit rename clears it.
      devices[idx] = device.nickname == null
          ? device.copyWith(nickname: devices[idx].nickname)
          : device;
    } else {
      devices.add(device);
    }
    await _writeAll(devices);
  }

  Future<void> remove(String id) async {
    final devices = loadAll()..removeWhere((d) => d.id == id);
    await _writeAll(devices);
    if (_prefs.getString(_lastUsedKey) == id) {
      await _prefs.remove(_lastUsedKey);
    }
  }

  Future<void> _writeAll(List<TvDevice> devices) async {
    await _prefs.setStringList(
      _devicesKey,
      devices.map((d) => jsonEncode(d.toJson())).toList(),
    );
  }

  TvDevice? loadLastUsed() {
    final id = _prefs.getString(_lastUsedKey);
    if (id == null) return null;
    for (final d in loadAll()) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> setLastUsed(String id) => _prefs.setString(_lastUsedKey, id);
}
