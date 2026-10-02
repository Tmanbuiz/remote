import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

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
  RawDatagramSocket? _rtcp;
  Timer? _keepAliveTimer;
  Timer? _sessionTimer;
  StreamSubscription<RawSocketEvent>? _rtpSub;
  SimpleOpusDecoder? _decoder;
  InternetAddress? _tv;
  bool _running = false;
  bool _heardAudio = false;
  int _packets = 0;

  /// Taken from the incoming stream: an RTCP report that does not name the
  /// sender's SSRC and the sequence reached is not a report the TV can match
  /// to its own stream, and it keeps sending only while it is satisfied.
  int? _senderSsrc;
  int _highestSeq = 0;

  /// Where the TV streams from. RTCP conventionally goes back to the port
  /// the media came from, not to a fixed one.
  int? _rtpSourcePort;

  /// Ours, arbitrary but stable for the session.
  static const int _ourSsrc = 0x524F4B55;

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

  Future<void> start(String tvHost) async {
    if (_running) return;
    await _ensureOpus();

    final local = await localAddressFor(tvHost);
    if (local == null) {
      throw StateError(
        'This phone is not on the same network as the TV, so the audio would '
        'have nowhere to go.',
      );
    }

    _tv = InternetAddress(tvHost);
    _decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);

    _rtp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, rtpPort);
    // Bind the port the TV expects to hear from. Falling back to an
    // ephemeral port keeps the stream alive on phones where 5150 is taken,
    // even though the TV may then ignore the reports.
    try {
      _rtcp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, rtcpPort);
    } on SocketException {
      _rtcp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }

    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: channels);
    FlutterPcmSound.start();

    debugPrint('private listening: rtp on ${_rtp?.port}, rtcp from ${_rtcp?.port}');
    _rtpSub = _rtp!.listen(_onRtpEvent);
    // The TV's own RTCP tells us where it expects replies; we were never
    // reading it, so any request from the set went unanswered.
    _rtcp?.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _rtcp?.receive();
      if (datagram == null) return;
      debugPrint(
        'rtcp <- ${datagram.address.address}:${datagram.port} '
        'pt=${datagram.data.length > 1 ? datagram.data[1] : -1} '
        'len=${datagram.data.length}',
      );
    });
    _running = true;
    _heardAudio = false;
    _packets = 0;

    // Tell the TV where to send it. Do this last: the stream can begin the
    // instant this returns, and dropping the first packets sounds like a fault.
    await _session.startAudioStream('$local:$rtpPort');

    _sendReceiverReport();
    _keepAliveTimer = Timer.periodic(_keepAlive, (_) => _sendReceiverReport());
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

    final packet = datagram.data;
    if (_rtpSourcePort == null) {
      _rtpSourcePort = datagram.port;
      debugPrint('rtp source ${datagram.address.address}:${datagram.port}');
    }
    _senderSsrc = (packet[8] << 24) | (packet[9] << 16) | (packet[10] << 8) | packet[11];
    final seq = (packet[2] << 8) | packet[3];
    if (seq > _highestSeq) _highestSeq = seq;

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

  /// Minimal RTCP receiver report. The TV only checks that something arrives.
  void _sendReceiverReport() {
    final tv = _tv;
    final rtcp = _rtcp;
    if (tv == null || rtcp == null || !_running) return;
    try {
      final report = buildCompoundReport(
          ourSsrc: _ourSsrc,
          senderSsrc: _senderSsrc ?? 0,
        highestSequence: _highestSeq,
      );
      rtcp.send(report, tv, rtcpPort);
      final source = _rtpSourcePort;
      if (source != null && source != rtcpPort) {
        rtcp.send(report, tv, source);
      }
    } on SocketException {
      // A dropped keepalive is recoverable; the next tick tries again.
    }
  }

  /// A conformant RTCP receiver report: header plus one report block.
  ///
  /// The earlier version sent an eight-byte stub with no report block, which
  /// is well-formed RTCP but tells the TV nothing about the stream it is
  /// sending. The TV treated that as nobody listening and stopped after a few
  /// seconds — audio that starts and then dies is the signature of this.
  static Uint8List buildReceiverReport({
    required int ourSsrc,
    required int senderSsrc,
    required int highestSequence,
    int fractionLost = 0,
    int cumulativeLost = 0,
  }) {
    final report = Uint8List(32);
    report[0] = 0x81; // version 2, one reception report block
    report[1] = 201; // receiver report
    report[2] = 0x00;
    report[3] = 0x07; // 32 bytes = 8 words, minus one
    _writeUint32(report, 4, ourSsrc);

    // Report block: the stream we are reporting on.
    _writeUint32(report, 8, senderSsrc);
    report[12] = fractionLost & 0xFF;
    report[13] = (cumulativeLost >> 16) & 0xFF;
    report[14] = (cumulativeLost >> 8) & 0xFF;
    report[15] = cumulativeLost & 0xFF;
    _writeUint32(report, 16, highestSequence);
    _writeUint32(report, 20, 0); // interarrival jitter
    _writeUint32(report, 24, 0); // last sender report
    _writeUint32(report, 28, 0); // delay since last sender report
    return report;
  }

  /// A receiver report followed by SDES, which is what RFC 3550 calls a
  /// compound packet and what the TV actually requires.
  ///
  /// A bare receiver report is well-formed on its own but not compliant: the
  /// spec says every compound packet must carry an SDES chunk with a CNAME.
  /// The TV sent audio for exactly five seconds and then stopped, regardless
  /// of how often the bare report was sent, because it was discarding them.
  static Uint8List buildCompoundReport({
    required int ourSsrc,
    required int senderSsrc,
    required int highestSequence,
    String cname = 'UniversalRemote',
  }) {
    final report = buildReceiverReport(
      ourSsrc: ourSsrc,
      senderSsrc: senderSsrc,
      highestSequence: highestSequence,
    );
    final sdes = buildSdes(ourSsrc, cname);
    return Uint8List.fromList([...report, ...sdes]);
  }

  /// SDES with a single CNAME item, padded to a 32-bit boundary.
  static Uint8List buildSdes(int ssrc, String cname) {
    final text = cname.codeUnits.take(255).toList();
    // ssrc + item type + item length + text + a terminating zero
    var chunkLength = 4 + 2 + text.length + 1;
    final padding = (4 - (chunkLength % 4)) % 4;
    chunkLength += padding;

    final packet = Uint8List(4 + chunkLength);
    packet[0] = 0x81; // version 2, one source chunk
    packet[1] = 202; // SDES
    final words = (packet.length ~/ 4) - 1;
    packet[2] = (words >> 8) & 0xFF;
    packet[3] = words & 0xFF;
    _writeUint32(packet, 4, ssrc);
    packet[8] = 1; // CNAME
    packet[9] = text.length;
    for (var i = 0; i < text.length; i++) {
      packet[10 + i] = text[i];
    }
    // Remaining bytes are already zero: the item terminator plus padding.
    return packet;
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
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _sessionTimer?.cancel();
    _sessionTimer = null;
    await _rtpSub?.cancel();
    _rtpSub = null;
    _rtp?.close();
    _rtcp?.close();
    _rtp = null;
    _rtcp = null;
    _decoder?.destroy();
    _decoder = null;
    try {
      await FlutterPcmSound.release();
    } catch (_) {
      // Releasing a player that never started is not an error worth raising.
    }
    try {
      await _session.stopAudioStream();
    } catch (_) {
      // The TV returns to its speakers on its own when the stream stops.
    }
  }
}
