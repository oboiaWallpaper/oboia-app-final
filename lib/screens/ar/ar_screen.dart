// lib/screens/ar/ar_screen.dart – COMPLETE AR SCREEN (const fixed)
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

  String _nativeStatus = "Initializing...";
  final List<String> _logLines = [];

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
      _logLines.insert(0, 'Init error: $e');
      setState(() => _nativeStatus = 'Init error: $e');
    }
    _eventSub = _arService.events.listen(_onAREvent);
  }

  void _onAREvent(AREvent event) {
    if (event.type == 'boot') {
      final msg = event.data['status'] ?? 'boot';
      setState(() {
        _nativeStatus = msg.toString();
        _logLines.insert(0, '[BOOT] $msg');
        if (_logLines.length > 15) _logLines.removeLast();
      });
    } else if (event.type == 'error') {
      final msg = event.errorMessage ?? 'Unknown error';
      setState(() {
        _nativeStatus = 'ERROR: $msg';
        _logLines.insert(0, '[ERROR] $msg');
        if (_logLines.length > 15) _logLines.removeLast();
      });
    } else if (event.type == 'scanUpdate') {
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
        } catch (_) {}
      }
    } else if (event.type == 'scanComplete') {
      setState(() {
        _isScanning = false;
        _hasSnapshot = true;
      });
      // Auto-apply wallpaper to all non-excluded walls
      for (int i = 0; i < _scannedSurfaces.length; i++) {
        final s = _scannedSurfaces[i];
        if (!s.excluded && s.type == 'wall') {
          _arService.placeWallpaper(
            wallpaper: widget.wallpaper,
            wallIndex: i,
            pricePerRoll: widget.pricePerRoll,
          );
        }
      }
    } else if (event.type == 'wallpaperPlaced') {
      final success = event.data['success'] as bool? ?? false;
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Wallpaper applied to wall ${event.wallIndex}'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _hasSnapshot = false;
      _scannedSurfaces.clear();
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

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // LAYER 0: Native camera (background)
          // FIXED: removed const from Positioned.fill
          Positioned.fill(
            child: UiKitView(
              viewType: 'com.oboia/ar_view',
              creationParams: const <String, dynamic>{},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),

          // LAYER 1: Back button (always visible)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 24),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // LAYER 2: Status overlay (small, top-left)
          Positioned(
            top: MediaQuery.of(context).padding.top + 44,
            left: 8,
            right: 60,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                color: Colors.black54,
                child: Text(
                  _nativeStatus,
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                ),
              ),
            ),
          ),

          // LAYER 3: Wallpaper info (top-right)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 12, 12, 12),
              child: Row(
                children: [
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        widget.wallpaper.name,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      Text(
                        '${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll',
                        style: const TextStyle(color: goldColor, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // LAYER 4: Scanning UI (only during scan)
          if (_isScanning) ...[
            const Positioned(
              top: 100,
              left: 20,
              right: 20,
              child: Text(
                'Move slowly around the room...',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            // Detected surfaces list
            Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 200,
                child: ListView.builder(
                  itemCount: _scannedSurfaces.length,
                  itemBuilder: (context, index) {
                    final s = _scannedSurfaces[index];
                    final excluded = s.excluded;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        _iconForType(s.type),
                        color: excluded ? Colors.grey : goldColor,
                        size: 20,
                      ),
                      title: Text(
                        '${s.type} ${index + 1}',
                        style: TextStyle(
                          color: excluded ? Colors.grey : Colors.white,
                          fontSize: 13,
                          decoration: excluded ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      subtitle: Text(
                        '${s.width.toStringAsFixed(1)} × ${s.height.toStringAsFixed(1)} m | ${s.area.toStringAsFixed(1)} m²',
                        style: const TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                      trailing: Switch(
                        value: !excluded,
                        onChanged: (_) => _toggleSurfaceExclusion(s.id),
                        activeColor: goldColor,
                      ),
                    );
                  },
                ),
              ),
            ),
            // Done scanning button
            Positioned(
              bottom: 40,
              left: 40,
              right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: goldColor,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                onPressed: _stopScan,
                child: const Text(
                  'Done Scanning',
                  style: TextStyle(fontSize: 18, color: Colors.black),
                ),
              ),
            ),
          ],

          // LAYER 5: Wall cards after scan
          if (_hasSnapshot && !_isScanning)
            Positioned(
              bottom: 20,
              left: 8,
              right: 8,
              child: SizedBox(
                height: 150,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _scannedSurfaces.length,
                  itemBuilder: (context, index) {
                    final s = _scannedSurfaces[index];
                    if (s.type != 'wall' || s.excluded) {
                      return const SizedBox.shrink();
                    }
                    return GestureDetector(
                      onTap: () => _enterEraserMode(index),
                      child: Container(
                        width: 130,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: goldColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: goldColor, width: 1),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Wall ${index + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${s.width.toStringAsFixed(1)} × ${s.height.toStringAsFixed(1)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              '${s.area.toStringAsFixed(1)} m²',
                              style: const TextStyle(
                                color: goldColor,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.brush, color: Colors.white70, size: 20),
                              onPressed: () => _enterEraserMode(index),
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

          // LAYER 6: Eraser exit button
          if (_currentWallIndex != null)
            Positioned(
              bottom: 20,
              left: 40,
              right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
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
              label: const Text(
                'Start Scan',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : null,
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'wall':
        return Icons.dashboard;
      case 'door':
        return Icons.door_front_door;
      case 'window':
        return Icons.window;
      case 'opening':
        return Icons.arrow_right_alt;
      default:
        return Icons.help_outline;
    }
  }
}

// ── Models ──────────────────────────────────────────────────

class DetectedSurface {
  final String id;
  final String type;
  final double width;
  final double height;
  final double area;
  final bool excluded;

  DetectedSurface({
    required this.id,
    required this.type,
    required this.width,
    required this.height,
    required this.area,
    this.excluded = false,
  });

  factory DetectedSurface.fromJson(Map<String, dynamic> json) {
    return DetectedSurface(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'unknown',
      width: (json['width'] as num?)?.toDouble() ?? 0.0,
      height: (json['height'] as num?)?.toDouble() ?? 0.0,
      area: (json['area'] as num?)?.toDouble() ?? 0.0,
      excluded: json['excluded'] as bool? ?? false,
    );
  }
}
