// lib/screens/ar/ar_screen.dart — v17 (in-AR marketplace browser)
//
// New in v17: an expandable bottom marketplace bar. While viewing a wall the
// user can swipe up a browser that drills Shops → Categories → Wallpapers
// (each shown as image tiles). Tapping a wallpaper swaps it LIVE onto the
// current wall (via ARService.switchWallpaper) and auto-minimizes the bar.
// The currently-applied wallpaper/shop/price are now mutable state, so
// Save Wall records whatever the user last selected — from any shop.

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/ar_service.dart';
import '../../services/firestore_service.dart';
import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';
import '../../models/saved_wall.dart';
import '../../providers/saved_walls_provider.dart';

const Color goldColor = Color(0xFFFFD369);

class ARScreen extends StatefulWidget {
  final WallpaperModel? wallpaper;
  final ShopModel? shop;
  final double pricePerRoll;
  ARScreen({super.key, WallpaperModel? initialWallpaper, ShopModel? initialShop, double? pricePerRoll})
      : wallpaper = initialWallpaper,
        shop = initialShop,
        pricePerRoll = pricePerRoll ?? 0.0;
  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  final ARService _arService = ARService.instance;
  StreamSubscription<AREvent>? _eventSub;

  // ★ v17: the ACTIVE selection is now mutable (was widget.* constants).
  WallpaperModel? _activeWallpaper;
  ShopModel? _activeShop;
  double _activePricePerRoll = 0;

  String _statusText = "Initializing...";
  final List<String> _logLines = [];
  bool _isScanning = false, _scanDone = false, _wallpaperApplied = false;
  bool _showLog = false;
  bool _editPanelOpen = false;
  bool _occluderEnabled = true;
  String _activeTool = 'erase';
  String _lassoMode = 'erase';
  double _brushSize = 0.08, _wallpaperOpacity = 1.0;
  double _totalWallArea = 0.0;

  int _lassoPointCount = 0;
  bool _lassoClosed = false;
  List<List<double>> _lassoScreenPoints = [];
  Offset? _lassoTapDown;

  // ★ v17: marketplace browser state
  bool _browserOpen = false;
  bool _swapping = false;

  @override
  void initState() {
    super.initState();
    _activeWallpaper = widget.wallpaper;
    _activeShop = widget.shop;
    _activePricePerRoll = widget.pricePerRoll;
    _initAR();
  }

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
        setState(() {
          _isScanning = false;
          _scanDone = true;
          if (area is num) _totalWallArea = area.toDouble();
        });
        _autoApplyWallpaper();
        break;
      case 'wallpaperPlaced':
        final ok = event.data['success'] as bool? ?? false;
        final area = event.data['area'];
        if (ok) {
          setState(() {
            _wallpaperApplied = true;
            if (area is num) _totalWallArea = area.toDouble();
          });
        }
        break;
      case 'selectionChanged':
        final area = event.data['area'];
        if (area is num) setState(() => _totalWallArea = area.toDouble());
        break;
      case 'lassoState':
        final count = (event.data['count'] as num?)?.toInt() ?? 0;
        final closed = event.data['closed'] as bool? ?? false;
        setState(() { _lassoPointCount = count; _lassoClosed = closed; });
        break;
      case 'lassoScreenPoints':
        final pts = event.data['points'];
        if (pts is List) {
          final parsed = pts.whereType<List>().map((p) {
            return p.whereType<num>().map((n) => n.toDouble()).toList();
          }).where((p) => p.length == 3).toList();
          setState(() { _lassoScreenPoints = parsed; });
        }
        break;
      default: break;
    }
  }

  double get _rollArea => (_activeWallpaper?.rollWidth ?? 0.53) * (_activeWallpaper?.rollLength ?? 10.0);
  int get _rollsNeeded => _rollArea > 0 ? (_totalWallArea / _rollArea).ceil() : 0;
  double get _totalPrice => _rollsNeeded * _activePricePerRoll;

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true; _scanDone = false; _wallpaperApplied = false;
      _totalWallArea = 0; _lassoPointCount = 0; _lassoClosed = false;
    });
    try {
      await _arService.setARMode('scanning');
      await _arService.startScan();
    } catch (e) { _log('Scan: $e'); }
  }

  Future<void> _stopScan() async {
    try { await _arService.stopScan(); } catch (e) { _log('Stop: $e'); }
  }

  Future<void> _autoApplyWallpaper() async {
    if (_activeWallpaper == null) {
      _log('No wallpaper selected — skipping auto-apply');
      return;
    }
    try {
      await _arService.placeWallpaper(
        wallpaper: _activeWallpaper!,
        wallIndex: 0,
        pricePerRoll: _activePricePerRoll,
      );
    } catch (e) { _log('Auto-apply: $e'); }
  }

  // ★ v17: Live-swap the wallpaper on the current wall from the browser.
  Future<void> _selectWallpaperFromBrowser(WallpaperModel wp, ShopModel shop) async {
    setState(() {
      _swapping = true;
      _activeWallpaper = wp;
      _activeShop = shop;
      _activePricePerRoll = wp.price;
      _browserOpen = false;   // auto-minimize as requested
    });
    try {
      await _arService.switchWallpaper(
        wallpaper: wp,
        wallIndex: 0,
        pricePerRoll: wp.price,
      );
      setState(() => _wallpaperApplied = true);
    } catch (e) {
      _log('Swap: $e');
    } finally {
      if (mounted) setState(() => _swapping = false);
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

  Future<void> _toggleOccluder(bool on) async {
    setState(() => _occluderEnabled = on);
    try { await _arService.setOccluderEnabled(on); } catch (_) {}
  }

  Future<void> _undo() async { try { await _arService.undoCut(0); } catch (_) {} }
  Future<void> _reset() async { try { await _arService.clearAllCuts(0); } catch (_) {} }

  Future<void> _lassoTap(Offset p) async {
    try { await _arService.lassoAddPoint(p.dx, p.dy); } catch (e) { _log('Lasso tap: $e'); }
  }

  Future<void> _applyLasso() async {
    try { await _arService.lassoApply(_lassoMode); } catch (e) { _log('Lasso apply: $e'); }
  }

  Future<void> _clearLassoPoints() async {
    try { await _arService.lassoClear(); } catch (_) {}
  }

  Future<void> _sendDiagnosticEmail() async {
    setState(() => _statusText = 'Building diagnostic report...');
    final report = await _arService.getDiagnostics();
    final subject = Uri.encodeComponent('OBOIA Diagnostic — ${DateTime.now()}');
    final body = Uri.encodeComponent(report);
    final mailto = Uri.parse('mailto:ehtishampayoneer@gmail.com?subject=$subject&body=$body');
    try {
      if (await canLaunchUrl(mailto)) {
        await launchUrl(mailto);
      } else {
        setState(() => _statusText = 'Could not open Mail app. Copy log from screen.');
      }
    } catch (e) {
      setState(() => _statusText = 'Diag err: $e');
    }
  }

  Future<void> _openEditPanel() async {
    if (_editPanelOpen) return;
    try { await _arService.enterCutMode(0); } catch (_) {}
    try { await _arService.setBrushMode(_activeTool == 'paint' ? 'paint' : 'erase'); } catch (_) {}
    setState(() => _editPanelOpen = true);
  }

  Future<void> _closeEditPanel() async {
    if (!_editPanelOpen) return;
    if (_activeTool == 'lasso') {
      try { await _arService.lassoEnd(); } catch (_) {}
    }
    try { await _arService.exitCutMode(); } catch (_) {}
    setState(() => _editPanelOpen = false);
  }

  Future<void> _setToolInline(String tool) async {
    if (_activeTool == 'lasso' && tool != 'lasso') {
      try { await _arService.lassoEnd(); } catch (_) {}
    }
    if (tool == 'lasso' && _activeTool != 'lasso') {
      try { await _arService.lassoStart(); } catch (_) {}
    }
    setState(() => _activeTool = tool);
    if (tool == 'paint' || tool == 'erase') {
      try { await _arService.setBrushMode(tool); } catch (_) {}
    }
  }

  // ★ v17: Save uses the ACTIVE wallpaper/shop (whatever was last selected).
  Future<void> _saveWall() async {
    if (_activeWallpaper == null || _activeShop == null) {
      _log('Cannot save: wallpaper or shop missing');
      return;
    }
    setState(() => _statusText = 'Saving wall...');
    final pngBytes = await _arService.captureScreenshot();
    if (!mounted) return;

    final saved = SavedWall(
      id: const Uuid().v4(),
      shop: _activeShop!,
      wallpaper: _activeWallpaper!,
      areaSqm: _totalWallArea,
      screenshotPng: pngBytes,
      savedAt: DateTime.now(),
    );
    context.read<SavedWallsProvider>().add(saved);

    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/walls');
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
      body: Stack(children: [
        Positioned.fill(child: UiKitView(
            viewType: 'com.oboia/ar_view',
            creationParams: const <String, dynamic>{},
            creationParamsCodec: StandardMessageCodec())),

        if (_activeTool == 'lasso' && _lassoScreenPoints.isNotEmpty)
          Positioned.fill(child: IgnorePointer(
            child: CustomPaint(painter: _LassoHintPainter(_lassoScreenPoints, _lassoClosed)))),

        if (_activeTool == 'lasso' && !_lassoClosed && _editPanelOpen)
          Positioned.fill(child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) { _lassoTapDown = e.localPosition; },
            onPointerUp: (e) {
              final start = _lassoTapDown;
              _lassoTapDown = null;
              if (start == null) return;
              final dx = e.localPosition.dx - start.dx;
              final dy = e.localPosition.dy - start.dy;
              if (dx * dx + dy * dy < 100) {
                _lassoTap(e.localPosition);
              }
            },
            child: Container(color: Colors.transparent))),

        Positioned(top: MediaQuery.of(context).padding.top + 8, left: 8,
          child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 22),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: () => Navigator.of(context).pop())),

        Positioned(top: MediaQuery.of(context).padding.top + 8, right: 12,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple.withOpacity(0.9),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              minimumSize: const Size(0, 32)),
            onPressed: _sendDiagnosticEmail,
            icon: const Icon(Icons.bug_report, color: Colors.white, size: 14),
            label: const Text('Diag', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)))),

        if (_wallpaperApplied && !_editPanelOpen)
          Positioned(top: MediaQuery.of(context).padding.top + 50, right: 12,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: goldColor,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                minimumSize: const Size(0, 36)),
              onPressed: _openEditPanel,
              icon: const Icon(Icons.edit, color: Colors.black, size: 16),
              label: const Text('Edit',
                  style: TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.w700)))),

        if (_isScanning) ...[
          Positioned(top: MediaQuery.of(context).padding.top + 50, left: 60, right: 110,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.92), borderRadius: BorderRadius.circular(12)),
              child: const Text(
                'Move slowly around the room.\nWalls light up as they are detected.',
                style: TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center))),
          Positioned(bottom: 30, left: 40, right: 40,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: goldColor,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
              onPressed: _stopScan,
              child: const Text('Done Scanning',
                  style: TextStyle(fontSize: 18, color: Colors.black, fontWeight: FontWeight.bold)))),
        ],

        // Bottom stats bar + Save + marketplace handle (after wallpaper applied)
        if (_wallpaperApplied && !_editPanelOpen && !_browserOpen)
          Positioned(bottom: 0, left: 0, right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(20, 14, 20, MediaQuery.of(context).padding.bottom + 14),
              decoration: const BoxDecoration(
                  color: Color(0xE6111111),
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(22), topRight: Radius.circular(22))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // ★ v17: "Browse wallpapers" handle — tap to expand the marketplace
                GestureDetector(
                  onTap: () => setState(() => _browserOpen = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 40, height: 4,
                          decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2))),
                      const SizedBox(height: 8),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                        Icon(Icons.grid_view_rounded, color: goldColor, size: 16),
                        SizedBox(width: 6),
                        Text('Browse more wallpapers',
                            style: TextStyle(color: goldColor, fontSize: 13, fontWeight: FontWeight.w700)),
                      ]),
                    ]),
                  ),
                ),
                const SizedBox(height: 10),
                // Active selection label
                if (_activeWallpaper != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${_activeWallpaper!.name}'
                      '${_activeShop != null ? '  ·  ${_activeShop!.displayName()}' : ''}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  _stat('Area', '${_totalWallArea.toStringAsFixed(1)} m²'),
                  _stat('Rolls', '$_rollsNeeded'),
                  _stat('Total', '${_totalPrice.toStringAsFixed(0)} UZS'),
                ]),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: _saveWall,
                    icon: const Icon(Icons.check, color: Colors.white, size: 18),
                    label: const Text('Save Wall',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700))),
              ]))),

        // ★ v17: The marketplace browser (expanded)
        if (_browserOpen && !_editPanelOpen)
          Positioned(left: 0, right: 0, bottom: 0,
            child: _MarketplaceBrowser(
              onClose: () => setState(() => _browserOpen = false),
              onPick: _selectWallpaperFromBrowser,
            )),

        if (_editPanelOpen)
          Positioned(bottom: 0, left: 0, right: 0,
            child: _EditSheet(
              activeTool: _activeTool,
              brushSize: _brushSize,
              wallpaperOpacity: _wallpaperOpacity,
              occluderEnabled: _occluderEnabled,
              lassoMode: _lassoMode,
              lassoPointCount: _lassoPointCount,
              lassoClosed: _lassoClosed,
              totalWallArea: _totalWallArea,
              onTool: _setToolInline,
              onBrushSize: _setBrushSize,
              onOpacity: _setOpacity,
              onOccluder: _toggleOccluder,
              onLassoModeChanged: (m) => setState(() => _lassoMode = m),
              onClearLasso: _clearLassoPoints,
              onApplyLasso: _applyLasso,
              onUndo: _undo,
              onReset: _reset,
              onDone: () { _closeEditPanel(); },
            )),

        if (_swapping)
          const Positioned(top: 0, left: 0, right: 0, bottom: 0,
            child: IgnorePointer(
              child: Center(
                child: CircularProgressIndicator(color: goldColor)))),

        if (!_isScanning)
          Positioned(top: MediaQuery.of(context).padding.top + 90, left: 70, right: 70,
            child: GestureDetector(onDoubleTap: () => setState(() => _showLog = !_showLog),
              child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: Text(_statusText,
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                      textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis)))),

        if (_showLog)
          Positioned(top: MediaQuery.of(context).padding.top + 115, left: 8, right: 8,
            child: IgnorePointer(
                child: Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    padding: const EdgeInsets.all(6), color: Colors.black87,
                    child: SingleChildScrollView(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                            children: _logLines.take(10).map((l) =>
                                Text(l, style: const TextStyle(color: Colors.white70, fontSize: 9),
                                    maxLines: 2, overflow: TextOverflow.ellipsis)).toList()))))),
      ]),
      floatingActionButton: !_isScanning && !_scanDone
          ? FloatingActionButton.extended(
              onPressed: _startScan,
              backgroundColor: goldColor,
              icon: const Icon(Icons.camera, color: Colors.black),
              label: const Text('Start Scan',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)))
          : null,
    );
  }

  Widget _stat(String label, String value) => Column(children: [
    Text(value, style: const TextStyle(color: goldColor, fontSize: 18, fontWeight: FontWeight.bold)),
    const SizedBox(height: 2),
    Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────
// MARKETPLACE BROWSER — Shops → Categories → Wallpapers (image tiles)
// ─────────────────────────────────────────────────────────────────────

class _MarketplaceBrowser extends StatefulWidget {
  final VoidCallback onClose;
  final Future<void> Function(WallpaperModel, ShopModel) onPick;
  const _MarketplaceBrowser({required this.onClose, required this.onPick});

  @override
  State<_MarketplaceBrowser> createState() => _MarketplaceBrowserState();
}

class _MarketplaceBrowserState extends State<_MarketplaceBrowser> {
  // Navigation level: 0 = shops, 1 = categories, 2 = wallpapers
  int _level = 0;
  ShopModel? _shop;
  String? _categoryId;
  String _categoryName = '';

  List<Map<String, dynamic>> _categories = [];
  bool _loadingCats = false;

  Future<void> _openShop(ShopModel shop) async {
    setState(() {
      _shop = shop;
      _level = 1;
      _loadingCats = true;
      _categories = [];
    });
    try {
      final snap = await FirebaseFirestore.instance
          .collection('categories')
          .where('shopId', isEqualTo: shop.id)
          .get();
      final cats = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      cats.sort((a, b) => (a['nameEn'] ?? '').toString().compareTo((b['nameEn'] ?? '').toString()));
      if (mounted) setState(() { _categories = cats; _loadingCats = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingCats = false);
    }
  }

  void _openCategory(String id, String name) {
    setState(() { _categoryId = id; _categoryName = name; _level = 2; });
  }

  void _back() {
    setState(() {
      if (_level == 2) { _level = 1; _categoryId = null; }
      else if (_level == 1) { _level = 0; _shop = null; }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.46,
      decoration: const BoxDecoration(
        color: Color(0xF2111111),
        borderRadius: BorderRadius.only(topLeft: Radius.circular(22), topRight: Radius.circular(22)),
      ),
      child: Column(children: [
        // Header: drag handle + breadcrumb + close
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 10),
            Row(children: [
              if (_level > 0)
                GestureDetector(
                  onTap: _back,
                  child: const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(Icons.arrow_back, color: goldColor, size: 20),
                  ),
                ),
              Expanded(
                child: Text(
                  _level == 0 ? 'Shops'
                    : _level == 1 ? (_shop?.displayName() ?? 'Categories')
                    : _categoryName,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(Icons.keyboard_arrow_down, color: Colors.white70, size: 26),
              ),
            ]),
          ]),
        ),
        const Divider(color: Colors.white12, height: 1),
        Expanded(child: _buildLevel()),
      ]),
    );
  }

  Widget _buildLevel() {
    if (_level == 0) return _buildShops();
    if (_level == 1) return _buildCategories();
    return _buildWallpapers();
  }

  // Level 0 — all visible shops (logo + name)
  Widget _buildShops() {
    return StreamBuilder<List<ShopModel>>(
      stream: FirestoreService.instance.activeShopsStream(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: goldColor));
        final shops = snap.data!;
        if (shops.isEmpty) return _empty('No shops available');
        return GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.82),
          itemCount: shops.length,
          itemBuilder: (_, i) {
            final s = shops[i];
            return _tile(
              imageUrl: s.thumbnailUrl,
              fallbackIcon: Icons.storefront,
              label: s.displayName(),
              onTap: () => _openShop(s),
            );
          },
        );
      },
    );
  }

  // Level 1 — categories of the selected shop (category image + name)
  Widget _buildCategories() {
    if (_loadingCats) return const Center(child: CircularProgressIndicator(color: goldColor));
    if (_categories.isEmpty) return _empty('No categories in this shop');
    return GridView.builder(
      padding: const EdgeInsets.all(14),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.82),
      itemCount: _categories.length,
      itemBuilder: (_, i) {
        final c = _categories[i];
        final name = (c['nameEn'] ?? c['nameUz'] ?? 'Category').toString();
        return _tile(
          imageUrl: (c['image'] ?? '').toString(),
          fallbackIcon: Icons.category,
          label: name,
          onTap: () => _openCategory(c['id'].toString(), name),
        );
      },
    );
  }

  // Level 2 — wallpapers in the selected shop+category (thumbnail + name)
  Widget _buildWallpapers() {
    return StreamBuilder<List<Wallpaper>>(
      stream: FirestoreService.instance.wallpapersForShopStream(_shop!.id),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: goldColor));
        final all = snap.data!;
        final inCat = all.where((w) => w.category == _categoryId).toList();
        if (inCat.isEmpty) return _empty('No wallpapers in this category');
        return GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.78),
          itemCount: inCat.length,
          itemBuilder: (_, i) {
            final w = inCat[i];
            return _tile(
              imageUrl: w.thumbnailUrl,
              fallbackIcon: Icons.wallpaper,
              label: w.name,
              onTap: () => widget.onPick(w, _shop!),
            );
          },
        );
      },
    );
  }

  Widget _tile({
    required String? imageUrl,
    required IconData fallbackIcon,
    required String label,
    required VoidCallback onTap,
  }) {
    final url = imageUrl ?? '';
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: url.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    placeholder: (_, __) => Container(color: Colors.white10),
                    errorWidget: (_, __, ___) => _iconBox(fallbackIcon),
                  )
                : _iconBox(fallbackIcon),
          ),
        ),
        const SizedBox(height: 5),
        Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  Widget _iconBox(IconData icon) => Container(
        color: Colors.white10,
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white30, size: 30),
      );

  Widget _empty(String msg) => Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Text(msg, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────
// EDIT BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────

class _EditSheet extends StatelessWidget {
  final String activeTool;
  final double brushSize, wallpaperOpacity;
  final bool occluderEnabled, lassoClosed;
  final String lassoMode;
  final int lassoPointCount;
  final double totalWallArea;
  final Future<void> Function(String) onTool;
  final Future<void> Function(double) onBrushSize;
  final Future<void> Function(double) onOpacity;
  final Future<void> Function(bool) onOccluder;
  final void Function(String) onLassoModeChanged;
  final Future<void> Function() onClearLasso;
  final Future<void> Function() onApplyLasso;
  final Future<void> Function() onUndo;
  final Future<void> Function() onReset;
  final VoidCallback onDone;

  const _EditSheet({
    required this.activeTool,
    required this.brushSize,
    required this.wallpaperOpacity,
    required this.occluderEnabled,
    required this.lassoClosed,
    required this.lassoMode,
    required this.lassoPointCount,
    required this.totalWallArea,
    required this.onTool,
    required this.onBrushSize,
    required this.onOpacity,
    required this.onOccluder,
    required this.onLassoModeChanged,
    required this.onClearLasso,
    required this.onApplyLasso,
    required this.onUndo,
    required this.onReset,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(14, 12, 14, MediaQuery.of(context).padding.bottom + 14),
      decoration: const BoxDecoration(
        color: Color(0xF2222222),
        borderRadius: BorderRadius.only(topLeft: Radius.circular(22), topRight: Radius.circular(22)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 38, height: 4,
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 14),

        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _toolBtn(Icons.brush, 'Paint', activeTool == 'paint', () => onTool('paint')),
          _toolBtn(Icons.auto_fix_high, 'Erase', activeTool == 'erase', () => onTool('erase')),
          _toolBtn(Icons.gesture, 'Lasso', activeTool == 'lasso', () => onTool('lasso')),
          _toolBtn(Icons.undo, 'Undo', false, onUndo),
          _toolBtn(Icons.restart_alt, 'Reset', false, onReset),
        ]),
        const SizedBox(height: 10),

        if (activeTool == 'lasso')
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('Lasso: ', style: TextStyle(color: Colors.white54, fontSize: 11)),
            _miniToggle('Erase', lassoMode == 'erase', () => onLassoModeChanged('erase')),
            const SizedBox(width: 8),
            _miniToggle('Paint', lassoMode == 'paint', () => onLassoModeChanged('paint')),
            const SizedBox(width: 12),
            if (lassoPointCount > 0)
              GestureDetector(
                onTap: onClearLasso,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.red.withOpacity(0.3), borderRadius: BorderRadius.circular(6)),
                  child: const Text('Clear', style: TextStyle(color: Colors.redAccent, fontSize: 10)))),
          ]),

        if (activeTool != 'lasso') Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const Icon(Icons.circle, color: Colors.white38, size: 8),
            Expanded(child: Slider(
                value: brushSize, min: 0.02, max: 0.25,
                activeColor: goldColor, inactiveColor: Colors.white24,
                onChanged: onBrushSize)),
            const Icon(Icons.circle, color: Colors.white38, size: 20),
          ]),
        ),

        Row(children: [
          const Text('Opacity', style: TextStyle(color: Colors.white60, fontSize: 11)),
          Expanded(child: Slider(
              value: wallpaperOpacity, min: 0.1, max: 1.0,
              activeColor: goldColor, inactiveColor: Colors.white12,
              onChanged: onOpacity)),
          Text('${(wallpaperOpacity * 100).toInt()}%',
              style: const TextStyle(color: Colors.white60, fontSize: 11)),
        ]),

        Row(children: [
          const Icon(Icons.view_in_ar, color: Colors.white38, size: 14),
          const SizedBox(width: 6),
          const Expanded(child: Text('Hide wallpaper behind objects',
              style: TextStyle(color: Colors.white60, fontSize: 11))),
          Switch(value: occluderEnabled, onChanged: onOccluder,
              activeColor: goldColor, activeTrackColor: goldColor.withOpacity(0.3)),
        ]),

        const SizedBox(height: 6),

        if (activeTool == 'lasso' && lassoPointCount >= 3) Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: lassoClosed ? Colors.green : Colors.redAccent,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              onPressed: () async { await onApplyLasso(); },
              icon: const Icon(Icons.check, color: Colors.white, size: 18),
              label: Text(lassoClosed ? 'Apply Lasso ($lassoMode)' : 'Apply ($lassoPointCount pts)',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)))),
        ),

        SizedBox(width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: goldColor,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: onDone,
            icon: const Icon(Icons.check_circle, color: Colors.black, size: 18),
            label: const Text('Done',
                style: TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.bold)))),
      ]),
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
      child: Text(label, style: TextStyle(color: active ? goldColor : Colors.white54, fontSize: 11, fontWeight: FontWeight.w500))));
  }
}

// ─────────────────────────────────────────────────────────────────────
// LASSO HINT PAINTER
// ─────────────────────────────────────────────────────────────────────

class _LassoHintPainter extends CustomPainter {
  final List<List<double>> screenPoints;
  final bool closed;
  _LassoHintPainter(this.screenPoints, this.closed);

  @override
  void paint(Canvas canvas, Size size) {
    if (screenPoints.isEmpty || closed) return;
    if (screenPoints.length < 3) return;
    final first = screenPoints[0];
    if (first.length < 3 || first[2] < 0.5) return;
    final hint = Paint()
      ..color = Colors.yellow.withOpacity(0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(first[0], first[1]), 30, hint);
  }

  @override
  bool shouldRepaint(covariant _LassoHintPainter old) =>
      old.screenPoints != screenPoints || old.closed != closed;
}
