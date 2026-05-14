// lib/screens/ar/ar_screen.dart — DIAGNOSTIC VERSION v2
// Shows scrollable log of all native events

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

  String _nativeStatus = "Initializing...";
  final List<String> _logLines = [];
  int _scanEventCount = 0;

  bool _isScanning = false;
  bool _hasSnapshot = false;
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
      _addLog('Init error: $e');
      setState(() => _nativeStatus = 'Init error: $e');
    }
    _eventSub = _arService.events.listen(_onAREvent);
  }

  void _addLog(String msg) {
    _logLines.insert(0, '[${DateTime.now().toString().substring(11, 19)}] $msg');
    if (_logLines.length > 25) _logLines.removeLast();
  }

  void _onAREvent(AREvent event) {
    if (event.type == 'boot') {
      final msg = event.data['status'] ?? 'boot';
      setState(() {
        _nativeStatus = msg.toString();
        _addLog('[BOOT] $msg');
      });
    } else if (event.type == 'error') {
      final msg = event.errorMessage ?? 'Unknown error';
      setState(() {
        _nativeStatus = 'ERROR: $msg';
        _addLog('[ERROR] $msg');
      });
    } else if (event.type == 'scanUpdate') {
      setState(() => _scanEventCount++);
      _addLog('[SCAN] event #$_scanEventCount');
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
          _addLog('[SCAN] ${_scannedSurfaces.length} surfaces parsed');
        } catch (e) {
          _addLog('[SCAN] parse error: $e');
        }
      }
    } else if (event.type == 'scanComplete') {
      setState(() { _isScanning = false; _hasSnapshot = true; });
      _addLog('[COMPLETE] ${_scannedSurfaces.length} surfaces');
      if (widget.wallpaper != null) {
        for (int i = 0; i < _scannedSurfaces.length; i++) {
          final s = _scannedSurfaces[i];
          if (!s.excluded && s.type == 'wall') {
            _arService.placeWallpaper(
              wallpaper: widget.wallpaper!,
              wallIndex: i,
              pricePerRoll: widget.pricePerRoll,
            );
          }
        }
      }
    } else if (event.type == 'wallpaperPlaced') {
      final success = event.data['success'] as bool? ?? false;
      _addLog('[PLACE] wall ${event.wallIndex} success=$success');
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Wallpaper applied to wall ${event.wallIndex}')),
        );
      }
    } else if (event.type == 'scanInstruction') {
      final instruction = event.data['instruction'] ?? '';
      _addLog('[INSTRUCTION] $instruction');
    } else if (event.type == 'arModeChanged') {
      _addLog('[MODE] ${event.data['mode']}');
    } else {
      _addLog('[${event.type}] ${event.data}');
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _hasSnapshot = false;
      _scannedSurfaces.clear();
      _scanEventCount = 0;
    });
    _addLog('Dart: calling setARMode(scanning)...');
    await _arService.setARMode('scanning');
    _addLog('Dart: calling startScan()...');
    await _arService.startScan();
    _addLog('Dart: startScan() returned');
  }

  Future<void> _stopScan() async { await _arService.stopScan(); }
  void _toggleSurfaceExclusion(String id) { _arService.toggleSurfaceExclusion(id); }
  void _enterEraserMode(int wallIndex) {
    setState(() => _currentWallIndex = wallIndex);
    _arService.selectWall(wallIndex);
    _arService.enterCutMode(wallIndex);
  }
  void _exitEraserMode() {
    setState(() => _currentWallIndex = null);
    _arService.exitCutMode();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _arService.disposeAR();
    super.dispose();
  }

  Widget _buildCameraView() {
    return Positioned.fill(
      child: UiKitView(
        viewType: 'com.oboia/ar_view',
        creationParams: const <String, dynamic>{},
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildCameraView(),

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

          // ═══════════════════════════════════════════════════════
          // DIAGNOSTIC LOG — shows last 25 messages from native
          // ═══════════════════════════════════════════════════════
          Positioned(
            top: MediaQuery.of(context).padding.top + 44,
            left: 8, right: 8,
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 200),
                padding: const EdgeInsets.all(6),
                color: Colors.black87,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Status: $_nativeStatus',
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Scan events: $_scanEventCount | Surfaces: ${_scannedSurfaces.length}',
                        style: const TextStyle(color: Colors.yellowAccent, fontSize: 10),
                      ),
                      const Divider(color: Colors.white24, height: 8),
                      ..._logLines.take(15).map((line) => Text(
                        line,
                        style: const TextStyle(color: Colors.white70, fontSize: 9),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      )),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Wallpaper info
          if (widget.wallpaper != null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 12, 12, 12),
                child: Row(children: [
                  const Spacer(),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(widget.wallpaper!.name, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    Text('${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll', style: const TextStyle(color: goldColor, fontSize: 11)),
                  ]),
                ]),
              ),
            ),

          // Scanning UI
          if (_isScanning) ...[
            Positioned(
              bottom: 180,
              left: 20, right: 20,
              child: Text(
                _scannedSurfaces.isEmpty
                    ? 'Move slowly around the room...'
                    : '${_scannedSurfaces.where((s) => s.type == "wall").length} walls detected',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            Positioned(
              bottom: 80, left: 0, right: 0,
              child: SizedBox(
                height: 100,
                child: ListView.builder(
                  itemCount: _scannedSurfaces.length,
                  itemBuilder: (context, index) {
                    final s = _scannedSurfaces[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(_iconForType(s.type), color: s.excluded ? Colors.grey : goldColor, size: 20),
                      title: Text('${s.type} ${index+1}', style: TextStyle(color: s.excluded ? Colors.grey : Colors.white, fontSize: 13)),
                      subtitle: Text('${s.width.toStringAsFixed(1)}×${s.height.toStringAsFixed(1)}m | ${s.area.toStringAsFixed(1)}m²', style: const TextStyle(color: Colors.white70, fontSize: 10)),
                      trailing: Switch(value: !s.excluded, onChanged: (_) => _toggleSurfaceExclusion(s.id), activeColor: goldColor),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              bottom: 20, left: 40, right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: goldColor, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                onPressed: _stopScan,
                child: const Text('Done Scanning', style: TextStyle(fontSize: 18, color: Colors.black)),
              ),
            ),
          ],

          // Post-scan wall cards
          if (_hasSnapshot && !_isScanning)
            Positioned(
              bottom: 20, left: 8, right: 8,
              child: SizedBox(
                height: 150,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _scannedSurfaces.length,
                  itemBuilder: (context, index) {
                    final s = _scannedSurfaces[index];
                    if (s.type != 'wall' || s.excluded) return const SizedBox.shrink();
                    return GestureDetector(
                      onTap: () => _enterEraserMode(index),
                      child: Container(
                        width: 130, margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(color: goldColor.withOpacity(0.2), borderRadius: BorderRadius.circular(12), border: Border.all(color: goldColor)),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text('Wall ${index+1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                          Text('${s.width.toStringAsFixed(1)}×${s.height.toStringAsFixed(1)}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          Text('${s.area.toStringAsFixed(1)} m²', style: const TextStyle(color: goldColor, fontSize: 12, fontWeight: FontWeight.bold)),
                          IconButton(icon: const Icon(Icons.brush, color: Colors.white70, size: 20), onPressed: () => _enterEraserMode(index), padding: EdgeInsets.zero),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ),

          // Eraser exit button
          if (_currentWallIndex != null)
            Positioned(
              bottom: 20, left: 40, right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, padding: const EdgeInsets.symmetric(vertical: 12)),
                onPressed: _exitEraserMode,
                child: const Text('Exit Eraser', style: TextStyle(color: Colors.white)),
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

  IconData _iconForType(String type) {
    switch (type) {
      case 'wall': return Icons.dashboard;
      case 'door': return Icons.door_front_door;
      case 'window': return Icons.window;
      case 'opening': return Icons.arrow_right_alt;
      default: return Icons.help_outline;
    }
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
