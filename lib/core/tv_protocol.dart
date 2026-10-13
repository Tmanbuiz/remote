import 'remote_key.dart';
import 'tv_device.dart';

/// Why a pairing attempt ended. Callers branch on this to decide whether to
/// show a PIN field, tell the user to look at the TV, or give up.
enum PairingStatus {
  /// Paired; [PairingResult.device] carries the token worth persisting.
  success,

  /// The set wants a code typed in — read it off the screen and call
  /// [TvProtocol.submitPin].
  pinRequired,

  /// The user declined the on-screen prompt.
  rejected,

  /// No prompt ever came back.
  timeout,

  failed,
}

class PairingResult {
  const PairingResult(this.status, {this.device, this.message});

  final PairingStatus status;
  final TvDevice? device;
  final String? message;

  bool get isSuccess => status == PairingStatus.success;
}

/// Raised when a set is reachable but refuses the command — distinct from a
/// socket failure, because the fix is different (re-pair vs. retry).
class RemoteAuthException implements Exception {
  RemoteAuthException(this.message);
  final String message;
  @override
  String toString() => 'RemoteAuthException: $message';
}

class RemoteTransportException implements Exception {
  RemoteTransportException(this.message);
  final String message;
  @override
  String toString() => 'RemoteTransportException: $message';
}

/// One adapter per brand. Everything above this line is brand-agnostic.
///
/// Lifecycle: [pair] once (may need [submitPin]), then [connect], then any
/// number of [sendKey], then [disconnect]. Adapters that are stateless over
/// HTTP may make [connect] a no-op.
abstract class TvProtocol {
  TvProtocol(this.device);

  TvDevice device;

  /// Keys this adapter can actually deliver. The UI greys out the rest rather
  /// than sending something the set will silently drop.
  Set<RemoteKey> get supportedKeys;

  bool get requiresPairing;

  /// True once a live session exists. HTTP adapters report true after a
  /// successful reachability probe.
  bool get isConnected;

  /// Set by whoever owns this protocol, to hear about a session that ended on
  /// its own. Adapters with no persistent session never call it.
  void Function()? onConnectionLost;

  Future<PairingResult> pair();

  /// Only meaningful after [PairingStatus.pinRequired].
  Future<PairingResult> submitPin(String pin) async =>
      const PairingResult(PairingStatus.failed,
          message: 'This device does not use PIN pairing');

  Future<void> connect();

  Future<void> disconnect();

  Future<void> sendKey(RemoteKey key);

  /// Free-text entry into whatever field the set has focused. Falls back to
  /// per-digit key presses when the protocol has no text channel.
  Future<void> sendText(String text) async {
    throw UnsupportedError('${device.brand.label} does not support text input');
  }

  /// Cheap liveness probe used by the reconnect loop.
  Future<bool> ping();
}
