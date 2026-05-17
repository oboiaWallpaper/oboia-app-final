// lib/screens/ar/ar_screen.dart — PHASE 1: Brush Selection + Toolbar

import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/ar_service.dart';
import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';
import 'package:flutter/services.dart';

const Color goldColor = Color(0xFFFFD369);

class ARScreen extends StatefulWidget {
  final WallpaperModel? wallpaper;
  final double pricePerRoll;

  ARScreen({
    super.key,
    WallpaperModel? initialWallpaper,
    ShopModel? initialShop,
    double? pricePerRoll,
  }) : wallpaper = initialWallpaper,
       pricePerRoll = pricePerRoll ?? 0.0;

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  final ARService _arService = ARService.instance;
  StreamSubscription<AREvent>? _eventSub;

  // State
  String _statusText = "Initializing...";
  final List<String> _logLines = [];
  bool _isScanning = false;
  bool _scanDone = false;
  bool _wallpaperApplied = false;
  bool _editMode = false;
  String _brushMode = 'erase'; // 'paint' or 'erase'
  double _brushSize = 0.08; // meters
  double _totalWallArea = 0.0;
  int _meshSegments = 0;
  bool _showLog = false;

  @override
  void initState() {
    super.initState();
    _initAR();
  }

  Future<void> _initAR() async {
    try {
      await Future.delayed(const Duration(milliseconds: 1200));
      await _arService.initAR();
    } catch (e) { _log('Init error: $e'); }
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
        final msg = (event.data['status'] ?? '').toString();
        setState(() => _statusText = msg);
        _log('[BOOT] $msg');
        break;
      case 'error':
        final msg = event.errorMessage ?? 'Unknown';
        setState(() => _statusText = 'ERROR: $msg');
        _log('[ERROR] $msg');
        break;
      case 'scanComplete':
        final area = event.data['totalWallArea'];
        final segs = event.data['meshSegments'];
        setState(() {
          _isScanning = false;
          _scanDone = true;
          if (area is num) _totalWallArea = area.toDouble();
          if (segs is num) _meshSegments = segs.toInt();
        });
        _log('[DONE] ${_totalWallArea.toStringAsFixed(1)}m², $_meshSegments mesh');
        // Go into edit mode by default after scan
        _enterEditMode();
        break;
      case 'wallpaperPlaced':
        final ok = event.data['success'] as bool? ?? false;
        final area = event.data['area'];
        if (ok) {
          setState(() {
            _wallpaperApplied = true;
            _editMode = false;
            if (area is num) _totalWallArea = area.toDouble();
          });
          _log('[WALLPAPER] Applied ✅');
        } else {
          _log('[WALLPAPER] Failed: ${event.data['message']}');
        }
        break;
      case 'selectionChanged':
        final area = event.data['area'];
        if (area is num) {
          setState(() => _totalWallArea = area.toDouble());
        }
        break;
      case 'wallDetected':
        break;
      default:
        _log('[${event.type}]');
    }
  }

  // ── Calculations ───────────────────────────────────────────
  double get _rollWidth => widget.wallpaper?.rollWidth ?? 0.53;
  double get _rollLength => widget.wallpaper?.rollLength ?? 10.0;
  double get _rollArea => _rollWidth * _rollLength;
  int get _rollsNeeded => _rollArea > 0 ? (_totalWallArea / _rollArea).ceil() : 0;
  double get _totalPrice => _rollsNeeded * widget.pricePerRoll;

  // ── Actions ────────────────────────────────────────────────
  Future<void> _startScan() async {
    setState(() {
      _isScanning = true; _scanDone = false; _wallpaperApplied = false;
      _editMode = false; _totalWallArea = 0; _meshSegments = 0;
    });
    try {
      await _arService.setARMode('scanning');
      await _arService.startScan();
    } catch (e) { _log('Scan error: $e'); }
  }

  Future<void> _stopScan() async {
    try { await _arService.stopScan(); } catch (e) { _log('Stop error: $e'); }
  }

  Future<void> _enterEditMode() async {
    setState(() { _editMode = true; _brushMode = 'erase'; });
    try {
      await _arService.enterCutMode(0);
      await _arService.setBrushMode('erase');
    } catch (e) { _log('Edit error: $e'); }
  }

  Future<void> _exitEditMode() async {
    setState(() => _editMode = false);
    try { await _arService.exitCutMode(); } catch (e) { _log('Exit error: $e'); }
  }

  Future<void> _setBrushMode(String mode) async {
    setState(() => _brushMode = mode);
    try { await _arService.setBrushMode(mode); } catch (e) { _log('Brush error: $e'); }
  }

  Future<void> _setBrushSize(double size) async {
    setState(() => _brushSize = size);
    try {
      await _arService.setBrushSize(size);
    } catch (e) { _log('Size error: $e'); }
  }

  Future<void> _undoSelection() async {
    try { await _arService.undoCut(0); } catch (e) { _log('Undo error: $e'); }
  }

  Future<void> _resetSelection() async {
    try { await _arService.clearAllCuts(0); } catch (e) { _log('Reset error: $e'); }
  }

  Future<void> _applyWallpaper() async {
    if (widget.wallpaper == null) return;
    try {
      await _arService.placeWallpaper(
        wallpaper: widget.wallpaper!,
        wallIndex: 0,
        pricePerRoll: widget.pricePerRoll,
      );
    } catch (e) { _log('Apply error: $e'); }
  }

  Future<void> _clearWallpaper() async {
    try {
      await _arService.clearWall(0);
      setState(() => _wallpaperApplied = false);
    } catch (e) { _log('Clear error: $e'); }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _arService.disposeAR();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // AR View
          Positioned.fill(
            child: UiKitView(
              viewType: 'com.oboia/ar_view',
              creationParams: const <String, dynamic>{},
              creationParamsCodec: StandardMessageCodec(),  // ← removed const
            ),
          ),

          // Back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8, left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 24),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // ─── SCANNING ─────────────────────────────────
          if (_isScanning) ...[
            Positioned(
              top: MediaQuery.of(context).padding.top + 8, left: 60, right: 60,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('Scan the walls you want\nto wallpaper',
                  style: TextStyle(color: Colors.black87, fontSize: 15, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center),
              ),
            ),
            Positioned(
              bottom: 100, left: 20, right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(_statusText, style: const TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            Positioned(
              bottom: 30, left: 40, right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: goldColor, padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                onPressed: _stopScan,
                child: const Text('Done Scanning', style: TextStyle(fontSize: 18, color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ),
          ],

          // ─── EDIT MODE: Floating Toolbar ──────────────
          if (_scanDone && _editMode) ...[
            // Instruction
            Positioned(
              top: MediaQuery.of(context).padding.top + 8, left: 50, right: 50,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(10)),
                child: Text(
                  _brushMode == 'erase'
                      ? 'Rub finger to remove unwanted areas'
                      : 'Rub finger to add missing areas',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center),
              ),
            ),

            // Toolbar
            Positioned(
              bottom: 140, left: 16, right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xE6222222),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // Tool buttons row
                  Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _toolBtn(Icons.brush, 'Paint', _brushMode == 'paint', () => _setBrushMode('paint')),
                    _toolBtn(Icons.auto_fix_high, 'Erase', _brushMode == 'erase', () => _setBrushMode('erase')),
                    _toolBtn(Icons.undo, 'Undo', false, _undoSelection),
                    _toolBtn(Icons.restart_alt, 'Reset', false, _resetSelection),
                  ]),
                  const SizedBox(height: 10),
                  // Brush size slider
                  Row(children: [
                    const Icon(Icons.circle, color: Colors.white38, size: 10),
                    Expanded(
                      child: Slider(
                        value: _brushSize,
                        min: 0.02, max: 0.25,
                        activeColor: goldColor,
                        inactiveColor: Colors.white24,
                        onChanged: (v) => _setBrushSize(v),
                      ),
                    ),
                    const Icon(Icons.circle, color: Colors.white38, size: 22),
                  ]),
                  // Area display
                  Text('Selected: ${_totalWallArea.toStringAsFixed(1)} m²',
                    style: const TextStyle(color: goldColor, fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),

            // Apply wallpaper button
            if (widget.wallpaper != null)
              Positioned(
                bottom: 30, left: 40, right: 40,
                child: Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: goldColor,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      onPressed: _applyWallpaper,
                      icon: const Icon(Icons.wallpaper, color: Colors.black, size: 20),
                      label: const Text('Apply Wallpaper', style: TextStyle(fontSize: 15, color: Colors.black, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ]),
              ),
          ],

          // ─── POST-APPLY: Summary ──────────────────────
          if (_scanDone && _wallpaperApplied && !_editMode) ...[
            // Wallpaper name
            if (widget.wallpaper != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8, right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(widget.wallpaper!.name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                    Text('${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll', style: const TextStyle(color: goldColor, fontSize: 11)),
                  ]),
                ),
              ),

            // Bottom summary
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
                decoration: const BoxDecoration(
                  color: Color(0xF0222222),
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 16),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                    _statCol('Wall Area', '${_totalWallArea.toStringAsFixed(1)} m²'),
                    _statCol('Rolls', '$_rollsNeeded'),
                    _statCol('Total', '${_totalPrice.toStringAsFixed(0)} UZS'),
                  ]),
                  const SizedBox(height: 16),
                  // Action buttons
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: goldColor,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: _enterEditMode,
                        icon: const Icon(Icons.edit, color: Colors.black, size: 18),
                        label: const Text('Edit Selection', style: TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: _clearWallpaper,
                        icon: const Icon(Icons.visibility_off, color: Colors.white70, size: 18),
                        label: const Text('Clear', style: TextStyle(color: Colors.white70, fontSize: 14)),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _startScan,
                    icon: const Icon(Icons.replay, color: Colors.white38, size: 16),
                    label: const Text('Rescan Room', style: TextStyle(color: Colors.white38, fontSize: 13)),
                  ),
                ]),
              ),
            ),
          ],

          // ─── POST-SCAN, no wallpaper yet, not editing ─
          if (_scanDone && !_wallpaperApplied && !_editMode)
            Positioned(
              bottom: 30, left: 40, right: 40,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${_totalWallArea.toStringAsFixed(1)} m² selected',
                  style: const TextStyle(color: goldColor, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: goldColor,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      onPressed: _enterEditMode,
                      icon: const Icon(Icons.edit, color: Colors.black),
                      label: const Text('Edit', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  if (widget.wallpaper != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        onPressed: _applyWallpaper,
                        icon: const Icon(Icons.wallpaper, color: Colors.white),
                        label: const Text('Apply', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ]),
              ]),
            ),

          // ─── DEBUG LOG (double tap status to toggle) ──
          if (!_isScanning && _showLog)
            Positioned(
              top: MediaQuery.of(context).padding.top + 50, left: 8, right: 8,
              child: IgnorePointer(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(6), color: Colors.black87,
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: _logLines.take(12).map((l) => Text(l,
                        style: const TextStyle(color: Colors.white70, fontSize: 9),
                        maxLines: 2, overflow: TextOverflow.ellipsis)).toList()),
                  ),
                ),
              ),
            ),

          // Status bar (double-tap to show log)
          if (!_isScanning)
            Positioned(
              top: MediaQuery.of(context).padding.top + 44, left: 50, right: 50,
              child: GestureDetector(
                onDoubleTap: () => setState(() => _showLog = !_showLog),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: Text(_statusText, style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                    textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: !_isScanning && !_scanDone
          ? FloatingActionButton.extended(
              onPressed: _startScan, backgroundColor: goldColor,
              icon: const Icon(Icons.camera, color: Colors.black),
              label: const Text('Start Scan', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            )
          : null,
    );
  }

  Widget _toolBtn(IconData icon, String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? goldColor.withOpacity(0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: active ? Border.all(color: goldColor, width: 1.5) : null,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: active ? goldColor : Colors.white60, size: 22),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: active ? goldColor : Colors.white60, fontSize: 10, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }

  Widget _statCol(String label, String value) {
    return Column(children: [
      Text(value, style: const TextStyle(color: goldColor, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ]);
  }
}
