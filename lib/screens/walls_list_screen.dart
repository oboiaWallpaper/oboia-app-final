// lib/screens/walls_list_screen.dart
//
// The user's "home base" between AR sessions. Shows every wall they've
// scanned + saved, with screenshot thumbnail, wallpaper name + shop, area,
// rolls, price. Each row can be discarded. Floating "Add Wall" button
// returns to AR for another scan. "Finish & Cart" goes to cart screen.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/saved_wall.dart';
import '../providers/saved_walls_provider.dart';
import '../theme/app_colors.dart';

class WallsListScreen extends StatelessWidget {
  const WallsListScreen({super.key});

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
                _summaryStat('${_formatPrice(provider.totalPrice)}', 'UZS'),
              ]),
            ),
            // List
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
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
              icon: const Icon(Icons.shopping_cart_checkout, color: Colors.white),
              label: const Text('Finish & Cart',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              onPressed: () => context.push('/cart'),
            ),
          ),
          FloatingActionButton.extended(
            heroTag: 'addwall',
            backgroundColor: AppColors.gold,
            icon: const Icon(Icons.add, color: Colors.black),
            label: const Text('Add Wall',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            onPressed: () => context.push('/shop-picker'),
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
          onPressed: () => context.push('/shop-picker'),
        ),
      ]),
    );
  }

  Widget _wallRow(BuildContext ctx, SavedWall wall, SavedWallsProvider provider) {
    return Dismissible(
      key: ValueKey(wall.id),
      direction: DismissDirection.endToStart,
      background: Container(
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
                Expanded(child: Text(wall.shop.name,
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
