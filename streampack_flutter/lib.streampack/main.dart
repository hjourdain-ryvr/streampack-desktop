import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'job_runner.dart';
import 'ui/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // waitUntilReadyToShow hides the window until the Flutter engine signals
  // it is ready to present a frame, then calls the callback to show it.
  // This is the officially supported way to prevent the startup flash.
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 1060),
      minimumSize: Size(900, 980),
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
