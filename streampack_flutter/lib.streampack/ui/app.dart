import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../main.dart' show repaintAfterFocus;
import 'encoder_tab.dart';
import 'validator_tab.dart';

const kAppVersion = '1.0.0';
const kAppCopyright = '© 2026 Hervé Jourdain — hjourdain@ryvrtech.com';

void _showAbout(BuildContext context) {
  final accent = Theme.of(context).colorScheme.primary;
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF111418),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF252a33)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Logo
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipPath(
                  clipper: _PlayClipper(),
                  child: Container(width: 32, height: 32, color: accent),
                ),
                const SizedBox(width: 14),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                    children: [
                      const TextSpan(text: 'Stream',
                          style: TextStyle(color: Color(0xFFe8eaf0))),
                      TextSpan(text: 'Pack', style: TextStyle(color: accent)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Version $kAppVersion',
                style: const TextStyle(
                    color: Color(0xFF8a92a8), fontSize: 12, fontFamily: 'monospace')),
            const SizedBox(height: 24),
            const Divider(color: Color(0xFF252a33)),
            const SizedBox(height: 16),
            const Text(
              'HLS & DASH adaptive streaming encoder\n'
              'for Linux and Windows.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF8a92a8), fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 20),
            Text(kAppCopyright,
                style: const TextStyle(
                    color: Color(0xFF4a5168), fontSize: 11)),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(foregroundColor: accent),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    ),
  );
}

class StreamPackApp extends StatelessWidget {
  const StreamPackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StreamPack',
      debugShowCheckedModeBanner: false,
      // Match scaffold background — prevents GTK surface bleed-through
      color: const Color(0xFF0a0c0f),
      theme: _buildTheme(),
      home: const _Shell(),
    );
  }

  ThemeData _buildTheme() {
    const bg       = Color(0xFF0a0c0f);
    const surface  = Color(0xFF111418);
    const surface2 = Color(0xFF181c22);
    const border   = Color(0xFF252a33);
    const fg       = Color(0xFFe8eaf0);
    const fg2      = Color(0xFF8a92a8);
    const accent   = Color(0xFF00d4aa);
    const red      = Color(0xFFff4f6a);
    const yellow   = Color(0xFFf5c542);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.dark(
        surface: surface,
        primary: accent,
        error: red,
        onSurface: fg,
        onPrimary: bg,
        secondary: yellow,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: const TextStyle(color: Color(0xFF4a5168), fontFamily: 'monospace'),
        labelStyle: const TextStyle(color: fg2),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: bg,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: fg, fontSize: 13),
        bodySmall:  TextStyle(color: fg2, fontSize: 11),
        labelSmall: TextStyle(color: fg2, fontSize: 10, letterSpacing: 0.8),
      ),
      dividerColor: border,
      tabBarTheme: const TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: fg2,
        indicatorColor: accent,
      ),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell>
    with SingleTickerProviderStateMixin
    implements WindowListener {

  late final TabController _tabs;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      initialIndex: 0,
      vsync: this,
      animationDuration: const Duration(),
    );
    _tabs.addListener(() {
      if (_tabs.index != _tabIndex) {
        setState(() => _tabIndex = _tabs.index);
      }
    });
    windowManager.addListener(this);
    // Window reveal is handled by waitUntilReadyToShow in main.dart
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _tabs.dispose();
    super.dispose();
  }

  // ── WindowListener ────────────────────────────────────────────────────────
  @override
  void onWindowFocus() => repaintAfterFocus();

  @override void onWindowBlur() {}
  @override void onWindowMaximize() {}
  @override void onWindowUnmaximize() {}
  @override void onWindowMinimize() {}
  @override void onWindowRestore() {}
  @override void onWindowResize() {}
  @override void onWindowResized() {}
  @override void onWindowMove() {}
  @override void onWindowMoved() {}
  @override void onWindowClose() {}
  @override void onWindowEnterFullScreen() {}
  @override void onWindowLeaveFullScreen() {}
  @override void onWindowDocked() {}
  @override void onWindowUndocked() {}
  @override void onWindowEvent(String eventName) {}

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Scaffold(
      // Explicit background on Scaffold prevents transparent frames
      backgroundColor: const Color(0xFF0a0c0f),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0a0c0f),
        elevation: 0,
        titleSpacing: 20,
        title: Row(
          children: [
            ClipPath(
              clipper: _PlayClipper(),
              child: Container(
                width: 28, height: 28,
                color: accent,
              ),
            ),
            const SizedBox(width: 12),
            RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                children: [
                  const TextSpan(text: 'Stream',
                      style: TextStyle(color: Color(0xFFe8eaf0))),
                  TextSpan(text: 'Pack',
                      style: TextStyle(color: accent)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, size: 18),
            color: const Color(0xFF4a5168),
            tooltip: 'About',
            onPressed: () => _showAbout(context),
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'ENCODER'),
            Tab(text: 'VALIDATOR'),
          ],
          labelStyle: const TextStyle(
              fontWeight: FontWeight.w700, letterSpacing: 1.5, fontSize: 11),
        ),
      ),
      // ColoredBox ensures the background is always opaque before tab content
      // paints — prevents accent color or transparency showing through on startup.
      body: ColoredBox(
        color: const Color(0xFF0a0c0f),
        child: IndexedStack(
          index: _tabIndex,
          children: const [
            EncoderTab(),
            ValidatorTab(),
          ],
        ),
      ),
    );
  }
}

class _PlayClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..moveTo(0, s.height * 0.2)
    ..lineTo(s.width, 0)
    ..lineTo(s.width, s.height * 0.8)
    ..lineTo(0, s.height)
    ..close();

  @override
  bool shouldReclip(_) => false;
}
