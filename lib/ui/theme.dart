import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app's visual identity.
///
/// Dark only, and deliberately not ThemeMode.system. A TV remote is used in a
/// dark room at night; a light interface is genuinely unpleasant there and the
/// phone becomes the brightest thing in it. Following the system theme would
/// mean most people get the wrong one.
///
/// The palette matches the launcher icon so the app and its icon read as one
/// thing: teal on a near-black that keeps a trace of the same hue.
abstract final class RemoteTheme {
  // Backgrounds, darkest first. Not pure black: a slight teal cast keeps the
  // accent from looking pasted on, and OLED pure black makes the scroll edges
  // disappear entirely.
  static const Color backdrop = Color(0xFF070C0E);
  static const Color surface = Color(0xFF101A1D);
  static const Color surfaceRaised = Color(0xFF162428);
  static const Color hairline = Color(0xFF1E3035);

  // The accent, straight from the icon.
  static const Color accent = Color(0xFF4FD1C5);
  static const Color accentDim = Color(0xFF2F8E87);
  static const Color accentGlow = Color(0x334FD1C5);

  static const Color text = Color(0xFFE6F1F0);
  static const Color textMuted = Color(0xFF7E979B);
  static const Color danger = Color(0xFFFF6B6B);

  /// Buttons that are pressed dozens of times in a row should feel quick.
  static const Duration press = Duration(milliseconds: 90);

  static ThemeData build() {
    const scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Color(0xFF04211F),
      secondary: accent,
      surface: surface,
      onSurface: text,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: backdrop,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: text,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: backdrop,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      textTheme: const TextTheme(
        headlineSmall: TextStyle(color: text, fontWeight: FontWeight.w600, letterSpacing: -0.4),
        titleMedium: TextStyle(color: text, fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(color: text),
        bodySmall: TextStyle(color: textMuted),
        labelMedium: TextStyle(color: textMuted, letterSpacing: 0.6),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceRaised,
        side: const BorderSide(color: hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        labelStyle: const TextStyle(
          color: text,
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
        iconTheme: const IconThemeData(color: accent, size: 18),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        pressElevation: 0,
      ),
      iconTheme: const IconThemeData(color: text),
      listTileTheme: const ListTileThemeData(
        iconColor: accent,
        textColor: text,
      ),
      dividerTheme: const DividerThemeData(color: hairline, space: 1),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF1C2E32),
        contentTextStyle: TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Wraps a tappable thing so it dips under the finger.
///
/// A remote lives or dies on whether a press feels acknowledged, and on a
/// touchscreen there is no travel to feel. Scale plus the existing haptic tick
/// is what stands in for it.
class PressFeedback extends StatefulWidget {
  const PressFeedback({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.93,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  @override
  State<PressFeedback> createState() => _PressFeedbackState();
}

class _PressFeedbackState extends State<PressFeedback> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value && widget.onTap != null) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: RemoteTheme.press,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
