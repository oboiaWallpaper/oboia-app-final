// lib/providers/saved_walls_provider.dart
//
// Holds the in-memory list of walls the user has saved during the current
// session. Walls are added after each AR scan-and-save cycle, can be
// discarded individually from the walls list, and are cleared after a
// successful cart submission.

import 'package:flutter/foundation.dart';
import '../models/saved_wall.dart';

class SavedWallsProvider extends ChangeNotifier {
  final List<SavedWall> _walls = [];

  List<SavedWall> get walls => List.unmodifiable(_walls);
  int get count => _walls.length;
  bool get isEmpty => _walls.isEmpty;
  bool get isNotEmpty => _walls.isNotEmpty;

  /// Total area across all saved walls (m²)
  double get totalArea => _walls.fold(0.0, (sum, w) => sum + w.areaSqm);

  /// Total rolls across all saved walls
  int get totalRolls => _walls.fold(0, (sum, w) => sum + w.rollsNeeded);

  /// Total UZS price across all saved walls
  double get totalPrice => _walls.fold(0.0, (sum, w) => sum + w.totalPrice);

  void add(SavedWall wall) {
    _walls.add(wall);
    notifyListeners();
  }

  void remove(String wallId) {
    _walls.removeWhere((w) => w.id == wallId);
    notifyListeners();
  }

  void clear() {
    _walls.clear();
    notifyListeners();
  }

  /// Aggregate walls by wallpaper. Same wallpaper used on multiple walls
  /// sums area and rolls into one line item. Returns list of CartLineItem.
  List<CartLineItem> aggregateByWallpaper() {
    final Map<String, CartLineItem> byWallpaper = {};
    for (final w in _walls) {
      final key = w.wallpaper.id;
      if (byWallpaper.containsKey(key)) {
        final existing = byWallpaper[key]!;
        byWallpaper[key] = CartLineItem(
          shop: existing.shop,
          wallpaper: existing.wallpaper,
          totalArea: existing.totalArea + w.areaSqm,
          wallCount: existing.wallCount + 1,
        );
      } else {
        byWallpaper[key] = CartLineItem(
          shop: w.shop,
          wallpaper: w.wallpaper,
          totalArea: w.areaSqm,
          wallCount: 1,
        );
      }
    }
    return byWallpaper.values.toList();
  }

  /// Group cart line items by shop. Returns map of shopId → list of items.
  Map<String, List<CartLineItem>> aggregateByShop() {
    final lines = aggregateByWallpaper();
    final Map<String, List<CartLineItem>> byShop = {};
    for (final line in lines) {
      byShop.putIfAbsent(line.shop.id, () => []).add(line);
    }
    return byShop;
  }
}

/// An aggregated line item in the cart — one wallpaper, total area across
/// all walls using it, the resulting rolls/price for that aggregated area.
class CartLineItem {
  final dynamic shop;             // ShopModel (avoid circular import in this file)
  final dynamic wallpaper;        // WallpaperModel
  final double totalArea;
  final int wallCount;

  const CartLineItem({
    required this.shop,
    required this.wallpaper,
    required this.totalArea,
    required this.wallCount,
  });

  int get rollsNeeded {
    final perRoll = wallpaper.rollWidth * wallpaper.rollLength;
    if (perRoll <= 0) return 0;
    return (totalArea / perRoll).ceil();
  }

  double get lineTotal => rollsNeeded * wallpaper.price;
}
