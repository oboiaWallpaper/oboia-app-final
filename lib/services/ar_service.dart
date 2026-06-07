// lib/services/ar_service.dart
//
// Dart-side bridge to native ARKit (iOS) / ARCore (Android) wallpaper renderer.
//
// v2.1 (May 2026) — FIXED: setARMode sends raw string, not Map
//   - Native events are buffered until the FIRST Dart listener attaches,
//     so the boot beacon never gets silently dropped.
//   - Every event is also captured into a circular ring buffer of the last
//     500 lines, accessible via ARService.instance.recentLogs.
//   - Logs are also appended to Documents/oboia-debug.log on every event,
//     surviving app restarts.
//   - DiagnosticLog.dump() returns the entire ring buffer as a String for
//     on-screen display.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';                       // ★ NEW: for base64Decode
import 'dart:io';
import 'dart:typed_data';                    // ★ NEW: for Uint8List
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/wallpaper_model.dart';

// ─────────────────────────────────────────────────────────────────────────
// DIAGNOSTIC LOG — global, never throws, always available
// ─────────────────────────────────────────────────────────────────────────

class DiagnosticLog {
  DiagnosticLog._();
  static final DiagnosticLog instance = DiagnosticLog._();

  static const int _maxEntries = 500;
  final Queue<String> _ring = Queue<String>();
  File? _file;
  bool _fileInitInFlight = false;
  bool _fileInitFailed = false;

  void log(String tag, String message) {
    final ts = _timestamp();
    final line = '$ts [$tag] $message';

    _ring.addLast(line);
    while (_ring.length > _maxEntries) {
      _ring.removeFirst();
    }

    debugPrint(line);

    _appendToFile(line);
  }

  String _timestamp() {
    final now = DateTime.now();
    String pad(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}.${pad(now.millisecond, 3)}';
  }

  Future<void> _appendToFile(String line) async {
    if (_fileInitFailed) return;
    try {
      _file ??= await _initFile();
      if (_file == null) return;
      await _file!.writeAsString('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  Future<File?> _initFile() async {
    if (_fileInitInFlight) return null;
    _fileInitInFlight = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/oboia-debug.log');
      if (await f.exists() && (await f.length()) > 1024 * 1024) {
        await f.writeAsString('');
      }
      _fileInitInFlight = false;
      return f;
    } catch (_) {
      _fileInitFailed = true;
      _fileInitInFlight = false;
      return null;
    }
  }

  String dump() {
    return _ring.join('\n');
  }

  void clear() {
    _ring.clear();
  }

  Future<String> readFileLog() async {
    try {
      final f = _file ?? await _initFile();
      if (f == null) return '';
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      return '(failed to read log file: $e)';
    }
  }
}

void dlog(String tag, String message) {
  DiagnosticLog.instance.log(tag, message);
}

// ─────────────────────────────────────────────────────────────────────────
// AR EVENT MODEL
// ─────────────────────────────────────────────────────────────────────────

class AREvent {
  final String type;
  final Map<String, dynamic> data;

  const AREvent({required this.type, required this.data});

  factory AREvent.fromMap(Map<String, dynamic> map) {
    final raw = map['data'];
    final Map<String, dynamic> data = raw is Map
        ? raw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    return AREvent(
      type: (map['type'] ?? '').toString(),
      data: data,
    );
  }

  int? get wallIndex => data['wallIndex'] is int
      ? data['wallIndex'] as int
      : (data['wallIndex'] as num?)?.toInt();

  double? get width => (data['width'] as num?)?.toDouble();
  double? get height => (data['height'] as num?)?.toDouble();
  double? get sqm => (data['sqm'] as num?)?.toDouble();
  bool? get success => data['success'] as bool?;
  String? get errorCode => data['code'] as String?;
  String? get errorMessage => data['message'] as String?;

  int? get cutCount => data['cutCount'] is int
      ? data['cutCount'] as int
      : (data['cutCount'] as num?)?.toInt();

  String? get tool => data['tool'] as String?;
  bool? get locked => data['locked'] as bool?;
  int? get obstacleCount => data['count'] is int
      ? data['count'] as int
      : (data['count'] as num?)?.toInt();

  String? get reason => data['reason'] as String?;
  int? get cornerNumber => data['corner'] is int
      ? data['corner'] as int
      : (data['corner'] as num?)?.toInt();
  int? get totalCorners => data['total'] is int
      ? data['total'] as int
      : (data['total'] as num?)?.toInt();
}

class WallMeasurements {
  final int wallIndex;
  final double width;
  final double height;
  final double sqm;

  const WallMeasurements({
    required this.wallIndex,
    required this.width,
    required this.height,
    required this.sqm,
  });

  int rollsNeeded({required double rollWidth, required double rollLength}) {
    final perRoll = rollWidth * rollLength;
    if (perRoll <= 0) return 0;
    return (sqm / perRoll).ceil();
  }

  double totalPrice({
    required double rollWidth,
    required double rollLength,
    required double pricePerRoll,
  }) {
    return rollsNeeded(rollWidth: rollWidth, rollLength: rollLength) * pricePerRoll;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// ARSERVICE — bulletproof bridge with buffering
// ─────────────────────────────────────────────────────────────────────────

class ARService {
  ARService._();
  static final ARService instance = ARService._();

  static const _channel = MethodChannel('com.oboia/ar');
  static const _eventChannel = EventChannel('com.oboia/ar_events');

  final StreamController<AREvent> _controller = StreamController<AREvent>.broadcast();

  final List<AREvent> _pendingEvents = [];

  bool _hasListener = false;

  StreamSubscription<dynamic>? _eventSub;
  bool _initialized = false;

  Stream<AREvent> get events {
    return Stream<AREvent>.multi((controller) {
      _hasListener = true;
      dlog('AR-DART', 'listener attached, draining ${_pendingEvents.length} pending events');

      final buffered = List<AREvent>.from(_pendingEvents);
      _pendingEvents.clear();
      for (final ev in buffered) {
        controller.add(ev);
      }

      final sub = _controller.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );

      controller.onCancel = () {
        sub.cancel();
      };
    });
  }

  void _emit(AREvent ev) {
    dlog('AR-DART', 'event recv type=${ev.type} data=${ev.data}');
    if (_hasListener) {
      _controller.add(ev);
    } else {
      _pendingEvents.add(ev);
      if (_pendingEvents.length > 200) {
        _pendingEvents.removeAt(0);
      }
    }
  }

  Future<void> initAR() async {
    dlog('AR-DART', 'initAR() called, _initialized=$_initialized');
    if (_initialized) {
      dlog('AR-DART', 'initAR() already initialized — ensuring listener still attached');
      if (_eventSub == null) {
        _attachEventChannel();
      }
      return;
    }
    _initialized = true;

    try {
      dlog('AR-DART', 'invoking initAR method on channel (before event channel attach)');
      await _channel.invokeMethod<void>('initAR');
      dlog('AR-DART', 'initAR method returned successfully');
    } on PlatformException catch (e) {
      dlog('AR-DART', 'initAR method FAILED: code=${e.code} msg=${e.message}');
      _emit(AREvent(
        type: 'error',
        data: {'code': e.code, 'message': e.message ?? ''},
      ));
      return;
    }

    await Future.delayed(const Duration(milliseconds: 800));

    dlog('AR-DART', 'attaching event channel listener (after native ready)');
    _attachEventChannel();
  }

  void _attachEventChannel() {
    dlog('AR-DART', 'attaching to event channel com.oboia/ar_events');
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final map = event.map((k, v) => MapEntry(k.toString(), v));
          _emit(AREvent.fromMap(map));
        } else {
          dlog('AR-DART', 'event channel got non-Map: ${event.runtimeType}');
        }
      },
      onError: (err) {
        dlog('AR-DART', 'event channel ERROR: $err');
        _emit(AREvent(
          type: 'error',
          data: {'message': err.toString(), 'code': 'stream_error'},
        ));
      },
      onDone: () {
        dlog('AR-DART', 'event channel closed (onDone)');
      },
    );
    dlog('AR-DART', 'event channel listener attached');
  }

  // ── Wallpaper Methods ───────────────────────────────────────────────────

  Future<void> placeWallpaper({
    required WallpaperModel wallpaper,
    required int wallIndex,
    required double pricePerRoll,
  }) async {
    dlog('AR-DART', 'placeWallpaper wallIndex=$wallIndex name="${wallpaper.name}"');
    dlog('AR-DART', '  albedoUrl="${wallpaper.pbr.albedoUrl}"');
    dlog('AR-DART', '  rollWidth=${wallpaper.rollWidth} rollLength=${wallpaper.rollLength}');
    try {
      await _channel.invokeMethod<void>('placeWallpaper', {
        'albedoUrl': wallpaper.pbr.albedoUrl,
        'normalUrl': wallpaper.pbr.normalUrl,
        'roughnessUrl': wallpaper.pbr.roughnessUrl,
        'aoUrl': wallpaper.pbr.aoUrl,
        'rollWidth': wallpaper.rollWidth,
        'rollLength': wallpaper.rollLength,
        'pricePerRoll': pricePerRoll,
        'wallIndex': wallIndex,
      });
      dlog('AR-DART', 'placeWallpaper method returned OK');
    } on PlatformException catch (e) {
      dlog('AR-DART', 'placeWallpaper FAILED: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> switchWallpaper({
    required WallpaperModel wallpaper,
    required int wallIndex,
    required double pricePerRoll,
  }) async {
    dlog('AR-DART', 'switchWallpaper wallIndex=$wallIndex name="${wallpaper.name}"');
    try {
      await _channel.invokeMethod<void>('switchWallpaper', {
        'albedoUrl': wallpaper.pbr.albedoUrl,
        'normalUrl': wallpaper.pbr.normalUrl,
        'roughnessUrl': wallpaper.pbr.roughnessUrl,
        'aoUrl': wallpaper.pbr.aoUrl,
        'rollWidth': wallpaper.rollWidth,
        'rollLength': wallpaper.rollLength,
        'pricePerRoll': pricePerRoll,
        'wallIndex': wallIndex,
      });
      dlog('AR-DART', 'switchWallpaper method returned OK');
    } on PlatformException catch (e) {
      dlog('AR-DART', 'switchWallpaper FAILED: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> selectWall(int wallIndex) async {
    dlog('AR-DART', 'selectWall wallIndex=$wallIndex');
    await _channel.invokeMethod<void>('selectWall', {'wallIndex': wallIndex});
  }

  Future<void> clearWall(int wallIndex) async {
    dlog('AR-DART', 'clearWall wallIndex=$wallIndex');
    await _channel.invokeMethod<void>('clearWall', {'wallIndex': wallIndex});
  }

  Future<WallMeasurements?> getWallMeasurements(int wallIndex) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'getWallMeasurements',
      {'wallIndex': wallIndex},
    );
    if (res == null) return null;
    return WallMeasurements(
      wallIndex: wallIndex,
      width: (res['width'] as num).toDouble(),
      height: (res['height'] as num).toDouble(),
      sqm: (res['sqm'] as num).toDouble(),
    );
  }

  Future<void> lockWall({required int wallIndex, required bool locked}) async {
    dlog('AR-DART', 'lockWall wallIndex=$wallIndex locked=$locked');
    await _channel.invokeMethod<void>('lockWall', {
      'wallIndex': wallIndex,
      'locked': locked,
    });
  }

  Future<void> disposeAR() async {
    dlog('AR-DART', 'disposeAR called');
    try {
      await _channel.invokeMethod<void>('disposeAR');
    } catch (_) {}
    await _eventSub?.cancel();
    _eventSub = null;
    _initialized = false;
    dlog('AR-DART', 'disposeAR complete');
  }

  // ── Phase 1: RoomPlan Scanning ─────────────────────────────────────────

  Future<void> startScan() async {
    dlog('AR-DART', 'startScan invoked');
    await _channel.invokeMethod<void>('startScan');
    dlog('AR-DART', 'startScan method returned');
  }

  Future<void> stopScan() async {
    dlog('AR-DART', 'stopScan invoked');
    try {
      await _channel.invokeMethod<void>('stopScan');
    } catch (_) {}
  }

  Future<void> toggleSurfaceExclusion(String id) async {
    dlog('AR-DART', 'toggleSurfaceExclusion id=$id');
    await _channel.invokeMethod<void>('toggleSurfaceExclusion', {'id': id});
  }

  Future<void> toggleObjectExclusion(String id) async {
    dlog('AR-DART', 'toggleObjectExclusion id=$id');
    await _channel.invokeMethod<void>('toggleObjectExclusion', {'id': id});
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CRITICAL FIX: Send mode as a raw String, NOT as {'mode': mode}.
  //
  // Swift expects: call.arguments as? String → "scanning"
  // Old code sent: call.arguments as? String → {'mode': 'scanning'} → FAILS
  //
  // This one-line bug prevented setARMode from EVER succeeding,
  // which meant startScan was NEVER called, which meant RoomScanner
  // was NEVER created, which meant zero scan events — always.
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> setARMode(String mode) async {
    dlog('AR-DART', 'setARMode -> $mode');
    await _channel.invokeMethod<void>('setARMode', mode);  // ← RAW STRING, not Map
  }

  // ── Manual Mode Methods ────────────────────────────────────────────────

  Future<void> enterManualMode() async {
    dlog('AR-DART', 'enterManualMode invoked');
    await _channel.invokeMethod<void>('enterManualMode');
    dlog('AR-DART', 'enterManualMode method returned');
  }

  Future<void> exitManualMode() async {
    dlog('AR-DART', 'exitManualMode invoked');
    await _channel.invokeMethod<void>('exitManualMode');
  }

  Future<void> resetManual() async {
    dlog('AR-DART', 'resetManual invoked');
    await _channel.invokeMethod<void>('resetManual');
  }

  // ── Cut Mode Methods ────────────────────────────────────────────────────

  Future<void> enterCutMode(int wallIndex) async {
    await _channel.invokeMethod<void>('enterCutMode', {'wallIndex': wallIndex});
  }

  Future<void> exitCutMode() async {
    await _channel.invokeMethod<void>('exitCutMode');
  }

  Future<void> smartCut({
    required double screenX,
    required double screenY,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('smartCut', {
      'screenX': screenX,
      'screenY': screenY,
      'wallIndex': wallIndex,
    });
  }

  Future<void> rectangleCut({
    required double screenMinX,
    required double screenMinY,
    required double screenMaxX,
    required double screenMaxY,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('rectangleCut', {
      'screenMinX': screenMinX,
      'screenMinY': screenMinY,
      'screenMaxX': screenMaxX,
      'screenMaxY': screenMaxY,
      'wallIndex': wallIndex,
    });
  }

  Future<void> freehandCut({
    required List<Map<String, double>> screenPoints,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('freehandCut', {
      'screenPoints': screenPoints,
      'wallIndex': wallIndex,
    });
  }

  Future<void> circleCut({
    required double screenCenterX,
    required double screenCenterY,
    required double screenRadius,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('circleCut', {
      'screenCenterX': screenCenterX,
      'screenCenterY': screenCenterY,
      'screenRadius': screenRadius,
      'wallIndex': wallIndex,
    });
  }

  Future<void> undoCut(int wallIndex) async {
    await _channel.invokeMethod<void>('undoCut', {'wallIndex': wallIndex});
  }

  Future<void> clearAllCuts(int wallIndex) async {
    await _channel.invokeMethod<void>('clearAllCuts', {'wallIndex': wallIndex});
  }

  // ── Brush Methods ───────────────────────────────────────────────────────

  /// Set brush mode: 'paint' to add selection, 'erase' to remove selection
  Future<void> setBrushMode(String mode) async {
    dlog('AR-DART', 'setBrushMode -> $mode');
    await _channel.invokeMethod<void>('setBrushMode', mode);
  }

  /// Set brush radius in meters (0.02 = 2cm, 0.25 = 25cm)
  Future<void> setBrushSize(double size) async {
    dlog('AR-DART', 'setBrushSize -> $size');
    await _channel.invokeMethod<void>('setBrushSize', {'size': size});
  }

  /// Set wallpaper opacity (0.1 to 1.0)
  Future<void> setWallpaperOpacity(double opacity) async {
    dlog('AR-DART', 'setWallpaperOpacity -> $opacity');
    await _channel.invokeMethod<void>('setWallpaperOpacity', {'opacity': opacity});
  }

  // ── Lasso Methods ───────────────────────────────────────────────────────

  /// Enter lasso mode — Swift starts tracking 3D anchored points
  Future<void> lassoStart() async {
    dlog('AR-DART', 'lassoStart');
    await _channel.invokeMethod<void>('lassoStart');
  }

  /// Exit lasso mode — Swift clears all lasso state
  Future<void> lassoEnd() async {
    dlog('AR-DART', 'lassoEnd');
    await _channel.invokeMethod<void>('lassoEnd');
  }

  /// Add a lasso point at the given screen coordinates.
  /// Swift raycasts to wall and stores 3D world position.
  Future<void> lassoAddPoint(double x, double y) async {
    dlog('AR-DART', 'lassoAddPoint x=$x y=$y');
    await _channel.invokeMethod<void>('lassoAddPoint', {'x': x, 'y': y});
  }

  /// Clear lasso points but stay in lasso mode
  Future<void> lassoClear() async {
    dlog('AR-DART', 'lassoClear');
    await _channel.invokeMethod<void>('lassoClear');
  }

  /// Apply lasso cut/paint. mode = 'erase' or 'paint'
  Future<void> lassoApply(String mode) async {
    dlog('AR-DART', 'lassoApply mode=$mode');
    await _channel.invokeMethod<void>('lassoApply', {'mode': mode});
  }

  /// Toggle freehand (pen) mode for lasso.
  /// true = pen/freehand, false = tap mode (default)
  Future<void> lassoSetFreehand(bool freehand) async {
    dlog('AR-DART', 'lassoSetFreehand $freehand');
    await _channel.invokeMethod<void>('lassoSetFreehand', freehand);
  }

  /// Pause AR session (freezes camera view, used for lasso drawing)
  Future<void> pauseSession() async {
    dlog('AR-DART', 'pauseSession');
    await _channel.invokeMethod<void>('pauseSession');
  }

  /// Resume AR session (unfreezes camera view)
  Future<void> resumeSession() async {
    dlog('AR-DART', 'resumeSession');
    await _channel.invokeMethod<void>('resumeSession');
  }

  // ── ADDED: Pen drag + LiDAR occluder methods ───────────────────────────

  /// Begin a pen-tool drag stroke (touch down)
  Future<void> lassoBeginDrag(double x, double y) async {
    dlog('AR-DART', 'lassoBeginDrag x=$x y=$y');
    await _channel.invokeMethod<void>('lassoBeginDrag', {'x': x, 'y': y});
  }

  /// Continue a pen-tool drag stroke (touch move)
  Future<void> lassoDragPoint(double x, double y) async {
    await _channel.invokeMethod<void>('lassoDragPoint', {'x': x, 'y': y});
  }

  /// End a pen-tool drag stroke (touch up) — auto-closes the polygon
  Future<void> lassoEndDrag() async {
    dlog('AR-DART', 'lassoEndDrag');
    await _channel.invokeMethod<void>('lassoEndDrag');
  }

  /// Enable/disable the LiDAR occluder.
  /// When ON: wallpaper is hidden behind furniture/curtains/objects in front of walls.
  /// When OFF: wallpaper shows through everything (useful for previewing without obstruction).
  Future<void> setOccluderEnabled(bool enabled) async {
    dlog('AR-DART', 'setOccluderEnabled $enabled');
    await _channel.invokeMethod<void>('setOccluderEnabled', {'enabled': enabled});
  }

  // ── ADDED: Diagnostics ─────────────────────────────────────────────────

  /// Fetch the full diagnostic report from Swift as a string.
  Future<String> getDiagnostics() async {
    try {
      final result = await _channel.invokeMethod<String>('getDiagnostics');
      return result ?? '(empty report)';
    } catch (e) {
      return '(error fetching diagnostics: $e)';
    }
  }

  // ── ADDED: Screenshot ──────────────────────────────────────────────────

  /// Capture the current AR scene as a PNG. Returns base64-decoded bytes.
  /// Used to thumbnail saved walls in the walls list.
  Future<Uint8List?> captureScreenshot() async {
    try {
      final b64 = await _channel.invokeMethod<String>('captureScreenshot');
      if (b64 == null || b64.isEmpty) return null;
      return base64Decode(b64);
    } catch (e) {
      dlog('AR-DART', 'captureScreenshot failed: $e');
      return null;
    }
  }
}
