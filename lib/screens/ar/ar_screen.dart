// lib/screens/ar/ar_screen.dart – AR SCREEN (const fixed, real camera)
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/ar_service.dart';

class ARScreen extends StatefulWidget {
  const ARScreen({
    super.key,
    dynamic initialWallpaper,
    dynamic initialShop,
    dynamic pricePerRoll,
  });

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  final ARService _arService = ARService.instance;
  StreamSubscription<AREvent>? _eventSub;

  String _nativeStatus = "Waiting...";
  final List<String> _logLines = [];

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
        if (_logLines.length > 10) _logLines.removeLast();
      });
    } else if (event.type == 'error') {
      final msg = event.errorMessage ?? 'Unknown error';
      setState(() {
        _nativeStatus = 'ERROR: $msg';
        _logLines.insert(0, '[ERROR] $msg');
        if (_logLines.length > 10) _logLines.removeLast();
      });
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // LAYER 0: Native AR view (background) — const FIXED
          Positioned.fill(
            child: UiKitView(
              viewType: 'com.oboia/ar_view',
              creationParams: const <String, dynamic>{},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),

          // LAYER 1: Back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 24),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // LAYER 2: Status overlay
          Positioned(
            top: MediaQuery.of(context).padding.top + 44,
            left: 16,
            right: 16,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.black54,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status: $_nativeStatus',
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
                    ),
                    if (_logLines.isNotEmpty)
                      ...(_logLines.map((line) => Text(line,
                          style: const TextStyle(color: Colors.white70, fontSize: 10)))),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
