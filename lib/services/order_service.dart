// lib/services/order_service.dart
//
// Submits orders to Firestore. One order document per shop. If user's cart
// has wallpapers from 2 shops, 2 separate order docs are written, so each
// shop owner only sees their own orders.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../providers/saved_walls_provider.dart';

class OrderService {
  OrderService._();
  static final OrderService instance = OrderService._();

  final _db = FirebaseFirestore.instance;

  /// Submit orders for the current cart. Returns list of order IDs that
  /// were successfully written. Throws on failure.
  Future<List<String>> submitOrders({
    required Map<String, List<CartLineItem>> byShop,
    String? notes,
  }) async {
    final userId = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    final batch = _db.batch();
    final orderIds = <String>[];
    final createdAt = FieldValue.serverTimestamp();

    for (final entry in byShop.entries) {
      final shopId = entry.key;
      final items = entry.value;
      if (items.isEmpty) continue;

      final docRef = _db.collection('orders').doc();
      orderIds.add(docRef.id);

      final lineTotalSum = items.fold<double>(0, (sum, l) => sum + l.lineTotal);

      batch.set(docRef, {
        'orderId': docRef.id,
        'shopId': shopId,
        'shopName': items.first.shop.name,
        'userId': userId,
        'status': 'pending',
        'items': items.map((l) => {
          'wallpaperId': l.wallpaper.id,
          'wallpaperName': l.wallpaper.name,
          'thumbnailUrl': l.wallpaper.thumbnailUrl ?? '',
          'wallCount': l.wallCount,
          'totalArea': l.totalArea,
          'rollWidth': l.wallpaper.rollWidth,
          'rollLength': l.wallpaper.rollLength,
          'pricePerRoll': l.wallpaper.price,
          'rollsNeeded': l.rollsNeeded,
          'lineTotal': l.lineTotal,
        }).toList(),
        'totalAmount': lineTotalSum,
        'currency': 'UZS',
        'notes': notes ?? '',
        'createdAt': createdAt,
      });
    }

    await batch.commit();
    return orderIds;
  }
}
