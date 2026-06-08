// lib/screens/pin_shop/pin_shop_screen.dart
//
// Token entry screen. Customer types the SHOP-XXXXX code they got from a
// physical shop / QR code / business card. On success, app pins to that
// shop and pops back to home. On failure, shows the error inline.
//
// QR scanning is deferred to a later round. Manual entry only for now.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/pinned_shop_provider.dart';
import '../../theme/app_colors.dart';

class PinShopScreen extends StatefulWidget {
  const PinShopScreen({super.key});

  @override
  State<PinShopScreen> createState() => _PinShopScreenState();
}

class _PinShopScreenState extends State<PinShopScreen> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text;
    if (raw.trim().isEmpty) {
      setState(() => _errorText = 'Enter a shop code to continue.');
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    final result = await context.read<PinnedShopProvider>().pinByToken(raw);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green,
          content: Text('Pinned to ${result.shop!.displayName()}'),
          duration: const Duration(seconds: 2),
        ),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/home');
      }
    } else {
      setState(() => _errorText = result.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinned = context.watch<PinnedShopProvider>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        title: const Text(
          'Shop code',
          style: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              // Icon header
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.gold.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.storefront,
                      color: AppColors.gold, size: 36),
                ),
              ),

              const SizedBox(height: 10),
              const Text(
                'Enter your shop code',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'If a wallpaper shop gave you a code, enter it here to '
                'lock the app to that shop. Format: SHOP-XXXXX',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 28),

              // Current pin status
              if (pinned.isPinned)
                Container(
                  margin: const EdgeInsets.only(bottom: 18),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.gold.withOpacity(0.08),
                    border: Border.all(color: AppColors.gold.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bookmark, color: AppColors.gold, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Currently pinned',
                              style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 11),
                            ),
                            Text(
                              pinned.shop!.displayName(),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await context.read<PinnedShopProvider>().unpin();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Unpinned')),
                            );
                          }
                        },
                        child: const Text('Unpin',
                            style: TextStyle(color: AppColors.error)),
                      ),
                    ],
                  ),
                ),

              // Input field
              TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  letterSpacing: 4,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(10),
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9\-a-z]')),
                  // Auto-uppercase the input visually
                  TextInputFormatter.withFunction((oldVal, newVal) {
                    return TextEditingValue(
                      text: newVal.text.toUpperCase(),
                      selection: newVal.selection,
                    );
                  }),
                ],
                decoration: InputDecoration(
                  hintText: 'SHOP-XXXXX',
                  hintStyle: const TextStyle(
                    color: AppColors.textTertiary,
                    letterSpacing: 4,
                  ),
                  errorText: _errorText,
                  filled: true,
                  fillColor: AppColors.card,
                  contentPadding: const EdgeInsets.symmetric(vertical: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: AppColors.gold, width: 1.5),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),

              // Submit button
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.black))
                    : const Text(
                        'Pin to this shop',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.bold),
                      ),
              ),

              const SizedBox(height: 24),

              // Help text
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Don\'t have a code? You can skip this and browse all shops '
                  'normally from the home screen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textTertiary, fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
