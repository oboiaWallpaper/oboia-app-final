import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/order_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/order_status_badge.dart';

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthProvider>().firebaseUser?.uid;
    final locale = context.watch<LocaleProvider>();
    String t(String k) => locale.t(k);

    return Scaffold(
      appBar: AppBar(title: Text(t('orders_title'))),
      body: uid == null
          ? Center(child: Text(t('orders_empty')))
          : StreamBuilder<List<AppOrder>>(
              stream:
                  FirestoreService.instance.ordersForCustomerStream(uid),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child:
                        CircularProgressIndicator(color: AppColors.gold),
                  );
                }
                final orders = snap.data ?? const <AppOrder>[];
                if (orders.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.receipt_long_outlined,
                              color: AppColors.textTertiary, size: 56),
                          const SizedBox(height: 14),
                          Text(
                            t('orders_empty'),
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
                            style: const TextStyle(
                                color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: orders.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _OrderTile(order: orders[i]),
                );
              },
            ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final AppOrder order;
  const _OrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final firstItem = order.items.isEmpty ? null : order.items.first;
    final extra = order.items.length > 1 ? ' +${order.items.length - 1}' : '';

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => context.push('/orders/${order.id}'),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '#${Fmt.shortCode(order.id)}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  Fmt.dateTime(order.createdAt),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
                const Spacer(),
                OrderStatusBadge(status: order.status),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              firstItem == null
                  ? order.shopName
                  : '${firstItem.wallpaperName}$extra',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  order.shopName,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                  ),
                ),
                Text(
                  Fmt.uzs(order.totalAmount),
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
