import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pages/home_page.dart';
import 'pages/history_page.dart';
import 'utils/permission_handler.dart';
import 'widgets/initial_permission_handler.dart';

/// Global navigator key so code outside [BuildContext] (e.g. services) can push routes.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Binds Flutter, requests BLE + location capabilities up front, then boots the app widget.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize permissions
  await Permission.bluetooth.request();
  await Permission.bluetoothScan.request();
  await Permission.bluetoothConnect.request();
  await Permission.location.request();
  
  runApp(const MyApp());
}

/// Root [MaterialApp]: Gripshot branding, light/dark themes, named `/history`, and
/// [InitialPermissionHandler] wrapping [HomePage] (default tab 2 = Profile).
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  /// Applies Material 3, Poppins via Google Fonts, and registers `/history`.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gripshot',
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2196F3),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.poppinsTextTheme(),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2196F3),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme),
      ),
      themeMode: ThemeMode.system,
      home: const InitialPermissionHandler(
        child: HomePage(initialTab: 2), // Start with profile page
      ),
      routes: {
        '/history': (context) => const HistoryPage(),
      },
    );
  }
} 