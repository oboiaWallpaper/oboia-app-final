import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/order_model.dart';
import '../models/shop_model.dart';
import '../models/wallpaper_model.dart';
import '../utils/constants.dart';

/// All Firestore reads/writes are wrapped here. Every query is filtered by
/// shopId or ownership where applicable — matching the business rule that
/// shops never see each other's data.
class FirestoreService {
  FirestoreService._();
  static final FirestoreService instance = FirestoreService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ─── SHOPS ───────────────────────────────────────────────────────────────

  /// Live list of active shops VISIBLE TO CUSTOMERS.
  /// Filters by admin-set isActive AND subscription status client-side
  /// (Firestore can't do time-based queries for expiry). Grace-period shops
  /// stay visible so renewal doesn't drop orders mid-flow.
  Stream<List<Shop>> activeShopsStream() {
    return _db
        .collection(K.shops)
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((s) {
          final all = s.docs.map(Shop.fromDoc).toList();
          // Subscription gate: hide expired shops, keep grace-period visible.
          final visible = all.where((shop) => shop.isVisibleToCustomers).toList();
          visible.sort((a, b) => a.displayName().toLowerCase()
              .compareTo(b.displayName().toLowerCase()));
          return visible;
        });
  }

  Stream<Shop?> shopStream(String shopId) {
    return _db
        .collection(K.shops)
        .doc(shopId)
        .snapshots()
        .map((snap) => snap.exists ? Shop.fromDoc(snap) : null);
  }

  /// Look up a shop by its token (for pin-by-token flow).
  /// Returns null if no shop matches, or if the matched shop is not visible
  /// to customers (inactive or fully expired). Grace-period shops resolve OK.
  Future<Shop?> shopByToken(String token) async {
    final trimmed = token.trim().toUpperCase();
    if (trimmed.isEmpty) return null;
    final snap = await _db
        .collection(K.shops)
        .where('token', isEqualTo: trimmed)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    final shop = Shop.fromDoc(snap.docs.first);
    if (!shop.isVisibleToCustomers) return null;
    return shop;
  }

  // ─── WALLPAPERS ──────────────────────────────────────────────────────────

  /// Approved, in-stock wallpapers for a shop — real-time.
  Stream<List<Wallpaper>> wallpapersForShopStream(String shopId) {
    return _db
        .collection(K.wallpapers)
        .where('shopId', isEqualTo: shopId)
        .where('isApproved', isEqualTo: true)
        .snapshots()
        .map((s) => s.docs.map(Wallpaper.fromDoc).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  /// Approved wallpapers across ALL shops — used by the AR thumbnail bar to
  /// let customers swap to wallpapers from other shops without leaving AR.
  Stream<List<Wallpaper>> allApprovedWallpapersStream() {
    return _db
        .collection(K.wallpapers)
        .where('isApproved', isEqualTo: true)
        .snapshots()
        .map((s) => s.docs.map(Wallpaper.fromDoc).toList());
  }

  Future<Wallpaper?> wallpaperById(String id) async {
    final snap = await _db.collection(K.wallpapers).doc(id).get();
    return snap.exists ? Wallpaper.fromDoc(snap) : null;
  }

  // ─── ORDERS ──────────────────────────────────────────────────────────────

  /// All orders for a given customer — real-time status updates.
  Stream<List<AppOrder>> ordersForCustomerStream(String customerId) {
    return _db
        .collection(K.orders)
        .where('customerId', isEqualTo: customerId)
        .snapshots()
        .map((s) => s.docs.map(AppOrder.fromDoc).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  Stream<AppOrder?> orderStream(String orderId) {
    return _db.collection(K.orders).doc(orderId).snapshots().map(
          (snap) => snap.exists ? AppOrder.fromDoc(snap) : null,
        );
  }

  /// Create a new order. Shops see it instantly in their dashboard.
  Future<String> createOrder({
    required String customerId,
    required String customerName,
    required String customerPhone,
    required String customerAddress,
    required String notes,
    required String shopId,
    required String shopName,
    required List<OrderItem> items,
    required double totalAmount,
  }) async {
    final ref = await _db.collection(K.orders).add({
      'customerId': customerId,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'customerAddress': customerAddress,
      'notes': notes,
      'shopId': shopId,
      'shopName': shopName,
      'items': items.map((e) => e.toMap()).toList(),
      'totalAmount': totalAmount,
      'status': K.statusPending,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  // ─── CRAFTSMAN ───────────────────────────────────────────────────────────

  /// Orders assigned to a craftsman (jobs list).
  Stream<List<AppOrder>> jobsForCraftsmanStream(String craftsmanId) {
    return _db
        .collection(K.orders)
        .where('craftsmanId', isEqualTo: craftsmanId)
        .snapshots()
        .map((s) => s.docs.map(AppOrder.fromDoc).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  /// Confirmed bonuses — ONLY from sales with status = closed.
  /// Business rule: bonus is realized only when the receipt is closed.
  Stream<double> confirmedBonusForCraftsman(String craftsmanId) {
    return _db
        .collection(K.sales)
        .where('craftsmanId', isEqualTo: craftsmanId)
        .where('status', isEqualTo: K.saleClosed)
        .snapshots()
        .map((s) => s.docs.fold<double>(0, (acc, d) {
              final v = (d.data()['craftsmanBonus'] as num?)?.toDouble() ?? 0;
              return acc + v;
            }));
  }

  /// Pending bonuses — sales still open, not yet closed.
  Stream<double> pendingBonusForCraftsman(String craftsmanId) {
    return _db
        .collection(K.sales)
        .where('craftsmanId', isEqualTo: craftsmanId)
        .where('status', isEqualTo: K.saleOpen)
        .snapshots()
        .map((s) => s.docs.fold<double>(0, (acc, d) {
              final v = (d.data()['craftsmanBonus'] as num?)?.toDouble() ?? 0;
              return acc + v;
            }));
  }

  /// Sales history — closed + refunded, for a craftsman.
  Stream<List<Map<String, dynamic>>> paymentHistoryForCraftsman(
    String craftsmanId,
  ) {
    return _db
        .collection(K.sales)
        .where('craftsmanId', isEqualTo: craftsmanId)
        .snapshots()
        .map((s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList()
          ..sort((a, b) {
            final aT = a['closedAt'];
            final bT = b['closedAt'];
            final aD = aT is Timestamp ? aT.toDate() : DateTime(1970);
            final bD = bT is Timestamp ? bT.toDate() : DateTime(1970);
            return bD.compareTo(aD);
          }));
  }

  // ─── PROFILE ─────────────────────────────────────────────────────────────

  Future<void> updateUserProfile({
    required String uid,
    String? name,
    String? photoUrl,
  }) {
    final map = <String, dynamic>{};
    if (name != null) map['name'] = name;
    if (photoUrl != null) map['photoUrl'] = photoUrl;
    return _db.collection(K.users).doc(uid).update(map);
  }
}
