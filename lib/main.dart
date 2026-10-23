/*
 * Campus Hustler — cross-platform (Android + Windows + Linux).
 *
 * - Password gate: one-time entry, stored as a salted SHA-256 hash.
 * - Headless WebView on every platform:
 *     Android → webview_flutter, hidden behind an opaque cover.
 *     Windows/Linux → headless Chrome spawned via Process.run and
 *     driven over the Chrome DevTools Protocol by webview_bridge.dart.
 * - Android foreground service + wakelock; desktop tray + window hide.
 *
 * Per cycle:
 *   1. clear cookies (fresh portal session)
 *   2. fresh random MAC
 *   3. load portal → click / auto-login
 *   4. 5 s stabilize
 *   5. verify online with HTTP probe
 *   6. REST 3 minutes (no checks, only heartbeats)
 *   7. POLL connectivity every 2 s until it drops
 *   8. on confirmed disconnect → next cycle (fresh MAC, reconnect)
 *   9. if connection stays up → keep polling, never rotate MAC
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'service_bridge.dart';
import 'webview_bridge.dart';

// ==========================================================================
// Configuration
// ==========================================================================
const String _urlPrefix =
    'https://kwatampora.portal.sopraent.com/hotspot?router=1895&mac=';
const String _urlSuffix =
    '&ip=10.10.4.114&username=&'
    'link-login-only=http%3A%2F%2Fhotspot.local%2Flogin&'
    'link-orig=http%3A%2F%2Fdetectportal.firefox.com%2Fcanonical.html&error=';

const String _macFixedPrefix = 'CC:D9:3A';

const int _checkIntervalMs = 2000;
const int _perRequestTimeoutMs = 3000;
const int _postClickWaitMs = 5000;
const int _cookieRefreshEvery = 2;
const int _waitForButtonMs = 12000;
const int _navTimeoutMs = 15000;

// Post-connect no-check rest, then poll for disconnect.
const int _postConnectRestMs = 3 * 60 * 1000;     // 3 minutes
const int _disconnectPollIntervalMs = 2000;       // 2 s per poll after rest
const int _disconnectConfirmDelayMs = 2000;       // 2 s recheck on offline

const String _desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

const String _requiredPassword = 'Vepo2tictok2techno5067';
const String _passwordSalt = 'campus_hustler::v1::2f8a3d9c-4e7b-11ef';

const List<String> _portalHosts = [
  'kwatampora.portal.sopraent.com',
  'hotspot.local',
  '10.10.0.1',
  'detectportal.firefox.com',
];

// ==========================================================================
// Palette
// ==========================================================================
const Color _bgColor       = Color.fromARGB(255, 14, 17, 23);
const Color _subtitleColor = Color.fromARGB(255, 158, 173, 194);
const Color _orbStopped    = Color.fromARGB(255, 82, 87, 102);
const Color _orbWorking    = Color.fromARGB(255, 255, 181, 56);
const Color _orbOnline     = Color.fromARGB(255, 56, 209, 107);
const Color _btnStart      = Color.fromARGB(255, 46, 166, 92);
const Color _btnStop       = Color.fromARGB(255, 189, 69, 69);
const Color _inputFill     = Color.fromARGB(255, 8, 10, 14);
const Color _inputBorder   = Color.fromARGB(255, 32, 38, 48);
const Color _errorColor    = Color.fromARGB(255, 224, 108, 108);

// ==========================================================================
// Password hashing
// ==========================================================================
String _hashPassword(String password) {
  final input = utf8.encode('$password::$_passwordSalt');
  return sha256.convert(input).toString();
}

final String _expectedHash = _hashPassword(_requiredPassword);

// ==========================================================================
// MAC generation
// ==========================================================================
String _generateRandomMac() {
  const hex = '0123456789ABCDEF';
  final rnd = math.Random();
  String byte() => '${hex[rnd.nextInt(16)]}${hex[rnd.nextInt(16)]}';
  return '$_macFixedPrefix:${byte()}:${byte()}:${byte()}';
}

String _buildHotspotUrl(String mac) {
  final encoded = mac.replaceAll(':', '%3A');
  return '$_urlPrefix$encoded$_urlSuffix';
}

// ==========================================================================
// Logger
// ==========================================================================
class AppLog {
  AppLog._();
  static void log(String msg) {
    final n = DateTime.now();
    String p(int x) => x.toString().padLeft(2, '0');
    final line = '${p(n.hour)}:${p(n.minute)}:${p(n.second)}.'
        '${n.millisecond.toString().padLeft(3, '0')}  $msg';
    if (kDebugMode) debugPrint('[CampusHustler] $line');
  }
}

// ==========================================================================
// Password persistence
// ==========================================================================
class PasswordStore {
  static const String _desktopFileName = 'campus_hustler_unlock.txt';

  static Future<String> getStoredHash() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return ServiceBridge.getStoredHash();
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_desktopFileName');
      if (!f.existsSync()) return '';
      return (await f.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  static Future<void> setStoredHash(String hash) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await ServiceBridge.setStoredHash(hash);
      return;
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_desktopFileName');
      await f.writeAsString(hash, flush: true);
    } catch (_) {}
  }

  static Future<bool> isUnlocked() async {
    final stored = await getStoredHash();
    if (stored.isEmpty) return false;
    return stored == _expectedHash;
  }
}

// ==========================================================================
// JS — click "GET a FREE TRIAL"
// ==========================================================================
const String _clickScript = r"""
(function() {
  var TARGETS = [
    'get a free trial', 'get free trial', 'free trial', 'start free trial',
    'free wifi', 'free wi-fi', 'start browsing', 'browse internet',
    'browse now', 'connect to internet', 'connect now', 'get connected',
    'get online', 'start connection'
  ];
  function norm(s) {
    return String(s == null ? '' : s)
      .replace(/\s+/g, ' ').replace(/[^\w\s]/g, '').trim().toLowerCase();
  }
  function matchesAny(str) {
    for (var k = 0; k < TARGETS.length; k++) {
      if (str.indexOf(TARGETS[k]) !== -1) return TARGETS[k];
    }
    return null;
  }
  function isVisible(el) {
    if (!el) return false;
    if (!el.getClientRects || el.getClientRects().length === 0) return false;
    var s = window.getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') return false;
    if (parseFloat(s.opacity) === 0) return false;
    return true;
  }
  function isClickable(el) {
    if (!el) return false;
    var t = (el.tagName || '').toUpperCase();
    if (t === 'A' || t === 'BUTTON' || t === 'INPUT') return true;
    if (el.onclick) return true;
    try {
      if (el.getAttribute('role') === 'button') return true;
      if (el.getAttribute('href')) return true;
    } catch (e) {}
    return false;
  }
  function describe(el) {
    var tag = (el.tagName || '?').toLowerCase();
    var txt = (el.innerText || el.textContent || el.value || '')
      .replace(/\s+/g, ' ').trim().slice(0, 80);
    return tag + (el.id ? '#' + el.id : '') + ': ' + txt;
  }
  function dispatchClick(el) {
    try { el.scrollIntoView({ block: 'center', behavior: 'instant' }); } catch (e) {}
    var o = { bubbles: true, cancelable: true, view: window };
    try {
      el.dispatchEvent(new PointerEvent('pointerdown', o));
      el.dispatchEvent(new MouseEvent('mousedown', o));
      el.dispatchEvent(new PointerEvent('pointerup', o));
      el.dispatchEvent(new MouseEvent('mouseup', o));
      el.dispatchEvent(new MouseEvent('click', o));
    } catch (e) {
      try { el.click(); } catch (e2) {}
    }
  }
  function collect(root, out, depth) {
    if (!root || depth > 8) return out;
    var list;
    try { list = root.querySelectorAll('*'); } catch (e) { return out; }
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      out.push(el);
      if (el.shadowRoot) collect(el.shadowRoot, out, depth + 1);
    }
    return out;
  }
  function findTarget(root) {
    var els = collect(root, [], 0);
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var tag = (el.tagName || '').toUpperCase();
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' ||
          tag === 'HEAD' || tag === 'META' || tag === 'LINK' || tag === 'TITLE') continue;
      var direct = '';
      for (var j = 0; j < el.childNodes.length; j++) {
        var n = el.childNodes[j];
        if (n.nodeType === 3) direct += n.nodeValue;
      }
      if (!matchesAny(norm(direct))) continue;
      if (!isVisible(el)) continue;
      var cur = el;
      for (var up = 0; up < 10 && cur; up++) {
        if (isClickable(cur)) return cur;
        cur = cur.parentElement;
      }
      return el;
    }
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var tag = (el.tagName || '').toUpperCase();
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' ||
          tag === 'HEAD' || tag === 'META' || tag === 'LINK' || tag === 'TITLE' ||
          tag === 'BODY' || tag === 'HTML') continue;
      var full = norm(el.textContent || '');
      if (!matchesAny(full)) continue;
      if (!isVisible(el)) continue;
      var cur = el;
      for (var up = 0; up < 10 && cur; up++) {
        if (isClickable(cur)) return cur;
        cur = cur.parentElement;
      }
      if (el.children.length < 3) return el;
    }
    return null;
  }
  function extractFormInfo(el) {
    var cur = el;
    for (var up = 0; up < 10 && cur; up++) {
      if (cur.tagName && cur.tagName.toUpperCase() === 'FORM') {
        var action = cur.action || '';
        var method = (cur.method || 'GET').toUpperCase();
        var inputs = cur.querySelectorAll('input, select, textarea');
        var data = '';
        for (var i = 0; i < inputs.length; i++) {
          var inp = inputs[i];
          if (!inp.name) continue;
          var val = inp.type === 'checkbox' || inp.type === 'radio'
            ? (inp.checked ? inp.value : '')
            : (inp.value || '');
          data += encodeURIComponent(inp.name) + '=' + encodeURIComponent(val) + '&';
        }
        return { form: cur, action: action, method: method, data: data };
      }
      cur = cur.parentElement;
    }
    return null;
  }

  var target = findTarget(document);
  if (!target) {
    var frames = document.querySelectorAll('iframe, frame');
    for (var k = 0; k < frames.length; k++) {
      try {
        var doc = frames[k].contentDocument;
        if (doc) {
          var r = findTarget(doc);
          if (r) { target = r; break; }
        }
      } catch (e) {}
    }
  }
  if (!target) return 'notfound';

  var desc = describe(target);
  var formInfo = extractFormInfo(target);
  var href = (target.getAttribute && target.getAttribute('href')) || '';

  var isSubmitButton = false;
  try {
    var tagU = (target.tagName || '').toUpperCase();
    if (tagU === 'INPUT') {
      var type = (target.getAttribute('type') || '').toLowerCase();
      if (type === 'submit' || type === 'image') isSubmitButton = true;
    } else if (tagU === 'BUTTON') {
      var btype = (target.getAttribute('type') || 'submit').toLowerCase();
      if (btype === 'submit') isSubmitButton = true;
    }
  } catch (e) {}

  dispatchClick(target);
  if (formInfo && formInfo.form && !isSubmitButton) {
    try { formInfo.form.submit(); } catch (e) {}
  }

  var result = 'found|' + desc + '|' + href;
  if (formInfo) {
    result += '|' + formInfo.action + '|' + formInfo.method + '|' + formInfo.data;
  } else {
    result += '|||';
  }
  return result;
})();
""";

// ==========================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await ServiceBridge.initDesktop(
    onShow: () => ServiceBridge.showWindow(),
    onQuit: () => ServiceBridge.quitApp(),
  );

  runApp(const CampusHustlerApp());
}

class CampusHustlerApp extends StatelessWidget {
  const CampusHustlerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Campus Hustler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bgColor,
      ),
      home: const GatePage(),
    );
  }
}

// ==========================================================================
// Gate
// ==========================================================================
class GatePage extends StatefulWidget {
  const GatePage({super.key});
  @override
  State<GatePage> createState() => _GatePageState();
}

class _GatePageState extends State<GatePage> {
  bool? _unlocked;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (_unlocked != null) return;
    final ok = await PasswordStore.isUnlocked();
    AppLog.log('gate: unlocked=$ok');
    if (!mounted) return;
    setState(() => _unlocked = ok);
  }

  void _onUnlock() {
    if (_unlocked == true) return;
    setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked == null) {
      return const Scaffold(
        backgroundColor: _bgColor,
        body: Center(
          child: SizedBox(
            width: 40, height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation(_subtitleColor),
            ),
          ),
        ),
      );
    }
    return _unlocked == true ? const HomePage() : const PasswordPage();
  }
}

// ==========================================================================
// Password page
// ==========================================================================
class PasswordPage extends StatefulWidget {
  const PasswordPage({super.key});
  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final input = _controller.text;
    final inputHash = _hashPassword(input);
    if (inputHash == _expectedHash) {
      AppLog.log('gate: correct password, storing hash');
      await PasswordStore.setStoredHash(_expectedHash);
      final readback = await PasswordStore.getStoredHash();
      AppLog.log('gate: persistence check '
          'stored=${readback.length == 64 ? "OK" : "FAIL(${readback.length})"}');
      if (!mounted) return;
      context.findAncestorStateOfType<_GatePageState>()?._onUnlock();
      return;
    }
    setState(() => _error = 'Incorrect password');
    AppLog.log('gate: wrong password attempt');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 80),
              const Text(
                'Campus Hustler',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Enter your password to unlock this app. '
                'You only need to do this once.',
                style: TextStyle(fontSize: 14, color: _subtitleColor, height: 1.4),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                cursorColor: _orbWorking,
                decoration: InputDecoration(
                  hintText: 'Password',
                  hintStyle: const TextStyle(color: _subtitleColor),
                  filled: true,
                  fillColor: _inputFill,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _inputBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _orbWorking, width: 2),
                  ),
                  errorText: _error,
                  errorStyle: const TextStyle(color: _errorColor),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      color: _subtitleColor,
                    ),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: _submit,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: _btnStart,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'UNLOCK',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// Home page
// ==========================================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  AppWebView? _webView;
  late final Watchdog _watchdog;
  late final Ticker _ticker;
  StreamSubscription<String>? _statusSub;

  String _status = 'stopped';
  bool _signingOff = false;

  double _phase = 0.0;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    AppLog.log('── Campus Hustler starting (headless) ──');

    try {
      _webView = AppWebView(
        userAgent: _desktopUserAgent,
        callbacks: WebViewCallbacks(
          onPageStarted: (url) => AppLog.log('page started: $url'),
          onPageFinished: (url) {
            AppLog.log('page finished: $url');
            _watchdog.notifyPageFinished(url);
          },
          onWebResourceError: (desc, code) {
            AppLog.log('MAIN FRAME ERROR: $desc (code $code)');
            _watchdog.notifyPageFailed();
          },
          onUrlChange: (url) {
            AppLog.log('url changed → $url');
            _watchdog.notifyUrlChanged(url);
          },
          onNavigationRequest: (url, isMainFrame) {
            AppLog.log('nav request: $url main=$isMainFrame');
          },
          onConsoleMessage: (level, msg) {
            if (level == 'error') AppLog.log('JS[error] $msg');
          },
        ),
      );
    } catch (e) {
      AppLog.log('webview construction failed: $e');
      _webView = null;
    }

    _watchdog = Watchdog(_webView);
    _statusSub = _watchdog.statusStream.listen(_onStatus);

    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _statusSub?.cancel();
    _watchdog.stop();
    _webView?.dispose();
    super.dispose();
  }

  void _onStatus(String status) {
    if (!mounted) return;
    AppLog.log('status → $status');
    setState(() {
      _status = status;
      if (status == 'stopped') _signingOff = false;
    });
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    if (_status == 'working' && !_signingOff) {
      setState(() { _phase = (_phase + dt * 2.2) % (2 * math.pi); });
    }
  }

  String get _title {
    if (_signingOff) return 'Signing off';
    switch (_status) {
      case 'working': return 'Getting you online';
      case 'online': return "You're online!";
      default: return 'Ready to go';
    }
  }
  String get _subtitle {
    if (_signingOff) return 'See you next time';
    switch (_status) {
      case 'working': return "Hang tight, this won't take long";
      case 'online': return 'Enjoy your browsing';
      default: return 'Tap below to get connected';
    }
  }
  String get _buttonLabel => _status == 'stopped' ? 'START' : 'STOP';
  Color get _orbColor {
    switch (_status) {
      case 'working': return _orbWorking;
      case 'online': return _orbOnline;
      default: return _orbStopped;
    }
  }
  Color get _glowColor {
    if (_status == 'working') {
      final a = 0.14 + 0.16 * (0.5 + 0.5 * math.sin(_phase));
      return _orbWorking.withOpacity(a);
    }
    if (_status == 'online') return _orbOnline.withOpacity(0.24);
    return _orbStopped.withOpacity(0.18);
  }
  Color get _buttonColor => _status == 'stopped' ? _btnStart : _btnStop;

  void _toggle() => _status == 'stopped' ? _start() : _stop();

  Future<void> _start() async {
    AppLog.log('user tapped START');
    setState(() { _signingOff = false; _status = 'working'; });
    await ServiceBridge.start();
    _watchdog.start();
  }

  Future<void> _stop() async {
    AppLog.log('user tapped STOP');
    if (_status == 'stopped') return;
    setState(() { _signingOff = true; });
    _watchdog.stop();
    await ServiceBridge.stop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await ServiceBridge.background();
      },
      child: Scaffold(
        backgroundColor: _bgColor,
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 84,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(26, 26, 26, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      'Campus Hustler',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    if (_webView != null)
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: _webView!.build(),
                        ),
                      ),
                    if (_webView != null)
                      Positioned.fill(child: Container(color: _bgColor)),
                    Align(
                      alignment: const Alignment(0, 0.20),
                      child: _Orb(color: _orbColor, glowColor: _glowColor),
                    ),
                    Align(
                      alignment: const Alignment(0, -0.34),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          _title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: const Alignment(0, -0.48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          _subtitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            color: _subtitleColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 120,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(30, 10, 30, 34),
                  child: GestureDetector(
                    onTap: _toggle,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _buttonColor,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _buttonLabel,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// Orb
// ==========================================================================
class _Orb extends StatelessWidget {
  final Color color;
  final Color glowColor;
  const _Orb({required this.color, required this.glowColor});

  static const double _orbSize = 180;
  static const double _glowPad = 26;

  @override
  Widget build(BuildContext context) {
    const total = _orbSize + _glowPad * 2;
    return SizedBox(
      width: total, height: total,
      child: Stack(children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, color: glowColor),
          ),
        ),
        Positioned(
          left: _glowPad, top: _glowPad,
          width: _orbSize, height: _orbSize,
          child: DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
        Positioned(
          left: _glowPad + 48, top: _glowPad + 34,
          width: 72, height: 38,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.16),
              borderRadius:
                  const BorderRadius.all(Radius.elliptical(36, 19)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ==========================================================================
// Watchdog
// ==========================================================================
class Watchdog {
  final AppWebView? _web;
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  Completer<void>? _pageLoadCompleter;
  Completer<void>? _pauseCompleter;
  bool _stop = false;
  bool _running = false;
  String? _lastReported;

  String _hotspotUrl = '';
  String _currentUrl = '';

  Watchdog(this._web);

  void notifyPageFinished(String url) {
    _currentUrl = url;
    final c = _pageLoadCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  void notifyPageFailed() {
    final c = _pageLoadCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  void notifyUrlChanged(String url) {
    _currentUrl = url;
  }

  // ------------------------------------------------------------------
  // URL classification
  // ------------------------------------------------------------------
  bool _isPortalUrl(String url) {
    if (url.isEmpty) return true;
    for (final h in _portalHosts) {
      if (url.contains(h)) return true;
    }
    return false;
  }

  bool _isErrorUrl(String url) {
    if (url.isEmpty) return true;
    final lower = url.toLowerCase();
    if (lower.startsWith('chrome-error://')) return true;
    if (lower.startsWith('chrome://')) return true;
    if (lower.startsWith('about:')) return true;
    if (lower.startsWith('data:')) return true;
    if (lower.contains('chromewebdata')) return true;
    return false;
  }

  bool _isSuccessUrl(String url) {
    if (url.isEmpty) return false;
    if (_isPortalUrl(url)) return false;
    if (_isErrorUrl(url)) return false;
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  void _report(String s) {
    if (s != _lastReported) { _lastReported = s; _statusController.add(s); }
  }

  Future<bool> _pause(double seconds) async {
    if (_stop) return true;
    final c = Completer<void>();
    _pauseCompleter = c;
    final t = Timer(
      Duration(milliseconds: (seconds * 1000).round()),
      () { if (!c.isCompleted) c.complete(); },
    );
    await c.future;
    t.cancel();
    _pauseCompleter = null;
    return _stop;
  }

  void stop() {
    if (_stop) return;
    AppLog.log('watchdog: stop requested');
    _stop = true;
    final c = _pauseCompleter;
    if (c != null && !c.isCompleted) c.complete();
    if (!_running) _report('stopped');
  }

  Future<bool> _isOnline() async {
    final client = HttpClient();
    client.connectionTimeout =
        const Duration(milliseconds: _perRequestTimeoutMs);
    try {
      try {
        final req = await client
            .getUrl(Uri.parse(
                'http://detectportal.firefox.com/canonical.html'))
            .timeout(const Duration(milliseconds: _perRequestTimeoutMs));
        final res = await req
            .close()
            .timeout(const Duration(milliseconds: _perRequestTimeoutMs));
        if (res.statusCode == 200) {
          final body = await res.transform(utf8.decoder).join();
          if (body.toLowerCase().contains('success')) {
            AppLog.log('check: online (firefox)');
            return true;
          }
        }
      } catch (_) {}
      try {
        final req = await client
            .getUrl(Uri.parse('http://clients3.google.com/generate_204'))
            .timeout(const Duration(milliseconds: _perRequestTimeoutMs));
        final res = await req
            .close()
            .timeout(const Duration(milliseconds: _perRequestTimeoutMs));
        await res.drain<void>();
        if (res.statusCode == 204) {
          AppLog.log('check: online (clients3)');
          return true;
        }
      } catch (_) {}
      try {
        final req = await client
            .getUrl(Uri.parse(
                'http://connectivitycheck.gstatic.com/generate_204'))
            .timeout(const Duration(milliseconds: _perRequestTimeoutMs));
        final res = await req
            .close()
            .timeout(const Duration(milliseconds: _perRequestTimeoutMs));
        await res.drain<void>();
        if (res.statusCode == 204) {
          AppLog.log('check: online (gstatic)');
          return true;
        }
      } catch (_) {}
      AppLog.log('check: offline');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _refreshCookies() async {
    final web = _web;
    if (web == null) return;
    try {
      await web.clearCookies();
      await web.clearCache();
      try {
        await web.evaluateJavaScript(
            'try { localStorage.clear(); sessionStorage.clear(); } catch(e) {}');
      } catch (_) {}
      AppLog.log('cookies: cleared');
    } catch (e) {
      AppLog.log('cookies: error while clearing: $e');
    }
  }

  Future<void> _goto() async {
    final web = _web;
    if (web == null) {
      AppLog.log('portal: no webview');
      return;
    }
    _pageLoadCompleter = Completer<void>();
    _currentUrl = '';
    AppLog.log('portal: loading hotspot URL');

    try {
      await web.loadUrl(_hotspotUrl);
    } catch (e) {
      AppLog.log('portal: loadUrl threw: $e');
      return;
    }
    try {
      await _pageLoadCompleter!.future
          .timeout(const Duration(milliseconds: _navTimeoutMs));
      AppLog.log('portal: page loaded');
    } catch (_) {
      AppLog.log('portal: load timed out (${_navTimeoutMs}ms)');
    }
  }

  Future<bool> _waitForLoginOrButton() async {
    final web = _web;
    if (web == null) return false;
    final deadline = DateTime.now()
        .add(const Duration(milliseconds: _waitForButtonMs));
    int tries = 0;
    int reloads = 0;
    bool clicked = false;
    String clickedAtUrl = '';

    while (DateTime.now().isBefore(deadline) && !_stop) {
      tries++;

      if (_isSuccessUrl(_currentUrl)) {
        AppLog.log('wait: login detected by URL ($_currentUrl)');
        return true;
      }

      if (_isErrorUrl(_currentUrl) && !clicked && reloads < 3) {
        reloads++;
        AppLog.log('wait: error page ($_currentUrl) — '
            'reloading (attempt $reloads/3)');
        _currentUrl = '';
        if (await _pause(1.0)) return false;
        await _goto();
        if (_stop) return false;
        continue;
      }

      if (clicked) {
        if (_currentUrl != clickedAtUrl && !_isErrorUrl(_currentUrl)) {
          AppLog.log('wait: navigation after click → $_currentUrl');
          return true;
        }
        if (await _pause(0.4)) return false;
        continue;
      }

      try {
        final raw = await web.evaluateJavaScript(_clickScript);
        final result = _unquote(raw);
        if (result.startsWith('found|')) {
          clicked = true;
          clickedAtUrl = _currentUrl;
          final parts = result.split('|');
          final desc = parts.length > 1 ? parts[1] : '';
          final href = parts.length > 2 ? parts[2] : '';
          final action = parts.length > 3 ? parts[3] : '';
          final method = parts.length > 4 ? parts[4] : '';
          final data = parts.length > 5 ? parts[5] : '';
          AppLog.log('wait: CLICKED after $tries tries — $desc');
          if (href.isNotEmpty) AppLog.log('wait: button href=$href');
          if (action.isNotEmpty) {
            AppLog.log('wait: form=$method $action dataLen=${data.length}');
          }
          if (await _pause(0.4)) return false;
          continue;
        }
        if (tries == 1 || tries % 10 == 0) {
          AppLog.log('wait: try $tries — button not found (url=$_currentUrl)');
        }
      } catch (e) {
        AppLog.log('wait: click threw: $e');
      }

      if (await _pause(0.5)) return false;
    }

    AppLog.log('wait: done — tries=$tries clicked=$clicked url=$_currentUrl');
    return clicked;
  }

  String _unquote(String s) {
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try { return jsonDecode(s) as String; }
      catch (_) { return s.substring(1, s.length - 1); }
    }
    return s;
  }

  // ------------------------------------------------------------------
  // Main loop:
  //
  //   Cycle:
  //     1. Clear cookies, wait 1.5 s
  //     2. Generate fresh MAC
  //     3. Load portal, click, verify online
  //     4. Rest 3 min (NO checks, only heartbeats)
  //     5. Poll connectivity every 2 s until it drops
  //     6. On confirmed disconnect → next cycle (fresh MAC)
  //     7. If connection stays up → keep polling, do not rotate MAC
  // ------------------------------------------------------------------
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _stop = false;
    _report('working');

    int cycle = 0;

    try {
      while (!_stop) {
        cycle++;
        AppLog.log('═══════ cycle $cycle start ═══════');
        _report('working');

        // 1. Fresh portal session.
        await _refreshCookies();
        if (_stop) break;
        if (await _pause(1.5)) break;

        // 2. Fresh MAC.
        final mac = _generateRandomMac();
        _hotspotUrl = _buildHotspotUrl(mac);
        AppLog.log('cycle $cycle: MAC $mac');

        // 3. Load portal.
        await _goto();
        if (_stop) break;

        // 4. Wait for login.
        final loggedIn = await _waitForLoginOrButton();
        if (_stop) break;

        bool online = false;
        if (loggedIn) {
          _report('online');
          AppLog.log('cycle $cycle: login confirmed — stabilizing '
              'for ${_postClickWaitMs}ms');
          if (await _pause(_postClickWaitMs / 1000.0)) break;
          online = await _isOnline();
          if (online) {
            AppLog.log('cycle $cycle: VERIFIED online ✓');
          } else {
            AppLog.log('cycle $cycle: login accepted but verify FAILED');
          }
        } else {
          online = await _isOnline();
          if (online) {
            _report('online');
            AppLog.log('cycle $cycle: no button, but already online — '
                'treating as success');
          } else {
            AppLog.log('cycle $cycle: no button AND offline — retrying soon');
          }
        }

        if (!online) {
          if (await _pause(_checkIntervalMs / 1000.0)) break;
          continue;
        }

        // 5. Rest 3 minutes with NO connectivity checks.
        AppLog.log('cycle $cycle: resting ${_postConnectRestMs ~/ 1000}s '
            '(no checks) before starting disconnect watch');
        final restEnd = DateTime.now()
            .add(Duration(milliseconds: _postConnectRestMs));
        while (!_stop) {
          final leftMs = restEnd.difference(DateTime.now()).inMilliseconds;
          if (leftMs <= 0) break;
          final chunkSec = (leftMs / 1000).ceil().clamp(1, 30);
          if (await _pause(chunkSec.toDouble())) break;
          final nowLeftSec = restEnd.difference(DateTime.now()).inSeconds;
          AppLog.log('cycle $cycle: rest — ${nowLeftSec}s remaining');
        }
        if (_stop) break;

        // 6. Poll until the connection drops.
        AppLog.log('cycle $cycle: rest complete — polling connectivity '
            'every ${_disconnectPollIntervalMs}ms until disconnect');
        int pollCount = 0;
        while (!_stop) {
          pollCount++;
          final online = await _isOnline();

          if (!online) {
            // Double-check to avoid transient blips.
            AppLog.log('cycle $cycle: first offline read at poll #$pollCount '
                '— confirming in ${_disconnectConfirmDelayMs}ms');
            if (await _pause(_disconnectConfirmDelayMs / 1000.0)) break;
            if (!await _isOnline()) {
              AppLog.log('cycle $cycle: DISCONNECT confirmed at '
                  'poll #$pollCount — reconnecting');
              break;
            }
            AppLog.log('cycle $cycle: transient blip at poll #$pollCount '
                '— still online');
            continue;
          }

          // Periodic heartbeat so the log shows we're still watching.
          if (pollCount % 30 == 0) {
            final secs = pollCount * _disconnectPollIntervalMs ~/ 1000;
            AppLog.log('cycle $cycle: still online '
                '(poll #$pollCount, ~${secs}s watching)');
          }

          if (await _pause(_disconnectPollIntervalMs / 1000.0)) break;
        }
        if (_stop) break;

        // Connection dropped → next cycle with fresh MAC.
        AppLog.log('cycle $cycle: watch complete — starting reconnect cycle');
      }
    } finally {
      _running = false;
      AppLog.log('watchdog: stopped');
      _report('stopped');
    }
  }
}