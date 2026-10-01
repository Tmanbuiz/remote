import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/tv_device.dart';

abstract class TokenVault {
  Future<String?> read(String id);
  Future<void> write(String id, String token);
  Future<void> delete(String id);
}

class SecureTokenVault implements TokenVault {
  const SecureTokenVault();
  static const storage = FlutterSecureStorage();
  @override
  Future<String?> read(String id) => storage.read(key: 'tv:$id');
  @override
  Future<void> write(String id, String token) =>
      storage.write(key: 'tv:$id', value: token);
  @override
  Future<void> delete(String id) => storage.delete(key: 'tv:$id');
}

class DeviceStore {
  DeviceStore(this._prefs, {TokenVault? vault})
    : _vault = vault ?? const SecureTokenVault();
  final SharedPreferences _prefs;
  final TokenVault _vault;
  final Map<String, String> _tokens = {};
  static const _devicesKey = 'paired_devices_v1';
  static const _lastUsedKey = 'last_used_device_id';
  SharedPreferences get preferences => _prefs;
  static Future<DeviceStore> open() async {
    final store = DeviceStore(await SharedPreferences.getInstance());
    await store.initialize();
    return store;
  }

  /// Write secrets successfully before stripping old plaintext credentials.
  /// Failure propagates: never silently erase the only usable credential.
  Future<void> initialize() async {
    final clean = <String>[];
    for (final raw in _prefs.getStringList(_devicesKey) ?? <String>[]) {
      Map<String, dynamic> j;
      try {
        j = jsonDecode(raw) as Map<String, dynamic>;
        TvDevice.fromJson(j);
      } catch (_) {
        continue;
      }
      final id = j['id'] as String;
      final old = j['pairingToken'] as String?;
      if (old != null && old.isNotEmpty) await _vault.write(id, old);
      final token = old ?? await _vault.read(id);
      if (token != null) _tokens[id] = token;
      j.remove('pairingToken');
      clean.add(jsonEncode(j));
    }
    await _prefs.setStringList(_devicesKey, clean);
  }

  List<TvDevice> loadAll() {
    final devices = <TvDevice>[];
    for (final entry in _prefs.getStringList(_devicesKey) ?? <String>[]) {
      try {
        final j = jsonDecode(entry) as Map<String, dynamic>;
        j['pairingToken'] = _tokens[j['id']];
        devices.add(TvDevice.fromJson(j));
      } catch (_) {
        /* Isolate a corrupt record. */
      }
    }
    return devices;
  }

  Future<void> save(TvDevice device) async {
    final token = device.pairingToken;
    if (token != null && token.isNotEmpty) {
      await _vault.write(device.id, token);
      _tokens[device.id] = token;
    }
    final devices = loadAll();
    final i = devices.indexWhere((d) => d.id == device.id);
    if (i < 0) {
      devices.add(device);
    } else {
      devices[i] = device;
    }
    await _writeAll(devices);
  }

  Future<void> clearCredential(String id) async {
    await _vault.delete(id);
    _tokens.remove(id);
  }

  Future<void> remove(String id) async {
    await _writeAll(loadAll()..removeWhere((d) => d.id == id));
    await clearCredential(id);
    if (_prefs.getString(_lastUsedKey) == id) await _prefs.remove(_lastUsedKey);
  }

  Future<void> _writeAll(List<TvDevice> devices) => _prefs.setStringList(
    _devicesKey,
    devices.map((d) => jsonEncode(d.toJson()..remove('pairingToken'))).toList(),
  );
  TvDevice? loadLastUsed() {
    final id = _prefs.getString(_lastUsedKey);
    for (final d in loadAll()) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> setLastUsed(String id) => _prefs.setString(_lastUsedKey, id);
}
