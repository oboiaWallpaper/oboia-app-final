// lib/screens/walls_list_screen.dart
//
// "My Walls" — the user's staging screen between AR scans and checkout.
// Lists all walls saved during the current session with thumbnail, name,
// shop, area, rolls, price. Each row can be discarded (swipe or × icon).
//
// Floating "Add Wall" → returns to shop list to pick another wallpaper.
// "Finish & Cart" → converts each saved wall to a CartItem via your existing
// CartProvider, clears the staging list, navigates to /cart.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/saved_wall.dart';
import '../models/cart_model.dart';
import '../providers/saved_walls_provider.dart';
import '../providers/cart_provider.dart';
import '../theme/app_colors.dart';

class WallsListScreen extends StatefulWidget {
  const WallsListScreen({super.key});
  @override
  State<WallsListScreen> createState() => _WallsListScreenState();
}

class _WallsListScreenState extends State<WallsListScreen> {
  bool _moving = false;

  /// Convert SavedWall → CartItem and push into CartProvider. Then clear
  /// the staging list and navigate to /cart. We approximate the wall as a
  /// square (width = height = sqrt(area)) since RoomPlan returns multiple
  /// wall planes per scan — a single width × height pair isn't meaningful
  /// here, but the area is correct.
  Future<void> _finishAndGoToCart() async {
    final saved = context.read<SavedWallsProvider>();
    final cart = context.read<CartProvider>();
    if (saved.isEmpty) return;

    setState(() => _moving = true);
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      int i = 0;
      for (final w in saved.walls) {
        final dim = math.sqrt(w.areaSqm);
        final cartItem = CartItem(
          id: '$ts-$i-${w.id}',
          wallpaperId: w.wallpaper.id,
          wallpaperName: w.wallpaper.name,
          wallpaperThumbnail: w.wallpaper.thumbnailUrl,
          shopId: w.shop.id,
          // ★ CHANGED: displayName() resolves nameEn/nameUz written by the
          // dashboard; plain .name is empty for dashboard-created shops.
          shopName: w.shop.displayName(),
          wallWidth: dim,
          wallHeight: dim,
          sqm: w.areaSqm,
          rollsNeeded: w.rollsNeeded,
          pricePerRoll: w.wallpaper.price,
          totalPrice: w.totalPrice,
          addedAt: DateTime.now(),
        );
        await cart.add(cartItem);
        i++;
      }
      saved.clear();
      if (!mounted) return;
      context.go('/cart');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not move walls to cart: $e'),
          backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('My Walls',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Consumer<SavedWallsProvider>(
        builder: (ctx, provider, _) {
          if (provider.isEmpty) {
            return _emptyState(context);
          }
          return Column(children: [
            // Summary header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              color: AppColors.surface,
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _summaryStat('${provider.count}', 'Walls'),
                _summaryStat('${provider.totalArea.toStringAsFixed(1)} m²', 'Area'),
                _summaryStat('${provider.totalRolls}', 'Rolls'),
                _summaryStat(_formatPrice(provider.totalPrice), 'UZS'),
              ]),
            ),
            // List
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 140),
                itemCount: provider.walls.length,
                itemBuilder: (ctx, i) => _wallRow(context, provider.walls[i], provider),
              ),
            ),
          ]);
        },
      ),
      floatingActionButton: Consumer<SavedWallsProvider>(builder: (ctx, provider, _) {
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (provider.isNotEmpty) Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FloatingActionButton.extended(
              heroTag: 'finish',
              backgroundColor: Colors.green,
              icon: _moving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Icon(Icons.shopping_cart_checkout, color: Colors.white),
              label: const Text('Finish & Cart',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              onPressed: _moving ? null : _finishAndGoToCart,
            ),
          ),
          FloatingActionButton.extended(
            heroTag: 'addwall',
            backgroundColor: AppColors.gold,
            icon: const Icon(Icons.add, color: Colors.black),
            label: const Text('Add Wall',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            // Go back to the shops list so user can pick another wallpaper.
            // If the app is pinned to one shop, home auto-redirects there.
            onPressed: () => context.go('/home'),
          ),
        ]);
      }),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.wallpaper, color: AppColors.textTertiary, size: 80),
        const SizedBox(height: 20),
        const Text('No walls yet',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 40),
          child: Text('Pick a shop, choose a wallpaper, scan a wall to add it here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          icon: const Icon(Icons.store, color: Colors.black),
          label: const Text('Browse Shops',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15)),
          onPressed: () => context.go('/home'),
        ),
      ]),
    );
  }

  Widget _wallRow(BuildContext ctx, SavedWall wall, SavedWallsProvider provider) {
    return Dismissible(
      key: ValueKey(wall.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 10),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: Colors.red.shade700,
          borderRadius: BorderRadius.circular(12)),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.delete, color: Colors.white),
          SizedBox(width: 6),
          Text('Discard', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ])),
      onDismissed: (_) {
        provider.remove(wall.id);
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Removed wall (${wall.wallpaper.name})'),
            duration: const Duration(seconds: 2)),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Screenshot thumbnail
          ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(11), bottomLeft: Radius.circular(11)),
            child: wall.screenshotPng != null
                ? Image.memory(wall.screenshotPng!,
                    width: 100, height: 110, fit: BoxFit.cover)
                : Container(
                    width: 100, height: 110,
                    color: AppColors.surface,
                    child: const Icon(Icons.image_not_supported,
                        color: AppColors.textTertiary, size: 30)),
          ),
          // Details
          Expanded(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(wall.wallpaper.name,
                style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(children: [
                const Icon(Icons.store, color: AppColors.textTertiary, size: 11),
                const SizedBox(width: 3),
                // ★ CHANGED: displayName() instead of .name (Unnamed shop fix)
                Expanded(child: Text(wall.shop.displayName(),
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                _miniStat(Icons.square_foot, '${wall.areaSqm.toStringAsFixed(1)} m²'),
                const SizedBox(width: 12),
                _miniStat(Icons.layers, '${wall.rollsNeeded} rolls'),
              ]),
              const SizedBox(height: 4),
              Text('${_formatPrice(wall.totalPrice)} UZS',
                style: const TextStyle(color: AppColors.gold, fontSize: 14, fontWeight: FontWeight.w800)),
            ]))),
          // Trash icon as alternative to swipe
          IconButton(
            icon: const Icon(Icons.close, color: AppColors.textTertiary, size: 18),
            onPressed: () {
              provider.remove(wall.id);
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('Removed wall (${wall.wallpaper.name})'),
                  duration: const Duration(seconds: 2)));
            },
          ),
        ]),
      ),
    );
  }

  Widget _miniStat(IconData icon, String text) => Row(children: [
    Icon(icon, color: AppColors.textTertiary, size: 12),
    const SizedBox(width: 3),
    Text(text, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
  ]);

  Widget _summaryStat(String value, String label) => Column(children: [
    Text(value, style: const TextStyle(color: AppColors.gold, fontSize: 18, fontWeight: FontWeight.w800)),
    const SizedBox(height: 2),
    Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
  ]);

  static String _formatPrice(double n) {
    final s = n.toStringAsFixed(0);
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
