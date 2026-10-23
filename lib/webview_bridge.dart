/*
 * Cross-platform WebView abstraction.
 *
 * - Android / iOS: package:webview_flutter (embedded widget)
 * - Windows / Linux: headless Chrome via the Chrome DevTools Protocol.
 *
 * On desktop we spawn the system Chrome/Chromium with --headless and
 * --remote-debugging-port, then drive it over WebSocket using CDP.
 * No extra packages required beyond dart:io.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Android only: use Hybrid Composition instead of the default texture mode.
const bool kUseHybridComposition = true;

class WebViewCallbacks {
  final void Function(String url) onPageStarted;
  final void Function(String url) onPageFinished;
  final void Function(String description, int errorCode) onWebResourceError;
  final void Function(String url) onUrlChange;
  final void Function(String url, bool isMainFrame)? onNavigationRequest;
  final void Function(String level, String message)? onConsoleMessage;

  WebViewCallbacks({
    required this.onPageStarted,
    required this.onPageFinished,
    required this.onWebResourceError,
    required this.onUrlChange,
    this.onNavigationRequest,
    this.onConsoleMessage,
  });
}

class AppWebView {
  final WebViewCallbacks cb;
  final bool _isMobile = Platform.isAndroid || Platform.isIOS;
  final String _userAgent;

  mobile.WebViewController? _mobileCtrl;
  Widget? _mobileWidget;

  HeadlessChromeBrowser? _desktopBrowser;
  final Completer<void> _desktopReady = Completer<void>();

  AppWebView._(this.cb, this._userAgent);

  factory AppWebView({
    required WebViewCallbacks callbacks,
    required String userAgent,
  }) {
    final v = AppWebView._(callbacks, userAgent);
    if (v._isMobile) {
      v._mobileCtrl = mobile.WebViewController()
        ..setJavaScriptMode(mobile.JavaScriptMode.unrestricted)
        ..setUserAgent(userAgent)
        ..setNavigationDelegate(mobile.NavigationDelegate(
          onNavigationRequest: (req) {
            callbacks.onNavigationRequest?.call(req.url, req.isMainFrame);
            return mobile.NavigationDecision.navigate;
          },
          onPageStarted: callbacks.onPageStarted,
          onPageFinished: callbacks.onPageFinished,
          onWebResourceError: (err) {
            if (err.isForMainFrame == true) {
              callbacks.onWebResourceError(err.description, err.errorCode);
            }
          },
          onUrlChange: (c) {
            if (c.url != null) callbacks.onUrlChange(c.url!);
          },
        ));
      try {
        v._mobileCtrl!.setOnConsoleMessage((msg) {
          callbacks.onConsoleMessage?.call(msg.level.name, msg.message);
        });
      } catch (_) {}
      if (v._mobileCtrl!.platform is AndroidWebViewController) {
        try {
          AndroidWebViewController.enableDebugging(true);
        } catch (_) {}
      }
    } else {
      v._initDesktop();
    }
    return v;
  }

  Future<void> _initDesktop() async {
    try {
      _desktopBrowser = HeadlessChromeBrowser(
        onPageStarted: (url) => cb.onPageStarted(url),
        onPageFinished: (url) => cb.onPageFinished(url),
        onUrlChange: (url) {
          cb.onUrlChange(url);
          cb.onNavigationRequest?.call(url, true);
        },
        onConsoleMessage: (level, msg) => cb.onConsoleMessage?.call(level, msg),
        onError: (desc) => cb.onWebResourceError(desc, -1),
      );
      await _desktopBrowser!.launch();
    } catch (e) {
      cb.onWebResourceError('Headless Chrome launch failed: $e', 0);
      try { await _desktopBrowser?.dispose(); } catch (_) {}
      _desktopBrowser = null;
    } finally {
      if (!_desktopReady.isCompleted) _desktopReady.complete();
    }
  }

  Widget build() {
    if (_isMobile) {
      return _mobileWidget ??= _createMobileWidget();
    }
    // Desktop: fully headless. Nothing in the widget tree.
    return const SizedBox.shrink();
  }

  Widget _createMobileWidget() {
    final ctrl = _mobileCtrl!;
    if (Platform.isAndroid && kUseHybridComposition) {
      return mobile.WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: ctrl.platform,
          displayWithHybridComposition: true,
        ),
      );
    }
    return mobile.WebViewWidget(controller: ctrl);
  }

  Future<void> loadUrl(String url) async {
    if (_isMobile) {
      await _mobileCtrl!.loadRequest(Uri.parse(url));
      return;
    }
    await _desktopReady.future;
    final browser = _desktopBrowser;
    if (browser == null || !browser.isRunning) {
      cb.onWebResourceError('headless browser not running', 0);
      return;
    }
    try {
      await browser.navigate(url);
    } catch (e) {
      cb.onWebResourceError('navigate failed: $e', 0);
    }
  }

  Future<String> evaluateJavaScript(String script) async {
    if (_isMobile) {
      final raw = await _mobileCtrl!.runJavaScriptReturningResult(script);
      return raw.toString();
    }
    await _desktopReady.future;
    final browser = _desktopBrowser;
    if (browser == null) return '';
    try {
      return await browser.evaluate(script);
    } catch (_) {
      return '';
    }
  }

  Future<String> currentUrl() async {
    if (_isMobile) {
      return (await _mobileCtrl!.currentUrl()) ?? '';
    }
    await _desktopReady.future;
    return _desktopBrowser?.lastUrl ?? '';
  }

  Future<void> clearCache() async {
    try {
      if (_isMobile) {
        await _mobileCtrl!.clearCache();
      } else {
        await _desktopBrowser?.clearBrowserData();
      }
    } catch (_) {}
  }

  Future<void> clearCookies() async {
    try {
      if (_isMobile) {
        await mobile.WebViewCookieManager().clearCookies();
      } else {
        await _desktopBrowser?.clearBrowserData();
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    try { await _desktopBrowser?.dispose(); } catch (_) {}
    _desktopBrowser = null;
  }
}

// ==========================================================================
// Headless Chrome driven by the Chrome DevTools Protocol.
// ==========================================================================
class HeadlessChromeBrowser {
  final void Function(String url) onPageStarted;
  final void Function(String url) onPageFinished;
  final void Function(String url) onUrlChange;
  final void Function(String level, String msg)? onConsoleMessage;
  final void Function(String desc) onError;

  Process? _process;
  WebSocket? _ws;
  String? _userDataDir;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  String _lastUrl = '';
  String? _mainFrameId;

  HeadlessChromeBrowser({
    required this.onPageStarted,
    required this.onPageFinished,
    required this.onUrlChange,
    required this.onError,
    this.onConsoleMessage,
  });

  bool get isRunning => _process != null && _ws != null;
  String get lastUrl => _lastUrl;

  Future<void> launch() async {
    final chromePath = await _findChrome();
    if (chromePath == null) {
      throw Exception(
          'Chrome/Chromium not found. Install Google Chrome or Chromium, '
          'or set CHROME_PATH environment variable.');
    }

    final tempDir = Directory.systemTemp.createTempSync('campus_hustler_');
    _userDataDir = tempDir.path;

    final args = <String>[
      '--headless',
      '--remote-debugging-port=0',
      '--user-data-dir=${tempDir.path}',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--disable-background-networking',
      '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding',
      '--disable-extensions',
      '--disable-sync',
      '--hide-scrollbars',
      '--mute-audio',
      // Sopra portal submits HTTP forms from an HTTPS page.
      '--allow-running-insecure-content',
      // Tolerate the portal's certificate.
      '--ignore-certificate-errors',
      'about:blank',
    ];

    _process = await Process.start(chromePath, args);
    // Drain pipes so the OS doesn't back up.
    _process!.stdout.drain<void>();
    _process!.stderr.drain<void>();

    // Wait for DevToolsActivePort file (contains the actual port).
    final portFile = File('${tempDir.path}/DevToolsActivePort');
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!portFile.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (_process == null) throw Exception('Chrome process died');
    }
    if (!portFile.existsSync()) {
      throw Exception('Chrome did not write DevToolsActivePort');
    }

    final lines = portFile.readAsLinesSync();
    if (lines.isEmpty) throw Exception('DevToolsActivePort is empty');
    final portStr = lines[0].replaceAll('\uFEFF', '').trim();
    final port = int.parse(portStr);

    // Find a page target.
    Map<String, dynamic>? pageTarget;
    final targetDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (pageTarget == null && DateTime.now().isBefore(targetDeadline)) {
      try {
        final list = await _httpGetJson('http://127.0.0.1:$port/json');
        if (list is List) {
          for (final item in list) {
            if (item is Map && item['type'] == 'page') {
              pageTarget = item.cast<String, dynamic>();
              break;
            }
          }
        }
      } catch (_) {}
      if (pageTarget == null) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    if (pageTarget == null) {
      throw Exception('No page target found in headless Chrome');
    }

    final wsUrl = pageTarget['webSocketDebuggerUrl'] as String?;
    if (wsUrl == null || wsUrl.isEmpty) {
      throw Exception('Page target has no webSocketDebuggerUrl');
    }

    _ws = await WebSocket.connect(wsUrl);
    _ws!.listen(
      _onMessage,
      onDone: _onWsClosed,
      onError: (e) => onError('WebSocket error: $e'),
      cancelOnError: false,
    );

    await _send('Page.enable', {});
    await _send('Runtime.enable', {});
    await _send('Network.enable', {});
  }

  Future<String?> _findChrome() async {
    // Explicit override via environment variable.
    final envPath = Platform.environment['CHROME_PATH'];
    if (envPath != null && envPath.isNotEmpty) {
      try {
        if (File(envPath).existsSync()) return envPath;
      } catch (_) {}
    }

    if (Platform.isWindows) {
      final paths = <String>[
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      ];
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        paths.insert(0,
            '$localAppData\\Google\\Chrome\\Application\\chrome.exe');
        paths.insert(1,
            '$localAppData\\Microsoft\\Edge\\Application\\msedge.exe');
      }
      for (final p in paths) {
        try { if (File(p).existsSync()) return p; } catch (_) {}
      }
      return null;
    }

    for (final name in [
      'google-chrome',
      'google-chrome-stable',
      'chromium',
      'chromium-browser',
      'chrome',
      'microsoft-edge',
    ]) {
      try {
        final r = await Process.run('which', [name]);
        if (r.exitCode == 0) {
          final path = (r.stdout as String).trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    }
    for (final p in [
      '/snap/bin/chromium',
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
      '/usr/bin/google-chrome',
      '/usr/bin/google-chrome-stable',
      '/opt/google/chrome/chrome',
    ]) {
      try { if (File(p).existsSync()) return p; } catch (_) {}
    }
    return null;
  }

  Future<dynamic> _httpGetJson(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _send(
      String method, Map<String, dynamic> params) async {
    final ws = _ws;
    if (ws == null) throw StateError('WebSocket not connected');
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    try {
      return await c.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _pending.remove(id);
      rethrow;
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // Response to a command.
    if (msg.containsKey('id')) {
      final id = msg['id'];
      if (id is int) {
        final c = _pending.remove(id);
        if (c != null && !c.isCompleted) {
          if (msg.containsKey('error')) {
            c.completeError(Exception('CDP: ${msg['error']}'));
          } else {
            c.complete(msg);
          }
        }
      }
      return;
    }

    // Event.
    final method = msg['method'] as String?;
    if (method == null) return;
    final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? {};

    switch (method) {
      case 'Page.frameNavigated':
        final frame = (params['frame'] as Map?)?.cast<String, dynamic>();
        if (frame != null && frame['parentId'] == null) {
          _mainFrameId = frame['id'] as String?;
          final url = (frame['url'] as String?) ?? '';
          if (url.isNotEmpty && url != 'about:blank' && url != _lastUrl) {
            _lastUrl = url;
            onUrlChange(url);
            onPageStarted(url);
          }
        }
        break;
      case 'Page.loadEventFired':
        if (_lastUrl.isNotEmpty) onPageFinished(_lastUrl);
        break;
      case 'Page.frameStoppedLoading':
        final fid = params['frameId'] as String?;
        if (fid != null && fid == _mainFrameId && _lastUrl.isNotEmpty) {
          onPageFinished(_lastUrl);
        }
        break;
      case 'Runtime.consoleAPICalled':
        final type = (params['type'] as String?) ?? 'log';
        final args = (params['args'] as List?) ?? const [];
        final parts = <String>[];
        for (final a in args) {
          if (a is Map) {
            final v = a['value'] ?? a['description'];
            if (v != null) parts.add(v.toString());
          }
        }
        if (parts.isNotEmpty) onConsoleMessage?.call(type, parts.join(' '));
        break;
      case 'Network.loadingFailed':
        if (params['type'] == 'Document') {
          onError('Navigation failed: ${params['errorText']}');
        }
        break;
    }
  }

  void _onWsClosed() {
    final err = Exception('CDP WebSocket closed');
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
  }

  Future<void> navigate(String url) async {
    _lastUrl = '';
    await _send('Page.navigate', {'url': url});
  }

  Future<String> evaluate(String script) async {
    final r = await _send('Runtime.evaluate', {
      'expression': script,
      'returnByValue': true,
      'awaitPromise': false,
    });
    final result = (r['result'] as Map?)?.cast<String, dynamic>();
    if (result == null || result['exceptionDetails'] != null) return '';
    final inner = (result['result'] as Map?)?.cast<String, dynamic>();
    if (inner == null) return '';
    final value = inner['value'];
    if (value == null) return '';
    if (value is String) return value;
    return jsonEncode(value);
  }

  Future<void> clearBrowserData() async {
    try {
      await _send('Network.clearBrowserCookies', {});
      await _send('Network.clearBrowserCache', {});
    } catch (_) {}
  }

  Future<void> dispose() async {
    // Synchronous kill — do not await WS close; the app may be exiting.
    try { _ws?.close(); } catch (_) {}
    _ws = null;
    try { _process?.kill(); } catch (_) {}
    _process = null;
    final dir = _userDataDir;
    _userDataDir = null;
    if (dir != null) {
      try {
        final d = Directory(dir);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}