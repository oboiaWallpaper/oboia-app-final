import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/cart_model.dart';
import '../../providers/cart_provider.dart';
import '../../providers/locale_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/custom_button.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final locale = context.watch<LocaleProvider>();
    String t(String k) => locale.t(k);
    final items = cart.items;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('cart_title')),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () => _confirmClear(context, t),
              child: Text(t('cart_remove')),
            ),
        ],
      ),
      body: items.isEmpty
          ? _empty(context, t)
          : Column(
              children: [
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => _CartRow(
                      item: items[i],
                      t: t,
                      onRemove: () =>
                          context.read<CartProvider>().remove(items[i].id),
                    ),
                  ),
                ),
                _footer(context, cart, t),
              ],
            ),
    );
  }

  Widget _empty(BuildContext context, String Function(String) t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shopping_bag_outlined,
                color: AppColors.textTertiary, size: 64),
            const SizedBox(height: 16),
            Text(
              t('cart_empty'),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t('cart_empty_sub'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            CustomButton(
              label: t('cart_browse'),
              variant: ButtonVariant.outline,
              expanded: false,
              onPressed: () => context.go('/home'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, CartProvider cart,
      String Function(String) t) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                t('cart_total'),
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
              Text(
                Fmt.uzs(cart.grandTotal),
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          CustomButton(
            label: t('cart_checkout'),
            icon: Icons.arrow_forward_rounded,
            onPressed: () => context.push('/order-confirm'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(
      BuildContext context, String Function(String) t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(t('cart_remove')),
        content: Text(t('cart_empty_sub')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('common_cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('cart_remove'),
                style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<CartProvider>().clear();
    }
  }
}

class _CartRow extends StatelessWidget {
  final CartItem item;
  final VoidCallback onRemove;
  final String Function(String) t;

  const _CartRow({required this.item, required this.onRemove, required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 64,
              height: 64,
              child: item.wallpaperThumbnail != null &&
                      item.wallpaperThumbnail!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: item.wallpaperThumbnail!,
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
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.wallpaperName,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  item.shopName,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _chip('${Fmt.meters(item.wallWidth)} × ${Fmt.meters(item.wallHeight)}'),
                    _chip(Fmt.sqm(item.sqm)),
                    _chip('${item.rollsNeeded} ${t('cart_rolls')}'),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  Fmt.uzs(item.totalPrice),
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline_rounded,
                color: AppColors.error),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 10.5),
      ),
    );
  }
}
