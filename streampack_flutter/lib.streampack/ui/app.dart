import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../main.dart' show repaintAfterFocus;
import '../l10n.dart';
import 'encoder_tab.dart';
import 'validator_tab.dart';

const kAppVersion   = '1.0.0';
const kAppCopyright = '© 2026 Hervé Jourdain — hjourdain@ryvrtech.com';

// ── About dialog ──────────────────────────────────────────────────────────────

void _showAbout(BuildContext context) {
  final accent = Theme.of(context).colorScheme.primary;
  final l10n   = context.l10n;
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF111418),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF2e3848)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                    color: Color(0xFFb8bfcf), fontSize: 12, fontFamily: 'monospace')),
            const SizedBox(height: 24),
            const Divider(color: Color(0xFF2e3848)),
            const SizedBox(height: 16),
            Text(
              l10n.aboutDescription,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 20),
            const Text(kAppCopyright,
                style: TextStyle(color: Color(0xFF9aa3b8), fontSize: 11)),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(foregroundColor: accent),
              child: Text(l10n.aboutClose),
            ),
          ],
        ),
      ),
    ),
  );
}

// ── Settings dialog ───────────────────────────────────────────────────────────

void _showSettings(BuildContext context) {
  final accent = Theme.of(context).colorScheme.primary;
  showDialog(
    context: context,
    builder: (ctx) => ValueListenableBuilder<AppLanguage>(
      valueListenable: languageNotifier,
      builder: (ctx, lang, _) {
        final l10n = AppLocalizations(lang);
        return Dialog(
          backgroundColor: const Color(0xFF111418),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF2e3848)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.settingsTitle,
                    style: const TextStyle(
                        color: Color(0xFFe8eaf0),
                        fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 24),
                const Divider(color: Color(0xFF2e3848)),
                const SizedBox(height: 20),

                // Language section
                Text(l10n.settingsLanguage.toUpperCase(),
                    style: const TextStyle(
                        color: Color(0xFF00d4aa),
                        fontSize: 9, fontWeight: FontWeight.w600,
                        letterSpacing: 1.5, fontFamily: 'monospace')),
                const SizedBox(height: 12),
                ...AppLanguage.values.map((language) => InkWell(
                  onTap: () => languageNotifier.value = language,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Row(children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 14, height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: lang == language
                                ? accent
                                : const Color(0xFF9aa3b8),
                            width: lang == language ? 4 : 1.5,
                          ),
                          color: const Color(0xFF111418),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(language.label,
                          style: TextStyle(
                              color: lang == language
                                  ? const Color(0xFFe8eaf0)
                                  : const Color(0xFFb8bfcf),
                              fontSize: 13,
                              fontWeight: lang == language
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                    ]),
                  ),
                )),

                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: TextButton.styleFrom(foregroundColor: accent),
                    child: Text(l10n.settingsClose),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// ── App root ──────────────────────────────────────────────────────────────────

class StreamPackApp extends StatelessWidget {
  const StreamPackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StreamPack',
      debugShowCheckedModeBanner: false,
      color: const Color(0xFF0a0c0f),
      theme: _buildTheme(),
      home: const _Shell(),
    );
  }

  ThemeData _buildTheme() {
    const bg       = Color(0xFF0a0c0f);
    const surface  = Color(0xFF111418);
    const surface2 = Color(0xFF20252f);
    const border   = Color(0xFF2e3848);
    const fg       = Color(0xFFe8eaf0);
    const fg2      = Color(0xFFb8bfcf);
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
        hintStyle: const TextStyle(color: Color(0xFF6b7589), fontFamily: 'monospace'),
        labelStyle: const TextStyle(color: fg2),
      ),
      sliderTheme: SliderThemeData(
        inactiveTrackColor: const Color(0xFF2e3848),
        thumbColor: accent,
        activeTrackColor: accent,
        overlayColor: accent.withOpacity(0.12),
        tickMarkShape: SliderTickMarkShape.noTickMark,
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

// ── Shell ─────────────────────────────────────────────────────────────────────

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
    languageNotifier.addListener(_onLanguageChanged);
  }

  void _onLanguageChanged() => setState(() {});

  @override
  void dispose() {
    languageNotifier.removeListener(_onLanguageChanged);
    windowManager.removeListener(this);
    _tabs.dispose();
    super.dispose();
  }

  // ── WindowListener ────────────────────────────────────────────────────────
  @override void onWindowFocus() => repaintAfterFocus();
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
    final l10n   = context.l10n;

    return Scaffold(
      backgroundColor: const Color(0xFF0a0c0f),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0a0c0f),
        elevation: 0,
        titleSpacing: 20,
        title: Row(
          children: [
            ClipPath(
              clipper: _PlayClipper(),
              child: Container(width: 28, height: 28, color: accent),
            ),
            const SizedBox(width: 12),
            RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                children: [
                  const TextSpan(text: 'Stream',
                      style: TextStyle(color: Color(0xFFe8eaf0))),
                  TextSpan(text: 'Pack', style: TextStyle(color: accent)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18, color: Color(0xFF9aa3b8)),
            tooltip: '',
            color: const Color(0xFF20252f),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xFF2e3848)),
            ),
            onSelected: (value) {
              if (value == 'settings') _showSettings(context);
              if (value == 'about')    _showAbout(context);
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'settings',
                child: Row(children: [
                  const Icon(Icons.settings_outlined,
                      size: 15, color: Color(0xFFb8bfcf)),
                  const SizedBox(width: 10),
                  Text(l10n.menuSettings,
                      style: const TextStyle(
                          color: Color(0xFFe8eaf0), fontSize: 13)),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'about',
                child: Row(children: [
                  const Icon(Icons.info_outline,
                      size: 15, color: Color(0xFFb8bfcf)),
                  const SizedBox(width: 10),
                  Text(l10n.menuAbout,
                      style: const TextStyle(
                          color: Color(0xFFe8eaf0), fontSize: 13)),
                ]),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: l10n.tabEncoder),
            Tab(text: l10n.tabValidator),
          ],
          labelStyle: const TextStyle(
              fontWeight: FontWeight.w700, letterSpacing: 1.5, fontSize: 11),
        ),
      ),
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
