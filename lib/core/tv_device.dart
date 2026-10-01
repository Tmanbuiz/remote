/// Which wire protocol a discovered set speaks. One brand can only ever map to
/// one of these; the value is what selects the adapter.
enum TvBrand {
  roku('Roku'),
  samsung('Samsung'),
  lg('LG'),
  sony('Sony'),
  vizio('Vizio'),
  androidTv('Android TV'),
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
    this.port,
    this.model,
    this.macAddress,
    this.pairingToken,
    this.tlsFingerprint,
  });

  /// Stable across rediscovery — usually the UPnP USN or the set's serial.
  final String id;
  final String name;
  final String host;
  final TvBrand brand;

  /// Null means "adapter picks its default".
  final int? port;
  final String? model;

  /// Needed for wake-on-LAN, which is the only way to power on a set whose
  /// network stack sleeps with it.
  final String? macAddress;

  final String? pairingToken;
  final String? tlsFingerprint;

  bool get isPaired => pairingToken != null && pairingToken!.isNotEmpty;

  TvDevice copyWith({
    String? name,
    String? host,
    int? port,
    String? model,
    String? macAddress,
    String? pairingToken,
    String? tlsFingerprint,
  }) {
    return TvDevice(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      brand: brand,
      port: port ?? this.port,
      model: model ?? this.model,
      macAddress: macAddress ?? this.macAddress,
      pairingToken: pairingToken ?? this.pairingToken,
      tlsFingerprint: tlsFingerprint ?? this.tlsFingerprint,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'brand': brand.name,
    'port': port,
    'model': model,
    'macAddress': macAddress,
    'pairingToken': pairingToken,
    'tlsFingerprint': tlsFingerprint,
  };

  factory TvDevice.fromJson(Map<String, dynamic> json) => TvDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    brand: TvBrand.values.firstWhere(
      (b) => b.name == json['brand'],
      orElse: () => TvBrand.unknown,
    ),
    port: json['port'] as int?,
    model: json['model'] as String?,
    macAddress: json['macAddress'] as String?,
    pairingToken: json['pairingToken'] as String?,
    tlsFingerprint: json['tlsFingerprint'] as String?,
  );

  @override
  bool operator ==(Object other) => other is TvDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TvDevice($name, ${brand.label}, $host)';
}
