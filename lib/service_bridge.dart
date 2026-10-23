/*
 * Abstracts the "keep the app alive in the background" mechanism.
 *
 *   Android  → native foreground service + wakelock (MethodChannel)
 *   Windows/Linux → system tray + window hide
 *
 * Every plugin call is wrapped in try/catch. If a plugin fails to
 * register (e.g. the generated registrant is stale), the app still
 * starts — you just lose that particular feature.
 */

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const MethodChannel _systemChannel = MethodChannel('campus_hustler/system');

class ServiceBridge {
  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static bool _trayReady = false;
  static bool _windowReady = false;

  // ------------------------------------------------------------------
  // Initialisation (desktop only).
  // ------------------------------------------------------------------
  static Future<void> initDesktop({
    required VoidCallback onShow,
    required VoidCallback onQuit,
  }) async {
    if (!_isDesktop || _trayReady) return;

    // --- window_manager --------------------------------------------------
    try {
      await windowManager.ensureInitialized();
      const opts = WindowOptions(
        size: Size(420, 680),
        minimumSize: Size(380, 600),
        center: true,
        title: 'Campus Hustler',
      );
      windowManager.waitUntilReadyToShow(opts, () async {
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}
      });

      await windowManager.setPreventClose(true);
      windowManager.addListener(_WindowListener(onQuit: onQuit));
      _windowReady = true;
    } catch (e) {
      debugPrint('service_bridge: window_manager init failed: $e');
    }

    // --- tray_manager ----------------------------------------------------
    try {
      await trayManager.setIcon('assets/tray_icon.png');
    } catch (e) {
      debugPrint('service_bridge: setIcon failed: $e');
    }

    try {
      final menu = Menu(items: [
        MenuItem(key: 'show', label: 'Show Campus Hustler'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ]);
      await trayManager.setContextMenu(menu);
      trayManager.addListener(_TrayListener(onShow: onShow, onQuit: onQuit));
    } catch (e) {
      debugPrint('service_bridge: tray menu setup failed: $e');
    }

    _trayReady = true;
  }

  // ------------------------------------------------------------------
  // Start / stop the "keep running" mechanism.
  // ------------------------------------------------------------------
  static Future<void> start() async {
    if (_isDesktop) {
      // Nothing extra to do — the tray keeps the window alive.
      return;
    }
    try {
      await _systemChannel.invokeMethod('requestNotificationPermission');
      await _systemChannel.invokeMethod('startForegroundService');
      await _systemChannel.invokeMethod('acquireWakeLock');
    } catch (e) {
      debugPrint('service_bridge: start failed: $e');
    }
  }

  static Future<void> stop() async {
    if (_isDesktop) return;
    try {
      await _systemChannel.invokeMethod('releaseWakeLock');
      await _systemChannel.invokeMethod('stopForegroundService');
    } catch (e) {
      debugPrint('service_bridge: stop failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // "Send to background" — Android: moveTaskToBack; desktop: hide window.
  // ------------------------------------------------------------------
  static Future<void> background() async {
    if (_isDesktop) {
      try {
        if (_windowReady) await windowManager.hide();
      } catch (e) {
        debugPrint('service_bridge: hide failed: $e');
      }
      return;
    }
    try {
      await _systemChannel.invokeMethod('moveTaskToBack');
    } catch (e) {
      debugPrint('service_bridge: moveTaskToBack failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // Bring the window back to front (desktop only, used by tray menu).
  // ------------------------------------------------------------------
  static Future<void> showWindow() async {
    if (!_isDesktop) return;
    try {
      if (_windowReady) {
        await windowManager.show();
        await windowManager.focus();
      }
    } catch (e) {
      debugPrint('service_bridge: showWindow failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // Fully quit the app (desktop only, used by tray menu).
  // ------------------------------------------------------------------
  static Future<void> quitApp() async {
    if (_isDesktop) {
      try {
        // Disable preventClose temporarily so destroy() actually works.
        if (_windowReady) await windowManager.setPreventClose(false);
        await windowManager.destroy();
      } catch (e) {
        debugPrint('service_bridge: quit failed: $e');
      }
      return;
    }
    // Android: just stop the service. OS will kill the process when the
    // task is swiped away.
    await stop();
  }

  // ------------------------------------------------------------------
  // Password persistence — Android only. Desktop handled by main.dart
  // via a plain file in the app support directory.
  // ------------------------------------------------------------------
  static Future<String> getStoredHash() async {
    if (_isDesktop) return '';
    try {
      final v = await _systemChannel.invokeMethod('getStoredHash');
      return (v as String?) ?? '';
    } catch (e) {
      debugPrint('service_bridge: getStoredHash failed: $e');
      return '';
    }
  }

  static Future<void> setStoredHash(String hash) async {
    if (_isDesktop) return;
    try {
      await _systemChannel
          .invokeMethod('setStoredHash', <String, String>{'hash': hash});
    } catch (e) {
      debugPrint('service_bridge: setStoredHash failed: $e');
    }
  }
}

// ==========================================================================
// Listeners
// ==========================================================================
class _WindowListener extends WindowListener {
  final VoidCallback onQuit;
  _WindowListener({required this.onQuit});

  @override
  void onWindowClose() async {
    // Hide instead of quitting; the tray keeps us alive.
    try {
      await windowManager.hide();
    } catch (_) {}
  }
}

class _TrayListener extends TrayListener {
  final VoidCallback onShow;
  final VoidCallback onQuit;
  _TrayListener({required this.onShow, required this.onQuit});

  @override
  void onTrayIconMouseDown() {
    onShow();
  }

  @override
  void onTrayIconRightMouseDown() {
    try {
      trayManager.popUpContextMenu();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'show') onShow();
    if (item.key == 'quit') onQuit();
  }
}