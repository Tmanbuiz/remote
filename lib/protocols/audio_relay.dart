import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'private_listening.dart';

/// Bridges TV audio from the home LAN to a listener reachable only over a VPN.
///
/// Private listening is one-way and unroutable by design: the TV is handed an
/// address and fires RTP at it, with no negotiation and no error when the
/// address is unreachable. A phone on the far end of Tailscale has a 100.x
/// address the TV has no route to, so the stream dies at the first hop and the
/// user hears nothing but silence.
///
/// This runs on a device that sits on both networks — the phone left at home —
/// and is the only thing either side needs to be told about. The TV is given
/// this device's LAN address, which it can reach; the datagrams are forwarded
/// to whatever endpoint registered over the VPN.
///
/// The RTCP keepalive is sent from here rather than from the listener, and
/// that is not an implementation convenience: the TV tracks a client by the
/// exact address and port in rtp-address and ignores reports from anywhere
/// else, cutting the stream at five seconds. Only this device can send them.
class AudioRelay {
  /// The TV will only ever send here, so the relay has to own this port.
  static const int rtpPort = PrivateListening.rtpPort;

  /// Where a listener announces itself. Separate from [rtpPort] so a
  /// registration can never be mistaken for audio.
  static const int controlPort = 6971;

  /// Keeps a listener registered. Three missed announcements and the relay
  /// assumes it went away, which matters because a phone that loses signal
  /// never gets the chance to say goodbye.
  static const Duration listenerTimeout = Duration(seconds: 45);

  /// Marks a registration. Any UDP port attracts stray traffic, and forwarding
  /// a stranger's audio to a stranger's address is worth one cheap check.
  static const String hello = 'URRELAY1';

  RawDatagramSocket? _rtp;
  RawDatagramSocket? _control;
  StreamSubscription<RawSocketEvent>? _rtpSub;
  StreamSubscription<RawSocketEvent>? _controlSub;
  Timer? _keepAlive;
  Timer? _sweep;

  InternetAddress? _tv;
  InternetAddress? _listener;
  int _listenerPort = 0;
  DateTime? _lastSeen;

  bool _running = false;
  int _forwarded = 0;

  bool get isRunning => _running;
  int get packetsForwarded => _forwarded;
  bool get hasListener => _listener != null;

  /// The address to hand the TV. Null until [start] has found an interface on
  /// the TV's network.
  String? lanEndpoint;

  void Function()? onChanged;

  /// Starts relaying audio from [tvHost].
  ///
  /// Binding both ports is the part that can fail in a way worth reporting:
  /// another copy of the app, or a real private-listening session on this same
  /// phone, already holds 6970.
  Future<void> start(String tvHost) async {
    if (_running) return;

    final local = await PrivateListening.localAddressFor(tvHost);
    if (local == null) {
      throw StateError(
        'This phone is not on the same network as the TV, so it cannot relay '
        'the audio. Leave it on the home Wi-Fi.',
      );
    }

    _tv = InternetAddress(tvHost);
    try {
      _rtp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, rtpPort);
      _control = await RawDatagramSocket.bind(InternetAddress.anyIPv4, controlPort);
    } on SocketException {
      await stop();
      throw StateError(
        'Port $rtpPort is already in use. Stop private listening on this phone '
        'before relaying it to another one.',
      );
    }

    lanEndpoint = '$local:$rtpPort';
    _rtpSub = _rtp!.listen(_onRtp);
    _controlSub = _control!.listen(_onControl);
    _running = true;
    _forwarded = 0;

    debugPrint('audio relay: listening on $lanEndpoint, control $controlPort');

    // The TV needs these whether or not anyone is listening yet, otherwise it
    // stops sending before the far end has finished registering.
    _sendKeepAlive();
    _keepAlive = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sendKeepAlive(),
    );
    _sweep = Timer.periodic(const Duration(seconds: 15), (_) => _dropStaleListener());
    onChanged?.call();
  }

  /// Audio from the TV, forwarded verbatim.
  ///
  /// Deliberately not parsed. The listener already knows how to read an RTP
  /// header, and a relay that understood the payload would be a second place
  /// for the format to be wrong.
  void _onRtp(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _rtp?.receive();
    if (datagram == null) return;

    final listener = _listener;
    if (listener == null) return;
    try {
      _rtp?.send(datagram.data, listener, _listenerPort);
      _forwarded++;
    } on SocketException {
      // The VPN drops and returns; the next packet tries again.
    }
  }

  /// A listener announcing where to send the audio.
  ///
  /// The endpoint is taken from the datagram rather than from anything it
  /// says, so a listener behind NAT registers the address that actually works.
  void _onControl(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _control?.receive();
    if (datagram == null) return;
    if (String.fromCharCodes(datagram.data) != hello) return;

    final changed = _listener?.address != datagram.address.address ||
        _listenerPort != datagram.port;
    _listener = datagram.address;
    _listenerPort = datagram.port;
    _lastSeen = DateTime.now();

    // Tell it which address to give the TV, so the far end never has to be
    // told this phone's LAN address by hand.
    try {
      _control?.send(
        (lanEndpoint ?? '').codeUnits,
        datagram.address,
        datagram.port,
      );
    } on SocketException {
      // It will ask again on its next announcement.
    }

    if (changed) {
      debugPrint('audio relay: listener ${datagram.address.address}:${datagram.port}');
      onChanged?.call();
    }
  }

  void _dropStaleListener() {
    final seen = _lastSeen;
    if (seen == null || _listener == null) return;
    if (DateTime.now().difference(seen) < listenerTimeout) return;
    _listener = null;
    _listenerPort = 0;
    _lastSeen = null;
    debugPrint('audio relay: listener went quiet, forwarding stopped');
    onChanged?.call();
  }

  /// The keepalive the TV insists on, sent from the RTP socket.
  void _sendKeepAlive() {
    final tv = _tv;
    final socket = _rtp;
    if (tv == null || socket == null || !_running) return;
    try {
      socket.send(PrivateListening.buildApp('VDLY', 500000), tv, PrivateListening.rtcpPort);
      socket.send(PrivateListening.buildApp('CVER', 808464434), tv, PrivateListening.rtcpPort);
      socket.send(PrivateListening.buildReceiverReport(), tv, PrivateListening.rtcpPort);
    } on SocketException {
      // A dropped keepalive is recoverable; the next tick tries again.
    }
  }

  Future<void> stop() async {
    _running = false;
    _keepAlive?.cancel();
    _keepAlive = null;
    _sweep?.cancel();
    _sweep = null;
    await _rtpSub?.cancel();
    _rtpSub = null;
    await _controlSub?.cancel();
    _controlSub = null;
    _rtp?.close();
    _rtp = null;
    _control?.close();
    _control = null;
    _listener = null;
    _listenerPort = 0;
    _lastSeen = null;
    lanEndpoint = null;
    onChanged?.call();
  }
}
