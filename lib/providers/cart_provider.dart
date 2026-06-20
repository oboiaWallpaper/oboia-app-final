// lib/providers/cart_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/cart_model.dart';
import '../models/wallpaper_model.dart';
import '../services/cart_service.dart';

class CartProvider extends ChangeNotifier {
  List<CartItem> _items = [];
  StreamSubscription<List<CartItem>>? _sub;
  String? _userId;

  // ── Getters ─────────────────────────────────────────────────────────────
  List<CartItem> get items => List.unmodifiable(_items);

  /// Number of distinct items in the cart.
  int get count => _items.length;

  /// Alias used by the AR screen cart badge.
  int get totalItems => _items.length;

  /// Grand total price across all items.
  double get grandTotal =>
      _items.fold<double>(0.0, (acc, it) => acc + it.totalPrice);

  // ── Bind to user ─────────────────────────────────────────────────────────
  /// Call whenever Firebase auth state changes (pass null on sign-out).
  void bindUser(String? userId) {
    if (_userId == userId) return;
    _userId = userId;
    _sub?.cancel();
    _sub = null;
    if (userId == null) {
      _items = [];
      notifyListeners();
      return;
    }
    _sub = CartService.instance.cartStream(userId).listen((list) {
      _items = list;
      notifyListeners();
    });
  }

  // ── Cart operations ──────────────────────────────────────────────────────
  /// Low-level add — prefer [addWallpaperToCart] from the AR screen.
  Future<void> add(CartItem item) async {
    if (_userId == null) return;
    await CartService.instance.addItem(_userId!, item);
  }

  /// Called by ar_screen.dart when the user taps "Add to Cart".
  /// Computes rolls needed and total price from the measured wall dimensions.
  Future<void> addWallpaperToCart({
    required WallpaperModel wallpaper,
    required String shopId,
    required String shopName,
    required double wallWidth,
    required double wallHeight,
  }) async {
    if (_userId == null) return;
    final sqm = wallWidth * wallHeight;
    final perRoll = wallpaper.rollWidth * wallpaper.rollLength;
    final rollsNeeded = (perRoll > 0) ? (sqm / perRoll).ceil() : 1;
    final totalPrice = rollsNeeded * wallpaper.price;
    final item = CartItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      wallpaperId: wallpaper.id,
      wallpaperName: wallpaper.name,
      wallpaperThumbnail: wallpaper.thumbnailUrl,
      shopId: shopId,
      shopName: shopName,
      wallWidth: wallWidth,
      wallHeight: wallHeight,
      sqm: sqm,
      rollsNeeded: rollsNeeded,
      pricePerRoll: wallpaper.price,
      totalPrice: totalPrice,
      addedAt: DateTime.now(),
    );
    await CartService.instance.addItem(_userId!, item);
  }

  /// ★ NEW: Add a wallpaper to the cart WITHOUT scanning a wall — the customer
  /// simply chooses how many rolls they want (like adding any normal product).
  /// Wall measurements are 0 here; the seller confirms exact needs at order time.
  Future<void> addWallpaperByQuantity({
    required WallpaperModel wallpaper,
    required String shopId,
    required String shopName,
    required int quantity,
  }) async {
    if (_userId == null) return;
    final qty = quantity < 1 ? 1 : quantity;
    final totalPrice = qty * wallpaper.price;
    final item = CartItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      wallpaperId: wallpaper.id,
      wallpaperName: wallpaper.name,
      wallpaperThumbnail: wallpaper.thumbnailUrl,
      shopId: shopId,
      shopName: shopName,
      wallWidth: 0,
      wallHeight: 0,
      sqm: 0,
      rollsNeeded: qty,
      pricePerRoll: wallpaper.price,
      totalPrice: totalPrice,
      addedAt: DateTime.now(),
    );
    await CartService.instance.addItem(_userId!, item);
  }

  Future<void> remove(String itemId) async {
    if (_userId == null) return;
    await CartService.instance.removeItem(_userId!, itemId);
  }

  Future<void> clear() async {
    if (_userId == null) return;
    await CartService.instance.clear(_userId!);
  }

  /// Groups cart items by shop so the order-confirm screen can split
  /// into one order per shop.
  Map<String, List<CartItem>> itemsByShop() {
    final map = <String, List<CartItem>>{};
    for (final it in _items) {
      map.putIfAbsent(it.shopId, () => []).add(it);
    }
    return map;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
