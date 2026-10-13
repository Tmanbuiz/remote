// Credential and topic interoperability based on vidaa-control (MIT).
// See THIRD_PARTY_NOTICES.md. A new identity still requires TV PIN approval.
import 'dart:convert';
import 'package:crypto/crypto.dart';

enum VidaaProfile { legacy, middle, modern }

class VidaaCredentials {
  const VidaaCredentials(this.clientId, this.username, this.password);
  final String clientId, username, password;
}

class VidaaWire {
  static VidaaProfile profile(int? version) => version == null || version >= 3290
      ? VidaaProfile.modern : (version >= 3000 ? VidaaProfile.middle : VidaaProfile.legacy);

  static VidaaCredentials credentials(String uuid, VidaaProfile profile, int seconds) {
    String digest(String value) => md5.convert(utf8.encode(value)).toString().toUpperCase();
    final race = digest('38D65DC30F45109A369A86FCE866A85B\$$uuid').substring(0, 6);
    final suffix = profile == VidaaProfile.modern ? 'h!i@s#\$v%i^d&a*a' : 'h*i&s%e!r^v0i1c9';
    final remainder = seconds.toString().split('').fold<int>(0, (sum, d) => sum + int.parse(d)) % 10;
    final value = digest('his$remainder$suffix').substring(0, 6);
    final username = profile == VidaaProfile.legacy ? seconds : seconds ^ 0x569814772b03a968;
    return VidaaCredentials('$uuid\$his\$${race}_vidaacommon_001', 'his\$$username', digest('$seconds\$$value'));
  }

  static String action(String client, String service, String action) =>
      '/remoteapp/tv/$service/$client/actions/$action';
  static String responses(String client) => '/remoteapp/mobile/$client/#';
  static String tokenRequest(String client) => '/remoteapp/tv/platform_service/$client/data/gettoken';
  static String pinPayload(String pin) {
    if (!RegExp(r'^\d{4}$').hasMatch(pin.trim())) {
      throw const FormatException('Enter the four-digit code shown on the TV.');
    }
    // Firmware expects a JSON number, not a quoted digit string.
    return jsonEncode({'authNum': int.parse(pin.trim())});
  }
  static bool pinAccepted(Object? payload) => payload is Map && payload['result'] == 1;

  static Map<String, dynamic>? tokens(Object? payload, DateTime now) {
    if (payload is! Map || payload['accesstoken'] is! String ||
        (payload['accesstoken'] as String).isEmpty) return null;
    int expiry(String prefix, int fallback) {
      final days = int.tryParse('${payload['${prefix}_duration_day']}') ?? fallback;
      final seconds = int.tryParse('${payload['${prefix}_time']}') ?? now.millisecondsSinceEpoch ~/ 1000;
      return seconds * 1000 + days.clamp(1, 3650).toInt() * Duration.millisecondsPerDay;
    }
    return {
      'accessToken': payload['accesstoken'],
      'refreshToken': payload['refreshtoken'] is String ? payload['refreshtoken'] : null,
      'accessExpiresAt': expiry('accesstoken', 7),
      'refreshExpiresAt': expiry('refreshtoken', 30),
    };
  }
}
