// lib/models/saved_wall.dart
//
// A wall the user has scanned + applied wallpaper + saved.
// In-memory only — does not persist across app restarts.

import 'dart:typed_data';
import 'wallpaper_model.dart';
import 'shop_model.dart';

class SavedWall {
  final String id;                     // local UUID
  final ShopModel shop;
  final WallpaperModel wallpaper;
  final double areaSqm;                // total wall area in m²
  final Uint8List? screenshotPng;      // base64-decoded screenshot bytes for thumbnail
  final DateTime savedAt;

  const SavedWall({
    required this.id,
    required this.shop,
    required this.wallpaper,
    required this.areaSqm,
    required this.screenshotPng,
    required this.savedAt,
  });

  /// Rolls needed (rounded up) for this wall using the wallpaper's roll dimensions.
  int get rollsNeeded {
    final perRoll = wallpaper.rollWidth * wallpaper.rollLength;
    if (perRoll <= 0) return 0;
    return (areaSqm / perRoll).ceil();
  }

  /// Total UZS price for this wall.
  double get totalPrice => rollsNeeded * wallpaper.price;
}
