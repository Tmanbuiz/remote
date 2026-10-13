import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Platform credentials are separate from the ordinary saved-TV preferences.
abstract class CredentialStore {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> value);
  Future<void> delete(String key);
}

class SecureCredentialStore implements CredentialStore {
  const SecureCredentialStore();
  static const _storage = FlutterSecureStorage();

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final raw = await _storage.read(key: 'remote:$key');
    if (raw == null) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) =>
      _storage.write(key: 'remote:$key', value: jsonEncode(value));

  @override
  Future<void> delete(String key) => _storage.delete(key: 'remote:$key');
}
