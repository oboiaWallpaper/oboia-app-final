// lib/providers/saved_walls_provider.dart
//
// Temporary in-memory staging list of walls the user has scanned + saved
// during the current session. This is NOT the cart — it's a holding area
// between AR scanning and your existing CartProvider/checkout flow.
//
// User flow:
//   AR scan + apply wallpaper + edit → tap Save → SavedWall added here
//   WallsListScreen displays them with thumbnails and lets user discard
//   "Finish & Cart" iterates this list, adds each as a CartItem to CartProvider,
//   then clears this provider and navigates to /cart.
//
// Cart aggregation (grouping by wallpaper, by shop, totals) is handled by
// your existing CartProvider — don't duplicate it here.

import 'package:flutter/foundation.dart';
import '../models/saved_wall.dart';

class SavedWallsProvider extends ChangeNotifier {
  final List<SavedWall> _walls = [];

  List<SavedWall> get walls => List.unmodifiable(_walls);
  int get count => _walls.length;
  bool get isEmpty => _walls.isEmpty;
  bool get isNotEmpty => _walls.isNotEmpty;

  /// Total area across all saved walls (m²) — used by the summary header
  /// in WallsListScreen. Real cart math happens in CartProvider after handoff.
  double get totalArea => _walls.fold(0.0, (sum, w) => sum + w.areaSqm);

  /// Total rolls (sum across walls)
  int get totalRolls => _walls.fold(0, (sum, w) => sum + w.rollsNeeded);

  /// Total UZS price (sum across walls)
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
}
