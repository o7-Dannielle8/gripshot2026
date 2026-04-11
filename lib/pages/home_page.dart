import 'package:flutter/material.dart';
import 'training_page.dart';
import 'history_page.dart';
import 'profile_page.dart';
import 'connected_device_page.dart';

/// Root shell after login: branded app bar, one of three main tabs in the body,
/// and a [NavigationBar] to switch between Training, History, and Profile.
class HomePage extends StatefulWidget {
  /// Which bottom-nav tab is selected on first frame (`0` Training, `1` History, `2` Profile).
  final int initialTab;
  
  const HomePage({
    Key? key,
    this.initialTab = 2, // Default to profile tab
  }) : super(key: key);

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  /// Mirrors [NavigationBar.selectedIndex]; drives which [_pages] entry is built.
  late int _selectedIndex;

  /// Fixed tab order: Training → History → Profile (indices 0–2).
  final List<Widget> _pages = const [
    TrainingPage(),
    HistoryPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialTab;
  }

  /// Lets parent routes (e.g. deep links) jump tabs without tapping the bar.
  void setSelectedIndex(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  /// App bar + current tab’s page + bottom [NavigationBar] destinations.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'GRIPSHOT',
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
            letterSpacing: 2.0,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        centerTitle: true,
      ),
      body: _pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.gps_fixed_outlined),
            selectedIcon: Icon(Icons.gps_fixed),
            label: 'Training',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
} 