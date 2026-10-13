import '../core/remote_key.dart';
import '../core/tv_protocol.dart';
import '../storage/credential_store.dart';
import 'android_tv_session.dart';
import 'tv_certificate.dart';

/// Google TV and Android TV share the same TLS/PIN Remote Service v2 protocol.
class AndroidTvProtocol extends TvProtocol {
  AndroidTvProtocol(
    super.device, {
    CredentialStore? credentials,
    AndroidTvSession? session,
  }) : _credentials = credentials ?? const SecureCredentialStore(),
       _session = session ?? AndroidTvSession();
  final CredentialStore _credentials;
  final AndroidTvSession _session;
  ClientIdentity? _identity;
  String get _key => 'android-tv:${device.id}';
  static const keyCodes = <RemoteKey, int>{
    RemoteKey.power: 26,
    RemoteKey.powerOn: 224,
    RemoteKey.powerOff: 223,
    RemoteKey.up: 19,
    RemoteKey.down: 20,
    RemoteKey.left: 21,
    RemoteKey.right: 22,
    RemoteKey.select: 23,
    RemoteKey.back: 4,
    RemoteKey.home: 3,
    RemoteKey.menu: 82,
    RemoteKey.info: 165,
    RemoteKey.volumeUp: 24,
    RemoteKey.volumeDown: 25,
    RemoteKey.mute: 164,
    RemoteKey.channelUp: 166,
    RemoteKey.channelDown: 167,
    RemoteKey.play: 126,
    RemoteKey.pause: 127,
    RemoteKey.playPause: 85,
    RemoteKey.stop: 86,
    RemoteKey.rewind: 89,
    RemoteKey.fastForward: 90,
    RemoteKey.next: 87,
    RemoteKey.previous: 88,
    RemoteKey.record: 130,
    RemoteKey.input: 178,
    RemoteKey.digit0: 7,
    RemoteKey.digit1: 8,
    RemoteKey.digit2: 9,
    RemoteKey.digit3: 10,
    RemoteKey.digit4: 11,
    RemoteKey.digit5: 12,
    RemoteKey.digit6: 13,
    RemoteKey.digit7: 14,
    RemoteKey.digit8: 15,
    RemoteKey.digit9: 16,
    RemoteKey.red: 183,
    RemoteKey.green: 184,
    RemoteKey.yellow: 185,
    RemoteKey.blue: 186,
  };
  @override
  Set<RemoteKey> get supportedKeys {
    final keys = keyCodes.keys.toSet();
    if (isConnected && (_session.features & 64) == 0) {
      keys.removeAll([
        RemoteKey.volumeUp,
        RemoteKey.volumeDown,
        RemoteKey.mute,
      ]);
    }
    if (isConnected && (_session.features & 32) == 0) {
      keys.removeAll([RemoteKey.power, RemoteKey.powerOn, RemoteKey.powerOff]);
    }
    return keys;
  }

  @override
  bool get requiresPairing => true;
  @override
  bool get isConnected => _session.isReady;
  @override
  bool get supportsTextInput => isConnected && (_session.features & 4) != 0;
  @override
  int get pairingCodeLength => 6;
  @override
  bool get pairingCodeIsHex => true;
  @override
  Future<PairingResult> pair() async {
    try {
      _identity ??= await ClientIdentity.load(_credentials);
      await _session.beginPairing(device.host, _identity!);
      return const PairingResult(
        PairingStatus.pinRequired,
        message: 'Enter the six-character code shown on your Google TV or Android TV.',
      );
    } catch (_) {
      await disconnect();
      return const PairingResult(
        PairingStatus.failed,
        message: 'Could not start TV pairing. Keep the TV on and update Android TV Remote Service.',
      );
    }
  }

  @override
  Future<PairingResult> submitPin(String pin) async {
    try {
      final fingerprint = await _session.finishPairing(pin, _identity!);
      await _credentials.write(_key, {'fingerprint': fingerprint});
      device = device.copyWith(pairingToken: 'android-v2');
      await connect();
      return PairingResult(PairingStatus.success, device: device);
    } on FormatException catch (e) {
      return PairingResult(
        PairingStatus.pinRequired,
        message: e.message.toString(),
      );
    } catch (_) {
      await disconnect();
      return const PairingResult(
        PairingStatus.failed,
        message: 'Pairing did not finish. Start again and use the code currently on the TV.',
      );
    }
  }

  @override
  Future<void> connect() async {
    final record = await _credentials.read(_key);
    if (record?['fingerprint'] is! String) {
      throw RemoteAuthException(
        'This TV needs pairing again. Use Pair again from its menu.',
      );
    }
    _identity ??= await ClientIdentity.load(_credentials);
    await _session.connect(
      device.host,
      device.port ?? 6466,
      _identity!,
      record!['fingerprint'] as String,
    );
    device = device.copyWith(
      model: _session.model.isEmpty ? device.model : _session.model,
      serviceVersion: _session.serviceVersion.isEmpty
          ? null
          : _session.serviceVersion,
      protocolVersion: 2,
    );
  }

  @override
  Future<void> disconnect() => _session.close();
  @override
  Future<void> sendKey(RemoteKey key) async {
    final code = keyCodes[key];
    if (code == null || !supportedKeys.contains(key)) {
      throw UnsupportedError('TV does not support $key.');
    }
    await _session.sendKey(code);
  }

  @override
  Future<void> sendText(String text) => _session.sendText(text);
  @override
  Future<bool> ping() async => isConnected;
}
