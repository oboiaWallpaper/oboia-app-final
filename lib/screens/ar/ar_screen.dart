// lib/screens/ar/ar_screen.dart
// OBOIA – AR Screen (no external permission_handler)

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/ar_service.dart';
import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';

const Color goldColor = Color(0xFFFFD369);

class ARScreen extends StatefulWidget {
  final WallpaperModel wallpaper;
  final double pricePerRoll;

  ARScreen({
    super.key,
    WallpaperModel? initialWallpaper,
    ShopModel? initialShop,
    double? pricePerRoll,
  }) : assert(initialWallpaper != null, 'A wallpaper must be provided'),
       wallpaper = initialWallpaper!,
       pricePerRoll = pricePerRoll ?? 0.0;

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  final ARService _arService = ARService.instance;
  StreamSubscription<AREvent>? _eventSub;

  // State
  bool _arInitialized = false;
  String _nativeStatus = "Initializing...";
  List<String> _logLines = [];

  bool _isScanning = false;
  bool _hasSnapshot = false;
  List<DetectedSurface> _scannedSurfaces = [];
  List<DetectedObject> _scannedObjects = [];
  int? _currentWallIndex;

  @override
  void initState() {
    super.initState();
    _initAR();
  }

  // FIX 3: Added 1200ms delay so native view is registered before initAR()
  Future<void> _initAR() async {
    try {
      await Future.delayed(const Duration(milliseconds: 1200));
      await _arService.initAR();
      setState(() => _arInitialized = true);
    } catch (e) {
      setState(() => _nativeStatus = "AR init failed: $e");
      _logLines.add('[ERROR] AR init failed: $e');
    }
    _eventSub = _arService.events.listen(_onAREvent);
  }

  void _onAREvent(AREvent event) {
    if (event.type == 'boot') {
      final msg = event.data['status'] ?? 'boot';
      setState(() {
        _nativeStatus = msg.toString();
        _logLines.add('[BOOT] $msg');
        if (_logLines.length > 20) _logLines.removeAt(0);
      });
      return;
    }
    if (event.type == 'error') {
      final msg = event.errorMessage ?? 'Unknown error';
      setState(() {
        _nativeStatus = 'ERROR: $msg';
        _logLines.add('[ERROR] $msg');
        if (_logLines.length > 20) _logLines.removeAt(0);
      });
      return;
    }
    if (event.type == 'scanUpdate') {
      final dataStr = event.data['data'] as String? ?? '';
      if (dataStr.isNotEmpty) {
        try {
          final Map<String, dynamic> json = jsonDecode(dataStr);
          final List<dynamic> surfaceList = json['surfaces'] ?? [];
          final List<dynamic> objectList = json['objects'] ?? [];
          setState(() {
            _scannedSurfaces = surfaceList.map((e) => DetectedSurface.fromJson(e)).toList();
            _scannedObjects = objectList.map((e) => DetectedObject.fromJson(e)).toList();
          });
        } catch (_) {}
      }
    } else if (event.type == 'scanComplete') {
      setState(() {
        _isScanning = false;
        _hasSnapshot = true;
      });
      // Auto-apply wallpaper to all non-excluded walls
      for (int i = 0; i < _scannedSurfaces.length; i++) {
        if (!_scannedSurfaces[i].excluded && _scannedSurfaces[i].type == 'wall') {
          _arService.placeWallpaper(
            wallpaper: widget.wallpaper,
            wallIndex: i,
            pricePerRoll: widget.pricePerRoll,
          );
        }
      }
    } else if (event.type == 'wallpaperPlaced') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wallpaper applied to wall ${event.wallIndex}')),
      );
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _hasSnapshot = false;
      _scannedSurfaces.clear();
      _scannedObjects.clear();
    });
    await _arService.setARMode('scanning');
    await _arService.startScan();
  }

  Future<void> _stopScan() async {
    await _arService.stopScan();
  }

  void _toggleSurfaceExclusion(String id) {
    _arService.toggleSurfaceExclusion(id);
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // FIX 2: was Colors.transparent — caused black flash / rendering artifacts
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // AR Camera View
          // FIX 1: removed const on Positioned.fill — UiKitView cannot be const
          Positioned.fill(
            child: UiKitView(
              viewType: 'com.oboia/ar_view',
              creationParams: const <String, dynamic>{},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),

          // Status overlay – always visible
          Positioned(
            top: 40,
            left: 10,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.75,
              padding: const EdgeInsets.all(8),
              color: Colors.black54,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Status: $_nativeStatus',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  if (_logLines.isNotEmpty)
                    ...(_logLines.map((line) => Text(line, style: const TextStyle(color: Colors.white70, fontSize: 10)))),
                ],
              ),
            ),
          ),

          // Top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(widget.wallpaper.name,
                          style: const TextStyle(color: Colors.white, fontSize: 16)),
                      Text('${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll',
                          style: const TextStyle(color: goldColor, fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Scanning overlay
          if (_isScanning) ...[
            const Positioned(
              top: 80,
              left: 20,
              right: 20,
              child: Text(
                'Move slowly around the room...',
                style: TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
            Positioned(
              bottom: 140,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 200,
                child: ListView.builder(
                  itemCount: _scannedSurfaces.length,
                  itemBuilder: (context, index) {
                    final surface = _scannedSurfaces[index];
                    final excluded = surface.excluded;
                    return ListTile(
                      leading: Icon(_iconForType(surface.type), color: excluded ? Colors.grey : goldColor),
                      title: Text('${surface.type} ${index + 1}', style: TextStyle(color: excluded ? Colors.grey : Colors.white)),
                      subtitle: Text('${surface.width.toStringAsFixed(1)} × ${surface.height.toStringAsFixed(1)} m²', style: const TextStyle(color: Colors.white70)),
                      trailing: Switch(value: !excluded, onChanged: (_) => _toggleSurfaceExclusion(surface.id), activeColor: goldColor),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              bottom: 50,
              left: 40,
              right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: goldColor),
                onPressed: _stopScan,
                child: const Text('Done Scanning'),
              ),
            ),
          ],

          // Post‑scan wall cards
          if (_hasSnapshot && !_isScanning)
            Positioned(
              bottom: 30,
              left: 10,
              right: 10,
              child: SizedBox(
                height: 160,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _scannedSurfaces.length,
                  itemBuilder: (context, index) {
                    final surface = _scannedSurfaces[index];
                    if (surface.type != 'wall') return const SizedBox.shrink();
                    return GestureDetector(
                      onTap: () => _enterEraserMode(index),
                      child: Container(
                        width: 140,
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: goldColor.withOpacity(0.2), borderRadius: BorderRadius.circular(12), border: Border.all(color: goldColor)),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Wall ${index + 1}', style: const TextStyle(color: Colors.white)),
                            Text('${surface.width.toStringAsFixed(1)} × ${surface.height.toStringAsFixed(1)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            Text('${surface.area.toStringAsFixed(1)} m²', style: const TextStyle(color: goldColor, fontSize: 12)),
                            IconButton(icon: const Icon(Icons.brush, color: Colors.white70), onPressed: () => _enterEraserMode(index)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

          if (_currentWallIndex != null)
            Positioned(
              bottom: 10,
              left: 40,
              right: 40,
              child: ElevatedButton(onPressed: _exitEraserMode, child: const Text('Exit Eraser')),
            ),
        ],
      ),
      floatingActionButton: !_isScanning && !_hasSnapshot
          ? FloatingActionButton.extended(
              onPressed: _startScan,
              backgroundColor: goldColor,
              label: const Text('Start Scan', style: TextStyle(color: Colors.black)),
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
  final String id;
  final String type;
  final double width;
  final double height;
  final double area;
  final bool excluded;
  DetectedSurface({required this.id, required this.type, required this.width, required this.height, required this.area, this.excluded = false});
  factory DetectedSurface.fromJson(Map<String, dynamic> json) => DetectedSurface(
    id: json['id'] as String,
    type: json['type'] as String,
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    area: (json['area'] as num).toDouble(),
    excluded: json['excluded'] as bool? ?? false,
  );
}

class DetectedObject {
  final String id;
  final String type;
  final bool excluded;
  DetectedObject({required this.id, required this.type, this.excluded = false});
  factory DetectedObject.fromJson(Map<String, dynamic> json) => DetectedObject(
    id: json['id'] as String,
    type: json['type'] as String,
    excluded: json['excluded'] as bool? ?? false,
  );
}
