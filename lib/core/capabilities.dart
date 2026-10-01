/// Capabilities describe the adapter, not a promise about every firmware version.
enum Delivery { sent, acknowledged, verified, uncertain, failed }

class ActionResult {
  const ActionResult(this.delivery, this.message);
  final Delivery delivery;
  final String message;
  bool get succeeded =>
      delivery == Delivery.sent ||
      delivery == Delivery.acknowledged ||
      delivery == Delivery.verified;
}

class RemoteApp {
  const RemoteApp(this.id, this.name, {this.isInput = false});
  final String id;
  final String name;
  final bool isInput;
}

class RemoteCapabilities {
  const RemoteCapabilities({
    this.text = false,
    this.apps = false,
    this.search = false,
    this.audioState = false,
    this.wake = false,
    this.acknowledgesKeys = false,
  });
  final bool text, apps, search, audioState, wake, acknowledgesKeys;
}

class AudioState {
  const AudioState({required this.muted, required this.volume});
  final bool muted;
  final int volume;
}
