// lib/screens/ar/ar_screen.dart — MESH SCAN UI v2 (AUDITED)
// Clean UI for LiDAR mesh wireframe + wallpaper application

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
  int _scanEventCount = 0;

  bool _isScanning = false;
  bool _hasSnapshot = false;
  bool _showDebugLog = false;
  List<DetectedSurface> _scannedSurfaces = [];
  int? _currentWallIndex;

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
    if (event.type == 'boot') {
      final msg = (event.data['status'] ?? 'boot').toString();
      _log('[BOOT] $msg');
      setState(() => _statusText = msg);
    } else if (event.type == 'error') {
      final msg = event.errorMessage ?? 'Unknown error';
      _log('[ERROR] $msg');
      setState(() => _statusText = 'ERROR: $msg');
    } else if (event.type == 'scanUpdate') {
      _scanEventCount++;
      final dataStr = event.data['data'] as String? ?? '';
      if (dataStr.isNotEmpty) {
        try {
          final Map<String, dynamic> json = jsonDecode(dataStr);
          final List<dynamic> surfaceList = json['surfaces'] ?? [];
          setState(() {
            _scannedSurfaces = surfaceList
                .map((e) => DetectedSurface.fromJson(e as Map<String, dynamic>))
                .toList();
          });
          _log('[SCAN] ${_scannedSurfaces.length} surfaces');
        } catch (e) {
          _log('[SCAN] parse error: $e');
        }
      }
    } else if (event.type == 'scanComplete') {
      setState(() { _isScanning = false; _hasSnapshot = true; });
      _log('[COMPLETE] ${_scannedSurfaces.length} surfaces');
      // Auto-apply wallpaper if selected
      if (widget.wallpaper != null && _scannedSurfaces.isNotEmpty) {
        _applyWallpaper();
      }
    } else if (event.type == 'wallpaperPlaced') {
      final success = event.data['success'] as bool? ?? false;
      _log('[PLACE] success=$success');
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wallpaper applied!'), duration: Duration(seconds: 2)),
        );
      }
    } else if (event.type == 'scanInstruction') {
      _log('[INSTRUCTION] ${event.data['instruction']}');
    } else if (event.type == 'wallDetected') {
      // Suppress spam
    } else {
      _log('[${event.type}] ${event.data}');
    }
  }

  Future<void> _applyWallpaper() async {
    if (widget.wallpaper == null) return;
    _log('Applying wallpaper...');
    try {
      await _arService.placeWallpaper(
        wallpaper: widget.wallpaper!,
        wallIndex: 0,
        pricePerRoll: widget.pricePerRoll,
      );
    } catch (e) {
      _log('placeWallpaper error: $e');
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _hasSnapshot = false;
      _scannedSurfaces.clear();
      _scanEventCount = 0;
    });

    _log('DART: setARMode(scanning)...');
    try {
      await _arService.setARMode('scanning');
      _log('DART: setARMode OK ✅');
    } catch (e) {
      _log('DART: setARMode THREW: $e');
    }

    _log('DART: startScan()...');
    try {
      await _arService.startScan();
      _log('DART: startScan OK ✅');
    } catch (e) {
      _log('DART: startScan THREW: $e');
    }
  }

  Future<void> _stopScan() async {
    _log('DART: stopScan()...');
    try {
      await _arService.stopScan();
      _log('DART: stopScan OK');
    } catch (e) {
      _log('DART: stopScan THREW: $e');
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _arService.disposeAR();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wallCount = _scannedSurfaces.where((s) => s.type == 'wall').length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera + AR view
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
          // SCANNING: Instruction banner (like competitor)
          // ═══════════════════════════════════════════════
          if (_isScanning)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 60, right: 60,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Scan the walls you want\nto wallpaper',
                  style: const TextStyle(color: Colors.black87, fontSize: 15, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

          // SCANNING: Status + Done button
          if (_isScanning) ...[
            // Status pill
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
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                ),
                onPressed: _stopScan,
                child: const Text('Done Scanning', style: TextStyle(fontSize: 18, color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ),
          ],

          // ═══════════════════════════════════════════════
          // POST-SCAN: Wall cards + Apply button
          // ═══════════════════════════════════════════════
          if (_hasSnapshot && !_isScanning) ...[
            if (_scannedSurfaces.isNotEmpty)
              Positioned(
                bottom: 80, left: 8, right: 8,
                child: SizedBox(
                  height: 110,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _scannedSurfaces.length,
                    itemBuilder: (context, index) {
                      final s = _scannedSurfaces[index];
                      if (s.type != 'wall') return const SizedBox.shrink();
                      return Container(
                        width: 120, margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: goldColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: goldColor),
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text('Wall ${index + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 4),
                          Text('${s.width.toStringAsFixed(1)}×${s.height.toStringAsFixed(1)}m', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          Text('${s.area.toStringAsFixed(1)} m²', style: const TextStyle(color: goldColor, fontSize: 12, fontWeight: FontWeight.bold)),
                        ]),
                      );
                    },
                  ),
                ),
              ),
            if (widget.wallpaper != null)
              Positioned(
                bottom: 20, left: 40, right: 40,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: goldColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  onPressed: _applyWallpaper,
                  child: const Text('Apply Wallpaper', style: TextStyle(fontSize: 16, color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ),
          ],

          // Wallpaper info (top right, when not scanning)
          if (widget.wallpaper != null && !_isScanning)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(widget.wallpaper!.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  Text('${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll', style: const TextStyle(color: goldColor, fontSize: 10)),
                ]),
              ),
            ),

          // ═══════════════════════════════════════════════
          // DEBUG LOG (tap anywhere on status to toggle)
          // ═══════════════════════════════════════════════
          if (!_isScanning && !_hasSnapshot)
            Positioned(
              top: MediaQuery.of(context).padding.top + 44,
              left: 8, right: 8,
              child: GestureDetector(
                onDoubleTap: () => setState(() => _showDebugLog = !_showDebugLog),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  color: Colors.black54,
                  child: Text('Status: $_statusText', style: const TextStyle(color: Colors.greenAccent, fontSize: 10)),
                ),
              ),
            ),

          if (_showDebugLog)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 8, right: 8,
              child: IgnorePointer(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(6),
                  color: Colors.black87,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _logLines.take(15).map((l) => Text(l, style: const TextStyle(color: Colors.white70, fontSize: 9), maxLines: 2, overflow: TextOverflow.ellipsis)).toList(),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: !_isScanning && !_hasSnapshot
          ? FloatingActionButton.extended(
              onPressed: _startScan,
              backgroundColor: goldColor,
              icon: const Icon(Icons.camera, color: Colors.black),
              label: const Text('Start Scan', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            )
          : null,
    );
  }
}

class DetectedSurface {
  final String id, type;
  final double width, height, area;
  final bool excluded;
  DetectedSurface({required this.id, required this.type, required this.width, required this.height, required this.area, this.excluded = false});
  factory DetectedSurface.fromJson(Map<String, dynamic> json) => DetectedSurface(
    id: json['id'] as String? ?? '',
    type: json['type'] as String? ?? 'unknown',
    width: (json['width'] as num?)?.toDouble() ?? 0.0,
    height: (json['height'] as num?)?.toDouble() ?? 0.0,
    area: (json['area'] as num?)?.toDouble() ?? 0.0,
    excluded: json['excluded'] as bool? ?? false,
  );
}
