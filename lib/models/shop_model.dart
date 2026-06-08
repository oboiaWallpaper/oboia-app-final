// lib/models/shop_model.dart
//
// Adds nested ShopSubscription with lazy status computation. Shops without
// a subscription field (legacy or unset) get status 'none' and are NOT
// visible to customers — admin must extend subscription to activate.

import 'package:cloud_firestore/cloud_firestore.dart';

class ShopSubscription {
  final bool active;                // raw flag (admin override)
  final String plan;                // 'monthly'
  final double amountUsd;           // 25
  final int graceDays;              // 5
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final DateTime? lastPaidAt;

  const ShopSubscription({
    this.active = false,
    this.plan = 'monthly',
    this.amountUsd = 25,
    this.graceDays = 5,
    this.startedAt,
    this.expiresAt,
    this.lastPaidAt,
  });

  factory ShopSubscription.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const ShopSubscription();
    DateTime? ts(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      return null;
    }
    return ShopSubscription(
      active: (m['active'] ?? false) as bool,
      plan: (m['plan'] ?? 'monthly') as String,
      amountUsd: ((m['amountUsd'] ?? 25) as num).toDouble(),
      graceDays: ((m['graceDays'] ?? 5) as num).toInt(),
      startedAt: ts(m['startedAt']),
      expiresAt: ts(m['expiresAt']),
      lastPaidAt: ts(m['lastPaidAt']),
    );
  }

  /// Status: 'active' | 'expiring' | 'grace' | 'expired' | 'none'
  /// Computed lazily — matches dashboard's getSubscriptionStatus exactly.
  String get status {
    if (expiresAt == null) return 'none';
    final now = DateTime.now();
    final daysUntilExpiry = expiresAt!.difference(now).inHours / 24.0;
    if (daysUntilExpiry > 7) return 'active';
    if (daysUntilExpiry > 0) return 'expiring';
    if (daysUntilExpiry > -graceDays) return 'grace';
    return 'expired';
  }

  /// Grace-period shops are still visible so renewal doesn't drop orders.
  bool get isVisibleToCustomers {
    final s = status;
    return s == 'active' || s == 'expiring' || s == 'grace';
  }

  int? get daysRemaining {
    if (expiresAt == null) return null;
    return expiresAt!.difference(DateTime.now()).inHours ~/ 24;
  }
}

class ShopModel {
  final String id;
  final String token;
  final String name;           // legacy field, fallback if nameEn/nameUz empty
  final String nameUz;
  final String nameEn;
  final String description;
  final String? thumbnailUrl;
  final String? bannerUrl;
  final bool isActive;
  final double exchangeRate;
  final String? ownerId;
  final int wallpaperCount;
  final DateTime createdAt;
  final ShopSubscription subscription;

  const ShopModel({
    required this.id,
    required this.token,
    required this.name,
    this.nameUz = '',
    this.nameEn = '',
    required this.description,
    this.thumbnailUrl,
    this.bannerUrl,
    required this.isActive,
    required this.exchangeRate,
    this.ownerId,
    this.wallpaperCount = 0,
    required this.createdAt,
    this.subscription = const ShopSubscription(),
  });

  /// True only if admin says active AND subscription is in a visible state.
  bool get isVisibleToCustomers => isActive && subscription.isVisibleToCustomers;

  /// Localized display name with graceful fallbacks.
  String displayName([String lang = 'en']) {
    if (lang == 'uz' && nameUz.isNotEmpty) return nameUz;
    if (lang == 'en' && nameEn.isNotEmpty) return nameEn;
    if (name.isNotEmpty) return name;
    return nameEn.isNotEmpty ? nameEn : nameUz;
  }

  factory ShopModel.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? {};
    return ShopModel(
      id: doc.id,
      token: (d['token'] ?? '') as String,
      name: (d['name'] ?? d['nameEn'] ?? d['nameUz'] ?? 'Unnamed shop') as String,
      nameUz: (d['nameUz'] ?? '') as String,
      nameEn: (d['nameEn'] ?? '') as String,
      description: (d['description'] ?? '') as String,
      thumbnailUrl: d['thumbnailUrl'] as String?,
      bannerUrl: d['bannerUrl'] as String?,
      isActive: (d['isActive'] ?? true) as bool,
      exchangeRate: ((d['exchangeRate'] ?? 12500) as num).toDouble(),
      ownerId: d['ownerId'] as String?,
      wallpaperCount: ((d['wallpaperCount'] ?? 0) as num).toInt(),
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      subscription: ShopSubscription.fromMap(d['subscription'] as Map<String, dynamic>?),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'token': token,
      'name': name,
      'nameUz': nameUz,
      'nameEn': nameEn,
      'description': description,
      'thumbnailUrl': thumbnailUrl,
      'bannerUrl': bannerUrl,
      'isActive': isActive,
      'exchangeRate': exchangeRate,
      'ownerId': ownerId,
      'wallpaperCount': wallpaperCount,
      'createdAt': createdAt,
    };
  }
}

// Backwards compatibility alias
typedef Shop = ShopModel;
