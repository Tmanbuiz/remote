import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'private_listening.dart';

/// "Listen to home": the microphone of a phone left at home, heard on a phone
/// somewhere else over the VPN.
///
/// This is a monitor for your own phone in your own home — a pet, a baby
/// sleeping down the hall, checking the house is quiet. It is built to be
/// obvious rather than discreet, and that is a design constraint, not a
/// styling choice: the talker only runs behind a foreground service whose
/// notification says the microphone is on, and it refuses to start when that
/// notification cannot be shown. Nothing in this file or its callers hides,
/// delays or disguises the capture.
///
/// The wire format deliberately mirrors the TV-audio relay so the listener
/// side is the same machinery: Opus in RTP, registration by a short hello,
/// and the talker answering from the same socket it sends audio from, which
/// is what lets the stream cross NAT and a VPN without any port forwarding.
/// The differences are the source (a microphone instead of a TV), the format
/// (16 kHz mono voice instead of 48 kHz stereo) and the control port, so a
/// monitor and a TV relay can be used on the same phone without colliding.
class MicStream {
  /// 16 kHz is the narrowest rate Opus accepts that still carries intelligible
  /// speech and household sound, and it is a third of the bandwidth of 48 kHz.
  static const int sampleRate = 16000;
  static const int channels = 1;

  /// Opus works in fixed frames. Twenty milliseconds is the usual voice
  /// compromise between packet overhead and the delay a lost packet costs.
  static const int frameMs = 20;
  static const int frameSamples = sampleRate * frameMs ~/ 1000; // 320

  /// RTP timestamps for Opus always tick at 48 kHz regardless of the encoded
  /// rate (RFC 7587), so one 20 ms frame advances the clock by 960.
  static const int rtpTimestampStep = 48000 * frameMs ~/ 1000;

  /// Dynamic payload type; nothing negotiates it, both ends just agree.
  static const int payloadType = 111;

  /// Where a listener announces itself. Not [AudioRelay.controlPort]: a phone
  /// can be relaying a TV and monitoring a room at once.
  static const int controlPort = 6972;

  /// Marks a registration, and distinguishes it from a TV-relay one.
  static const String hello = 'URMIC001';

  /// Voice quality at a bitrate a mobile link will not notice.
  static const int bitrate = 24000;

  /// A listener that has not announced itself for this long is assumed gone,
  /// which matters because a phone that loses signal cannot say goodbye.
  static const Duration listenerTimeout = Duration(seconds: 45);

  /// How often a listener re-announces. Three announcements per timeout.
  static const Duration announceEvery = Duration(seconds: 10);

  /// The talker's answer to a hello: the tag plus the format of what follows,
  /// so the listener configures its decoder from what is actually sent
  /// rather than from a constant that could drift.
  static String get announcement => '$hello:$sampleRate:$channels';

  /// Reads the talker's answer. Null for anything that is not one, including
  /// the stray datagrams any UDP port attracts.
  static ({int sampleRate, int channels})? parseAnnouncement(String text) {
    final parts = text.split(':');
    if (parts.length != 3 || parts[0] != hello) return null;
    final rate = int.tryParse(parts[1]);
    final channels = int.tryParse(parts[2]);
    if (rate == null || channels == null) return null;
    if (rate <= 0 || channels < 1 || channels > 2) return null;
    return (sampleRate: rate, channels: channels);
  }
}

/// Slices the arbitrary-sized chunks a recorder emits into the fixed frames
/// Opus requires.
///
/// Recorders hand back whatever the audio driver delivered — 20 ms one moment,
/// 37 the next, and on some devices an odd number of bytes — so frame
/// boundaries cannot be assumed. Anything left over is carried to the next
/// call rather than padded, because padding would insert silence into live
/// audio every time a chunk ended mid-frame.
class PcmFramer {
  PcmFramer({this.frameSamples = MicStream.frameSamples});

  final int frameSamples;
  final List<int> _pending = [];
  int? _straddlingByte;

  /// Samples held back, waiting for the rest of a frame.
  int get buffered => _pending.length;

  /// Accepts little-endian 16-bit PCM and returns every complete frame.
  List<Int16List> add(Uint8List bytes) {
    var start = 0;
    if (_straddlingByte != null && bytes.isNotEmpty) {
      // A sample was split across two chunks; this byte completes it.
      _pending.add(_signed(_straddlingByte! | (bytes[0] << 8)));
      _straddlingByte = null;
      start = 1;
    }
    var i = start;
    for (; i + 1 < bytes.length; i += 2) {
      _pending.add(_signed(bytes[i] | (bytes[i + 1] << 8)));
    }
    if (i < bytes.length) _straddlingByte = bytes[i];

    final frames = <Int16List>[];
    while (_pending.length >= frameSamples) {
      frames.add(Int16List.fromList(_pending.sublist(0, frameSamples)));
      _pending.removeRange(0, frameSamples);
    }
    return frames;
  }

  void reset() {
    _pending.clear();
    _straddlingByte = null;
  }

  static int _signed(int unsigned) => unsigned >= 0x8000 ? unsigned - 0x10000 : unsigned;
}

/// Wraps Opus frames in RTP, producing exactly what
/// [PrivateListening.rtpPayload] unwraps.
///
/// The marker bit is never set. The listener's parser currently reads that bit
/// as "padding present" and would trim bytes off the end of the Opus frame, so
/// the one packet that carried it would decode as garbage. Opus gains nothing
/// from the marker (it is only a talkspurt hint), so it stays clear.
class RtpPacketizer {
  RtpPacketizer({int? ssrc, int sequence = 0, int timestamp = 0})
      : ssrc = ssrc ?? DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF,
        _sequence = sequence & 0xFFFF,
        _timestamp = timestamp & 0xFFFFFFFF;

  final int ssrc;
  int _sequence;
  int _timestamp;

  int get nextSequence => _sequence;
  int get nextTimestamp => _timestamp;

  /// The 12-byte header plus [payload], advancing the sequence number and
  /// clock. Both wrap, as RTP requires.
  Uint8List wrap(Uint8List payload) {
    final packet = Uint8List(12 + payload.length);
    packet[0] = 0x80; // version 2, no padding, no extension, no CSRC
    packet[1] = MicStream.payloadType; // marker clear — see class comment
    packet[2] = (_sequence >> 8) & 0xFF;
    packet[3] = _sequence & 0xFF;
    packet[4] = (_timestamp >> 24) & 0xFF;
    packet[5] = (_timestamp >> 16) & 0xFF;
    packet[6] = (_timestamp >> 8) & 0xFF;
    packet[7] = _timestamp & 0xFF;
    packet[8] = (ssrc >> 24) & 0xFF;
    packet[9] = (ssrc >> 16) & 0xFF;
    packet[10] = (ssrc >> 8) & 0xFF;
    packet[11] = ssrc & 0xFF;
    packet.setRange(12, packet.length, payload);

    _sequence = (_sequence + 1) & 0xFFFF;
    _timestamp = (_timestamp + MicStream.rtpTimestampStep) & 0xFFFFFFFF;
    return packet;
  }

  /// The 16-bit sequence number of a packet [wrap] produced.
  static int sequenceOf(Uint8List packet) => (packet[2] << 8) | packet[3];

  /// Whether [candidate] is later than [last], allowing for wrap-around.
  ///
  /// UDP over a VPN reorders and duplicates; decoding a stale frame after a
  /// newer one plays a fragment of the past into the present. Half the
  /// sequence space is the conventional window for "newer".
  static bool isNewer(int candidate, int? last) {
    if (last == null) return true;
    final delta = (candidate - last) & 0xFFFF;
    return delta != 0 && delta < 0x8000;
  }
}

/// Turns 20 ms of PCM into one Opus frame. Injected so tests can run without
/// the native library, which only exists inside a built app.
typedef OpusFrameEncoder = Uint8List Function(Int16List pcm);

/// The home end: encodes microphone audio and sends it to whoever registered.
///
/// Capturing is not this class's job — it is handed a PCM stream. That keeps
/// the part that decides what leaves the phone (the listener check, the
/// framing, the destination) testable on its own, and keeps the part that
/// touches the microphone in one place where the visible notification is
/// also managed. See HomeMonitor.
class MicTalker {
  MicTalker({
    this.controlPort = MicStream.controlPort,
    this.bindAddress,
    this.encoder,
  });

  /// 0 asks the OS for a free port, which is what tests use.
  final int controlPort;

  /// Null binds every interface, so a LAN and a Tailscale listener both work.
  final InternetAddress? bindAddress;

  /// Replaces real Opus encoding; only tests pass this.
  final OpusFrameEncoder? encoder;
  OpusFrameEncoder? _encode;
  SimpleOpusEncoder? _opus;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  StreamSubscription<Uint8List>? _pcmSub;
  Timer? _sweep;
  final PcmFramer _framer = PcmFramer();
  final RtpPacketizer _packetizer = RtpPacketizer();

  InternetAddress? _listener;
  int _listenerPort = 0;
  DateTime? _lastSeen;
  bool _running = false;
  int _sent = 0;

  bool get isRunning => _running;
  bool get hasListener => _listener != null;
  int get packetsSent => _sent;

  /// The port actually bound; differs from [controlPort] when that was 0.
  int get boundPort => _socket?.port ?? 0;

  void Function()? onChanged;

  static bool _opusInitialised = false;

  static Future<void> _ensureOpus() async {
    if (_opusInitialised) return;
    initOpus(await opus_flutter.load());
    _opusInitialised = true;
  }

  /// Starts answering registrations and sending [pcm] to the registered
  /// listener.
  ///
  /// Audio produced while nobody is registered is dropped here rather than
  /// buffered: a listener who joins late should hear now, not a backlog, and
  /// nothing the microphone hears is retained on this phone.
  Future<void> start(Stream<Uint8List> pcm) async {
    if (_running) return;

    _encode = encoder;
    if (_encode == null) {
      await _ensureOpus();
      _opus = SimpleOpusEncoder(
        sampleRate: MicStream.sampleRate,
        channels: MicStream.channels,
        application: Application.voip,
      );
      _encode = (frame) => _opus!.encode(input: frame);
    }

    try {
      _socket = await RawDatagramSocket.bind(
        bindAddress ?? InternetAddress.anyIPv4,
        controlPort,
      );
    } on SocketException {
      _opus?.destroy();
      _opus = null;
      throw StateError(
        'Port $controlPort is already in use. Another copy of the monitor may '
        'be running on this phone.',
      );
    }

    _socketSub = _socket!.listen(_onControl);
    _pcmSub = pcm.listen(_onPcm);
    _sweep = Timer.periodic(const Duration(seconds: 15), (_) => _dropStaleListener());
    _running = true;
    _sent = 0;
    debugPrint('mic talker: listening for registrations on ${_socket!.port}');
    onChanged?.call();
  }

  void _onControl(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    if (String.fromCharCodes(datagram.data) != MicStream.hello) return;

    // The endpoint comes from the datagram, not from anything it claims, so a
    // listener behind NAT registers the address that actually works.
    final changed = _listener?.address != datagram.address.address ||
        _listenerPort != datagram.port;
    _listener = datagram.address;
    _listenerPort = datagram.port;
    _lastSeen = DateTime.now();

    try {
      _socket?.send(MicStream.announcement.codeUnits, datagram.address, datagram.port);
    } on SocketException {
      // It will ask again on its next announcement.
    }
    if (changed) {
      debugPrint('mic talker: listener ${datagram.address.address}:${datagram.port}');
      onChanged?.call();
    }
  }

  void _onPcm(Uint8List chunk) {
    // Nobody listening means nothing is even encoded.
    if (_listener == null) {
      _framer.reset();
      return;
    }
    for (final frame in _framer.add(chunk)) {
      final Uint8List opus;
      try {
        opus = _encode!(frame);
      } catch (_) {
        // One bad frame is a click, not a reason to stop the monitor.
        continue;
      }
      _send(_packetizer.wrap(opus));
    }
  }

  void _send(Uint8List packet) {
    final listener = _listener;
    if (listener == null) return;
    try {
      _socket?.send(packet, listener, _listenerPort);
      _sent++;
    } on SocketException {
      // The VPN drops and returns; the next frame tries again.
    }
  }

  void _dropStaleListener() {
    final seen = _lastSeen;
    if (seen == null || _listener == null) return;
    if (DateTime.now().difference(seen) < MicStream.listenerTimeout) return;
    _listener = null;
    _listenerPort = 0;
    _lastSeen = null;
    debugPrint('mic talker: listener went quiet, sending stopped');
    onChanged?.call();
  }

  Future<void> stop() async {
    _running = false;
    _sweep?.cancel();
    _sweep = null;
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _opus?.destroy();
    _opus = null;
    _encode = null;
    _framer.reset();
    _listener = null;
    _listenerPort = 0;
    _lastSeen = null;
    onChanged?.call();
  }
}

/// The far end: registers with the home phone and plays what it sends.
///
/// This is the TV-relay listener path reused for a different source. The
/// registration socket doubles as the audio socket for the same reason it does
/// there: the talker sends to the endpoint the hello arrived from, so a
/// second socket would be a port nothing is sending to.
class MicListener {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  Timer? _announceTimer;
  Timer? _watchdog;
  SimpleOpusDecoder? _decoder;
  InternetAddress? _talker;
  int _talkerPort = MicStream.controlPort;
  int? _lastSequence;
  bool _running = false;
  bool _heardAudio = false;
  int _packets = 0;
  DateTime? _lastAudio;

  bool get isRunning => _running;
  bool get hasAudio => _heardAudio;
  int get packetsReceived => _packets;

  /// Whether audio arrived recently — "connected" and "can hear" are different
  /// states, and only the second one means the monitor is working.
  bool get isHearing {
    final last = _lastAudio;
    return last != null && DateTime.now().difference(last) < const Duration(seconds: 3);
  }

  void Function()? onChanged;
  void Function(String reason)? onFailure;

  static bool _opusInitialised = false;

  static Future<void> _ensureOpus() async {
    if (_opusInitialised) return;
    initOpus(await opus_flutter.load());
    _opusInitialised = true;
  }

  /// Registers with the talker at [host] and starts playing.
  ///
  /// Throws if the talker does not answer, which is the only way a UDP-only
  /// protocol can say "nobody is home".
  Future<void> start(String host, {int port = MicStream.controlPort}) async {
    if (_running) return;
    await _ensureOpus();

    _talker = InternetAddress(host);
    _talkerPort = port;
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    final reply = Completer<({int sampleRate, int channels})?>();
    _sub = _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket?.receive();
      if (datagram == null) return;
      if (!reply.isCompleted) {
        final format = MicStream.parseAnnouncement(String.fromCharCodes(datagram.data));
        if (format != null) reply.complete(format);
        return;
      }
      _onAudio(datagram.data);
    });

    // Repeated: the first datagram over a sleeping tunnel is the likeliest lost.
    ({int sampleRate, int channels})? format;
    for (var attempt = 0; attempt < 5 && format == null; attempt++) {
      _announce();
      format = await Future.any([
        reply.future,
        Future<({int sampleRate, int channels})?>.delayed(
          const Duration(milliseconds: 600),
          () => null,
        ),
      ]);
    }
    if (format == null) {
      await stop();
      throw StateError(
        'The phone at $host did not answer. Check that Listen to home is '
        'switched on there, and that Tailscale is connected on both phones.',
      );
    }

    _decoder = SimpleOpusDecoder(sampleRate: format.sampleRate, channels: format.channels);
    await FlutterPcmSound.setup(
      sampleRate: format.sampleRate,
      channelCount: format.channels,
      iosAllowBackgroundAudio: true,
    );
    FlutterPcmSound.start();

    _running = true;
    _heardAudio = false;
    _packets = 0;
    _lastSequence = null;
    _announceTimer = Timer.periodic(MicStream.announceEvery, (_) => _announce());

    // A talker that is registered but silent (microphone blocked, phone
    // asleep, tunnel down) looks exactly like a quiet room. Say so.
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      onChanged?.call();
    });
    Timer(const Duration(seconds: 6), () {
      if (_running && !_heardAudio) {
        onFailure?.call(
          'Connected, but no audio is arriving. The phone at home may be '
          'asleep, or its microphone may be in use by another app.',
        );
      }
    });
    onChanged?.call();
  }

  void _announce() {
    final talker = _talker;
    final socket = _socket;
    if (talker == null || socket == null) return;
    try {
      socket.send(MicStream.hello.codeUnits, talker, _talkerPort);
    } on SocketException {
      // The next tick tries again.
    }
  }

  void _onAudio(Uint8List packet) {
    final payload = PrivateListening.rtpPayload(packet);
    if (payload == null) return;

    final sequence = RtpPacketizer.sequenceOf(packet);
    if (!RtpPacketizer.isNewer(sequence, _lastSequence)) return;
    _lastSequence = sequence;

    final Int16List pcm;
    try {
      pcm = _decoder!.decode(input: payload);
    } catch (_) {
      return;
    }
    _packets++;
    _lastAudio = DateTime.now();
    if (!_heardAudio) {
      _heardAudio = true;
      onChanged?.call();
    }
    FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm));
  }

  Future<void> stop() async {
    _running = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    _decoder?.destroy();
    _decoder = null;
    try {
      await FlutterPcmSound.release();
    } catch (_) {
      // Releasing a player that never started is not an error worth raising.
    }
    _lastAudio = null;
    onChanged?.call();
  }
}
