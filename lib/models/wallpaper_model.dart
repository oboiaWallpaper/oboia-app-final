import 'package:cloud_firestore/cloud_firestore.dart';

class PbrMaps {
  final String albedoUrl;
  final String normalUrl;
  final String roughnessUrl;
  final String aoUrl;

  const PbrMaps({
    this.albedoUrl = '',
    this.normalUrl = '',
    this.roughnessUrl = '',
    this.aoUrl = '',
  });

  factory PbrMaps.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const PbrMaps();
    String _clean(String? url) => url?.trim().replaceAll(RegExp(r'^"|"$'), '') ?? '';
    return PbrMaps(
      albedoUrl: _clean(m['albedoUrl'] as String?),
      normalUrl: _clean(m['normalUrl'] as String?),
      roughnessUrl: _clean(m['roughnessUrl'] as String?),
      aoUrl: _clean(m['aoUrl'] as String?),
    );
  }

  bool get hasAlbedo => albedoUrl.isNotEmpty;
  bool get hasNormal => normalUrl.isNotEmpty;
  bool get hasRoughness => roughnessUrl.isNotEmpty;
  bool get hasAo => aoUrl.isNotEmpty;
  bool get hasFullPbr => hasAlbedo && hasNormal && hasRoughness && hasAo;
}

class WallpaperModel {
  final String id;
  final String name;
  final String description;
  final String category;
  final String brand;
  final double price;
  final double pricePerSqm;
  final double rollWidth;
  final double rollLength;
  final int stock;
  final String shopId;
  final bool isApproved;
  final String? thumbnailUrl;
  final PbrMaps pbr;
  final String? processingStatus;
  final DateTime createdAt;

  const WallpaperModel({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.brand,
    required this.price,
    required this.pricePerSqm,
    required this.rollWidth,
    required this.rollLength,
    required this.stock,
    required this.shopId,
    required this.isApproved,
    this.thumbnailUrl,
    required this.pbr,
    this.processingStatus,
    required this.createdAt,
  });

  bool get inStock => stock > 0;
  double get pricePerRoll => price;
  String get arTextureUrl =>
      pbr.albedoUrl.isNotEmpty ? pbr.albedoUrl : (thumbnailUrl ?? '');

  double sqmForWall(double wallWidth, double wallHeight) =>
      wallWidth * wallHeight;

  int rollsNeeded(double wallWidth, double wallHeight) {
    final sqm = sqmForWall(wallWidth, wallHeight);
    final perRoll = rollWidth * rollLength;
    if (perRoll <= 0) return 0;
    return (sqm / perRoll).ceil();
  }

  double totalPriceForWall(double wallWidth, double wallHeight) =>
      rollsNeeded(wallWidth, wallHeight) * price;

  static String _cleanUrl(String? url) =>
      url?.trim().replaceAll(RegExp(r'^"|"$'), '') ?? '';

  // ─────────────────────────────────────────────────────────────────────────
  // ★ FIELD-MAPPING FIX (so dashboard edits show up live in the app)
  //
  // The dashboard stores names/prices/category under DIFFERENT field names than
  // the app was reading, so edits saved but never appeared. These helpers read
  // the dashboard's fields first, then fall back to the old/mobile field names,
  // so BOTH new and legacy wallpapers work, and edits reflect immediately.
  //
  //   name      → nameEn / nameUz / name
  //   price     → sellPrice / price
  //   category  → categoryId / category
  //   rollWidth → rollWidth(m) / rollWidthCm÷100
  //   rollLength→ rollLength / rollLengthM
  // ─────────────────────────────────────────────────────────────────────────
  static String _pickName(Map<String, dynamic> d) {
    final en = (d['nameEn'] ?? '').toString().trim();
    final uz = (d['nameUz'] ?? '').toString().trim();
    final legacy = (d['name'] ?? '').toString().trim();
    if (en.isNotEmpty) return en;
    if (uz.isNotEmpty) return uz;
    if (legacy.isNotEmpty) return legacy;
    return 'Unnamed';
  }

  static String _pickDescription(Map<String, dynamic> d) {
    final en = (d['descriptionEn'] ?? '').toString().trim();
    final uz = (d['descriptionUz'] ?? '').toString().trim();
    final legacy = (d['description'] ?? '').toString().trim();
    if (en.isNotEmpty) return en;
    if (uz.isNotEmpty) return uz;
    return legacy;
  }

  static double _pickPrice(Map<String, dynamic> d) {
    final sell = d['sellPrice'];
    if (sell is num && sell > 0) return sell.toDouble();
    final p = d['price'];
    if (p is num) return p.toDouble();
    return 0;
  }

  static String _pickCategory(Map<String, dynamic> d) {
    final catId = (d['categoryId'] ?? '').toString().trim();
    if (catId.isNotEmpty) return catId;
    return (d['category'] ?? '').toString().trim();
  }

  static double _pickRollWidth(Map<String, dynamic> d) {
    // App expects metres. Dashboard stores rollWidthCm.
    final m = d['rollWidth'];
    if (m is num && m > 0) return m.toDouble();
    final cm = d['rollWidthCm'];
    if (cm is num && cm > 0) return cm.toDouble() / 100.0;
    return 0.53;
  }

  static double _pickRollLength(Map<String, dynamic> d) {
    final m = d['rollLength'];
    if (m is num && m > 0) return m.toDouble();
    final lm = d['rollLengthM'];
    if (lm is num && lm > 0) return lm.toDouble();
    return 10;
  }

  static bool _pickApproved(Map<String, dynamic> d) {
    // Prefer the boolean the app filters on; also accept the dashboard's
    // string status ('approved') so either schema works.
    if (d['isApproved'] is bool) return d['isApproved'] as bool;
    final status = (d['approvalStatus'] ?? '').toString().toLowerCase();
    if (status.isNotEmpty) return status == 'approved';
    return false;
  }

  static String? _pickThumb(Map<String, dynamic> d) {
    final t = _cleanUrl(d['thumbnailUrl'] as String?);
    if (t.isNotEmpty) return t;
    // Dashboard sometimes only has images[] / arTexture.
    final imgs = d['images'];
    if (imgs is List && imgs.isNotEmpty) {
      return _cleanUrl(imgs.first?.toString());
    }
    final ar = _cleanUrl(d['arTexture'] as String?);
    if (ar.isNotEmpty) return ar;
    return '';
  }

  factory WallpaperModel.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? {};
    return WallpaperModel._fromData(d, doc.id);
  }

  factory WallpaperModel.fromMap(Map<String, dynamic> d, String id) {
    return WallpaperModel._fromData(d, id);
  }

  // Single shared builder so fromDoc and fromMap stay identical.
  factory WallpaperModel._fromData(Map<String, dynamic> d, String id) {
    return WallpaperModel(
      id: id,
      name: _pickName(d),
      description: _pickDescription(d),
      category: _pickCategory(d),
      brand: (d['brand'] ?? '') as String,
      price: _pickPrice(d),
      pricePerSqm: ((d['pricePerSqm'] ?? 0) as num).toDouble(),
      rollWidth: _pickRollWidth(d),
      rollLength: _pickRollLength(d),
      stock: ((d['stock'] ?? 0) as num).toInt(),
      shopId: (d['shopId'] ?? '') as String,
      isApproved: _pickApproved(d),
      thumbnailUrl: _pickThumb(d),
      pbr: PbrMaps.fromMap(d['pbr'] as Map<String, dynamic>?),
      processingStatus: d['processingStatus'] as String?,
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'category': category,
      'brand': brand,
      'price': price,
      'pricePerSqm': pricePerSqm,
      'rollWidth': rollWidth,
      'rollLength': rollLength,
      'stock': stock,
      'shopId': shopId,
      'isApproved': isApproved,
      'thumbnailUrl': thumbnailUrl,
      'pbr': {
        'albedoUrl': pbr.albedoUrl,
        'normalUrl': pbr.normalUrl,
        'roughnessUrl': pbr.roughnessUrl,
        'aoUrl': pbr.aoUrl,
      },
      'processingStatus': processingStatus,
      'createdAt': createdAt,
    };
  }
}

typedef Wallpaper = WallpaperModel;
