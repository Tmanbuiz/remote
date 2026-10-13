import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Platform credentials are separate from the ordinary saved-TV preferences.
abstract class CredentialStore {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> value);
  Future<void> delete(String key);
}

final _credentialLoads = Expando<Map<String, Future<Map<String, dynamic>>>>();

/// A cancelled/overlapping pairing must not overwrite another TV's client key.
Future<Map<String, dynamic>> readOrCreateCredential(
  CredentialStore store,
  String key,
  Future<Map<String, dynamic>> Function() create,
) {
  final pending = _credentialLoads[store] ??= {};
  final existing = pending[key];
  if (existing != null) return existing;
  Future<Map<String, dynamic>> load() async {
    final saved = await store.read(key);
    if (saved != null) return saved;
    final value = await create();
    await store.write(key, value);
    return value;
  }

  final result = load();
  pending[key] = result;
  return result.whenComplete(() {
    if (identical(pending[key], result)) pending.remove(key);
  });
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
