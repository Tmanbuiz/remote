import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'audio_relay.dart';
import 'roku_ecp2_session.dart';

/// Roku private listening: TV audio to this phone's headphones.
///
/// The TV sends Opus in RTP to a port it is told about and nothing else. There
/// is no negotiation, no acknowledgement that the stream started, and no error
/// if the address is wrong — it simply plays to nobody. So every failure here
/// has to be inferred from silence, which is why [onFirstAudio] exists.
///
/// Protocol, reverse engineered by the RPListening project:
///   - start:  set-audio-output with param-devname `<our ip>:<rtp port>`
///   - audio:  RTP on UDP 6970, payload is Opus at 48 kHz stereo
///   - keep:   an RTCP receiver report to the TV every 5 s, or it stops
class PrivateListening {
  PrivateListening(this._session);

  final RokuEcp2Session _session;

  /// The TV will only send to these; they are not negotiated.
  static const int rtpPort = 6970;
  static const int rtcpPort = 5150;

  /// Opus in Roku's stream is always 48 kHz stereo.
  static const int sampleRate = 48000;
  static const int channels = 2;

  /// How often to reassure the TV that someone is still listening.
  ///
  /// The reference implementation uses five seconds, but this TV drops the
  /// stream after roughly four — audio played for two seconds and then the
  /// set went back to its speakers, every time, just before the second report
  /// was due. One second costs 32 bytes and removes the race entirely.
  static const Duration _keepAlive = Duration(seconds: 1);

  RawDatagramSocket? _rtp;
  InternetAddress? _relay;
  bool _viaRelay = false;
  Timer? _keepAliveTimer;
  Timer? _sessionTimer;
  StreamSubscription<RawSocketEvent>? _rtpSub;
  SimpleOpusDecoder? _decoder;
  InternetAddress? _tv;
  bool _running = false;
  bool _askedTv = false;
  bool _heardAudio = false;
  int _packets = 0;

  bool get isRunning => _running;

  /// Packets received so far — the only honest signal that it is working.
  int get packetsReceived => _packets;

  /// Fires once the first audio packet arrives, so the UI can stop saying
  /// "starting" and admit success. If it never fires, something upstream is
  /// wrong and the user is owed a message rather than indefinite silence.
  void Function()? onFirstAudio;
  void Function(String reason)? onFailure;

  static bool _opusInitialised = false;

  /// libopus is loaded from the platform package once per process.
  static Future<void> _ensureOpus() async {
    if (_opusInitialised) return;
    initOpus(await opus_flutter.load());
    _opusInitialised = true;
  }

  /// Finds this phone's address on the same network as [tvHost].
  ///
  /// The TV sends to whatever address we hand it, so a VPN or cellular
  /// interface here means the audio goes somewhere unreachable and the user
  /// just hears nothing. Matching the TV's /24 is crude but it is what
  /// actually distinguishes the right interface on a phone.
  static Future<String?> localAddressFor(String tvHost) async {
    final tvPrefix = tvHost.substring(0, tvHost.lastIndexOf('.') + 1);
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.address.startsWith(tvPrefix)) return address.address;
      }
    }
    return null;
  }

  /// Starts the stream.
  ///
  /// [relayHost] routes the audio through a phone left at home, for a listener
  /// that can reach the TV's control channel over a VPN but cannot receive its
  /// audio — see AudioRelay. Without it this phone must be on the TV's own
  /// network, which is the ordinary case.
  Future<void> start(String tvHost, {String? relayHost}) async {
    if (_running) return;
    _askedTv = false;
    try {
      await _begin(tvHost, relayHost: relayHost);
    } catch (_) {
      // A start that throws must not leave anything behind. Before this, the
      // failure came after _running was already true, so the chip read
      // "Listening" over a stream that never began, with the RTP port still
      // bound and the player still open.
      _running = false;
      await _release();
      if (_askedTv) {
        // The TV may have registered us before the failure; leaving it
        // registered is how a set ends up refusing further clients.
        try {
          await _session.stopAudioStream();
        } catch (_) {
          // The session is likely the thing that failed.
        }
      }
      rethrow;
    }
  }

  Future<void> _begin(String tvHost, {String? relayHost}) async {
    await _ensureOpus();

    _viaRelay = relayHost != null && relayHost.isNotEmpty;

    final String endpoint;
    if (_viaRelay) {
      // The relay answers with the address the TV should be given, so the
      // user never has to know the home phone's LAN address.
      final announced = await _registerWithRelay(relayHost!);
      if (announced == null) {
        throw StateError(
          'The relay at $relayHost did not answer. Check that the phone at '
          'home is on the same Wi-Fi as the TV, with relaying switched on.',
        );
      }
      endpoint = announced;
    } else {
      final local = await localAddressFor(tvHost);
      if (local == null) {
        throw StateError(
          'This phone is not on the same network as the TV, so the audio would '
          'have nowhere to go.',
        );
      }
      endpoint = '$local:$rtpPort';
    }

    _tv = InternetAddress(tvHost);
    _decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);

    // Through a relay the port is whatever the registration socket already
    // claimed, because that is the endpoint the relay learned to forward to.
    _rtp ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, rtpPort);
    // Deliberately no separate RTCP socket. The TV tracks the client by the
    // exact address:port it was handed in rtp-address, and only counts
    // keepalives arriving from that same endpoint. Reports sent from their
    // own port are well-formed, reach the TV, and are ignored — the stream
    // then stops after five seconds. Measured: from 6970 it runs for 40
    // seconds and counting, from 6971 or 5150 it dies at 5.0.

    // iosAllowBackgroundAudio pairs with UIBackgroundModes audio in Info.plist.
    // Without it iOS stops playback the moment the screen locks, which is
    // exactly when someone listening on headphones puts the phone down.
    await FlutterPcmSound.setup(
      sampleRate: sampleRate,
      channelCount: channels,
      iosAllowBackgroundAudio: true,
    );
    FlutterPcmSound.start();

    debugPrint('private listening: rtp on ${_rtp?.port}${_viaRelay ? ' via relay' : ''}');
    // Through a relay the subscription was already made during registration,
    // and a second listen on the same socket would throw.
    _rtpSub ??= _rtp!.listen(_onRtpEvent);
    _running = true;
    _heardAudio = false;
    _packets = 0;

    // Tell the TV where to send it. Do this last: the stream can begin the
    // instant this returns, and dropping the first packets sounds like a fault.
    _askedTv = true;
    await _session.startAudioStream(endpoint);

    if (_viaRelay) {
      // The relay owns the RTCP path — it is the endpoint the TV recognises,
      // and reports from here would be ignored. Keep announcing instead, so
      // it knows this listener is still there.
      _keepAliveTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _announce(),
      );
    } else {
      _sendReceiverReport();
      _keepAliveTimer = Timer.periodic(_keepAlive, (_) => _sendReceiverReport());
    }
    // Keep the control session talking too. Silence on the WebSocket, not
    // the RTCP path, is the difference between us and the official client.
    _sessionTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_running) return;
      try {
        await _session.heartbeat();
      } catch (_) {
        // A missed heartbeat is not fatal on its own.
      }
    });

    // Silence is the TV's way of reporting every possible failure, so give it
    // a deadline rather than leaving the user staring at a hopeful spinner.
    Timer(const Duration(seconds: 6), () {
      if (_running && !_heardAudio) {
        onFailure?.call(
          'No audio arrived from the TV. Private listening is not supported by '
          'every set, and some networks block the stream.',
        );
      }
    });
  }

  void _onRtpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _rtp?.receive();
    if (datagram == null) return;
    final decoded = _decodeRtp(datagram.data);
    if (decoded == null) return;

    _packets++;
    if (!_heardAudio) {
      _heardAudio = true;
      onFirstAudio?.call();
    }
    FlutterPcmSound.feed(PcmArrayInt16.fromList(decoded));
  }

  /// Strips the RTP header and decodes the Opus payload to 16-bit PCM.
  ///
  /// Returns null for anything that is not a well-formed RTP packet, which
  /// includes the stray traffic any broadcast-heavy network produces.
  List<int>? _decodeRtp(Uint8List packet) {
    final payload = rtpPayload(packet);
    if (payload == null) return null;
    try {
      return _decoder?.decode(input: payload);
    } catch (_) {
      // A corrupt frame is not worth tearing the session down for.
      return null;
    }
  }

  /// RTP header is 12 bytes, plus 4 per CSRC, plus an optional extension.
  /// Exposed for tests: this is pure parsing with no socket involved.
  static Uint8List? rtpPayload(Uint8List packet) {
    if (packet.length < 12) return null;
    if ((packet[0] >> 6) != 2) return null; // version must be 2

    final csrcCount = packet[0] & 0x0F;
    var offset = 12 + csrcCount * 4;
    if (packet.length < offset) return null;

    final hasExtension = (packet[0] & 0x10) != 0;
    if (hasExtension) {
      if (packet.length < offset + 4) return null;
      final words = (packet[offset + 2] << 8) | packet[offset + 3];
      offset += 4 + words * 4;
      if (packet.length < offset) return null;
    }

    if ((packet[1] & 0x80) != 0) {
      // Padding: the final byte says how much to drop.
      final padding = packet[packet.length - 1];
      if (padding == 0 || packet.length - padding < offset) return null;
      return packet.sublist(offset, packet.length - padding);
    }
    return packet.sublist(offset);
  }

  /// Announces this listener to the relay and returns the address the relay
  /// says to hand the TV.
  ///
  /// The socket used here is kept and reused for the audio, because the relay
  /// forwards to whatever endpoint the announcement arrived from — binding a
  /// second socket would register a port nothing is listening on.
  Future<String?> _registerWithRelay(String relayHost) async {
    _relay = InternetAddress(relayHost);
    _rtp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    final reply = Completer<String?>();
    _rtpSub = _rtp!.listen((event) {
      // Once registered, everything arriving here is audio.
      if (reply.isCompleted) {
        _onRtpEvent(event);
        return;
      }
      if (event != RawSocketEvent.read) return;
      final datagram = _rtp?.receive();
      if (datagram == null) return;
      final text = String.fromCharCodes(datagram.data);
      if (text.contains(':')) reply.complete(text);
    });

    // Repeated rather than sent once: this is a VPN hop, and the first
    // datagram over a sleeping tunnel is the one most likely to vanish.
    for (var attempt = 0; attempt < 5; attempt++) {
      _announce();
      final answer = await Future.any([
        reply.future,
        Future<String?>.delayed(const Duration(milliseconds: 600), () => null),
      ]);
      if (answer != null) return answer;
    }
    return null;
  }

  void _announce() {
    final relay = _relay;
    final socket = _rtp;
    if (relay == null || socket == null) return;
    try {
      socket.send(AudioRelay.hello.codeUnits, relay, AudioRelay.controlPort);
    } on SocketException {
      // The next tick tries again.
    }
  }

  /// Minimal RTCP receiver report. The TV only checks that something arrives.
  void _sendReceiverReport() {
    final tv = _tv;
    final rtcp = _rtp;
    if (tv == null || rtcp == null || !_running) return;
    try {
      // The reference client sends three packets per tick, each with a zero
      // identifier rather than our own SSRC.
      rtcp.send(buildApp('VDLY', 500000), tv, rtcpPort);
      rtcp.send(buildApp('CVER', 808464434), tv, rtcpPort);
      rtcp.send(buildReceiverReport(), tv, rtcpPort);
    } on SocketException {
      // A dropped keepalive is recoverable; the next tick tries again.
    }
  }

  /// RTCP APP packet, built exactly as the reference client builds it.
  ///
  /// The identifier field is zero rather than our SSRC. Both forms are
  /// well-formed RTCP and the TV accepts either; what it will not accept is
  /// a report from the wrong source port.
  static Uint8List buildApp(String name, int value) {
    final packet = Uint8List(16);
    packet[0] = 0x80; // version 2, no padding, subtype 0
    packet[1] = 204; // APP
    packet[2] = 0x00;
    packet[3] = 0x03; // 16 bytes = 4 words, minus one
    _writeUint32(packet, 4, 0); // identifier: zero
    final label = name.codeUnits;
    for (var i = 0; i < 4 && i < label.length; i++) {
      packet[8 + i] = label[i];
    }
    _writeUint32(packet, 12, value);
    return packet;
  }

  /// The fixed receiver report the reference client sends verbatim.
  static Uint8List buildReceiverReport() {
    final report = Uint8List(32);
    report[0] = 0x81; // version 2, one reception report block
    report[1] = 201; // receiver report
    report[2] = 0x00;
    report[3] = 0x07; // 32 bytes = 8 words, minus one
    // Everything after the header stays zero, as the reference sends it.
    return report;
  }

  static void _writeUint32(Uint8List target, int offset, int value) {
    target[offset] = (value >> 24) & 0xFF;
    target[offset + 1] = (value >> 16) & 0xFF;
    target[offset + 2] = (value >> 8) & 0xFF;
    target[offset + 3] = value & 0xFF;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _release();
    try {
      await _session.stopAudioStream();
    } catch (_) {
      // The TV returns to its speakers on its own when the stream stops.
    }
  }

  /// Everything start() can have acquired, released idempotently.
  Future<void> _release() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _sessionTimer?.cancel();
    _sessionTimer = null;
    await _rtpSub?.cancel();
    _rtpSub = null;
    _rtp?.close();
    _rtp = null;
    _relay = null;
    _viaRelay = false;
    _decoder?.destroy();
    _decoder = null;
    try {
      await FlutterPcmSound.release();
    } catch (_) {
      // Releasing a player that never started is not an error worth raising.
    }
  }
}
