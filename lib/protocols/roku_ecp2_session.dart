import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/tv_protocol.dart';

/// A channel or TV input the set can switch to.
class RokuChannel {
  const RokuChannel(this.id, this.name, {this.isInput = false});

  final String id;
  final String name;

  /// True for HDMI/tuner entries, which the TV returns in the same list as
  /// streaming channels but which behave differently in the UI.
  final bool isInput;

  @override
  String toString() => name;
}

/// Roku's ECP-2 control channel: a WebSocket to `ws://host:8060/ecp-session`
/// speaking the `ecp-2` subprotocol, authenticated by challenge/response.
///
/// **Why this exists instead of plain HTTP ECP.** Roku's "Control by mobile
/// apps" setting has a Limited mode which makes `POST /keypress/...` and
/// `/query/apps` return 403, while leaving `/query/device-info` readable. This
/// is the channel Roku's own app uses, and the TV honours it in that mode — so
/// discovery still happens over HTTP, but every actual command goes here.
///
/// The Java original hand-rolled RFC 6455 framing; `dart:io` negotiates the
/// subprotocol and does the framing itself, so only the ECP-2 layer is ported.
class RokuEcp2Session {
  RokuEcp2Session({this.clientName = 'Universal Remote'});

  /// Identifies this app in the TV's connected-devices list.
  final String clientName;

  /// Roku's published ECP-2 secret. `authResponseFor` is pinned to a captured
  /// handshake vector in the tests, so a typo here fails loudly.
  static const String authKey = 'F3A278B8-1C6F-44A9-9D89-F1979CA4C6F1';

  static const int port = 8060;

  /// The TV closes idle sessions, and only allows a small number at once.
  static const Duration _connectTimeout = Duration(seconds: 6);

  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  final Map<String, Completer<Map<String, String>>> _pending = {};
  int _nextId = 1;
  bool _open = false;

  bool get isOpen => _open;

  /// `base64(sha1(challenge + authKey))` — the response the TV expects.
  static String authResponseFor(String challenge) {
    final bytes = <int>[
      ...utf8.encode(challenge),
      ...utf8.encode(authKey),
    ];
    return base64.encode(sha1.convert(bytes).bytes);
  }

  /// The TV answers 202 Accepted to power keys rather than 200, so the whole
  /// 2xx range counts as success. Treating only 200 as success makes the power
  /// button look broken when it worked.
  static bool accepted(String? status) {
    if (status == null || status.length != 3) return false;
    final code = int.tryParse(status);
    return code != null && code >= 200 && code < 300;
  }

  /// Roku channel ids are digits; TV inputs look like `tvinput.hdmi1`.
  static bool isChannelId(String? id) {
    if (id == null || id.isEmpty || id.length > 40) return false;
    return RegExp(r'^[0-9a-zA-Z._-]+$').hasMatch(id);
  }

  Future<void> open(String host) async {
    await close();

    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        'ws://$host:$port/ecp-session',
        protocols: const ['ecp-2'],
      ).timeout(_connectTimeout);
    } catch (e) {
      throw RemoteTransportException('TV did not accept the remote channel: $e');
    }

    // The exchange before the reader loop starts is strictly sequential: the TV
    // speaks first with a challenge, and nothing else may be sent until it has
    // accepted our response.
    final incoming = StreamQueue<dynamic>(socket);
    try {
      final challengeMsg = _decode(await incoming.next.timeout(_connectTimeout));
      final challenge = challengeMsg['param-challenge'];
      if (challenge == null) {
        throw RemoteTransportException('TV did not start authentication.');
      }

      socket.add(jsonEncode({
        'request': 'authenticate',
        'request-id': '${_nextId++}',
        'param-response': authResponseFor(challenge),
        'param-client-friendly-name': clientName,
        // Private listening is a capability of Roku's voice remote, which has both

        // a microphone and the headphone jack. A client that declares no microphone

        // is handed audio and then cut off after five seconds, so claim the same

        // capabilities the official client does.

        'param-has-microphone': 'true',

        'param-microphone-sample-rates': '1600',
      }));

      final reply = _decode(await incoming.next.timeout(_connectTimeout));
      if (!accepted(reply['status'])) {
        throw RemoteAuthException('TV declined the remote session.');
      }
    } catch (e) {
      await incoming.cancel(immediate: true);
      await socket.close();
      if (e is RemoteAuthException || e is RemoteTransportException) rethrow;
      throw RemoteTransportException('TV failed the remote handshake: $e');
    }

    // Hand the still-open socket back to a normal listener for the rest of the
    // session. `rest` preserves anything already buffered.
    _socket = socket;
    _open = true;
    _sub = incoming.rest.listen(
      _onMessage,
      onError: (Object e) => _fail('$e'),
      onDone: () => _fail('TV closed the channel.'),
      cancelOnError: false,
    );
  }

  void _onMessage(dynamic raw) {
    debugPrint('ecp2 <- $raw');
    final msg = _decode(raw);
    final id = msg['response-id'];
    if (id == null) return;
    _pending.remove(id)?.complete(msg);
  }

  void _fail(String reason) {
    debugPrint('ecp2 FAILED: $reason');
    _open = false;
    for (final waiter in _pending.values) {
      waiter.completeError(RemoteTransportException(reason));
    }
    _pending.clear();
  }

  Future<void> close() async {
    _open = false;
    await _sub?.cancel();
    _sub = null;
    await _socket?.close();
    _socket = null;
    _fail('Session closed.');
  }

  /// Sends one request and waits for the reply with the matching id.
  Future<Map<String, String>> _call(
    String request,
    Map<String, String> params, {
    Duration timeout = const Duration(seconds: 3),
    required String onTimeout,
  }) async {
    final socket = _socket;
    if (!_open || socket == null) {
      throw RemoteTransportException('Remote session is not open.');
    }

    final id = '${_nextId++}';
    final completer = Completer<Map<String, String>>();
    _pending[id] = completer;

    socket.add(jsonEncode({
      'request': request,
      ...params,
      'request-id': id,
    }));

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw RemoteTransportException(onTimeout);
    } finally {
      _pending.remove(id);
    }
  }

  /// Points the TV's audio at this phone, starting private listening.
  ///
  /// [endpoint] is `<this phone's LAN address>:<RTP port>`. The TV has no
  /// other way to learn where to send the stream — there is no negotiation
  /// and no reply carrying a port, so an address that is wrong or
  /// unreachable simply produces silence rather than an error.
  Future<void> startAudioStream(String endpoint) async {
    final reply = await _call(
      'set-audio-output',
      {'param-audio-output': 'datagram', 'param-devname': endpoint},
      timeout: const Duration(seconds: 5),
      onTimeout: 'TV did not answer the private listening request.',
    );
    if (!accepted(reply['status'])) {
      throw RemoteTransportException('This TV refused private listening.');
    }
  }

  /// Hands audio back to the TV speakers.
  Future<void> stopAudioStream() async {
    final reply = await _call(
      'set-audio-output',
      {'param-audio-output': 'default'},
      timeout: const Duration(seconds: 5),
      onTimeout: 'TV did not answer when handing audio back.',
    );
    if (!accepted(reply['status'])) {
      throw RemoteTransportException('TV would not release private listening.');
    }
  }

  Future<void> press(String key) async {
    final reply = await _call(
      'key-press',
      {'param-key': key},
      onTimeout: 'TV did not respond to the button.',
    );
    if (!accepted(reply['status'])) {
      throw RemoteTransportException('TV refused that button.');
    }
  }

  /// The remote key that selects a TV input, or null for a normal channel.
  ///
  /// Inputs cannot be launched. The TV answers `launch` with **403 Forbidden**
  /// for any `tvinput.*` id — verified against a TCL Roku TV, where the same
  /// id launched over plain HTTP succeeds. They are only reachable over ECP-2
  /// as key presses, even though `query-apps` lists them alongside real
  /// channels with no hint of the difference.
  static String? inputKeyFor(String channelId) {
    if (!channelId.startsWith('tvinput.')) return null;
    final input = channelId.substring('tvinput.'.length).toLowerCase();
    if (RegExp(r'^hdmi[1-4]$').hasMatch(input)) {
      return 'InputHDMI${input.substring(4)}';
    }
    return switch (input) {
      'tuner' || 'dtv' || 'antenna' => 'InputTuner',
      'av1' || 'av' || 'composite' => 'InputAV1',
      _ => null,
    };
  }

  Future<void> launch(String channelId) async {
    if (!isChannelId(channelId)) {
      throw ArgumentError('Unsupported channel id: $channelId');
    }

    // Inputs take the key-press path; only real channels can be launched.
    if (channelId.startsWith('tvinput.')) {
      final inputKey = inputKeyFor(channelId);
      if (inputKey == null) {
        // Falling through to launch would return 403 and surface as the
        // misleading "not installed" message.
        throw RemoteTransportException('This TV input cannot be selected.');
      }
      await press(inputKey);
      return;
    }

    final reply = await _call(
      'launch',
      {'param-channel-id': channelId},
      timeout: const Duration(seconds: 5),
      onTimeout: 'TV did not respond to the channel.',
    );
    if (!accepted(reply['status'])) {
      throw RemoteTransportException('That channel is not installed on this TV.');
    }
  }

  /// The installed channels and TV inputs, as the TV reports them.
  Future<List<RokuChannel>> channels() async {
    final reply = await _call(
      'query-apps',
      const {},
      timeout: const Duration(seconds: 6),
      onTimeout: 'TV did not send its channel list.',
    );
    if (!accepted(reply['status'])) {
      throw RemoteTransportException('TV would not share its channel list.');
    }
    final encoded = reply['content-data'];
    if (encoded == null || encoded.isEmpty) {
      throw RemoteTransportException('TV sent an empty channel list.');
    }

    List<int> xml;
    try {
      xml = base64.decode(encoded.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw RemoteTransportException('TV sent an unreadable channel list.');
    }
    if (xml.length > 262144) {
      throw RemoteTransportException('Channel list is too large.');
    }
    return parseChannels(utf8.decode(xml, allowMalformed: true));
  }

  /// Parses the `<apps>` document. Deliberately refuses a DOCTYPE: this input
  /// arrives base64-wrapped from the network, and an inline doctype is the
  /// entity-expansion vector, not something a real TV ever sends.
  static List<RokuChannel> parseChannels(String xml) {
    if (RegExp(r'<!DOCTYPE', caseSensitive: false).hasMatch(xml)) {
      throw RemoteTransportException('Unexpected document type.');
    }
    if (!RegExp(r'<apps[\s>]').hasMatch(xml)) {
      throw RemoteTransportException('This is not a Roku channel list.');
    }

    final channels = <RokuChannel>[];
    final app = RegExp(
      r'''<app\s+([^>]*?)>(.*?)</app>''',
      caseSensitive: false,
      dotAll: true,
    );
    final attr = RegExp(r'''(\w[\w-]*)\s*=\s*"([^"]*)"''');

    for (final match in app.allMatches(xml)) {
      final attrs = <String, String>{
        for (final a in attr.allMatches(match.group(1)!))
          a.group(1)!: a.group(2)!,
      };
      final id = attrs['id'];
      // Roku pads some names with a non-breaking space; normalise it so the
      // list does not render with odd gaps.
      final name = match
          .group(2)!
          .replaceAll(' ', ' ')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();

      if (isChannelId(id) && name.isNotEmpty) {
        channels.add(RokuChannel(id!, name, isInput: attrs['type'] == 'tvin'));
      }
      if (channels.length >= 200) break;
    }
    return channels;
  }

  /// Flattens a TV message to string fields. Values are simple scalars, so a
  /// shallow map is enough and keeps the call sites terse.
  static Map<String, String> _decode(dynamic raw) {
    if (raw is! String) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value.toString(),
      };
    } catch (_) {
      return const {};
    }
  }
}

/// Minimal pull-style adapter over a stream.
///
/// The ECP-2 handshake has to read exactly two messages in order before the
/// session becomes event-driven, which a plain `listen` cannot express. Written
/// here rather than pulling in `package:async` for one class.
class StreamQueue<T> {
  StreamQueue(Stream<T> source) {
    _sub = source.listen(
      (event) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(event);
        } else {
          _buffered.add(event);
        }
      },
      onError: (Object e) {
        if (_waiting.isNotEmpty) _waiting.removeAt(0).completeError(e);
      },
      onDone: () {
        _done = true;
        for (final waiter in _waiting) {
          waiter.completeError(StateError('Stream closed'));
        }
        _waiting.clear();
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<T> _sub;
  final List<T> _buffered = [];
  final List<Completer<T>> _waiting = [];
  bool _done = false;

  Future<T> get next {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    if (_done) return Future.error(StateError('Stream closed'));
    final completer = Completer<T>();
    _waiting.add(completer);
    return completer.future;
  }

  /// Everything not yet consumed, as a stream. Ends this queue's ownership.
  Stream<T> get rest {
    final controller = StreamController<T>();
    for (final event in _buffered) {
      controller.add(event);
    }
    _buffered.clear();
    _sub.onData(controller.add);
    _sub.onError(controller.addError);
    _sub.onDone(controller.close);
    controller.onCancel = _sub.cancel;
    return controller.stream;
  }

  Future<void> cancel({bool immediate = false}) => _sub.cancel();
}
