import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'job_runner.dart';
import 'ui/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Single source of truth for the version: read it from the build (pubspec).
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) kAppVersion = info.version;
  } catch (_) {}

  await windowManager.ensureInitialized();

  // waitUntilReadyToShow hides the window until the Flutter engine signals
  // it is ready to present a frame, then calls the callback to show it.
  // This is the officially supported way to prevent the startup flash.
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 880),
      minimumSize: Size(1120, 720),
      center: true,
      title: 'StreamPack',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(
    ChangeNotifierProvider(
      create: (_) => JobRunner(),
      child: const StreamPackApp(),
    ),
  );
}

/// Called when the window regains focus after a dialog/picker closes.
/// Nudges window size to flush any GTK compositor artifacts.
Future<void> repaintAfterFocus() async {
  await Future.delayed(const Duration(milliseconds: 50));
  final size = await windowManager.getSize();
  await windowManager.setSize(Size(size.width + 1, size.height));
  await Future.delayed(const Duration(milliseconds: 30));
  await windowManager.setSize(size);
}
