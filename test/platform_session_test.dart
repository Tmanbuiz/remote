import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_remote/core/tv_protocol.dart';
import 'package:universal_remote/protocols/android_tv_session.dart';
import 'package:universal_remote/protocols/protobuf_wire.dart';
import 'package:universal_remote/protocols/tv_certificate.dart';
import 'package:universal_remote/protocols/vidaa_session.dart';
import 'package:universal_remote/protocols/vidaa_wire.dart';
import 'package:universal_remote/storage/credential_store.dart';

class MemoryCredentials implements CredentialStore {
  final values = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String key) async => values[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class AndroidFixture implements AndroidTvTransport {
  AndroidFixture(this.peerCertificate);
  @override
  final String peerCertificate;
  final input = StreamController<Uint8List>();
  final sent = <List<int>>[];
  void Function(List<int>)? onSend;
  bool closed = false;
  void receive(List<int> value) => input.add(Uint8List.fromList(value));
  @override
  Stream<Uint8List> get messages => input.stream;
  @override
  Future<void> send(List<int> message) async {
    sent.add(message);
    onSend?.call(message);
  }

  @override
  Future<void> close() async {
    closed = true;
    await input.close();
  }
}

class VidaaFixture implements VidaaTransport {
  VidaaFixture(this.clientId);
  final String clientId;
  final input = StreamController<VidaaMessage>();
  final sent = <({String topic, String payload})>[];
  bool connected = true;
  bool rejectPin = false;
  @override
  String get fingerprint => 'fixture-tv-fingerprint';
  @override
  bool get isConnected => connected;
  @override
  Stream<VidaaMessage> get messages => input.stream;
  void receive(String type, Object payload, {bool retained = false}) =>
      input.add(
        VidaaMessage(
          '/remoteapp/mobile/$clientId/ui_service/data/$type',
          jsonEncode(payload),
          retained: retained,
        ),
      );
  @override
  Future<void> publish(String topic, String payload) async {
    sent.add((topic: topic, payload: payload));
    if (topic.endsWith('/vidaa_app_connect')) receive('authentication', {});
    if (topic.endsWith('/authenticationcode')) {
      receive('authenticationcode', {'result': rejectPin ? 0 : 1});
    }
    if (topic.endsWith('/gettoken')) {
      receive('tokenissuance', {
        'accesstoken': 'retained-poison',
      }, retained: true);
      receive('tokenissuance', {
        'accesstoken': 'approved-test-token',
        'refreshtoken': 'test-refresh',
      });
    }
    if (topic.endsWith('/getvolume')) receive('volume', {'volume_value': 25});
  }

  @override
  Future<void> close() async {
    connected = false;
    await input.close();
  }
}

void main() {
  test(
    'overlapping identity requests share one creation and stored key',
    () async {
      final store = MemoryCredentials();
      final generated = Completer<Map<String, dynamic>>();
      var creations = 0;
      Future<Map<String, dynamic>> create() {
        creations++;
        return generated.future;
      }

      final first = readOrCreateCredential(store, 'identity', create);
      final second = readOrCreateCredential(store, 'identity', create);
      await Future<void>.delayed(Duration.zero);
      expect(creations, 1);
      generated.complete({'certificate': 'one-test-identity'});
      expect(await first, await second);
      expect(store.values['identity']!['certificate'], 'one-test-identity');
    },
  );

  test('Android handshake retains the pairing socket, negotiates capabilities, and answers pings', () async {
    final clientPem = File('test/fixtures/android-client.pem')
        .readAsStringSync();
    final serverPem = File('test/fixtures/android-server.pem')
        .readAsStringSync();
    final identity = ClientIdentity(clientPem, 'not-used-by-fixture');
    final opened = <AndroidFixture>[];
    final session = AndroidTvSession(
      connector: (host, port, identity, fingerprint) async {
        final wire = AndroidFixture(serverPem);
        opened.add(wire);
        if (port == 6467) {
          wire.onSend = (data) {
            final request = Proto.decode(data);
            final response = request.containsKey(10)
                ? 11
                : request.containsKey(20)
                ? 20
                : request.containsKey(30)
                ? 31
                : 41;
            wire.receive([
              ...Proto.number(1, 2),
              ...Proto.number(2, 200),
              ...Proto.bytes(response, []),
            ]);
          };
        } else {
          wire.receive(
            Proto.bytes(1, [
              ...Proto.number(1, AndroidTvSession.requestedFeatures),
              ...Proto.bytes(2, [
                ...Proto.text(1, 'Fixture TV'),
                ...Proto.text(6, '6.2'),
              ]),
            ]),
          );
          wire.onSend = (data) {
            if (Proto.decode(data).containsKey(1)) {
              wire.receive(Proto.bytes(40, Proto.number(1, 1)));
            }
          };
        }
        return wire;
      },
    );
    await session.beginPairing('192.168.1.25', identity);
    expect(opened.length, 1);
    final fingerprint = await session.finishPairing('BEB34C', identity);
    expect(fingerprint, certificateFingerprint(serverPem));
    expect(opened.first.closed, isTrue);
    await session.connect('192.168.1.25', 6466, identity, fingerprint);
    expect(session.isReady, isTrue);
    expect(session.model, 'Fixture TV');
    expect(session.serviceVersion, '6.2');
    await session.sendKey(25);
    expect(opened.last.sent.last, [0x52, 4, 8, 25, 16, 3]);
    opened.last.receive(Proto.bytes(8, Proto.number(1, 99)));
    await Future<void>.delayed(Duration.zero);
    expect(
      Proto.integer(Proto.nested(Proto.decode(opened.last.sent.last), 9), 1),
      99,
    );
    await session.close();
    expect(session.isReady, isFalse);
  });

  test('Android refuses RemoteStart without a valid configuration', () async {
    final pem = File('test/fixtures/android-server.pem').readAsStringSync();
    final session = AndroidTvSession(
      connector: (host, port, identity, fingerprint) async {
        final wire = AndroidFixture(pem);
        wire.receive(Proto.bytes(40, Proto.number(1, 1)));
        return wire;
      },
    );
    await expectLater(
      session.connect(
        '192.168.1.25',
        6466,
        ClientIdentity(pem, 'fixture'),
        'expected',
      ),
      throwsFormatException,
    );
    expect(session.isReady, isFalse);
  });

  test('VIDAA requires PIN approval and ignores retained tokens', () async {
    final store = MemoryCredentials();
    VidaaFixture? fixture;
    final session = VidaaSession(
      store,
      'tv',
      connector: (host, port, credentials, fingerprint) async {
        fixture = VidaaFixture(credentials.clientId);
        return fixture!;
      },
    );
    await session.beginPairing('192.168.1.25', 36669, 3290);
    expect(session.isReady, isFalse);
    await expectLater(
      session.sendKey('KEY_VOLUMEUP'),
      throwsA(isA<RemoteAuthException>()),
    );
    await session.finishPairing('0012');
    expect(session.isReady, isTrue);
    expect(store.values['vidaa:tv']!['accessToken'], 'approved-test-token');
    expect(
      fixture!.sent
          .firstWhere((p) => p.topic.endsWith('/authenticationcode'))
          .payload,
      '{"authNum":12}',
    );
    await session.sendKey('KEY_VOLUMEDOWN');
    expect(fixture!.sent.last.payload, 'KEY_VOLUMEDOWN');
    await session.close();
  });

  test(
    'VIDAA wrong PIN stays unauthorized and stores no TV credentials',
    () async {
      final store = MemoryCredentials();
      final session = VidaaSession(
        store,
        'tv',
        connector: (host, port, credentials, fingerprint) async =>
            VidaaFixture(credentials.clientId)..rejectPin = true,
      );
      await session.beginPairing('192.168.1.25', 36669, 3290);
      await expectLater(
        session.finishPairing('0000'),
        throwsA(isA<RemoteAuthException>()),
      );
      expect(session.isReady, isFalse);
      expect(store.values.containsKey('vidaa:tv'), isFalse);
      await session.close();
    },
  );

  test(
    'VIDAA reconnect uses stored authorization and pins the TV certificate',
    () async {
      final store = MemoryCredentials();
      VidaaCredentials? reconnectCredentials;
      String? suppliedFingerprint;
      final session = VidaaSession(
        store,
        'tv',
        connector: (host, port, credentials, fingerprint) async {
          reconnectCredentials = credentials;
          suppliedFingerprint = fingerprint;
          return VidaaFixture(credentials.clientId);
        },
      );
      await session.beginPairing('192.168.1.25', 36669, 3290);
      await session.finishPairing('1234');
      await session.close();
      await session.connect('192.168.1.25', 36669);
      expect(reconnectCredentials!.password, 'approved-test-token');
      expect(suppliedFingerprint, 'fixture-tv-fingerprint');
      expect(session.isReady, isTrue);
      await session.close();
    },
  );
}
