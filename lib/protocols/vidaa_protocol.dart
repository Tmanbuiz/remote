import '../core/remote_key.dart';
import '../core/tv_protocol.dart';
import '../storage/credential_store.dart';
import 'vidaa_session.dart';

class VidaaProtocol extends TvProtocol {
  VidaaProtocol(
    super.device, {
    CredentialStore? credentials,
    VidaaSession? session,
  }) : _session =
           session ??
           VidaaSession(
             credentials ?? const SecureCredentialStore(),
             device.id,
           );
  final VidaaSession _session;
  static const keyNames = <RemoteKey, String>{
    RemoteKey.power: 'KEY_POWER',
    RemoteKey.up: 'KEY_UP',
    RemoteKey.down: 'KEY_DOWN',
    RemoteKey.left: 'KEY_LEFT',
    RemoteKey.right: 'KEY_RIGHT',
    RemoteKey.select: 'KEY_OK',
    RemoteKey.back: 'KEY_RETURNS',
    RemoteKey.home: 'KEY_HOME',
    RemoteKey.menu: 'KEY_MENU',
    RemoteKey.exit: 'KEY_EXIT',
    RemoteKey.info: 'KEY_INFO',
    RemoteKey.volumeUp: 'KEY_VOLUMEUP',
    RemoteKey.volumeDown: 'KEY_VOLUMEDOWN',
    RemoteKey.mute: 'KEY_MUTE',
    RemoteKey.channelUp: 'KEY_CHANNELUP',
    RemoteKey.channelDown: 'KEY_CHANNELDOWN',
    RemoteKey.play: 'KEY_PLAY',
    RemoteKey.pause: 'KEY_PAUSE',
    RemoteKey.stop: 'KEY_STOP',
    RemoteKey.rewind: 'KEY_BACK',
    RemoteKey.fastForward: 'KEY_FORWARDS',
    RemoteKey.digit0: 'KEY_0',
    RemoteKey.digit1: 'KEY_1',
    RemoteKey.digit2: 'KEY_2',
    RemoteKey.digit3: 'KEY_3',
    RemoteKey.digit4: 'KEY_4',
    RemoteKey.digit5: 'KEY_5',
    RemoteKey.digit6: 'KEY_6',
    RemoteKey.digit7: 'KEY_7',
    RemoteKey.digit8: 'KEY_8',
    RemoteKey.digit9: 'KEY_9',
    RemoteKey.red: 'KEY_RED',
    RemoteKey.green: 'KEY_GREEN',
    RemoteKey.yellow: 'KEY_YELLOW',
    RemoteKey.blue: 'KEY_BLUE',
  };
  @override
  Set<RemoteKey> get supportedKeys => keyNames.keys.toSet();
  @override
  bool get requiresPairing => true;
  @override
  bool get isConnected => _session.isReady;
  @override
  bool get supportsTextInput => false;
  @override
  int get pairingCodeLength => 4;
  @override
  Future<PairingResult> pair() async {
    try {
      await _session.beginPairing(
        device.host,
        device.port ?? 36669,
        device.protocolVersion,
      );
      return const PairingResult(
        PairingStatus.pinRequired,
        message: 'Enter the four-digit PIN displayed on your VIDAA TV.',
      );
    } catch (_) {
      await disconnect();
      return const PairingResult(
        PairingStatus.failed,
        message: 'VIDAA pairing could not start. Check Support → Mobile App on the TV and keep both devices on the home network.',
      );
    }
  }

  @override
  Future<PairingResult> submitPin(String pin) async {
    try {
      await _session.finishPairing(pin);
      device = device.copyWith(
        pairingToken: 'vidaa',
        firmwareVersion: _session.firmware.isEmpty ? null : _session.firmware,
      );
      return PairingResult(PairingStatus.success, device: device);
    } on FormatException catch (e) {
      return PairingResult(
        PairingStatus.pinRequired,
        message: e.message.toString(),
      );
    } on RemoteAuthException catch (e) {
      return PairingResult(PairingStatus.pinRequired, message: e.message);
    } catch (_) {
      await disconnect();
      return const PairingResult(
        PairingStatus.failed,
        message: 'The TV did not finish authentication. Start pairing again; this firmware may need an updated mobile-control adapter.',
      );
    }
  }

  @override
  Future<void> connect() async {
    await _session.connect(device.host, device.port ?? 36669);
    device = device.copyWith(
      firmwareVersion: _session.firmware.isEmpty ? null : _session.firmware,
    );
  }

  @override
  Future<void> disconnect() => _session.close();
  @override
  Future<void> sendKey(RemoteKey key) async {
    final name = keyNames[key];
    if (name == null) throw UnsupportedError('VIDAA does not support $key.');
    await _session.sendKey(name);
  }

  @override
  Future<bool> ping() async => isConnected;
}
