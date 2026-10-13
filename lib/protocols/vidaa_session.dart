import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../core/tv_protocol.dart';
import '../storage/credential_store.dart';
import 'tv_certificate.dart';
import 'vidaa_wire.dart';

class VidaaMessage {
  const VidaaMessage(this.topic, this.payload, {this.retained = false});
  final String topic, payload;
  final bool retained;
}

abstract class VidaaTransport {
  Stream<VidaaMessage> get messages;
  String get fingerprint;
  bool get isConnected;
  Future<void> publish(String topic, String payload);
  Future<void> close();
}

typedef VidaaConnector = Future<VidaaTransport> Function(
    String host, int port, VidaaCredentials credentials, String? fingerprint);

class MqttVidaaTransport implements VidaaTransport {
  MqttVidaaTransport._(this._client, this.fingerprint);
  final MqttServerClient _client;
  @override
  final String fingerprint;
  @override
  bool get isConnected => _client.connectionStatus?.state == MqttConnectionState.connected;
  @override
  Stream<VidaaMessage> get messages => _client.updates!.expand((batch) => batch.map((event) {
    final message = event.payload as MqttPublishMessage;
    return VidaaMessage(event.topic,
      MqttPublishPayload.bytesToStringAsString(message.payload.message),
      retained: message.header?.retain ?? false);
  }));

  static Future<VidaaTransport> connect(String host, int port,
      VidaaCredentials credentials, String? fingerprint) async {
    final certificate = await rootBundle.loadString('assets/vidaa/client.pem');
    final key = await rootBundle.loadString('assets/vidaa/client.key');
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(utf8.encode(key));
    String? observed;
    final client = MqttServerClient.withPort(host, credentials.clientId, port)
      ..secure = true
      ..securityContext = context
      ..setProtocolV311()
      ..keepAlivePeriod = 20
      ..connectTimeoutPeriod = 8000
      ..maxConnectionAttempts = 1
      ..autoReconnect = false
      ..logging(on: false)
      ..onBadCertificate = (cert) {
        observed = certificateFingerprint(cert.pem);
        return fingerprint == null || fingerprint == observed;
      }
      ..connectionMessage = MqttConnectMessage().withClientIdentifier(credentials.clientId).startClean();
    try {
      await client.connect(credentials.username, credentials.password);
      if (client.connectionStatus?.state != MqttConnectionState.connected || observed == null) {
        throw RemoteAuthException('VIDAA rejected the connection or its certificate could not be verified.');
      }
      final topics = [VidaaWire.responses(credentials.clientId),
        '/remoteapp/mobile/broadcast/ui_service/state',
        '/remoteapp/mobile/broadcast/ui_service/volume'];
      final waiting = topics.toSet();
      final subscribed = Completer<void>();
      client.onSubscribed = (topic) {
        waiting.remove(topic);
        if (waiting.isEmpty && !subscribed.isCompleted) subscribed.complete();
      };
      for (final topic in topics) { client.subscribe(topic, MqttQos.atMostOnce); }
      await subscribed.future.timeout(const Duration(seconds: 8));
      return MqttVidaaTransport._(client, observed!);
    } catch (_) { client.disconnect(); rethrow; }
  }

  @override
  Future<void> publish(String topic, String payload) async {
    if (!isConnected) throw RemoteTransportException('VIDAA disconnected.');
    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    // Commands are never retained or queued across reconnects.
    _client.publishMessage(topic, MqttQos.atMostOnce, builder.payload!, retain: false);
  }
  @override
  Future<void> close() async { _client.disconnect(); }
}

class VidaaSession {
  VidaaSession(this._store, this.deviceId, {VidaaConnector? connector})
      : _connector = connector ?? MqttVidaaTransport.connect;
  final CredentialStore _store;
  final String deviceId;
  final VidaaConnector _connector;
  String get _key => 'vidaa:$deviceId';
  VidaaTransport? _transport;
  StreamSubscription<VidaaMessage>? _subscription;
  VidaaCredentials? _credentials;
  VidaaProfile profile = VidaaProfile.modern;
  bool _authenticated = false;
  Completer<bool>? _auth;
  Completer<void>? _prompt;
  Completer<Map<String, dynamic>>? _tokens;
  Completer<void>? _state;
  String firmware = '';
  bool get isReady => _authenticated && (_transport?.isConnected ?? false);

  Future<String> _uuid() async {
    final record = await readOrCreateCredential(_store, 'vidaa:identity', () async {
      final random = Random.secure();
      final bytes = List.generate(6, (_) => random.nextInt(256));
      bytes[0] = (bytes[0] | 2) & 254;
      return {'uuid': bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join(':')};
    });
    return record['uuid'] as String;
  }

  Future<void> _open(String host, int port, VidaaCredentials credentials,
      String? fingerprint) async {
    await close(); _credentials = credentials;
    _transport = await _connector(host, port, credentials, fingerprint);
    _subscription = _transport!.messages.listen(_receive,
      onError: (Object error) { _fail(error); }, onDone: () {
        _fail(RemoteTransportException('VIDAA disconnected.'));
      });
  }

  Future<void> beginPairing(String host, int port, int? protocolVersion) async {
    final uuid = await _uuid();
    final methods = protocolVersion == null
        ? [VidaaProfile.modern, VidaaProfile.middle, VidaaProfile.legacy]
        : [VidaaWire.profile(protocolVersion)];
    for (final method in methods) {
      try {
        profile = method;
        final credentials = VidaaWire.credentials(uuid, method, DateTime.now().millisecondsSinceEpoch ~/ 1000);
        await _open(host, port, credentials, null);
        break;
      } catch (_) {
        await close();
        if (method == methods.last) {
          throw RemoteAuthException('This VIDAA firmware rejected the mobile connection. Check Support → Mobile App on the TV.');
        }
      }
    }
    _prompt = Completer<void>(); _prompt!.future.ignore();
    await _publish('ui_service', 'vidaa_app_connect', jsonEncode({
      'app_version': 2, 'connect_result': 0, 'device_type': 'Mobile App',
    }));
    await _prompt!.future.timeout(const Duration(seconds: 12));
  }

  Future<void> finishPairing(String pin) async {
    final payload = VidaaWire.pinPayload(pin);
    _auth = Completer<bool>(); _auth!.future.ignore();
    _tokens = Completer<Map<String, dynamic>>(); _tokens!.future.ignore();
    await _publish('ui_service', 'authenticationcode', payload);
    if (!await _auth!.future.timeout(const Duration(seconds: 12))) {
      throw RemoteAuthException('The TV rejected that PIN. Use the code on its screen.');
    }
    await _transport!.publish(VidaaWire.tokenRequest(_credentials!.clientId), '{"refreshtoken":""}');
    Map<String, dynamic> tokens;
    try {
      tokens = await _tokens!.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      if (profile == VidaaProfile.modern) rethrow;
      // Older firmware can authorize the UUID without issuing access tokens.
      // Verify a fresh state response before declaring the remote ready.
      await _verifyState(); tokens = {};
    }
    await _store.write(_key, {
      ...tokens, 'clientId': _credentials!.clientId,
      'username': _credentials!.username, 'profile': profile.name,
      'fingerprint': _transport!.fingerprint,
    });
    _authenticated = true;
    await _publish('ui_service', 'authenticationcodeclose', '');
    await _publish('platform_service', 'gettvinfo', '');
  }

  Future<void> connect(String host, int port) async {
    final record = await _store.read(_key);
    if (record == null || record['fingerprint'] is! String) {
      throw RemoteAuthException('Pair this VIDAA TV again from its device menu.');
    }
    profile = VidaaProfile.values.byName(record['profile'] as String);
    final now = DateTime.now().millisecondsSinceEpoch;
    final accessExpired = (record['accessExpiresAt'] as int? ?? 0) <= now;
    final refresh = accessExpired && record['refreshToken'] is String;
    if (accessExpired && record['accessToken'] is String && !refresh) {
      throw RemoteAuthException('TV authorization expired. Pair this TV again.');
    }
    if (refresh && (record['refreshExpiresAt'] as int? ?? 0) <= now) {
      throw RemoteAuthException('TV pairing expired. Pair this TV again.');
    }
    VidaaCredentials credentials;
    if (record['accessToken'] is String) {
      credentials = VidaaCredentials(record['clientId'] as String, record['username'] as String,
        (refresh ? record['refreshToken'] : record['accessToken']) as String);
    } else {
      credentials = VidaaWire.credentials(await _uuid(), profile, now ~/ 1000);
    }
    await _open(host, port, credentials, record['fingerprint'] as String);
    if (refresh) {
      _tokens = Completer<Map<String, dynamic>>(); _tokens!.future.ignore();
      await _transport!.publish(VidaaWire.tokenRequest(credentials.clientId),
        jsonEncode({'refreshtoken': record['refreshToken']}));
      final renewed = await _tokens!.future.timeout(const Duration(seconds: 10));
      await _store.write(_key, {...record, ...renewed});
    }
    await _verifyState(); _authenticated = true;
    await _publish('platform_service', 'gettvinfo', '');
  }

  Future<void> _verifyState() async {
    _state = Completer<void>(); _state!.future.ignore();
    await _publish('platform_service', 'getvolume', '');
    await _state!.future.timeout(const Duration(seconds: 8));
  }

  void _receive(VidaaMessage message) {
    if (message.retained || message.payload.length > 65536) return;
    try {
      Object? payload;
      try { payload = jsonDecode(message.payload); } catch (_) { payload = null; }
      if (payload is String) {
        try { payload = jsonDecode(payload); } catch (_) { payload = null; }
      }
      final base = '/remoteapp/mobile/${_credentials!.clientId}/';
      if (message.topic.startsWith(base)) {
        if (message.topic.endsWith('/authentication')) {
          if (!(_prompt?.isCompleted ?? true)) _prompt!.complete();
        } else if (message.topic.endsWith('/authenticationcode')) {
          if (!(_auth?.isCompleted ?? true)) _auth!.complete(VidaaWire.pinAccepted(payload));
        } else if (message.topic.endsWith('/tokenissuance')) {
          final value = VidaaWire.tokens(payload, DateTime.now());
          if (value != null && !(_tokens?.isCompleted ?? true)) _tokens!.complete(value);
        } else if (message.topic.endsWith('/gettvinfo') || message.topic.endsWith('/getdeviceinfo')) {
          if (payload is Map) {
            for (final key in ['software_version', 'softwareVersion', 'firmware_version', 'firmwareVersion']) {
              if (payload[key] is String) { firmware = payload[key] as String; break; }
            }
          }
        }
      }
      if ((message.topic.startsWith(base) || message.topic.startsWith('/remoteapp/mobile/broadcast/')) &&
          message.topic.endsWith('/volume') && payload is Map &&
          (payload.containsKey('volume_value') || payload.containsKey('volume'))) {
        if (!(_state?.isCompleted ?? true)) _state!.complete();
      }
    } catch (error) { _fail(error); }
  }

  void _fail(Object error) {
    _authenticated = false;
    for (final pending in [_prompt, _state]) {
      if (pending != null && !pending.isCompleted) pending.completeError(error);
    }
    if (_auth != null && !_auth!.isCompleted) _auth!.completeError(error);
    if (_tokens != null && !_tokens!.isCompleted) _tokens!.completeError(error);
  }
  Future<void> _publish(String service, String action, String payload) =>
      _transport!.publish(VidaaWire.action(_credentials!.clientId, service, action), payload);
  Future<void> sendKey(String key) async {
    if (!isReady) throw RemoteAuthException('Pair and connect to the TV before controlling it.');
    await _publish('remote_service', 'sendkey', key);
  }
  Future<void> close() async {
    _fail(RemoteTransportException('Session closed.'));
    _authenticated = false;
    await _subscription?.cancel(); _subscription = null;
    final old = _transport; _transport = null;
    if (old != null) await old.close();
  }
}
