// lib/screens/home/home_screen.dart
//
// Hybrid mode home screen with EN/UZ language support.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/shop_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../providers/locale_provider.dart';
import '../../providers/pinned_shop_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/constants.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/shop_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _redirectedToPinned = false;

  String _t(String key) => context.read<LocaleProvider>().t(key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PinnedShopProvider>().refresh();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _maybeRedirectToPinned(BuildContext ctx, Shop? pinned) {
    if (pinned == null || _redirectedToPinned) return;
    _redirectedToPinned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ctx.push('/shop/${pinned.id}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final cart = context.watch<CartProvider>();
    final pinned = context.watch<PinnedShopProvider>();
    final locale = context.watch<LocaleProvider>();
    final name = (auth.appUser?.name.split(' ').first ?? _t('home_there'));

    _maybeRedirectToPinned(context, pinned.shop);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_t('home_hello')}, $name',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _t('home_find_wallpaper'),
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // ★ Language toggle — tap to switch EN/UZ from the first screen.
                  _langButton(locale),
                  const SizedBox(width: 8),
                  _iconButton(
                    Icons.shopping_bag_outlined,
                    badge: cart.count,
                    onTap: () => context.push('/cart'),
                  ),
                  const SizedBox(width: 8),
                  _iconButton(
                    Icons.person_outline_rounded,
                    onTap: () => context.push('/profile'),
                  ),
                ],
              ),
            ),

            _PinBanner(
              pinned: pinned.shop,
              t: _t,
              onEnterCode: () => context.push('/pin-shop'),
              onOpenShop: (s) => context.push('/shop/${s.id}'),
              onUnpin: () async {
                await context.read<PinnedShopProvider>().unpin();
                _redirectedToPinned = false;
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(_t('home_unpinned_msg')),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: AppColors.textPrimary),
                onChanged: (v) => setState(() => _query = v.toLowerCase()),
                decoration: InputDecoration(
                  hintText: _t('home_search_shops'),
                  prefixIcon: const Icon(Icons.search,
                      color: AppColors.textSecondary, size: 20),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded,
                              color: AppColors.textSecondary, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Shop>>(
                stream: FirestoreService.instance.activeShopsStream(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return ListView.builder(
                      itemCount: 5,
                      itemBuilder: (_, __) => const ShopCardSkeleton(),
                    );
                  }
                  if (snap.hasError) {
                    return _error('${_t('home_load_error')}\n${snap.error}');
                  }
                  var shops = snap.data ?? const <Shop>[];

                  if (pinned.isPinned) {
                    shops = shops.where((s) => s.id == pinned.shop!.id).toList();
                  }

                  shops = shops
                      .where((s) => _query.isEmpty ||
                          s.displayName().toLowerCase().contains(_query) ||
                          s.description.toLowerCase().contains(_query))
                      .toList();
                  if (shops.isEmpty) {
                    return _empty(_query.isEmpty
                        ? (pinned.isPinned
                            ? _t('home_pinned_unavailable')
                            : _t('home_no_shops'))
                        : '${_t('home_no_match')} "$_query".');
                  }
                  return RefreshIndicator(
                    color: AppColors.gold,
                    onRefresh: () async {
                      await context.read<PinnedShopProvider>().refresh();
                      await Future.delayed(const Duration(milliseconds: 400));
                    },
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: shops.length,
                      itemBuilder: (context, i) {
                        final shop = shops[i];
                        return _LiveWallpaperCountCard(
                          shop: shop,
                          onTap: () => context.push('/shop/${shop.id}'),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ★ Compact language toggle button showing the current language code.
  Widget _langButton(LocaleProvider locale) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => locale.toggle(),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language_rounded,
                  color: AppColors.gold, size: 18),
              const SizedBox(width: 4),
              Text(
                locale.lang.toUpperCase(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon,
      {required VoidCallback onTap, int badge = 0}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.textPrimary, size: 20),
            ),
          ),
        ),
        if (badge > 0)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.gold,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.background, width: 2),
              ),
              child: Text(
                '$badge',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _empty(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storefront_outlined,
                color: AppColors.textTertiary, size: 56),
            const SizedBox(height: 16),
            Text(
              msg,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _error(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 48),
            const SizedBox(height: 12),
            Text(
              msg,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinBanner extends StatelessWidget {
  final Shop? pinned;
  final String Function(String) t;
  final VoidCallback onEnterCode;
  final void Function(Shop) onOpenShop;
  final VoidCallback onUnpin;

  const _PinBanner({
    required this.pinned,
    required this.t,
    required this.onEnterCode,
    required this.onOpenShop,
    required this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    if (pinned == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        child: InkWell(
          onTap: onEnterCode,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.qr_code_2,
                    color: AppColors.textSecondary, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('home_have_code'),
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ),
                const Icon(Icons.chevron_right,
                    color: AppColors.textSecondary, size: 16),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.gold.withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.gold.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.bookmark, color: AppColors.gold, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: () => onOpenShop(pinned!),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t('home_pinned_to'),
                      style: const TextStyle(
                          color: AppColors.textTertiary, fontSize: 10),
                    ),
                    Text(
                      pinned!.displayName(),
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: onUnpin,
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: Text(t('home_unpin'),
                  style: const TextStyle(color: AppColors.error, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveWallpaperCountCard extends StatelessWidget {
  final Shop shop;
  final VoidCallback onTap;

  const _LiveWallpaperCountCard({required this.shop, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(K.wallpapers)
          .where('shopId', isEqualTo: shop.id)
          .where('isApproved', isEqualTo: true)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? shop.wallpaperCount;
        return ShopCard(shop: shop, wallpaperCount: count, onTap: onTap);
      },
    );
  }
}
