import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/shop_model.dart';
import '../../models/wallpaper_model.dart';
import '../../providers/cart_provider.dart';
import '../../providers/saved_walls_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/wallpaper_card.dart';

class ShopScreen extends StatefulWidget {
  final String shopId;
  const ShopScreen({super.key, required this.shopId});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  String? _category;
  String _query = '';
  final _searchCtrl = TextEditingController();

  Map<String, String> _categoryNames = {};

  @override
  void initState() {
    super.initState();
    _loadCategoryNames();
  }

  Future<void> _loadCategoryNames() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('categories')
          .where('shopId', isEqualTo: widget.shopId)
          .get();
      if (!mounted) return;
      setState(() {
        _categoryNames = {
          for (final d in snap.docs)
            d.id: (d.data()['nameEn'] ??
                    d.data()['nameUz'] ??
                    d.data()['name'] ??
                    d.id)
                .toString(),
        };
      });
    } catch (_) {
      // Lookup failure is non-fatal — chips fall back to raw values.
    }
  }

  String _categoryLabel(String raw) => _categoryNames[raw] ?? raw;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<Shop?>(
        stream: FirestoreService.instance.shopStream(widget.shopId),
        builder: (context, shopSnap) {
          final shop = shopSnap.data;
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 220,
                pinned: true,
                backgroundColor: AppColors.background,
                iconTheme: const IconThemeData(color: AppColors.textPrimary),
                flexibleSpace: FlexibleSpaceBar(
                  background: _banner(shop),
                  title: Text(
                    shop?.displayName() ?? '',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
                  titlePadding:
                      const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
                ),
              ),
              if ((shop?.description ?? '').isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                    child: Text(
                      shop!.description,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: AppColors.textPrimary),
                    onChanged: (v) =>
                        setState(() => _query = v.toLowerCase().trim()),
                    decoration: const InputDecoration(
                      hintText: 'Search wallpapers',
                      prefixIcon: Icon(Icons.search,
                          color: AppColors.textSecondary, size: 20),
                    ),
                  ),
                ),
              ),
              StreamBuilder<List<Wallpaper>>(
                stream: FirestoreService.instance
                    .wallpapersForShopStream(widget.shopId),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SliverToBoxAdapter(child: _LoadingGrid());
                  }
                  if (snap.hasError) {
                    return SliverToBoxAdapter(
                      child: _msgBox(
                        icon: Icons.error_outline,
                        text: 'Could not load wallpapers.',
                      ),
                    );
                  }
                  final all = snap.data ?? const <Wallpaper>[];
                  final categories = <String>{
                    for (final w in all)
                      if (w.category.isNotEmpty) w.category
                  }.toList()
                    ..sort((a, b) =>
                        _categoryLabel(a).compareTo(_categoryLabel(b)));

                  final filtered = all.where((w) {
                    if (_category != null && w.category != _category) {
                      return false;
                    }
                    if (_query.isEmpty) return true;
                    return w.name.toLowerCase().contains(_query) ||
                        w.brand.toLowerCase().contains(_query);
                  }).toList();

                  return SliverMainAxisGroup(slivers: [
                    if (categories.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _categoryChips(categories),
                      ),
                    if (filtered.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _msgBox(
                          icon: Icons.inventory_2_outlined,
                          text: all.isEmpty
                              ? 'No wallpapers yet in this shop.'
                              : 'No results for this filter.',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.72,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final w = filtered[i];
                              // Card opens AR on tap (unchanged). A small gold
                              // cart button is overlaid to add WITHOUT scanning.
                              return Stack(
                                children: [
                                  Positioned.fill(
                                    child: WallpaperCard(
                                      wallpaper: w,
                                      onTap: () => _openAR(shop, w),
                                    ),
                                  ),
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: _AddToCartButton(
                                      onTap: () => _openQuantitySheet(shop, w),
                                    ),
                                  ),
                                ],
                              );
                            },
                            childCount: filtered.length,
                          ),
                        ),
                      ),
                  ]);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _openAR(Shop? shop, Wallpaper w) {
    if (shop == null) return;
    context.read<ShopProvider>().setContext(shop: shop, wallpaper: w);
    context.push('/ar', extra: {'wallpaper': w, 'shop': shop}).then((_) {
      if (!mounted) return;
      final staging = context.read<SavedWallsProvider>();
      if (staging.isNotEmpty) {
        context.push('/walls');
      }
    });
  }

  // Quantity picker — add a wallpaper to the cart without scanning a wall.
  void _openQuantitySheet(Shop? shop, Wallpaper w) {
    if (shop == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _QuantitySheet(wallpaper: w, shop: shop),
    );
  }

  Widget _banner(Shop? shop) {
    final url = shop?.bannerUrl ?? shop?.thumbnailUrl ?? '';
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url.isNotEmpty)
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(color: AppColors.surface),
            placeholder: (_, __) => Container(color: AppColors.surface),
          )
        else
          Container(color: AppColors.surface),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, AppColors.background],
            ),
          ),
        ),
      ],
    );
  }

  Widget _categoryChips(List<String> categories) {
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: categories.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            final active = _category == null;
            return _chip('All', active, () => setState(() => _category = null));
          }
          final cat = categories[i - 1];
          final active = _category == cat;
          return _chip(_categoryLabel(cat), active,
              () => setState(() => _category = cat));
        },
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: active ? AppColors.gold : AppColors.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active ? AppColors.gold : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.black : AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _msgBox({required IconData icon, required String text}) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Icon(icon, color: AppColors.textTertiary, size: 48),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

// Small gold cart button shown on each wallpaper card.
class _AddToCartButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddToCartButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.gold,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.add_shopping_cart_rounded,
              color: Colors.black, size: 18),
        ),
      ),
    );
  }
}

// Bottom sheet: choose quantity (rolls) and add to cart without scanning.
class _QuantitySheet extends StatefulWidget {
  final Wallpaper wallpaper;
  final Shop shop;
  const _QuantitySheet({required this.wallpaper, required this.shop});

  @override
  State<_QuantitySheet> createState() => _QuantitySheetState();
}

class _QuantitySheetState extends State<_QuantitySheet> {
  int _qty = 1;
  bool _adding = false;

  // Simple price formatter (no external dependency): 1234567 -> "1 234 567"
  String _money(num v) {
    final s = v.round().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.wallpaper;
    final total = _qty * w.price;

    return Container(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 20 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: (w.thumbnailUrl != null && w.thumbnailUrl!.isNotEmpty)
                      ? CachedNetworkImage(
                          imageUrl: w.thumbnailUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              Container(color: AppColors.surface),
                        )
                      : Container(
                          color: AppColors.surface,
                          child: const Icon(Icons.wallpaper,
                              color: AppColors.textTertiary),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_money(w.price)} so\'m / roll',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Quantity (rolls)',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                children: [
                  _stepBtn(Icons.remove, () {
                    if (_qty > 1) setState(() => _qty--);
                  }),
                  Container(
                    width: 48,
                    alignment: Alignment.center,
                    child: Text(
                      '$_qty',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  _stepBtn(Icons.add, () => setState(() => _qty++)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Total',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '${_money(total)} so\'m',
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _adding ? null : _add,
              icon: _adding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.shopping_cart_checkout_rounded,
                      color: Colors.black, size: 20),
              label: const Text(
                'Add to cart',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback onTap) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: AppColors.textPrimary, size: 20),
        ),
      ),
    );
  }

  Future<void> _add() async {
    setState(() => _adding = true);
    try {
      await context.read<CartProvider>().addWallpaperByQuantity(
            wallpaper: widget.wallpaper,
            shopId: widget.shop.id,
            shopName: widget.shop.displayName(),
            quantity: _qty,
          );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Added to cart'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _adding = false);
    }
  }
}

class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.72,
        ),
        itemBuilder: (_, __) => const WallpaperCardSkeleton(),
      ),
    );
  }
}
