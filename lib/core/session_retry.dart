import 'tv_protocol.dart';

/// Runs [action] on a control session that may have died without anyone
/// noticing.
///
/// A TV drops an idle ECP-2 channel, and iOS suspends the app's sockets when it
/// is backgrounded. Either way the session's own flag flips to closed while
/// everything above it — the green dot, the remote screen — still believes it
/// is connected, so the first thing the user presses lands on a dead socket.
///
/// The rule for when to retry matters more than the retry. A failure that left
/// the session *closed* means the socket was stale: rebuild it and go again.
/// A failure with the session still *open* means the TV is alive and simply did
/// not answer, and retrying would only make the user wait twice for the same
/// refusal, so that error is passed through untouched.
Future<T> withLiveSession<T>({
  required bool Function() isOpen,
  required Future<void> Function() reconnect,
  required Future<T> Function() action,
}) async {
  if (!isOpen()) await reconnect();
  try {
    return await action();
  } on RemoteTransportException {
    if (isOpen()) rethrow;
    await reconnect();
    return action();
  }
}
