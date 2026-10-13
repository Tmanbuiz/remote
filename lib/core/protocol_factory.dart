import '../protocols/lg_protocol.dart';
import '../protocols/roku_protocol.dart';
import '../protocols/samsung_protocol.dart';
import '../protocols/android_tv_protocol.dart';
import '../protocols/vidaa_protocol.dart';
import '../storage/credential_store.dart';
import 'tv_device.dart';
import 'tv_protocol.dart';

/// The single place that maps a brand to its adapter. Adding a TV brand to the
/// app means writing an adapter and adding one line here.
class ProtocolFactory {
  const ProtocolFactory._();

  static TvProtocol create(TvDevice device) {
    switch (device.brand) {
      case TvBrand.roku:
        return RokuProtocol(device);
      case TvBrand.samsung:
        return SamsungProtocol(device);
      case TvBrand.lg:
        return LgProtocol(device);
      case TvBrand.androidTv:
        return AndroidTvProtocol(device);
      case TvBrand.vidaa:
        return VidaaProtocol(device);
      case TvBrand.sony:
      case TvBrand.vizio:
      case TvBrand.appleTv:
      case TvBrand.unknown:
        throw UnimplementedError(
          '${device.brand.label} is not supported yet',
        );
    }
  }

  /// Brands with a working adapter today. The device list uses this to mark
  /// discovered-but-unsupported sets rather than letting the user tap into a
  /// dead end.
  static const Set<TvBrand> supported = {
    TvBrand.roku,
    TvBrand.samsung,
    TvBrand.lg,
    TvBrand.androidTv,
    TvBrand.vidaa,
  };

  static Future<void> forgetCredentials(TvDevice device) async {
    const store = SecureCredentialStore();
    if (device.brand == TvBrand.androidTv) await store.delete('android-tv:${device.id}');
    if (device.brand == TvBrand.vidaa) await store.delete('vidaa:${device.id}');
  }
}

