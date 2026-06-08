// lib/providers/pinned_shop_provider.dart
//
// Manages the "pinned shop" state. When pinned, the customer's experience
// is locked to one shop (walk-in / QR-code use case). Without a pin, the
// app is the open marketplace.
//
// Pinning persists across app restarts via shared_preferences. The current
// pinned shop is re-validated against Firestore on app launch — if the
// shop became invisible (subscription expired or admin deactivated), the
// pin is auto-cleared and the customer falls back to marketplace mode.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/shop_model.dart';
import '../services/firestore_service.dart';

class PinnedShopProvider extends ChangeNotifier {
  static const _kShopId = 'pinned_shop_id';
  static const _kToken = 'pinned_shop_token';

  Shop? _shop;
  bool _loading = true;
  String? _error;

  Shop? get shop => _shop;
  bool get isPinned => _shop != null;
  bool get loading => _loading;
  String? get error => _error;

  /// Call once at app startup. Reads saved pin from disk and revalidates
  /// against Firestore — if the shop is gone or no longer visible, clears.
  Future<void> hydrate() async {
    _loading = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_kShopId);
      final savedToken = prefs.getString(_kToken);
      if (savedId == null || savedToken == null) {
        _shop = null;
      } else {
        // Re-fetch by token (token is more stable than id for our use case —
        // if admin regenerated the token, the pin is invalidated).
        final fresh = await FirestoreService.instance.shopByToken(savedToken);
        if (fresh != null && fresh.id == savedId && fresh.isVisibleToCustomers) {
          _shop = fresh;
        } else {
          // Stale pin — token changed or shop no longer visible. Clear it.
          _shop = null;
          await prefs.remove(_kShopId);
          await prefs.remove(_kToken);
        }
      }
    } catch (e) {
      _error = 'Could not load pinned shop: $e';
      _shop = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Try to pin the app to a shop by token. Returns success/failure with
  /// human-readable reason for UI display.
  ///
  /// Validation order:
  ///   1. Format check (SHOP-XXXXX, alphanumeric uppercase)
  ///   2. Firestore lookup
  ///   3. Visibility check (must be visible to customers)
  Future<PinResult> pinByToken(String rawToken) async {
    _error = null;
    final token = rawToken.trim().toUpperCase();

    final formatOk = RegExp(r'^SHOP-[A-Z0-9]{5}$').hasMatch(token);
    if (!formatOk) {
      return const PinResult.failure(
        'Invalid format. Code should look like SHOP-AB12C.',
      );
    }

    try {
      final shop = await FirestoreService.instance.shopByToken(token);
      if (shop == null) {
        return const PinResult.failure(
          'No shop matches that code, or the shop is currently unavailable.',
        );
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kShopId, shop.id);
      await prefs.setString(_kToken, shop.token);
      _shop = shop;
      notifyListeners();
      return PinResult.success(shop);
    } catch (e) {
      return PinResult.failure('Something went wrong: $e');
    }
  }

  /// Clear the pin and return to marketplace mode.
  Future<void> unpin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kShopId);
    await prefs.remove(_kToken);
    _shop = null;
    notifyListeners();
  }

  /// Refresh the pinned shop from Firestore (call when entering a screen
  /// that depends on subscription state, in case it changed).
  Future<void> refresh() async {
    if (_shop == null) return;
    try {
      final fresh = await FirestoreService.instance.shopByToken(_shop!.token);
      if (fresh == null || !fresh.isVisibleToCustomers) {
        await unpin();
      } else {
        _shop = fresh;
        notifyListeners();
      }
    } catch (_) {
      // Silent: don't drop pin on a network blip.
    }
  }
}

/// Result of a pin attempt.
class PinResult {
  final bool success;
  final Shop? shop;
  final String? message;

  const PinResult.success(Shop this.shop)
      : success = true,
        message = null;

  const PinResult.failure(String this.message)
      : success = false,
        shop = null;
}
