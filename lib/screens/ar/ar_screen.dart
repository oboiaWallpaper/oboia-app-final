// lib/screens/ar/ar_screen.dart — PHASE A
// Total wall area from mesh, auto-apply wallpaper, rolls + price

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/ar_service.dart';
import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';

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

  String _statusText = "Initializing...";
  final List<String> _logLines = [];

  bool _isScanning = false;
  bool _scanDone = false;
  bool _wallpaperApplied = false;

  double _totalWallArea = 0.0;
  int _meshSegments = 0;

  @override
  void initState() {
    super.initState();
    _initAR();
  }

  Future<void> _initAR() async {
    try {
      await Future.delayed(const Duration(milliseconds: 1200));
      await _arService.initAR();
    } catch (e) {
      _log('Init error: $e');
    }
    _eventSub = _arService.events.listen(_onAREvent);
  }

  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      _logLines.insert(0, '[${DateTime.now().toString().substring(11, 19)}] $msg');
      if (_logLines.length > 30) _logLines.removeLast();
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
        // Extract total wall area from mesh calculation
        final area = event.data['totalWallArea'];
        final segs = event.data['meshSegments'];
        setState(() {
          _isScanning = false;
          _scanDone = true;
          if (area is num) _totalWallArea = area.toDouble();
          if (segs is num) _meshSegments = segs.toInt();
        });
        _log('[DONE] ${_totalWallArea.toStringAsFixed(1)} m², $_meshSegments mesh');

        // Auto-apply wallpaper if selected
        if (widget.wallpaper != null) {
          _applyWallpaper();
        }
        break;

      case 'wallpaperPlaced':
        final ok = event.data['success'] as bool? ?? false;
        if (ok) {
          setState(() => _wallpaperApplied = true);
          _log('[WALLPAPER] Applied ✅');
        } else {
          final msg = event.data['message'] ?? 'Failed';
          _log('[WALLPAPER] Failed: $msg');
        }
        break;

      case 'wallDetected':
        break; // suppress

      default:
        _log('[${event.type}] ${event.data}');
    }
  }

  // ── Roll calculation ───────────────────────────────────────

  double get _rollWidth => widget.wallpaper?.rollWidth ?? 0.53;
  double get _rollLength => widget.wallpaper?.rollLength ?? 10.0;
  double get _rollArea => _rollWidth * _rollLength;
  int get _rollsNeeded => _rollArea > 0 ? (_totalWallArea / _rollArea).ceil() : 0;
  double get _totalPrice => _rollsNeeded * widget.pricePerRoll;

  // ── Actions ────────────────────────────────────────────────

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _scanDone = false;
      _wallpaperApplied = false;
      _totalWallArea = 0;
      _meshSegments = 0;
    });
    try {
      await _arService.setARMode('scanning');
      await _arService.startScan();
      _log('Scan started');
    } catch (e) {
      _log('startScan error: $e');
    }
  }

  Future<void> _stopScan() async {
    try {
      await _arService.stopScan();
    } catch (e) {
      _log('stopScan error: $e');
    }
  }

  Future<void> _applyWallpaper() async {
    if (widget.wallpaper == null) return;
    setState(() => _statusText = 'Applying wallpaper...');
    try {
      await _arService.placeWallpaper(
        wallpaper: widget.wallpaper!,
        wallIndex: 0,
        pricePerRoll: widget.pricePerRoll,
      );
    } catch (e) {
      _log('Apply error: $e');
    }
  }

  Future<void> _clearWallpaper() async {
    try {
      await _arService.clearWall(0);
      setState(() => _wallpaperApplied = false);
    } catch (e) {
      _log('Clear error: $e');
    }
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
          // AR Camera View
          Positioned.fill(
            child: UiKitView(
              viewType: 'com.oboia/ar_view',
              creationParams: const <String, dynamic>{},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),

          // Back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 24),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // ═══════════════════════════════════════════════
          // SCANNING PHASE
          // ═══════════════════════════════════════════════
          if (_isScanning) ...[
            // Top instruction banner
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 60, right: 60,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
                ),
                child: const Text(
                  'Scan the walls you want\nto wallpaper',
                  style: TextStyle(color: Colors.black87, fontSize: 15, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            // Bottom status
            Positioned(
              bottom: 100, left: 20, right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _statusText,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // Done button
            Positioned(
              bottom: 30, left: 40, right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: goldColor,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  elevation: 4,
                ),
                onPressed: _stopScan,
                child: const Text('Done Scanning', style: TextStyle(fontSize: 18, color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ),
          ],

          // ═══════════════════════════════════════════════
          // POST-SCAN PHASE
          // ═══════════════════════════════════════════════
          if (_scanDone && !_isScanning) ...[
            // Wallpaper name (top right)
            if (widget.wallpaper != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(widget.wallpaper!.name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                    Text('${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll', style: const TextStyle(color: goldColor, fontSize: 11)),
                  ]),
                ),
              ),

            // Bottom summary card
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
                decoration: const BoxDecoration(
                  color: Color(0xF0222222),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(24),
                    topRight: Radius.circular(24),
                  ),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // Drag handle
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 16),

                  // Stats row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statColumn('Wall Area', '${_totalWallArea.toStringAsFixed(1)} m²'),
                      _statColumn('Rolls', '$_rollsNeeded'),
                      _statColumn('Total', '${_totalPrice.toStringAsFixed(0)} UZS'),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Action buttons
                  if (!_wallpaperApplied && widget.wallpaper != null)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: goldColor,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _applyWallpaper,
                        child: const Text('Apply Wallpaper', style: TextStyle(fontSize: 16, color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
                    ),

                  if (_wallpaperApplied) ...[
                    // Applied state — show change/clear/rescan options
                    Row(children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: goldColor,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _applyWallpaper,
                          icon: const Icon(Icons.refresh, color: Colors.black, size: 18),
                          label: const Text('Change', style: TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white38),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _clearWallpaper,
                          icon: const Icon(Icons.visibility_off, color: Colors.white70, size: 18),
                          label: const Text('Clear', style: TextStyle(color: Colors.white70, fontSize: 14)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    // Rescan button
                    TextButton.icon(
                      onPressed: _startScan,
                      icon: const Icon(Icons.replay, color: Colors.white38, size: 16),
                      label: const Text('Rescan Room', style: TextStyle(color: Colors.white38, fontSize: 13)),
                    ),
                  ],
                ]),
              ),
            ),
          ],

          // ═══════════════════════════════════════════════
          // IDLE: Status + Start Scan button
          // ═══════════════════════════════════════════════
          if (!_isScanning && !_scanDone)
            Positioned(
              top: MediaQuery.of(context).padding.top + 48,
              left: 12, right: 12,
              child: Container(
                padding: const EdgeInsets.all(6),
                color: Colors.black45,
                child: Text(
                  _statusText,
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: !_isScanning && !_scanDone
          ? FloatingActionButton.extended(
              onPressed: _startScan,
              backgroundColor: goldColor,
              icon: const Icon(Icons.camera, color: Colors.black),
              label: const Text('Start Scan', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            )
          : null,
    );
  }

  Widget _statColumn(String label, String value) {
    return Column(children: [
      Text(value, style: const TextStyle(color: goldColor, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ]);
  }
}
