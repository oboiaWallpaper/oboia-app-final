// lib/l10n/app_strings.dart
//
// App-wide translations (English + Uzbek). Access via context.t('key') or
// AppStrings.of(context).t('key'). Keys are grouped by screen. Uzbek is
// real, hand-written Uzbek (ported from the dashboard), not machine output.
//
// To add a new string: add the key to BOTH `en` and `uz` maps below, then
// use t('your_key') in any widget. Missing keys fall back to English, then
// to the raw key, so the app never crashes on a missing translation.

class AppStrings {
  static const Map<String, Map<String, String>> _data = {
    'en': {
      // Common
      'common_ok': 'OK',
      'common_cancel': 'Cancel',
      'common_save': 'Save',
      'common_close': 'Close',
      'common_retry': 'Retry',
      'common_loading': 'Loading...',
      'common_search': 'Search',
      'common_yes': 'Yes',
      'common_no': 'No',
      'common_rolls': 'rolls',

      // Home
      'home_hello': 'Hello',
      'home_there': 'there',
      'home_find_wallpaper': 'Find your wallpaper',
      'home_search_shops': 'Search shops',
      'home_have_code': 'Have a shop code? Pin your app to one shop.',
      'home_pinned_to': 'Pinned to',
      'home_unpin': 'Unpin',
      'home_unpinned_msg': 'Unpinned. Showing all shops.',
      'home_no_shops': 'No active shops yet.\nCheck back soon.',
      'home_pinned_unavailable': 'Your pinned shop is no longer available.\nTap "Unpin" above to browse all shops.',
      'home_no_match': 'No shops match',
      'home_load_error': 'Could not load shops.',

      // Profile
      'profile_title': 'Profile',
      'profile_edit_name': 'Edit name',
      'profile_your_name': 'Your name',
      'profile_my_orders': 'My orders',
      'profile_language': 'Language',
      'profile_help': 'Help & support',
      'profile_sign_out': 'Sign out',
      'profile_upload_failed': 'Upload failed. Make sure Firebase Storage is enabled.',
      'profile_language_pick': 'Choose your language',
      'profile_english': 'English',
      'profile_uzbek': "O'zbek",
      'profile_help_body': 'Need help with your order?\nContact the shop directly through the order screen, or reach OBOIA support via your dashboard provider.',

      // Shop
      'shop_wallpapers': 'Wallpapers',
      'shop_no_wallpapers': 'No wallpapers in this shop yet.',
      'shop_view_ar': 'View in AR',
      'shop_add_to_cart': 'Add to cart',
      'shop_categories': 'Categories',
      'shop_all': 'All',

      // Cart
      'cart_title': 'Cart',
      'cart_empty': 'Your cart is empty',
      'cart_empty_sub': 'Browse shops and add wallpapers to get started.',
      'cart_browse': 'Browse shops',
      'cart_total': 'Total',
      'cart_checkout': 'Place order',
      'cart_remove': 'Remove',
      'cart_rolls': 'rolls',
      'cart_area': 'Area',

      // Order confirm
      'order_confirm_title': 'Confirm order',
      'order_name': 'Your name',
      'order_phone': 'Phone number',
      'order_address': 'Delivery address',
      'order_notes': 'Notes (optional)',
      'order_place': 'Place order',
      'order_placing': 'Placing order...',
      'order_success': 'Order placed! The shop will contact you.',
      'order_phone_required': 'Phone number is required',

      // Orders list
      'orders_title': 'My orders',
      'orders_empty': 'No orders yet',
      'orders_status_pending': 'Pending',
      'orders_status_negotiating': 'Negotiating',
      'orders_status_ready': 'Ready',
      'orders_status_closed': 'Completed',
      'orders_status_cancelled': 'Cancelled',
      'orders_view': 'View details',

      // Order detail
      'order_detail_title': 'Order details',
      'order_detail_items': 'Items',
      'order_detail_status': 'Status',
      'order_detail_shop': 'Shop',
      'order_detail_total': 'Estimated total',

      // AR
      'ar_start_scan': 'Start Scan',
      'ar_done_scanning': 'Done Scanning',
      'ar_scan_hint': 'Move slowly around the room.\nWalls light up as they are detected.',
      'ar_edit': 'Edit',
      'ar_save': 'Save',
      'ar_browse': 'Browse',
      'ar_browse_more': 'Browse more wallpapers',
      'ar_shops': 'Shops',
      'ar_area': 'Area',
      'ar_rolls': 'Rolls',
      'ar_total': 'Total',
      'ar_paint': 'Paint',
      'ar_erase': 'Erase',
      'ar_lasso': 'Lasso',
      'ar_undo': 'Undo',
      'ar_reset': 'Reset',
      'ar_done': 'Done',
      'ar_opacity': 'Opacity',
      'ar_hide_behind': 'Hide wallpaper behind objects',
      'ar_no_shops': 'No shops available',
      'ar_no_categories': 'No categories in this shop',
      'ar_no_wallpapers': 'No wallpapers in this category',

      // Pin shop
      'pin_title': 'Enter shop code',
      'pin_hint': 'Enter the SHOP-XXXXX code from your shopkeeper',
      'pin_button': 'Pin shop',
      'pin_invalid': 'Invalid or inactive shop code.',

      // Walls list
      'walls_title': 'My Walls',
      'walls_empty': 'No saved walls yet',
      'walls_finish_cart': 'Finish & Cart',

      // Auth
      'auth_welcome': 'Welcome to OBOIA',
      'auth_subtitle': 'See wallpaper on your walls before you buy',
      'auth_login': 'Log in',
      'auth_signup': 'Sign up',
      'auth_email': 'Email',
      'auth_password': 'Password',
      'auth_name': 'Full name',
      'auth_continue': 'Continue',
      'auth_have_account': 'Already have an account?',
      'auth_no_account': "Don't have an account?",
    },

    'uz': {
      // Common
      'common_ok': 'OK',
      'common_cancel': 'Bekor qilish',
      'common_save': 'Saqlash',
      'common_close': 'Yopish',
      'common_retry': 'Qayta urinish',
      'common_loading': 'Yuklanmoqda...',
      'common_search': 'Qidirish',
      'common_yes': 'Ha',
      'common_no': "Yo'q",
      'common_rolls': 'rulon',

      // Home
      'home_hello': 'Salom',
      'home_there': 'foydalanuvchi',
      'home_find_wallpaper': 'Devor qog\'ozingizni toping',
      'home_search_shops': 'Do\'konlarni qidirish',
      'home_have_code': 'Do\'kon kodingiz bormi? Ilovani bitta do\'konga biriktiring.',
      'home_pinned_to': 'Biriktirilgan',
      'home_unpin': 'Ajratish',
      'home_unpinned_msg': 'Ajratildi. Barcha do\'konlar ko\'rsatilmoqda.',
      'home_no_shops': 'Hozircha faol do\'konlar yo\'q.\nKeyinroq qayta tekshiring.',
      'home_pinned_unavailable': 'Biriktirilgan do\'koningiz endi mavjud emas.\nBarcha do\'konlarni ko\'rish uchun "Ajratish"ni bosing.',
      'home_no_match': 'Mos do\'kon topilmadi',
      'home_load_error': 'Do\'konlarni yuklab bo\'lmadi.',

      // Profile
      'profile_title': 'Profil',
      'profile_edit_name': 'Ismni tahrirlash',
      'profile_your_name': 'Ismingiz',
      'profile_my_orders': 'Buyurtmalarim',
      'profile_language': 'Til',
      'profile_help': 'Yordam',
      'profile_sign_out': 'Chiqish',
      'profile_upload_failed': 'Yuklash amalga oshmadi. Firebase Storage yoqilganligiga ishonch hosil qiling.',
      'profile_language_pick': 'Tilni tanlang',
      'profile_english': 'English',
      'profile_uzbek': "O'zbek",
      'profile_help_body': 'Buyurtmangiz bo\'yicha yordam kerakmi?\nBuyurtma ekrani orqali do\'kon bilan to\'g\'ridan-to\'g\'ri bog\'laning yoki OBOIA qo\'llab-quvvatlash xizmatiga murojaat qiling.',

      // Shop
      'shop_wallpapers': 'Devor qog\'ozlari',
      'shop_no_wallpapers': 'Bu do\'konda hali devor qog\'ozlari yo\'q.',
      'shop_view_ar': 'AR da ko\'rish',
      'shop_add_to_cart': 'Savatga qo\'shish',
      'shop_categories': 'Kategoriyalar',
      'shop_all': 'Barchasi',

      // Cart
      'cart_title': 'Savat',
      'cart_empty': 'Savatingiz bo\'sh',
      'cart_empty_sub': 'Boshlash uchun do\'konlarni ko\'rib chiqing va devor qog\'ozlari qo\'shing.',
      'cart_browse': 'Do\'konlarni ko\'rish',
      'cart_total': 'Jami',
      'cart_checkout': 'Buyurtma berish',
      'cart_remove': 'O\'chirish',
      'cart_rolls': 'rulon',
      'cart_area': 'Maydon',

      // Order confirm
      'order_confirm_title': 'Buyurtmani tasdiqlash',
      'order_name': 'Ismingiz',
      'order_phone': 'Telefon raqami',
      'order_address': 'Yetkazib berish manzili',
      'order_notes': 'Izohlar (ixtiyoriy)',
      'order_place': 'Buyurtma berish',
      'order_placing': 'Buyurtma berilmoqda...',
      'order_success': 'Buyurtma berildi! Do\'kon siz bilan bog\'lanadi.',
      'order_phone_required': 'Telefon raqami talab qilinadi',

      // Orders list
      'orders_title': 'Buyurtmalarim',
      'orders_empty': 'Hali buyurtmalar yo\'q',
      'orders_status_pending': 'Kutilmoqda',
      'orders_status_negotiating': 'Muzokara',
      'orders_status_ready': 'Tayyor',
      'orders_status_closed': 'Yakunlangan',
      'orders_status_cancelled': 'Bekor qilingan',
      'orders_view': 'Tafsilotlarni ko\'rish',

      // Order detail
      'order_detail_title': 'Buyurtma tafsilotlari',
      'order_detail_items': 'Mahsulotlar',
      'order_detail_status': 'Holat',
      'order_detail_shop': 'Do\'kon',
      'order_detail_total': 'Taxminiy jami',

      // AR
      'ar_start_scan': 'Skanerni boshlash',
      'ar_done_scanning': 'Skanerni tugatish',
      'ar_scan_hint': 'Xona bo\'ylab sekin harakatlaning.\nDevorlar aniqlanganda yoritiladi.',
      'ar_edit': 'Tahrirlash',
      'ar_save': 'Saqlash',
      'ar_browse': 'Ko\'rish',
      'ar_browse_more': 'Boshqa devor qog\'ozlarini ko\'rish',
      'ar_shops': 'Do\'konlar',
      'ar_area': 'Maydon',
      'ar_rolls': 'Rulon',
      'ar_total': 'Jami',
      'ar_paint': 'Bo\'yash',
      'ar_erase': 'O\'chirish',
      'ar_lasso': 'Lasso',
      'ar_undo': 'Orqaga',
      'ar_reset': 'Tiklash',
      'ar_done': 'Tayyor',
      'ar_opacity': 'Shaffoflik',
      'ar_hide_behind': 'Devor qog\'ozini buyumlar orqasiga yashirish',
      'ar_no_shops': 'Do\'konlar mavjud emas',
      'ar_no_categories': 'Bu do\'konda kategoriyalar yo\'q',
      'ar_no_wallpapers': 'Bu kategoriyada devor qog\'ozlari yo\'q',

      // Pin shop
      'pin_title': 'Do\'kon kodini kiriting',
      'pin_hint': 'Sotuvchidan olgan SHOP-XXXXX kodini kiriting',
      'pin_button': 'Do\'konni biriktirish',
      'pin_invalid': 'Kod noto\'g\'ri yoki nofaol.',

      // Walls list
      'walls_title': 'Mening devorlarim',
      'walls_empty': 'Hali saqlangan devorlar yo\'q',
      'walls_finish_cart': 'Tugatish va savatga',

      // Auth
      'auth_welcome': 'OBOIA ga xush kelibsiz',
      'auth_subtitle': 'Sotib olishdan oldin devor qog\'ozini devoringizda ko\'ring',
      'auth_login': 'Kirish',
      'auth_signup': 'Ro\'yxatdan o\'tish',
      'auth_email': 'Email',
      'auth_password': 'Parol',
      'auth_name': 'To\'liq ism',
      'auth_continue': 'Davom etish',
      'auth_have_account': 'Hisobingiz bormi?',
      'auth_no_account': 'Hisobingiz yo\'qmi?',
    },
  };

  static String translate(String lang, String key) {
    final l = _data[lang] ?? _data['en']!;
    return l[key] ?? _data['en']![key] ?? key;
  }

  static bool isSupported(String lang) => _data.containsKey(lang);
}
