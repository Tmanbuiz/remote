/// The brand-neutral key vocabulary every protocol adapter maps onto its own
/// wire format. UI code only ever speaks [RemoteKey]; it never knows whether
/// the TV on the other end is a Roku, a Tizen set or a webOS panel.
enum RemoteKey {
  power,
  powerOn,
  powerOff,

  up,
  down,
  left,
  right,
  select,
  back,
  home,
  menu,
  exit,
  info,

  volumeUp,
  volumeDown,
  mute,

  channelUp,
  channelDown,

  play,
  pause,
  playPause,
  stop,
  rewind,
  fastForward,
  next,
  previous,
  record,

  input,

  digit0,
  digit1,
  digit2,
  digit3,
  digit4,
  digit5,
  digit6,
  digit7,
  digit8,
  digit9,

  red,
  green,
  yellow,
  blue;

  /// Digits are addressed positionally often enough to be worth a helper.
  static RemoteKey digit(int n) {
    assert(n >= 0 && n <= 9, 'digit must be 0-9');
    return RemoteKey.values[RemoteKey.digit0.index + n];
  }

  bool get isDigit =>
      index >= RemoteKey.digit0.index && index <= RemoteKey.digit9.index;

  int? get digitValue => isDigit ? index - RemoteKey.digit0.index : null;
}
