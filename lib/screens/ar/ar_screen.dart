// lib/screens/ar/ar_screen.dart – RED SCREEN TEST

import 'package:flutter/material.dart';

class ARScreen extends StatefulWidget {
  const ARScreen({super.key});

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // TEMPORARY: replaced UiKitView with red box
          const Positioned.fill(
            child: ColoredBox(color: Colors.red),
          ),
          // Back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 24),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          // Status text
          const Positioned(
            top: 80,
            left: 20,
            child: Text('STATUS: TESTING',
                style: TextStyle(color: Colors.greenAccent, fontSize: 16)),
          ),
        ],
      ),
    );
  }
}
