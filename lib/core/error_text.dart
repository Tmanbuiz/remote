import 'tv_protocol.dart';

/// Turns a thrown object into something fit to show on a remote's screen.
///
/// `toString()` on our own exceptions includes the class name, which is how
/// "RemoteTransportException: Remote session is not open." ended up in front of
/// a user. The message is the part meant for people.
String describeError(Object error) {
  if (error is RemoteTransportException) return error.message;
  if (error is RemoteAuthException) return error.message;
  if (error is StateError) return error.message;
  final text = error.toString();
  // "Exception: x" and "Bad state: x" carry no information the message lacks.
  return text.replaceFirst(RegExp(r'^(Exception|Error|Bad state): '), '');
}
