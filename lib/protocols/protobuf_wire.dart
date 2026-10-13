import 'dart:convert';
import 'dart:typed_data';

/// The Android TV service uses varint-delimited protobuf, not fixed-size frames.
/// A small wire codec keeps the supported message subset independent of protoc.
class Proto {
  static List<int> varint(int value) {
    if (value < 0) throw const FormatException('Negative protobuf value');
    final out = <int>[];
    do {
      final part = value & 127;
      value >>= 7;
      out.add(part | (value == 0 ? 0 : 128));
    } while (value != 0);
    return out;
  }

  static List<int> number(int field, int value) =>
      [...varint(field << 3), ...varint(value)];
  static List<int> bytes(int field, List<int> value) =>
      [...varint((field << 3) | 2), ...varint(value.length), ...value];
  static List<int> text(int field, String value) => bytes(field, utf8.encode(value));
  static List<int> frame(List<int> message) => [...varint(message.length), ...message];

  static Map<int, List<Object>> decode(List<int> data) {
    final fields = <int, List<Object>>{};
    var pos = 0;
    int readNumber() {
      var value = 0;
      for (var shift = 0; shift < 63; shift += 7) {
        if (pos >= data.length) throw const FormatException('Truncated protobuf');
        final byte = data[pos++];
        value |= (byte & 127) << shift;
        if ((byte & 128) == 0) return value;
      }
      throw const FormatException('Invalid protobuf varint');
    }
    while (pos < data.length) {
      final tag = readNumber();
      final field = tag >> 3;
      if (field == 0) throw const FormatException('Invalid protobuf field');
      final wire = tag & 7;
      Object value;
      if (wire == 0) {
        value = readNumber();
      } else if (wire == 2 || wire == 1 || wire == 5) {
        final size = wire == 2 ? readNumber() : (wire == 1 ? 8 : 4);
        if (size < 0 || pos + size > data.length) {
          throw const FormatException('Truncated protobuf field');
        }
        value = Uint8List.fromList(data.sublist(pos, pos + size));
        pos += size;
      } else {
        throw const FormatException('Unsupported protobuf wire type');
      }
      (fields[field] ??= []).add(value);
    }
    return fields;
  }

  static int integer(Map<int, List<Object>> fields, int tag, [int fallback = 0]) =>
      fields[tag]?.firstOrNull is int ? fields[tag]!.first as int : fallback;
  static Map<int, List<Object>> nested(Map<int, List<Object>> fields, int tag) =>
      fields[tag]?.firstOrNull is Uint8List
          ? decode(fields[tag]!.first as Uint8List) : {};
  static String string(Map<int, List<Object>> fields, int tag) =>
      fields[tag]?.firstOrNull is Uint8List
          ? utf8.decode(fields[tag]!.first as Uint8List) : '';
}

class ProtoFrames {
  static const maximumSize = 1024 * 1024;
  final List<int> _buffer = [];

  List<Uint8List> add(List<int> chunk) {
    _buffer.addAll(chunk);
    final out = <Uint8List>[];
    while (_buffer.isNotEmpty) {
      var size = 0;
      var prefix = 0;
      var complete = false;
      for (; prefix < _buffer.length && prefix < 5; prefix++) {
        final b = _buffer[prefix];
        size |= (b & 127) << (7 * prefix);
        if ((b & 128) == 0) { prefix++; complete = true; break; }
      }
      if (!complete) {
        if (prefix == 5) throw const FormatException('Invalid frame length');
        break;
      }
      if (size > maximumSize) throw const FormatException('Frame too large');
      if (_buffer.length < prefix + size) break;
      out.add(Uint8List.fromList(_buffer.sublist(prefix, prefix + size)));
      _buffer.removeRange(0, prefix + size);
    }
    if (_buffer.length > maximumSize + 5) {
      throw const FormatException('Frame buffer too large');
    }
    return out;
  }
}
