// lib/screens/ar/ar_screen.dart — v3 FIXES
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/ar_service.dart';
import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';

const Color goldColor = Color(0xFFFFD369);

class ARScreen extends StatefulWidget {
  final WallpaperModel? wallpaper;
  final double pricePerRoll;
  ARScreen({super.key, WallpaperModel? initialWallpaper, ShopModel? initialShop, double? pricePerRoll})
      : wallpaper = initialWallpaper, pricePerRoll = pricePerRoll ?? 0.0;
  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  final ARService _arService = ARService.instance;
  StreamSubscription<AREvent>? _eventSub;

  String _statusText = "Initializing...";
  final List<String> _logLines = [];
  bool _isScanning = false, _scanDone = false, _wallpaperApplied = false;
  bool _editMode = false, _showLog = false;
  String _activeTool = 'erase'; // 'paint', 'erase', 'lasso'
  String _lassoMode = 'erase'; // sub-mode for lasso: 'paint' or 'erase'
  double _brushSize = 0.08, _wallpaperOpacity = 0.96;
  double _totalWallArea = 0.0;
  List<Offset> _lassoPoints = [];

  @override
  void initState() { super.initState(); _initAR(); }

  Future<void> _initAR() async {
    try {
      await Future.delayed(const Duration(milliseconds: 1200));
      await _arService.initAR();
    } catch (e) { _log('Init: $e'); }
    _eventSub = _arService.events.listen(_onAREvent);
  }

  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      _logLines.insert(0, '[${DateTime.now().toString().substring(11, 19)}] $msg');
      if (_logLines.length > 25) _logLines.removeLast();
    });
  }

  void _onAREvent(AREvent event) {
    switch (event.type) {
      case 'boot':
        setState(() => _statusText = (event.data['status'] ?? '').toString());
        break;
      case 'error':
        setState(() => _statusText = 'ERROR: ${event.errorMessage}');
        _log('[ERROR] ${event.errorMessage}');
        break;
      case 'scanComplete':
        final area = event.data['totalWallArea'];
        setState(() { _isScanning = false; _scanDone = true;
          if (area is num) _totalWallArea = area.toDouble(); });
        _enterEditMode();
        break;
      case 'wallpaperPlaced':
        final ok = event.data['success'] as bool? ?? false;
        final area = event.data['area'];
        if (ok) setState(() { _wallpaperApplied = true; _editMode = false;
          if (area is num) _totalWallArea = area.toDouble(); });
        break;
      case 'selectionChanged':
        final area = event.data['area'];
        if (area is num) setState(() => _totalWallArea = area.toDouble());
        break;
      default: break;
    }
  }

  // Calculations
  double get _rollArea => (widget.wallpaper?.rollWidth ?? 0.53) * (widget.wallpaper?.rollLength ?? 10.0);
  int get _rollsNeeded => _rollArea > 0 ? (_totalWallArea / _rollArea).ceil() : 0;
  double get _totalPrice => _rollsNeeded * widget.pricePerRoll;

  // Actions
  Future<void> _startScan() async {
    setState(() { _isScanning = true; _scanDone = false; _wallpaperApplied = false;
      _editMode = false; _totalWallArea = 0; _lassoPoints.clear(); });
    try { await _arService.setARMode('scanning'); await _arService.startScan(); } catch (e) { _log('Scan: $e'); }
  }
  Future<void> _stopScan() async { try { await _arService.stopScan(); } catch (e) { _log('Stop: $e'); } }

  Future<void> _enterEditMode() async {
    setState(() { _editMode = true; _activeTool = 'erase'; _lassoPoints.clear(); });
    try { await _arService.enterCutMode(0); await _arService.setBrushMode('erase'); } catch (_) {}
  }
  Future<void> _exitEditMode() async {
    setState(() { _editMode = false; _lassoPoints.clear(); });
    try { await _arService.exitCutMode(); } catch (_) {}
  }

  Future<void> _setTool(String tool) async {
    setState(() { _activeTool = tool; _lassoPoints.clear(); });
    if (tool == 'paint' || tool == 'erase') {
      try { await _arService.setBrushMode(tool); } catch (_) {}
    }
  }

  Future<void> _setBrushSize(double size) async {
    setState(() => _brushSize = size);
    try { await _arService.setBrushSize(size); } catch (_) {}
  }
  Future<void> _setOpacity(double val) async {
    setState(() => _wallpaperOpacity = val);
    try { await _arService.setWallpaperOpacity(val); } catch (_) {}
  }
  Future<void> _undo() async { try { await _arService.undoCut(0); } catch (_) {} }
  Future<void> _reset() async { try { await _arService.clearAllCuts(0); } catch (_) {} }

  Future<void> _applyWallpaper() async {
    if (widget.wallpaper == null) return;
    try { await _arService.placeWallpaper(wallpaper: widget.wallpaper!, wallIndex: 0, pricePerRoll: widget.pricePerRoll); } catch (e) { _log('Apply: $e'); }
  }
  Future<void> _clearWallpaper() async {
    try { await _arService.clearWall(0); setState(() => _wallpaperApplied = false); } catch (_) {}
  }

  // Lasso
  void _addLassoPoint(Offset point) { setState(() => _lassoPoints.add(point)); }
  Future<void> _applyLasso() async {
    if (_lassoPoints.length < 3) return;
    final pts = _lassoPoints.map((p) => [p.dx, p.dy]).toList();
    try { await _arService.applyLasso(pts, _lassoMode); } catch (e) { _log('Lasso: $e'); }
    setState(() => _lassoPoints.clear());
  }
  void _clearLassoPoints() { setState(() => _lassoPoints.clear()); }

  @override
  void dispose() { _eventSub?.cancel(); _arService.disposeAR(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // AR View
        Positioned.fill(child: UiKitView(viewType: 'com.oboia/ar_view',
            creationParams: const <String, dynamic>{}, creationParamsCodec: StandardMessageCodec())),

        // Lasso overlay
        if (_editMode && _activeTool == 'lasso' && _lassoPoints.isNotEmpty)
          Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _LassoPainter(_lassoPoints, _lassoMode)))),

        // Lasso tap area
        if (_editMode && _activeTool == 'lasso')
          Positioned.fill(child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (d) => _addLassoPoint(d.localPosition),
            child: Container(color: Colors.transparent))),

        // Back button
        Positioned(top: MediaQuery.of(context).padding.top + 8, left: 8,
          child: IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 24),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: () => Navigator.of(context).pop())),

        // ── SCANNING ─────────────────────────────
        if (_isScanning) ...[
          Positioned(top: MediaQuery.of(context).padding.top + 8, left: 60, right: 60,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.92), borderRadius: BorderRadius.circular(12)),
              child: const Text('Scan the walls you want\nto wallpaper',
                style: TextStyle(color: Colors.black87, fontSize: 15, fontWeight: FontWeight.w600), textAlign: TextAlign.center))),
          Positioned(bottom: 100, left: 20, right: 20,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(_statusText, style: const TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis))),
          Positioned(bottom: 30, left: 40, right: 40,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: goldColor, padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
              onPressed: _stopScan,
              child: const Text('Done Scanning', style: TextStyle(fontSize: 18, color: Colors.black, fontWeight: FontWeight.bold)))),
        ],

        // ── EDIT MODE ────────────────────────────
        if (_scanDone && _editMode) ...[
          // Instruction
          Positioned(top: MediaQuery.of(context).padding.top + 8, left: 50, right: 50,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.75), borderRadius: BorderRadius.circular(10)),
              child: Text(
                _activeTool == 'lasso'
                    ? 'Tap corners to draw shape (${_lassoPoints.length} pts)'
                    : _activeTool == 'erase' ? 'Rub to remove areas' : 'Rub to add areas',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center))),

          // Toolbar
          Positioned(bottom: _activeTool == 'lasso' && _lassoPoints.length >= 3 ? 170 : 140,
            left: 12, right: 12,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(color: const Color(0xE6222222), borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Tool row
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _toolBtn(Icons.brush, 'Paint', _activeTool == 'paint', () => _setTool('paint')),
                  _toolBtn(Icons.auto_fix_high, 'Erase', _activeTool == 'erase', () => _setTool('erase')),
                  _toolBtn(Icons.polyline, 'Lasso', _activeTool == 'lasso', () => _setTool('lasso')),
                  _toolBtn(Icons.undo, 'Undo', false, _undo),
                  _toolBtn(Icons.restart_alt, 'Reset', false, _reset),
                ]),
                const SizedBox(height: 8),

                // Lasso sub-mode toggle (paint vs erase)
                if (_activeTool == 'lasso')
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Text('Lasso: ', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    _miniToggle('Erase', _lassoMode == 'erase', () => setState(() => _lassoMode = 'erase')),
                    const SizedBox(width: 8),
                    _miniToggle('Paint', _lassoMode == 'paint', () => setState(() => _lassoMode = 'paint')),
                    const SizedBox(width: 12),
                    if (_lassoPoints.isNotEmpty)
                      GestureDetector(
                        onTap: _clearLassoPoints,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: Colors.red.withOpacity(0.3), borderRadius: BorderRadius.circular(6)),
                          child: const Text('Clear pts', style: TextStyle(color: Colors.redAccent, fontSize: 10)),
                        ),
                      ),
                  ]),

                // Brush size (hidden for lasso)
                if (_activeTool != 'lasso')
                  Row(children: [
                    const Icon(Icons.circle, color: Colors.white38, size: 8),
                    Expanded(child: Slider(value: _brushSize, min: 0.02, max: 0.25,
                        activeColor: goldColor, inactiveColor: Colors.white24,
                        onChanged: (v) => _setBrushSize(v))),
                    const Icon(Icons.circle, color: Colors.white38, size: 20),
                  ]),

                // Opacity
                Row(children: [
                  const Text('Opacity', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  Expanded(child: Slider(value: _wallpaperOpacity, min: 0.1, max: 1.0,
                      activeColor: goldColor.withOpacity(0.6), inactiveColor: Colors.white12,
                      onChanged: (v) => _setOpacity(v))),
                  Text('${(_wallpaperOpacity * 100).toInt()}%', style: const TextStyle(color: Colors.white38, fontSize: 10)),
                ]),

                Text('Selected: ${_totalWallArea.toStringAsFixed(1)} m²',
                    style: const TextStyle(color: goldColor, fontSize: 13, fontWeight: FontWeight.w600)),
              ]))),

          // Lasso apply button
          if (_activeTool == 'lasso' && _lassoPoints.length >= 3)
            Positioned(bottom: 80, left: 40, right: 40,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                onPressed: _applyLasso,
                icon: const Icon(Icons.check, color: Colors.white),
                label: Text('Apply Lasso (${_lassoMode})', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),

          // Apply wallpaper
          if (widget.wallpaper != null)
            Positioned(bottom: 20, left: 40, right: 40,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: goldColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                onPressed: _applyWallpaper,
                icon: const Icon(Icons.wallpaper, color: Colors.black, size: 20),
                label: const Text('Apply Wallpaper', style: TextStyle(fontSize: 15, color: Colors.black, fontWeight: FontWeight.bold)))),
        ],

        // ── POST-APPLY ───────────────────────────
        if (_scanDone && _wallpaperApplied && !_editMode) ...[
          if (widget.wallpaper != null)
            Positioned(top: MediaQuery.of(context).padding.top + 8, right: 12,
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(widget.wallpaper!.name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                  Text('${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll', style: const TextStyle(color: goldColor, fontSize: 11)),
                ]))),

          Positioned(bottom: 0, left: 0, right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
              decoration: const BoxDecoration(color: Color(0xF0222222),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  _stat('Wall Area', '${_totalWallArea.toStringAsFixed(1)} m²'),
                  _stat('Rolls', '$_rollsNeeded'),
                  _stat('Total', '${_totalPrice.toStringAsFixed(0)} UZS'),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: goldColor,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: _enterEditMode,
                    icon: const Icon(Icons.edit, color: Colors.black, size: 18),
                    label: const Text('Edit', style: TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w600)))),
                  const SizedBox(width: 12),
                  Expanded(child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white38),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: _clearWallpaper,
                    icon: const Icon(Icons.visibility_off, color: Colors.white70, size: 18),
                    label: const Text('Clear', style: TextStyle(color: Colors.white70, fontSize: 14)))),
                ]),
                const SizedBox(height: 8),
                TextButton.icon(onPressed: _startScan,
                    icon: const Icon(Icons.replay, color: Colors.white38, size: 16),
                    label: const Text('Rescan', style: TextStyle(color: Colors.white38, fontSize: 13))),
              ]))),
        ],

        // Status (double-tap for log)
        if (!_isScanning)
          Positioned(top: MediaQuery.of(context).padding.top + 44, left: 50, right: 50,
            child: GestureDetector(onDoubleTap: () => setState(() => _showLog = !_showLog),
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text(_statusText, style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                    textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis)))),

        if (_showLog)
          Positioned(top: MediaQuery.of(context).padding.top + 65, left: 8, right: 8,
            child: IgnorePointer(child: Container(constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(6), color: Colors.black87,
                child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: _logLines.take(10).map((l) => Text(l, style: const TextStyle(color: Colors.white70, fontSize: 9),
                        maxLines: 2, overflow: TextOverflow.ellipsis)).toList()))))),
      ]),
      floatingActionButton: !_isScanning && !_scanDone
          ? FloatingActionButton.extended(onPressed: _startScan, backgroundColor: goldColor,
              icon: const Icon(Icons.camera, color: Colors.black),
              label: const Text('Start Scan', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)))
          : null,
    );
  }

  Widget _toolBtn(IconData icon, String label, bool active, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? goldColor.withOpacity(0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: active ? Border.all(color: goldColor, width: 1.5) : null),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: active ? goldColor : Colors.white60, size: 20),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: active ? goldColor : Colors.white60, fontSize: 9, fontWeight: FontWeight.w500)),
        ])));
  }

  Widget _miniToggle(String label, bool active, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active ? goldColor.withOpacity(0.3) : Colors.white10,
        borderRadius: BorderRadius.circular(8),
        border: active ? Border.all(color: goldColor) : null),
      child: Text(label, style: TextStyle(color: active ? goldColor : Colors.white54, fontSize: 11, fontWeight: FontWeight.w500)),
    ));
  }

  Widget _stat(String label, String value) => Column(children: [
    Text(value, style: const TextStyle(color: goldColor, fontSize: 20, fontWeight: FontWeight.bold)),
    const SizedBox(height: 2),
    Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
  ]);
}

class _LassoPainter extends CustomPainter {
  final List<Offset> points;
  final String mode;
  _LassoPainter(this.points, this.mode);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final color = mode == 'erase' ? Colors.redAccent : Colors.greenAccent;
    final linePaint = Paint()..color = color..strokeWidth = 2.5..style = PaintingStyle.stroke;
    final dotPaint = Paint()..color = Colors.white..style = PaintingStyle.fill;
    final fillPaint = Paint()..color = color.withOpacity(0.1)..style = PaintingStyle.fill;

    if (points.length >= 3) {
      final path = Path()..moveTo(points[0].dx, points[0].dy);
      for (int i = 1; i < points.length; i++) { path.lineTo(points[i].dx, points[i].dy); }
      path.close();
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, linePaint);
    } else {
      for (int i = 0; i < points.length - 1; i++) { canvas.drawLine(points[i], points[i + 1], linePaint); }
    }
    for (final p in points) {
      canvas.drawCircle(p, 6, dotPaint);
      canvas.drawCircle(p, 6, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LassoPainter old) => true;
}
