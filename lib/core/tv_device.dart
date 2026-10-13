/// Which wire protocol a discovered set speaks. One brand can only ever map to
/// one of these; the value is what selects the adapter.
enum TvBrand {
  roku('Roku'),
  samsung('Samsung'),
  lg('LG'),
  sony('Sony'),
  vizio('Vizio'),
  androidTv('Google TV / Android TV'),
  vidaa('VIDAA OS'),
  appleTv('Apple TV'),
  unknown('Unknown');

  const TvBrand(this.label);
  final String label;
}

/// A set on the network, plus whatever credential we earned by pairing with it.
///
/// [pairingToken] is the one field that must survive app restarts: Samsung and
/// LG both hand back a token on first accept and refuse to re-prompt cheaply,
/// so losing it means making the user walk to the TV again.
class TvDevice {
  const TvDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.brand,
    this.nickname,
    this.port,
    this.model,
    this.macAddress,
    this.pairingToken,
    this.firmwareVersion,
    this.serviceVersion,
    this.protocolVersion,
  });

  /// Stable across rediscovery — usually the UPnP USN or the set's serial.
  final String id;

  /// The name the set reports, such as `70" Hisense Roku TV`.
  final String name;

  /// What the user renamed it to, such as `living room TV`.
  ///
  /// Kept separate from [name] rather than overwriting it, so rediscovery can
  /// refresh what the set reports without silently discarding the name the
  /// user chose, and so clearing it restores the original instead of leaving
  /// the device nameless.
  final String? nickname;

  final String host;
  final TvBrand brand;

  /// Null means "adapter picks its default".
  final int? port;
  final String? model;

  /// Needed for wake-on-LAN, which is the only way to power on a set whose
  /// network stack sleeps with it.
  final String? macAddress;

  final String? pairingToken;
  final String? firmwareVersion;
  final String? serviceVersion;
  final int? protocolVersion;

  /// What the interface shows, and what Siri matches a spoken name against.
  String get displayName => (nickname != null && nickname!.trim().isNotEmpty)
      ? nickname!.trim()
      : name;

  bool get isPaired => pairingToken != null && pairingToken!.isNotEmpty;

  /// [clearNickname] exists because `nickname: null` cannot distinguish
  /// "leave it as it is" from "remove it" in this idiom.
  TvDevice copyWith({
    String? name,
    String? nickname,
    bool clearNickname = false,
    String? host,
    int? port,
    String? model,
    String? macAddress,
    String? pairingToken,
    bool clearPairingToken = false,
    String? firmwareVersion,
    String? serviceVersion,
    int? protocolVersion,
  }) {
    return TvDevice(
      id: id,
      name: name ?? this.name,
      nickname: clearNickname ? null : (nickname ?? this.nickname),
      host: host ?? this.host,
      brand: brand,
      port: port ?? this.port,
      model: model ?? this.model,
      macAddress: macAddress ?? this.macAddress,
      pairingToken: clearPairingToken
          ? null
          : (pairingToken ?? this.pairingToken),
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      serviceVersion: serviceVersion ?? this.serviceVersion,
      protocolVersion: protocolVersion ?? this.protocolVersion,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'nickname': nickname,
    'host': host,
    'brand': brand.name,
    'port': port,
    'model': model,
    'macAddress': macAddress,
    'pairingToken': pairingToken,
    'firmwareVersion': firmwareVersion,
    'serviceVersion': serviceVersion,
    'protocolVersion': protocolVersion,
  };

  factory TvDevice.fromJson(Map<String, dynamic> json) => TvDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    nickname: json['nickname'] as String?,
    host: json['host'] as String,
    brand: TvBrand.values.firstWhere(
      (b) => b.name == json['brand'],
      orElse: () => TvBrand.unknown,
    ),
    port: json['port'] as int?,
    model: json['model'] as String?,
    macAddress: json['macAddress'] as String?,
    pairingToken: json['pairingToken'] as String?,
    firmwareVersion: json['firmwareVersion'] as String?,
    serviceVersion: json['serviceVersion'] as String?,
    protocolVersion: json['protocolVersion'] as int?,
  );

  @override
  bool operator ==(Object other) => other is TvDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TvDevice($displayName, ${brand.label}, $host)';
}
