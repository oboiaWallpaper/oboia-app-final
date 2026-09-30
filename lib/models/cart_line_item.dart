// lib/models/cart_line_item.dart
//
// One line in a customer's cart: a wallpaper from a shop,
// with the wall measurements it was calculated for.

import 'shop_model.dart';
import 'wallpaper_model.dart';

class CartLineItem {
  final WallpaperModel wallpaper;
  final ShopModel shop;
  final int wallCount;
  final double totalArea;
  final int rollsNeeded;
  final double lineTotal;

  const CartLineItem({
    required this.wallpaper,
    required this.shop,
    required this.wallCount,
    required this.totalArea,
    required this.rollsNeeded,
    required this.lineTotal,
  });
}
