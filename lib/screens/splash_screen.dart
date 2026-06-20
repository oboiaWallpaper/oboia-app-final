import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// OBOIA splash screen.
///
/// Shows the brand logo on a dark background for a short moment when the app
/// opens, then hands control to the router. It navigates to '/welcome' and the
/// app's global redirect (in main.dart) instantly forwards signed-in users on
/// to '/home' (or '/craftsman'), so this works for both signed-in and
/// signed-out users.
///
/// Pure Flutter + go_router — no native or Codemagic changes needed.
/// Lives at: lib/screens/splash_screen.dart
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  static const Color _bg = Color(0xFF1A1C22); // brand dark
  static const Color _gold = Color(0xFFFFD369); // brand gold

  static const Duration _hold = Duration(milliseconds: 2200);

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeOutBack),
    );
    _c.forward();

    // After the hold, hand off to the router. Going to '/welcome' lets the
    // global redirect in main.dart route signed-in users onward automatically.
    Future.delayed(_hold, () {
      if (!mounted) return;
      context.go('/welcome');
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo. If the asset is ever missing, fall back to gold text
                // so the splash can never crash the app.
                Image.asset(
                  'assets/splash_logo.png',
                  width: 140,
                  height: 140,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text(
                    'OBOIA',
                    style: TextStyle(
                      color: _gold,
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    valueColor: AlwaysStoppedAnimation<Color>(_gold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
