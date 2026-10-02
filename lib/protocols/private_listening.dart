import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  /// The TV stops sending if it hears nothing back within a few seconds.
  static const Duration _keepAlive = Duration(seconds: 5);

  RawDatagramSocket? _rtp;
  RawDatagramSocket? _rtcp;
  Timer? _keepAliveTimer;
  StreamSubscription<RawSocketEvent>? _rtpSub;
  SimpleOpusDecoder? _decoder;
  InternetAddress? _tv;
  bool _running = false;
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
    _rtcp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: channels);
    FlutterPcmSound.start();

    _rtpSub = _rtp!.listen(_onRtpEvent);
    _running = true;
    _heardAudio = false;
    _packets = 0;

    // Tell the TV where to send it. Do this last: the stream can begin the
    // instant this returns, and dropping the first packets sounds like a fault.
    await _session.startAudioStream('$local:$rtpPort');

    _sendReceiverReport();
    _keepAliveTimer = Timer.periodic(_keepAlive, (_) => _sendReceiverReport());

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

  /// Minimal RTCP receiver report. The TV only checks that something arrives.
  void _sendReceiverReport() {
    final tv = _tv;
    final rtcp = _rtcp;
    if (tv == null || rtcp == null || !_running) return;
    try {
      rtcp.send(buildReceiverReport(_packets), tv, rtcpPort);
    } on SocketException {
      // A dropped keepalive is recoverable; the next tick tries again.
    }
  }

  /// An empty RR: version 2, no report blocks, our SSRC. Static for tests.
  static Uint8List buildReceiverReport(int packetCount) {
    final report = Uint8List(8);
    report[0] = 0x80; // version 2, no reception report blocks
    report[1] = 201; // packet type: receiver report
    report[2] = 0x00;
    report[3] = 0x01; // length in 32-bit words minus one
    // SSRC, arbitrary but stable within a session.
    report[4] = 0x52;
    report[5] = 0x4F;
    report[6] = 0x4B;
    report[7] = 0x55;
    return report;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
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
