// lib/screens/ar/ar_screen.dart
// OBOIA – AR Screen with in‑line scanning & wallpaper placement
// Camera always visible; scan UI overlays; eraser available after walls detected.

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
  bool _isScanning = false;
  bool _hasSnapshot = false;
  List<DetectedSurface> _scannedSurfaces = [];
  List<DetectedObject> _scannedObjects = [];

  int? _currentWallIndex;

  /// Collect error messages from native to display on screen
  final List<String> _errorMessages = [];

  @override
  void initState() {
    super.initState();
    _initAR();
  }

  Future<void> _initAR() async {
    await _arService.initAR();
    _eventSub = _arService.events.listen(_onAREvent);
  }

  void _onAREvent(AREvent event) {
    if (event.type == 'error') {
      final msg = event.errorMessage ?? 'Unknown native error';
      _errorMessages.add('[${DateTime.now().toString().substring(11,19)}] $msg');
      if (_errorMessages.length > 20) _errorMessages.removeAt(0);
      setState(() {});
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
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Native AR view – fill the entire screen
          const Positioned.fill(
            child: UiKitView(
              viewType: 'com.oboia/ar_view',
              creationParams: <String, dynamic>{},
              creationParamsCodec: StandardMessageCodec(),
            ),
          ),

          // Debug error overlay (top left)
          if (_errorMessages.isNotEmpty)
            Positioned(
              top: 60,
              left: 10,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.6,
                padding: const EdgeInsets.all(8),
                color: Colors.black54,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _errorMessages.map((msg) => Text(msg, style: const TextStyle(color: Colors.red, fontSize: 10))).toList(),
                ),
              ),
            ),

          // Top bar with wallpaper info and back button
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

          // SCANNING OVERLAY
          if (_isScanning) ...[
            const Positioned(
              top: 80,
              left: 20,
              right: 20,
              child: Text(
                'Move your device slowly around the room...',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
                      leading: Icon(
                        _iconForType(surface.type),
                        color: excluded ? Colors.grey : goldColor,
                      ),
                      title: Text(
                        '${surface.type} ${index + 1}',
                        style: TextStyle(
                          color: excluded ? Colors.grey : Colors.white,
                          decoration: excluded ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      subtitle: Text(
                        '${surface.width.toStringAsFixed(1)} × ${surface.height.toStringAsFixed(1)} m²',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      trailing: Switch(
                        value: !excluded,
                        onChanged: (_) => _toggleSurfaceExclusion(surface.id),
                        activeColor: goldColor,
                      ),
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
                style: ElevatedButton.styleFrom(
                  backgroundColor: goldColor,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
                onPressed: _stopScan,
                child: const Text('Done Scanning', style: TextStyle(fontSize: 18, color: Colors.black)),
              ),
            ),
          ],

          // AFTER SCAN – WALL CARDS
          if (_hasSnapshot && !_isScanning) ...[
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
                        decoration: BoxDecoration(
                          color: goldColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: goldColor, width: 1),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Wall ${index + 1}',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text('${surface.width.toStringAsFixed(1)} × ${surface.height.toStringAsFixed(1)}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            Text('${surface.area.toStringAsFixed(1)} m²',
                                style: const TextStyle(color: goldColor, fontSize: 12)),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.brush, color: Colors.white70),
                              onPressed: () => _enterEraserMode(index),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],

          // Eraser exit button
          if (_currentWallIndex != null)
            Positioned(
              bottom: 10,
              left: 40,
              right: 40,
              child: ElevatedButton(
                onPressed: _exitEraserMode,
                child: const Text('Exit Eraser'),
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
