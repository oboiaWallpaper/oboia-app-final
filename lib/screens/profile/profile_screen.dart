import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../services/firestore_service.dart';
import '../../services/storage_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/custom_button.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _uploading = false;

  String _t(String key) => context.read<LocaleProvider>().t(key);

  Future<void> _editName() async {
    final auth = context.read<AuthProvider>();
    final ctrl = TextEditingController(text: auth.appUser?.name ?? '');
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(_t('profile_edit_name')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(hintText: _t('profile_your_name')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('common_cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(_t('common_save')),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    final uid = auth.firebaseUser?.uid;
    if (uid == null) return;
    await FirestoreService.instance.updateUserProfile(uid: uid, name: newName);
  }

  Future<void> _changePhoto() async {
    final auth = context.read<AuthProvider>();
    final uid = auth.firebaseUser?.uid;
    if (uid == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() => _uploading = true);
    try {
      final url = await StorageService.instance.uploadProfilePhoto(
        uid: uid,
        file: File(picked.path),
      );
      await FirestoreService.instance
          .updateUserProfile(uid: uid, photoUrl: url);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_t('profile_upload_failed')}\n$e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _signOut() async {
    await context.read<AuthProvider>().signOut();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    // Watch locale so this screen rebuilds when the language changes.
    context.watch<LocaleProvider>();
    final user = auth.appUser;

    return Scaffold(
      appBar: AppBar(title: Text(_t('profile_title'))),
      body: user == null
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.gold))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _uploading ? null : _changePhoto,
                        child: Stack(
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: AppColors.gold, width: 2),
                                image: (user.photoUrl != null &&
                                        user.photoUrl!.isNotEmpty)
                                    ? DecorationImage(
                                        image:
                                            NetworkImage(user.photoUrl!),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                                color: AppColors.surface,
                              ),
                              child: (user.photoUrl == null ||
                                      user.photoUrl!.isEmpty)
                                  ? const Icon(Icons.person_rounded,
                                      size: 48,
                                      color: AppColors.textSecondary)
                                  : null,
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(
                                  color: AppColors.gold,
                                  shape: BoxShape.circle,
                                ),
                                child: _uploading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.black,
                                        ),
                                      )
                                    : const Icon(Icons.camera_alt_rounded,
                                        color: Colors.black, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        user.name,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        user.email,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                _tile(Icons.edit_rounded, _t('profile_edit_name'), _editName),
                _tile(Icons.receipt_long_rounded, _t('profile_my_orders'),
                    () => context.push('/orders')),
                _tile(Icons.language_rounded, _t('profile_language'),
                    _showLanguageDialog),
                _tile(Icons.help_outline_rounded, _t('profile_help'),
                    _showHelp),
                const SizedBox(height: 28),
                CustomButton(
                  label: _t('profile_sign_out'),
                  variant: ButtonVariant.outline,
                  icon: Icons.logout_rounded,
                  onPressed: _signOut,
                ),
                const SizedBox(height: 24),
                const Center(
                  child: Text(
                    'OBOIA  ·  v1.0.0',
                    style: TextStyle(
                        color: AppColors.textTertiary, fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.gold, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ★ Real language picker — switches the whole app instantly + persists.
  void _showLanguageDialog() {
    final locale = context.read<LocaleProvider>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(_t('profile_language_pick')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _langOption('en', _t('profile_english'), locale),
            const SizedBox(height: 8),
            _langOption('uz', _t('profile_uzbek'), locale),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('common_close')),
          ),
        ],
      ),
    );
  }

  Widget _langOption(String code, String label, LocaleProvider locale) {
    final selected = locale.lang == code;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        await locale.setLanguage(code);
        if (mounted) {
          Navigator.pop(context);
          setState(() {});
        }
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.gold.withOpacity(0.12) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? AppColors.gold : AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.gold : AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, color: AppColors.gold, size: 20),
          ],
        ),
      ),
    );
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(_t('profile_help')),
        content: Text(_t('profile_help_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('common_ok')),
          ),
        ],
      ),
    );
  }
}
