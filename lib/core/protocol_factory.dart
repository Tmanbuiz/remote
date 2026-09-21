import '../protocols/lg_protocol.dart';
import '../protocols/roku_protocol.dart';
import '../protocols/samsung_protocol.dart';
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
      case TvBrand.sony:
      case TvBrand.vizio:
      case TvBrand.androidTv:
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
  };
}
