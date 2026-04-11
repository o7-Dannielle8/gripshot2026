/// Live session screen for a paired Gripshot gun (BLE) and optional target.
///
/// Handles: BLE subscriptions for gun sensors and target laser events, coordinated
/// hit detection (button + laser), 4×4 target grid scoring, training vs practice
/// modes, target scanning/connect, persisting completed sessions, and navigation
/// after training ends.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'home_page.dart';
import 'database_helper.dart';
import 'training_page.dart';
import 'history_page.dart';
import '../../main.dart';

/// Global key so training flow can reach [HomePageState] when resetting UI after sessions.
final GlobalKey<HomePageState> homePageKey = GlobalKey<HomePageState>();

/// Serializable summary of one training run (used when encoding session payloads).
class TrainingSession {
  final DateTime date;
  final int totalScore;
  final List<Map<String, dynamic>> hitHistory;
  final int duration; // in minutes

  TrainingSession({
    required this.date,
    required this.totalScore,
    required this.hitHistory,
    required this.duration,
  });

  Map<String, dynamic> toJson() {
    return {
      'date': date.toIso8601String(),
      'totalScore': totalScore,
      'hitHistory': hitHistory,
      'duration': duration,
    };
  }
}

/// Route widget shown after connecting to the gun. Optionally opens in practice mode
/// or with a forced “start training” prompt; [onPracticeEnd] notifies callers when practice finishes.
class ConnectedDevicePage extends StatefulWidget {
  /// The connected Bluetooth gun device (Nordic UART / sensor service).
  final BluetoothDevice device;
  /// When true, session uses unlimited “bullets” and skips normal save path where applicable.
  final bool isPracticeMode;
  /// When true, idle UI shows the start-training prompt even if other copy would apply.
  final bool forceShowStartPrompt;
  /// Optional callback when practice mode ends (score, per-shot maps, elapsed time).
  final Function(int score, List<Map<String, dynamic>> hits, Duration duration)? onPracticeEnd;

  const ConnectedDevicePage({
    super.key,
    required this.device,
    this.isPracticeMode = false,
    this.forceShowStartPrompt = false,
    this.onPracticeEnd,
  });

  @override
  State<ConnectedDevicePage> createState() => _ConnectedDevicePageState();
}

class _ConnectedDevicePageState extends State<ConnectedDevicePage> {
  // --- Session / UI mode ---
  bool _isTraining = false;
  bool _isTargetConnected = false;
  bool _isPracticeMode = false;
  static const int gridRows = 4;
  static const int gridColumns = 4;
  static const int maxBullets = 17;

  /// Which cells on the 4×4 target grid have registered a hit this session.
  List<List<bool>> _hitCells = List.generate(
    gridRows,
    (_) => List.generate(gridColumns, (_) => false),
  );
  int _bulletCount = 17;  // Total bullets available
  static const int TOTAL_BULLETS = 17;  // Maximum number of bullets

  // --- Live sensor values from gun (comma-separated BLE payloads) ---
  double _gripReading = 0.0;
  double _pitchReading = 0.0;
  String _pitchStatus = "SAFE";
  String _touchStatus = "NOT TOUCHED";

  // Add BLE characteristic subscription
  StreamSubscription<List<int>>? _characteristicSubscription;
  StreamSubscription<List<int>>? _targetCharacteristicSubscription;
  static const String SENSOR_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String SENSOR_CHARACTERISTIC_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
  static const String TARGET_SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0";
  static const String TARGET_CHARACTERISTIC_UUID = "12345678-1234-5678-1234-56789abcdef1";

  // Add connection state monitoring
  StreamSubscription<BluetoothConnectionState>? _gunConnectionSubscription;
  StreamSubscription<BluetoothConnectionState>? _targetConnectionSubscription;
  bool _isGunConnected = true;
  /// Selected GripShot Target device, if any; laser strings are merged into the same parser as the gun.
  BluetoothDevice? _targetDevice;

  // Add optimization variables
  static const int UPDATE_THRESHOLD_MS = 50; // Minimum time between updates (50ms = 20Hz)
  DateTime _lastUpdateTime = DateTime.now();
  String _lastReceivedData = '';
  bool _isProcessingData = false;
  
  // Buffer for sensor data
  final List<String> _dataBuffer = [];
  static const int MAX_BUFFER_SIZE = 5;
  
  // Debounce timer for UI updates
  Timer? _updateTimer;
  static const int UI_UPDATE_INTERVAL_MS = 100; // Update UI every 100ms

  // --- Bluetooth scan for separate target peripheral ---
  bool _isScanningTargets = false;
  List<ScanResult> _targetScanResults = [];
  StreamSubscription<List<ScanResult>>? _targetScanSubscription;
  StreamSubscription<bool>? _targetIsScanningSubscription;

  /// Concentric ring colors for [TargetPainter] (legacy circular target visualization).
  static const List<Color> _ringColors = [
    Color(0xFFE3F2FD),    // Light blue - Center (very light)
    Colors.black,         // Ring 1
    Color(0xFFBBDEFB),    // Ring 2 (slightly darker blue)
    Colors.black,         // Ring 3
    Color(0xFF90CAF9),    // Ring 4 (medium blue)
    Colors.black,         // Ring 5
    Color(0xFF64B5F6),    // Ring 6 (darker blue)
    Colors.black,         // Ring 7
  ];

  static const List<int> _ringScores = [10, 9, 8, 7, 6, 5, 4, 3];

  // Update grid dimensions for a 4x4 square target
  static const double gridSpacing = 1.0;  // Spacing between cells

  /// Score per cell, row-major, for the 4×4 grid (center cells worth more).
  static const List<int> _gridScores = [
    4, 6, 6, 4,
    6, 10, 10, 6,
    6, 10, 10, 6,
    4, 6, 6, 4
  ];

  // --- Aggregates for current training run ---
  List<Map<String, dynamic>> _hitHistory = [];
  DateTime _sessionStartTime = DateTime.now();
  int _totalScore = 0;

  /// Time-series of grip / pitch / touch for charts and saved session detail.
  List<Map<String, dynamic>> _gripHistory = [];
  List<Map<String, dynamic>> _pitchHistory = [];
  List<Map<String, dynamic>> _touchHistory = [];
  
  // Add timer for periodic sensor data collection
  Timer? _sensorDataTimer;
  static const int SENSOR_DATA_INTERVAL_MS = 100; // Collect data every 100ms

  /// Bands used for on-screen “optimal / too light / too heavy” style hints (training UI).
  static const double OPTIMAL_GRIP_MIN = 2.0;  // kg
  static const double OPTIMAL_GRIP_MAX = 4.0;  // kg
  static const double OPTIMAL_PITCH_MIN = -5.0; // degrees
  static const double OPTIMAL_PITCH_MAX = 5.0;  // degrees

  // Training metrics
  double _accuracy = 0.0;
  int _shotsFired = 0;
  double _averageScore = 0.0;

  // Add button press tracking
  bool _lastButtonState = false;

  /// Flat index order matches row-major cells; values are GPIO numbers from firmware strings.
  static const List<int> photoPins = [
    12, 8, 4, 0,
    13, 9, 5, 1,
    14, 10, 6, 2,
    15, 11, 7, 3,
  ];

  String _userGender = 'Male'; // Default to Male

  bool _forceShowStartPrompt = false;

  /// MUX channel index per grid cell (used when firmware reports `LASER DETECTED MUX CH …`).
  static const List<List<int>> channelGridMap = [
    [12, 8, 4, 0],
    [13, 9, 5, 1],
    [14, 10, 6, 2],
    [15, 11, 7, 3],
  ];

  // Helper to get (row, col) from channel
  Map<String, int>? getGridCellFromChannel(int channel) {
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        if (channelGridMap[row][col] == channel) {
          return {'row': row, 'col': col};
        }
      }
    }
    return null;
  }

  /// Returns the photoresistor pin for a given grid cell (row, col)
  int getPhotoPinForCell(int row, int col) {
    final index = row * gridColumns + col;
    if (index >= 0 && index < photoPins.length) {
      return photoPins[index];
    }
    return -1; // Invalid
  }

  // Add these methods to evaluate grip and pitch status
  String _getGripStatus(double grip) {
    if (grip < OPTIMAL_GRIP_MIN) return 'Too Light';
    if (grip > OPTIMAL_GRIP_MAX) return 'Too Heavy';
    return 'Optimal';
  }

  /// Text label for pitch relative to [OPTIMAL_PITCH_MIN] / [OPTIMAL_PITCH_MAX].
  String _getPitchStatus(double pitch) {
    if (pitch < OPTIMAL_PITCH_MIN) return 'Too Low';
    if (pitch > OPTIMAL_PITCH_MAX) return 'Too High';
    return 'Level';
  }

  /// Traffic-light color for grip relative to optimal band.
  Color _getGripStatusColor(double grip) {
    if (grip < OPTIMAL_GRIP_MIN) return Colors.orange;
    if (grip > OPTIMAL_GRIP_MAX) return Colors.red;
    return Colors.green;
  }

  /// Traffic-light color for pitch relative to optimal band.
  Color _getPitchStatusColor(double pitch) {
    if (pitch < OPTIMAL_PITCH_MIN) return Colors.orange;
    if (pitch > OPTIMAL_PITCH_MAX) return Colors.red;
    return Colors.green;
  }

  // --- Coordinated hit detection (gun trigger + target laser) ---
  DateTime? _lastButtonPressTime;
  /// Staged laser cell when button and laser ordering differs (window controlled by [HIT_WINDOW_MS]).
  Map<String, dynamic>? _pendingLaserHit; // {row, col, time, pin/channel}
  /// Max milliseconds between button and laser to count as one shot (0 = only same-tick pairing in practice).
  static const int HIT_WINDOW_MS = 0;
  String? _lastButtonSource; // 'gun' or 'target'

  /// True after normal training completion so disconnect handlers do not stack duplicate navigation.
  bool _navigatedAfterTraining = false;

  @override
  void initState() {
    super.initState();
    _loadUserGender();
    _hitCells = List.generate(
      gridRows,
      (_) => List.filled(gridColumns, false),
    );
    _bulletCount = widget.isPracticeMode ? 999999 : TOTAL_BULLETS;
    _forceShowStartPrompt = widget.forceShowStartPrompt;
    _setupBLESubscription();
    _startUpdateTimer();
  }

  /// Loads profile sex from [SharedPreferences] for grip strength labels (male/female bands).
  Future<void> _loadUserGender() async {
    final prefs = await SharedPreferences.getInstance();
    final gender = prefs.getString('profile_sex');
    if (gender != null && (gender.toLowerCase() == 'male' || gender.toLowerCase() == 'female')) {
      setState(() {
        _userGender = gender;
      });
    }
  }

  /// Maps raw grip (device units) to Weak / Moderate / Excessive using gender-specific thresholds.
  String _evaluateGripStrength(double grip, String gender) {
    if (gender.toLowerCase() == 'male') {
      if (grip < 40) return 'Weak';
      if (grip <= 45) return 'Moderate';
      if (grip <= 53) return 'Excessive';
      return 'Excessive';
    } else if (gender.toLowerCase() == 'female') {
      if (grip < 20) return 'Weak';
      if (grip <= 25) return 'Moderate';
      if (grip <= 29) return 'Excessive';
      return 'Excessive';
    }
    return 'Unknown';
  }

  /// Periodically triggers [setState] so sensor numbers repaint without waiting for every BLE packet.
  void _startUpdateTimer() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(
      const Duration(milliseconds: UI_UPDATE_INTERVAL_MS),
      (timer) {
        if (!mounted) return;
        setState(() {
          // Force UI update to show latest sensor readings
          _gripReading = _gripReading;
          _pitchReading = _pitchReading;
          _totalScore = _totalScore;
          _bulletCount = _bulletCount;
        });
      },
    );
  }

  @override
  void dispose() {
    // Tear down BLE listeners, timers, and scanning so the page does not leak or hold the radio.
    _characteristicSubscription?.cancel();
    _targetCharacteristicSubscription?.cancel();
    _gunConnectionSubscription?.cancel();
    _targetConnectionSubscription?.cancel();
    _updateTimer?.cancel();
    _sensorDataTimer?.cancel();
    _targetScanSubscription?.cancel();
    _targetIsScanningSubscription?.cancel();
    // Stop any ongoing scans to be safe
    if (FlutterBluePlus.isScanningNow) {
      FlutterBluePlus.stopScan();
    }
    // Do NOT disconnect from devices here; let parent handle it
    super.dispose();
  }

  /// Buffers incoming BLE lines and forwards them to [_parseAndUpdateData] at a capped rate.
  void _processSensorData(String data) {
    if (_isProcessingData) return; // Skip if still processing previous data
    try {
      _isProcessingData = true;
      // Add to buffer if different from last data
      if (data != _lastReceivedData) {
        print('Raw data received from ESP32: "' + data + '"');
        _dataBuffer.add(data);
        if (_dataBuffer.length > MAX_BUFFER_SIZE) {
          _dataBuffer.removeAt(0);
        }
        _lastReceivedData = data;
      }
      // Process buffer if enough time has passed
      final now = DateTime.now();
      if (now.difference(_lastUpdateTime).inMilliseconds >= UPDATE_THRESHOLD_MS) {
        if (_dataBuffer.isNotEmpty) {
          final latestData = _dataBuffer.last;
          print('Processing latest data: "' + latestData + '"');
          _parseAndUpdateData(latestData);
          _lastUpdateTime = now;
          _dataBuffer.clear();
        }
      }
    } finally {
      _isProcessingData = false;
    }
  }

  /// Interprets one BLE string: trigger events, laser hit formats (GPIO / MUX), or `key:value` sensor CSV.
  void _parseAndUpdateData(String data) {
    print('📥 RAW BLE DATA RECEIVED: "' + data + '"');
    debugPrint('[BLE RAW DATA] ' + data);
    try {
      // --- Coordinated HIT LOGIC ---
      // 1. BUTTON PRESS from gun
      if (data.trim() == "button_pressed" || data.trim() == "BUTTON PRESSED") {
        final now = DateTime.now();
        _lastButtonPressTime = now;
        _lastButtonSource = 'gun';
        bool hitRegistered = false;
        if (_pendingLaserHit != null) {
          final laserTime = _pendingLaserHit!['time'] as DateTime;
          final row = _pendingLaserHit!['row'] as int;
          final col = _pendingLaserHit!['col'] as int;
          final pin = _pendingLaserHit!['pin'] ?? _pendingLaserHit!['channel'];
          // If the laser hit is recent enough (optional: you can remove this check if you want ANY pending hit to count)
          if ((now.difference(laserTime).inMilliseconds).abs() <= HIT_WINDOW_MS) {
            final score = _gridScores[row * gridColumns + col];
            _recordHit(row, col, score);
            _pendingLaserHit = null;
            _lastButtonPressTime = null;
            _lastButtonSource = null;
            hitRegistered = true;
          } else {
            _pendingLaserHit = null;
          }
        }
        if (!hitRegistered) {
          // Register miss immediately
          if (mounted) {
            setState(() {
              _hitHistory.add({
                'row': null,
                'col': null,
                'score': 0,
                'timestamp': now,
                'grip': _gripReading,
                'pitch': _pitchReading,
                'miss': true,
              });
              if (_bulletCount > 0) {
                _bulletCount--;
                if (_bulletCount == 0) {
                  _showTrainingCompleteDialog();
                }
              }
            });
          }
          _lastButtonPressTime = null;
          _lastButtonSource = null;
        }
        return;
      }

      // 2. LASER HIT from target (old format)
      final regex = RegExp(r'LASER DETECTED at GPIO\s*(\d+)');
      final match = regex.firstMatch(data);
      if (match != null) {
        final pin = int.tryParse(match.group(1) ?? '');
        if (pin != null) {
          final index = photoPins.indexOf(pin);
          if (index != -1) {
            final row = index ~/ gridColumns;
            final col = index % gridColumns;
            final now = DateTime.now();
            print('💡 LASER HIT DETECTED at pin $pin (row $row, col $col) at ' + now.toIso8601String());
            // Check for recent button press
            if (_lastButtonPressTime != null &&
                (now.difference(_lastButtonPressTime!).inMilliseconds).abs() <= HIT_WINDOW_MS) {
              final buttonTime = _lastButtonPressTime!;
              final score = _gridScores[row * gridColumns + col];
              print('✅ Registering HIT (laser then button) at ($row, $col, pin $pin) [laser: $now, button: $buttonTime]');
              _recordHit(row, col, score);
              debugPrint('Coordinated HIT: Laser and Button matched at (row $row, col $col, pin $pin)');
              _pendingLaserHit = null;
              _lastButtonPressTime = null;
              _lastButtonSource = null;
              return;
            } else {
              print('No recent button press, ignoring this laser hit. (Time diff: ' + (_lastButtonPressTime != null ? (now.difference(_lastButtonPressTime!).inMilliseconds).toString() : 'N/A') + ' ms, HIT_WINDOW_MS=' + HIT_WINDOW_MS.toString() + ')');
              // Do NOT store as pending
            }
          } else {
            debugPrint('Pin $pin not found in photoPins list');
          }
        }
        return;
      }

      // 2b. LASER DETECTED MUX CH <channel> -> <value> (new format)
      final muxRegex = RegExp(r'LASER DETECTED MUX CH (\d+) -> (\d+)');
      final muxMatch = muxRegex.firstMatch(data);
      if (muxMatch != null) {
        final channel = int.tryParse(muxMatch.group(1) ?? '');
        final value = int.tryParse(muxMatch.group(2) ?? '');
        print('[DEBUG] LASER DETECTED MUX: channel=$channel, value=$value');
        if (channel != null && value != null) {
          final cell = getGridCellFromChannel(channel);
          print('[DEBUG] getGridCellFromChannel($channel) => $cell');
          if (cell != null && cell['row'] != null && cell['col'] != null) {
            final now = DateTime.now();
            final row = cell['row']!;
            final col = cell['col']!;
            // Check for recent button press
            if (_lastButtonPressTime != null &&
                (now.difference(_lastButtonPressTime!).inMilliseconds).abs() <= HIT_WINDOW_MS) {
              final buttonTime = _lastButtonPressTime!;
              final score = _gridScores[row * gridColumns + col];
              print('✅ Registering HIT (laser then button, MUX) at ($row, $col, channel $channel) [laser: $now, button: $buttonTime]');
              _recordHit(row, col, score);
              debugPrint('Coordinated HIT: Laser and Button matched at (row $row, col $col, channel $channel)');
              _pendingLaserHit = null;
              _lastButtonPressTime = null;
              _lastButtonSource = null;
              return;
            } else {
              print('No recent button press, ignoring this laser hit. (Time diff: ' + (_lastButtonPressTime != null ? (now.difference(_lastButtonPressTime!).inMilliseconds).toString() : 'N/A') + ' ms, HIT_WINDOW_MS=' + HIT_WINDOW_MS.toString() + ')');
              // Do NOT store as pending
            }
          } else {
            debugPrint('⚠️ Channel $channel not found in channelGridMap or mapping is incomplete. Ignoring this hit.');
            print('[DEBUG] Available channels in channelGridMap: $channelGridMap');
            return;
          }
        }
        return;
      }

      // 2c. LASER DETECTED ON MUX CH <channel> (new format)
      final muxOnRegex = RegExp(r'LASER DETECTED ON MUX CH (\d+)');
      final muxOnMatch = muxOnRegex.firstMatch(data);
      if (muxOnMatch != null) {
        final channel = int.tryParse(muxOnMatch.group(1) ?? '');
        print('[DEBUG] LASER DETECTED ON MUX CH: channel=$channel');
        if (channel != null) {
          final cell = getGridCellFromChannel(channel);
          print('[DEBUG] getGridCellFromChannel($channel) => $cell');
          if (cell != null && cell['row'] != null && cell['col'] != null) {
            final now = DateTime.now();
            final row = cell['row']!;
            final col = cell['col']!;
            // Check for recent button press
            if (_lastButtonPressTime != null &&
                (now.difference(_lastButtonPressTime!).inMilliseconds).abs() <= HIT_WINDOW_MS) {
              final buttonTime = _lastButtonPressTime!;
              final score = _gridScores[row * gridColumns + col];
              print('✅ Registering HIT (laser then button, MUX ON) at ($row, $col, channel $channel) [laser: $now, button: $buttonTime]');
              _recordHit(row, col, score);
              debugPrint('Coordinated HIT: Laser and Button matched at (row $row, col $col, channel $channel)');
              _pendingLaserHit = null;
              _lastButtonPressTime = null;
              _lastButtonSource = null;
              return;
            } else {
              print('No recent button press, ignoring this laser hit. (Time diff: ' + (_lastButtonPressTime != null ? (now.difference(_lastButtonPressTime!).inMilliseconds).toString() : 'N/A') + ' ms, HIT_WINDOW_MS=' + HIT_WINDOW_MS.toString() + ')');
              // Do NOT store as pending
            }
          } else {
            debugPrint('⚠️ Channel $channel not found in channelGridMap or mapping is incomplete. Ignoring this hit.');
            print('[DEBUG] Available channels in channelGridMap: $channelGridMap');
            return;
          }
        }
        return;
      }

      // Parse sensor data
      print('\n=== Parsing Sensor Data ===');
      print('Raw data to parse: ' + data);
      final parts = data.split(',');
      print('Split into parts: ' + parts.toString());
      final Map<String, String> sensorData = {};
      for (var part in parts) {
        if (!part.contains(':')) {
          print('⚠️ Skipping malformed part (no colon found): ' + part);
          continue;
        }
        final keyValue = part.split(':');
        if (keyValue.length != 2) {
          print('⚠️ Skipping malformed part (unexpected split length): ' + part + ' (split: ' + keyValue.toString() + ')');
          continue;
        }
        final key = keyValue[0].trim();
        final value = keyValue[1].trim();
        if (key.isEmpty || value.isEmpty) {
          print('⚠️ Skipping malformed part (empty key or value): ' + part);
          continue;
        }
        sensorData[key] = value;
        print('Parsed key-value: ' + key + ' = ' + value);
      }
      print('\nFinal parsed sensor data map: ' + sensorData.toString());
      setState(() {
        if (sensorData.containsKey('grip')) {
          final gripStr = sensorData['grip']!.replaceAll('kg', '').trim();
          final newGrip = double.tryParse(gripStr);
          if (newGrip != null) {
            _gripReading = newGrip;
            print('Updated grip reading: ' + _gripReading.toString() + ' kg');
          } else {
            print('⚠️ Could not parse grip value as double: ' + sensorData['grip']!);
          }
        }
        if (sensorData.containsKey('pitch')) {
          final pitchStr = sensorData['pitch']!.trim();
          final newPitch = double.tryParse(pitchStr);
          if (newPitch != null) {
            _pitchReading = newPitch;
            print('Updated pitch reading: ' + _pitchReading.toString() + '°');
          } else {
            print('⚠️ Could not parse pitch value as double: ' + sensorData['pitch']!);
          }
        }
        if (sensorData.containsKey('status')) {
          _pitchStatus = sensorData['status']!;
          print('Updated status: ' + _pitchStatus);
        }
        if (sensorData.containsKey('touch')) {
          _touchStatus = sensorData['touch']!;
          print('Updated touch status: ' + _touchStatus);
        }
      });
      print('=== End of Data Processing ===\n');
    } catch (e, stack) {
      print('❌ Error parsing data: ' + e.toString());
      print('Error occurred while processing data: ' + data);
      print('Stack trace: ' + stack.toString());
    }
  }

  /// Discovers Nordic UART on the gun, enables notify, subscribes to target if [_targetDevice] is set,
  /// and watches connection state (e.g. navigate home if gun drops).
  Future<void> _setupBLESubscription() async {
    try {
      print('Setting up optimized BLE subscription...');
      
      // Set up connection state monitoring for gun device
      _gunConnectionSubscription?.cancel();
      _gunConnectionSubscription = widget.device.connectionState.listen(
        (state) {
          if (_navigatedAfterTraining) {
            print('[DEBUG] Navigation after training already handled, skipping disconnect handler navigation.');
            return;
          }
          print('Gun device connection state changed: $state');
          if (mounted) {
            setState(() {
              _isGunConnected = state == BluetoothConnectionState.connected;
            });
          }
          if (state == BluetoothConnectionState.disconnected) {
            print('Gun device disconnected');
            if (mounted) {
              // Stop training if it was active
              if (_isTraining) {
                setState(() {
                  _isTraining = false;
                });
              }
              // Redirect to the main HomePage (with tabs) ONLY if not already navigated after training
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted && !_navigatedAfterTraining) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (context) => HomePage(initialTab: 0)),
                    (route) => false,
                  );
                }
              });
            }
          }
        },
        onError: (error) {
          print('Gun connection state monitoring error: $error');
        },
      );
      
      // Discover services with increased timeout for Android 11
      final services = await widget.device.discoverServices().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Service discovery timed out'),
      );
      
      // Find sensor service using cached UUID
      final sensorService = services.firstWhere(
        (service) => service.uuid.toString().toUpperCase() == SENSOR_SERVICE_UUID.toUpperCase(),
        orElse: () => throw Exception('Sensor service not found'),
      );
      
      // Find characteristic using cached UUID
      final characteristic = sensorService.characteristics.firstWhere(
        (c) => c.uuid.toString().toUpperCase() == SENSOR_CHARACTERISTIC_UUID.toUpperCase(),
        orElse: () => throw Exception('Sensor characteristic not found'),
      );
      
      // Enable notifications with retry for Android 11
      int retryCount = 0;
      while (retryCount < 3) {
        try {
          await characteristic.setNotifyValue(true);
          break;
        } catch (e) {
          retryCount++;
          if (retryCount == 3) rethrow;
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      
      // Optimize BLE connection parameters for Android 11
      try {
        // Request a more conservative MTU size
        await widget.device.requestMtu(256);
      } catch (e) {
        print('MTU optimization not available: $e');
      }
      
      // Set up subscription with error handling
      _characteristicSubscription = characteristic.onValueReceived.listen(
        (value) {
          if (!mounted) return;
          if (value.isNotEmpty) {
            final data = String.fromCharCodes(value);
            print('📥 [GUN] RAW BLE DATA RECEIVED: "$data"');
            _processSensorData(data);
          }
        },
        onError: (error) {
          if (!mounted) return;
          print('BLE subscription error: $error');
          // Attempt to reconnect on error
          _reconnectBLE();
        },
        cancelOnError: false,
      );
      
      // If a target device is connected, set up a separate subscription for it
      if (_targetDevice != null) {
        try {
          print('[DEBUG] Starting target BLE subscription setup for device: \'${_targetDevice!.platformName}\'');
          
          // Set up connection state monitoring for target device
          _targetConnectionSubscription?.cancel();
          _targetConnectionSubscription = _targetDevice!.connectionState.listen(
            (state) {
              print('Target device connection state changed: $state');
              if (mounted) {
                setState(() {
                  _isTargetConnected = state == BluetoothConnectionState.connected;
                });
              }
              if (state == BluetoothConnectionState.disconnected) {
                print('Target device disconnected');
                if (mounted) {
                  // Stop training if it was active
                  if (_isTraining) {
                    setState(() {
                      _isTraining = false;
                    });
                  }
                }
              }
            },
            onError: (error) {
              print('Target connection state monitoring error: $error');
            },
          );
          
          final targetServices = await _targetDevice!.discoverServices();
          print('[DEBUG] Target services discovered.');
          final targetService = targetServices.firstWhere(
            (service) => service.uuid.toString().toUpperCase() == TARGET_SERVICE_UUID.toUpperCase(),
            orElse: () => throw Exception('Target service not found'),
          );
          print('[DEBUG] Target service found: \'${targetService.uuid}\'');
          final targetCharacteristic = targetService.characteristics.firstWhere(
            (c) => c.uuid.toString().toUpperCase() == TARGET_CHARACTERISTIC_UUID.toUpperCase(),
            orElse: () => throw Exception('Target characteristic not found'),
          );
          print('[DEBUG] Target characteristic found: \'${targetCharacteristic.uuid}\'');
          await targetCharacteristic.setNotifyValue(true);
          print('[DEBUG] setNotifyValue(true) called on target characteristic.');
          _targetCharacteristicSubscription?.cancel();
          _targetCharacteristicSubscription = targetCharacteristic.onValueReceived.listen(
            (value) {
              if (!mounted) return;
              if (value.isNotEmpty) {
                final data = String.fromCharCodes(value);
                print('📥 [TARGET] RAW BLE DATA RECEIVED: "$data"');
                _processSensorData(data);
              }
            },
            onError: (error) {
              if (!mounted) return;
              print('Target BLE subscription error: $error');
            },
            cancelOnError: false,
          );
          print('[DEBUG] Target BLE subscription successfully set up.');
        } catch (e) {
          print('[ERROR] Error setting up target BLE notifications: $e');
          print('Error setting up target BLE notifications: $e');
        }
      }
      
      // Set up periodic UI updates
      _updateTimer = Timer.periodic(
        const Duration(milliseconds: UI_UPDATE_INTERVAL_MS),
        (_) {
          if (!mounted) return;
          if (_dataBuffer.isNotEmpty) {
            setState(() {}); // Trigger UI update
          }
        },
      );
    } catch (e) {
      print('Error setting up BLE subscription: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error setting up connection: ${e.toString()}',
              style: GoogleFonts.poppins(),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      // Attempt to reconnect
      _reconnectBLE();
    }
  }

  /// Retries [_setupBLESubscription] a few times with increasing delay after failures.
  Future<void> _reconnectBLE() async {
    if (!mounted) return;
    
    int retryCount = 0;
    const maxRetries = 3;
    
    while (retryCount < maxRetries && mounted) {
      try {
        await Future.delayed(Duration(seconds: pow(2, retryCount).toInt()));
        await _setupBLESubscription();
        return;
      } catch (e) {
        retryCount++;
        print('Reconnection attempt $retryCount failed: $e');
      }
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connection lost. Please reconnect manually.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Starts a scored training session: clears grid/history, resets bullets, begins sensor sampling.
  /// Training cannot be toggled off from here (only completes when out of bullets or flow ends).
  void _toggleTraining() {
    if (!_isTraining) {  // Only allow starting training
      print('Starting training mode'); // Debug print
    setState(() {
      _isTraining = true;
      _isPracticeMode = false;
      // Reset all tracking data
      for (var i = 0; i < gridRows; i++) {
        for (var j = 0; j < gridColumns; j++) {
          _hitCells[i][j] = false;
        }
      }
      _bulletCount = TOTAL_BULLETS;
        print('Bullet count reset to: $_bulletCount'); // Debug print
      _totalScore = 0;
      _hitHistory = [];
      _gripHistory = [];
      _pitchHistory = [];
        _touchHistory = [];
      _sessionStartTime = DateTime.now();
      
      // Start collecting sensor data
      _startSensorDataCollection();
    });
    }
    // Remove the ability to toggle off training
  }

  /// Appends current grip, pitch, and touch snapshot to histories for post-session analytics.
  void _startSensorDataCollection() {
    _sensorDataTimer?.cancel();
    _sensorDataTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      
      setState(() {
        // Record grip and pitch data with timestamp
        _gripHistory.add({
          'value': _gripReading,
          'timestamp': DateTime.now(),
        });
        _pitchHistory.add({
          'value': _pitchReading,
          'timestamp': DateTime.now(),
        });
        // Record touch data with timestamp
        _touchHistory.add({
          'value': _touchStatus == "TOUCHED" ? 1.0 : 0.0, // Convert to numeric for charting
          'timestamp': DateTime.now(),
        });
      });
    });
  }

  /// Registers a valid hit: updates [_hitCells], [_hitHistory], score, decrements bullets, may end session.
  void _recordHit(int row, int col, int score) {
    if (!mounted) return;
    print('[DEBUG] _recordHit called: row=$row, col=$col, score=$score');
    print('[DEBUG] Before setState - _hitCells[$row][$col] = ${_hitCells[row][col]}');
    setState(() {
      final now = DateTime.now();
      _hitHistory.add({
        'row': row,
        'col': col,
        'score': score,
        'timestamp': now,
        'grip': _gripReading,
        'pitch': _pitchReading,
      });
      _totalScore += score;
      _bulletCount--;
      _hitCells[row][col] = true;
      print('[DEBUG] Inside setState - _hitCells[$row][$col] set to true');
      print('[DEBUG] _hitCells updated: $_hitCells');
      // Check if all bullets are used
      if (_bulletCount == 0) {
        print('Bullet count is 0. Ending training session and saving to history.');
        _completeTrainingAndNavigate();
      }
    });
    print('[DEBUG] After setState - _hitCells[$row][$col] = ${_hitCells[row][col]}');
    print('[DEBUG] setState completed, UI should refresh');
  }

  /// Serializes the current session (hits + sensor histories + metadata) into SharedPreferences.
  Future<void> _saveSessionAndNavigate() async {
    if (_isPracticeMode) return; // Don't save practice sessions

    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Calculate additional metrics
      final shotsFired = _hitHistory.length;
      final accuracy = shotsFired > 0 ? (_hitHistory.where((hit) => (hit['score'] ?? 0) > 0).length / shotsFired * 100).round() : 0;
      final averageScore = shotsFired > 0 ? _totalScore / shotsFired : 0.0;
      
      // Create session data
      final sessionData = {
        'date': _sessionStartTime.toIso8601String(),
        'totalScore': _totalScore,
        'hitHistory': _hitHistory.map((hit) {
          return {
            'row': hit['row'] ?? 0,
            'col': hit['col'] ?? 0,
            'score': hit['score'] ?? 0,
            'timestamp': (hit['timestamp'] as DateTime).toIso8601String(),
            'grip': hit['grip'] ?? 0.0,
            'pitch': hit['pitch'] ?? 0.0,
          };
        }).toList(),
        'duration': DateTime.now().difference(_sessionStartTime).inSeconds,
        'accuracy': accuracy,
        'shotsFired': shotsFired,
        'averageScore': averageScore,
        'gripHistory': _gripHistory.map((entry) => {
          'value': entry['value'] ?? 0.0,
          'timestamp': (entry['timestamp'] as DateTime).toIso8601String(),
        }).toList(),
        'pitchHistory': _pitchHistory.map((entry) => {
          'value': entry['value'] ?? 0.0,
          'timestamp': (entry['timestamp'] as DateTime).toIso8601String(),
        }).toList(),
        'touchHistory': _touchHistory.map((entry) => {
          'value': entry['value'] ?? 0.0,
          'timestamp': (entry['timestamp'] as DateTime).toIso8601String(),
        }).toList(),
        'deviceName': widget.device.platformName,
      };

      print('Saving session data: $sessionData'); // Debug print

      // Get existing sessions
      final sessionsJson = prefs.getStringList('training_sessions') ?? [];
      
      // Add new session
      sessionsJson.add(jsonEncode(sessionData));
      
      // Save updated sessions list
      await prefs.setStringList('training_sessions', sessionsJson);

      print('Session saved successfully. Total sessions: ${sessionsJson.length}'); // Debug print

      // Show success message
      if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Training session saved successfully!',
              style: GoogleFonts.poppins(),
          ),
          backgroundColor: Colors.green,
        ),
      );
      }
    } catch (e) {
      print('Error saving session: $e'); // Debug print
      if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Error saving training session: $e',
              style: GoogleFonts.poppins(),
          ),
          backgroundColor: Colors.red,
        ),
      );
      }
    }
  }

  /// Decrements remaining bullets; when zero, completes training (legacy path if used).
  void _updateBulletCount() {
    if (_bulletCount > 0) {
      setState(() {
        _bulletCount--;
      });
      
      // Check if all bullets are used
      if (_bulletCount == 0) {
        _completeTrainingAndNavigate();
      }
    }
  }

  /// One row for summary dialogs (label left, value right).
  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: Colors.grey[600],
            ),
          ),
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  /// Starts a BLE scan for peripherals named like “GripShot Target”, then shows results or a snackbar.
  Future<void> _startTargetScan() async {
    if (!mounted) return;

    // Stop any existing scan first
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    setState(() {
      _isScanningTargets = true;
      _targetScanResults = [];
    });

    // Listen for scan results
    _targetScanSubscription?.cancel(); // Cancel any existing subscription
    _targetScanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      
      setState(() {
        // Keep ScanResult type and filter for GripShot Target devices
        _targetScanResults = results
            .where((result) {
              final name = result.device.platformName;
              return name.contains('GripShot Target') || name.contains('Gripshot Target');
            })
            .toList();
      });
    }, onError: (e) {
      print('Error in scan results: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error scanning for targets: ${e.toString()}',
              style: GoogleFonts.poppins(),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    });

    // Listen for scanning state
    _targetIsScanningSubscription?.cancel(); // Cancel any existing subscription
    _targetIsScanningSubscription = FlutterBluePlus.isScanning.listen((isScanning) {
      if (!mounted) return;
      
      setState(() {
        _isScanningTargets = isScanning;
      });
      
      // Only check for results when scanning has completely stopped
      if (!isScanning) {
        // Increased delay for Android 11
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!mounted) return;
          
          // Only show dialog or message if scanning is still stopped
          if (!FlutterBluePlus.isScanningNow) {
            if (_targetScanResults.isNotEmpty) {
              _showScanResults();
            } else {
              // Only show "no devices found" message if scanning is completely finished
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'No GripShot Targets found',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  backgroundColor: Colors.red,
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          }
        });
      }
    }, onError: (e) {
      print('Error in scanning state: $e');
    });

    try {
      // Start new scan with optimized settings for Android 11
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 4), // Reduced timeout from 10 to 4 seconds
        androidUsesFineLocation: true, // Always use fine location
        androidScanMode: AndroidScanMode.lowLatency, // Use low latency mode
      );
    } catch (e) {
      print('Scan error: $e');
      if (!mounted) return;
      setState(() {
        _isScanningTargets = false;
      });
      if (!FlutterBluePlus.isScanningNow) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error scanning for targets: ${e.toString()}',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Stops scan and clears scan-related stream subscriptions.
  Future<void> _stopTargetScan() async {
    try {
      await FlutterBluePlus.stopScan();
      _targetScanSubscription?.cancel();
      _targetIsScanningSubscription?.cancel();
      setState(() {
        _isScanningTargets = false;
      });
    } catch (e) {
      print('Error stopping target scan: $e');
    }
  }

  /// Connects to [device], refreshes BLE subscriptions, resets local training grid state, closes dialogs.
  Future<void> _connectToTarget(BluetoothDevice device) async {
    try {
      // Show connecting dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(
            'Connecting to Target',
            style: GoogleFonts.poppins(
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Please wait...',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      );

      // Connect with increased timeout for Android 11
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      // Try to optimize connection parameters
      try {
        await device.requestMtu(256); // More conservative MTU size
      } catch (e) {
        print('MTU optimization not available: $e');
      }
      
      // Close both dialogs
      Navigator.of(context).pop(); // Close connecting dialog
      Navigator.of(context).pop(); // Close scan results dialog

      setState(() {
        _targetDevice = device;
        print('[DEBUG] _targetDevice set: ${device.platformName}');
        _isTargetConnected = true;
        _isTraining = false;
        _bulletCount = TOTAL_BULLETS;
        for (var i = 0; i < gridRows; i++) {
          for (var j = 0; j < gridColumns; j++) {
            _hitCells[i][j] = false;
          }
        }
      });
      await _setupBLESubscription();

      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully connected to target',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Error connecting to target: $e');
      if (mounted) {
        Navigator.of(context).pop(); // Close connecting dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to connect to target: ${e.toString()}',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Human-readable RSSI bucket for scan UI.
  String _getSignalStrength(int rssi) {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -70) return 'Good';
    if (rssi >= -90) return 'Fair';
    return 'Poor';
  }

  /// Matches [_getSignalStrength] tiers to green → red for list tiles.
  Color _getSignalStrengthColor(int rssi) {
    if (rssi >= -50) return Colors.green;
    if (rssi >= -70) return Colors.lightGreen;
    if (rssi >= -90) return Colors.orange;
    return Colors.red;
  }

  /// Scrollable list of scan results with signal badge and Connect action.
  Widget _buildTargetList() {
    if (_targetScanResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isScanningTargets ? Icons.gps_fixed : Icons.gps_fixed,
              size: 48,
              color: _isScanningTargets 
                ? Theme.of(context).colorScheme.secondary.withOpacity(0.5)
                : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              _isScanningTargets 
                ? 'Scanning for targets...'
                : 'No targets found',
              style: GoogleFonts.poppins(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _targetScanResults.length,
      itemBuilder: (context, index) {
        final result = _targetScanResults[index];
        final device = result.device;
        final rssi = result.rssi;
        final signalStrength = _getSignalStrength(rssi);
        final signalColor = _getSignalStrengthColor(rssi);
        
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            leading: Icon(
              Icons.gps_fixed,
              color: Theme.of(context).colorScheme.secondary,
            ),
            title: Text(
              device.platformName.isNotEmpty 
                ? device.platformName 
                : 'Unknown Target',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
            ),
            subtitle: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: signalColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$signalStrength Signal (${rssi} dBm)',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: signalColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            trailing: ElevatedButton(
              onPressed: () => _connectToTarget(device),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: Text(
                'Connect',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Toggles target BLE scan on/off from UI buttons.
  void _handleScanTarget() {
    if (_isScanningTargets) {
      _stopTargetScan();
    } else {
      _startTargetScan();
    }
  }

  /// Colors SAFE vs UNSAFE pitch/status text from firmware.
  Color _getStatusColor(String status) {
    switch (status.toUpperCase()) {
      case 'SAFE':
        return Colors.green;
      case 'UNSAFE':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  /// External hook to sync target connection flag (e.g. if parent manages BLE elsewhere).
  void _handleTargetConnection(bool connected) {
    setState(() {
      _isTargetConnected = connected;
    });
  }

  /// Modal listing discovered targets; user can connect, scan again, or close.
  void _showScanResults() {
    print('Showing scan results dialog with ${_targetScanResults.length} targets'); // Debug print
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Available Targets',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: _targetScanResults.isEmpty
              ? Center(
                  child: Text(
                    'No targets found',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      color: Colors.grey[600],
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _targetScanResults.length,
                  itemBuilder: (context, index) {
                    final result = _targetScanResults[index];
                    print('Building list item for: ${result.device.platformName}'); // Debug print
                    return ListTile(
                      title: Text(
                        result.device.platformName,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        'Signal Strength: ${result.rssi} dBm',
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                      trailing: ElevatedButton(
                        onPressed: () => _connectToTarget(result.device),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: Text(
                          'Connect',
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _startTargetScan();
            },
            child: Text(
              'Scan Again',
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.blue,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Close',
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Start Training (finite bullets) and Start Practice (unlimited) — both require a connected target.
  Widget _buildTrainingButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Start Training Button
          Expanded(
            child: ElevatedButton.icon(
              onPressed: (!_isTargetConnected || _isTraining) ? null : _toggleTraining,
              icon: Icon(_isTraining ? Icons.timer : Icons.play_arrow),
              label: Text(
                _isTraining 
                    ? 'Training in Progress' 
                    : _isTargetConnected 
                        ? 'Start Training'
                        : 'Connect Target First',
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w500,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isTraining 
                    ? Colors.red.withOpacity(0.1)
                    : _isTargetConnected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey.withOpacity(0.3),
                foregroundColor: _isTraining 
                    ? Colors.red
                    : _isTargetConnected
                        ? Colors.white
                        : Colors.grey,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                disabledBackgroundColor: Colors.grey.withOpacity(0.1),
                disabledForegroundColor: Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Start Practice Button (disabled during training)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: (!_isTargetConnected || _isTraining) ? null : () {
                setState(() {
                  _isTraining = true;
                  _isPracticeMode = true;
                  // Reset all tracking data
                  for (var i = 0; i < gridRows; i++) {
                    for (var j = 0; j < gridColumns; j++) {
                      _hitCells[i][j] = false;
                    }
                  }
                  _bulletCount = 999999; // Unlimited bullets for practice
                  _totalScore = 0;
                  _hitHistory = [];
                  _gripHistory = [];
                  _pitchHistory = [];
                  _touchHistory = [];
                  _sessionStartTime = DateTime.now();
                  
                  // Start collecting sensor data
                  _startSensorDataCollection();
                });
              },
              icon: const Icon(Icons.gps_fixed),
              label: Text(
                _isTargetConnected 
                    ? 'Start Practice'
                    : 'Connect Target First',
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w500,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isTraining 
                    ? Colors.grey.withOpacity(0.1)
                    : _isTargetConnected
                        ? Theme.of(context).colorScheme.secondary
                        : Colors.grey.withOpacity(0.3),
                foregroundColor: _isTraining 
                    ? Colors.grey
                    : _isTargetConnected
                        ? Colors.white
                        : Colors.grey,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                disabledBackgroundColor: Colors.grey.withOpacity(0.1),
                disabledForegroundColor: Colors.grey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Blocks Android back during real training; practice prompts before exit.
    return WillPopScope(
      onWillPop: () async {
        if (_isTraining && !_isPracticeMode) {
          // Prevent exiting during training mode (but allow prompt in practice mode)
          return false;
        }
        if (_isPracticeMode) {
          // Show exit practice dialog
          final shouldExit = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Exit Practice?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
              content: Text('Are you sure you want to exit practice mode?', style: GoogleFonts.poppins()),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Cancel', style: GoogleFonts.poppins()),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text('Exit', style: GoogleFonts.poppins(color: Colors.red)),
                ),
              ],
            ),
          );
          if (shouldExit == true) {
            setState(() {
              _isPracticeMode = false;
              _isTraining = false;
            });
            // Do NOT navigate with pushAndRemoveUntil; just update the state.
            // Optionally, show a message or pop the dialog if needed.
            return false;
          }
          return false; // Prevent pop
        }
        return true; // Allow normal pop
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // Device Info Card
              Card(
                elevation: 0,
                color: Colors.grey[100],
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Device Information',
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[900],
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Two-column layout for devices
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Gun Device Info Column
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Gun',
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                _buildInfoRow('Device Name', widget.device.platformName.isNotEmpty 
                                    ? widget.device.platformName 
                                    : 'Unknown Device'),
                                _buildInfoRow('Status', _isGunConnected ? 'Connected' : 'Not Connected'),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Target Device Info Column
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Target',
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.secondary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                _buildInfoRow('Device Name', _targetDevice?.platformName.isNotEmpty == true 
                                    ? _targetDevice!.platformName 
                                    : 'Not Connected'),
                                _buildInfoRow('Status', _isTargetConnected ? 'Connected' : 'Not Connected'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Training Button (Static when training is active)
              Center(
                child: _isTraining
                  ? Container( // Static button when training is active
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.timer, color: Colors.red),
                          const SizedBox(width: 8),
                          Text(
                            'Ongoing Training',
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _buildTrainingButtons(),
              ),
              const SizedBox(height: 16),

              // Always show training content if training is active
              if (_isTraining) ...[
                // Target Visualization Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Target Visualization',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _handleScanTarget,
                        icon: Icon(
                        _isScanningTargets ? Icons.stop : Icons.gps_fixed,
                          size: 18,
                        ),
                        label: Text(
                          _isScanningTargets ? 'Stop Scanning' : 'Scan Target',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isScanningTargets 
                            ? Colors.red 
                            : Theme.of(context).colorScheme.secondary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Target Visualization
                Expanded(
                  child: _buildTargetVisualization(),
                ),
                const SizedBox(height: 12),
                
                // Sensor Readings
                Padding(
                  padding: const EdgeInsets.only(bottom: 4.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildSensorBox('Grip', _gripReading.toStringAsFixed(1), 'kg', Colors.blue),
                      _buildSensorBox('Pitch', _pitchReading.toStringAsFixed(1), '°', Colors.orange),
                    _buildSensorBox('Score', _totalScore.toString(), '', Colors.green),
                    _buildSensorBox('Bullets', _bulletCount.toString(), '', Colors.red),
                    ],
                  ),
                ),
              ] else ...[
                // Placeholder when not training
                Expanded(
                  child: Center(
                    child: _forceShowStartPrompt
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.gps_fixed,
                                size: 64,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Press Start Training to begin',
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.gps_fixed,
                                size: 64,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _isTargetConnected
                                    ? 'Press Start Training to begin'
                                    : 'Connect to a target to start training',
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (!_isTargetConnected) ...[
                                const SizedBox(height: 24),
                                ElevatedButton.icon(
                                  onPressed: _handleScanTarget,
                                  icon: Icon(
                                    _isScanningTargets ? Icons.stop : Icons.gps_fixed,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _isScanningTargets ? 'Stop Scanning' : 'Scan for Targets',
                                    style: GoogleFonts.poppins(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isScanningTargets
                                        ? Colors.red
                                        : Theme.of(context).colorScheme.secondary,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                  ),
                                ),
                              ],
                            ],
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Single label/value pair in the device card (connection status gets green/red value color).
  Widget _buildInfoRow(String label, String value) {
    // Determine color based on label and value
    Color valueColor = Colors.black87;
    if (label == 'Status') {
      if (value == 'Connected') {
        valueColor = Colors.green;
      } else if (value == 'Not Connected') {
        valueColor = Colors.red;
      }
    }
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.black87,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 4×4 grid with per-cell MUX channel label; hit cells show a marker and stronger styling.
  Widget _buildTargetVisualization() {
    print('[DEBUG] _buildTargetVisualization called - _hitCells state: $_hitCells');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
      ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Target',
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.grey[800],
            ),
          ),
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: gridColumns,
                  mainAxisSpacing: gridSpacing,
                  crossAxisSpacing: gridSpacing,
                ),
                itemCount: gridRows * gridColumns,
                itemBuilder: (context, index) {
                  final row = index ~/ gridColumns;
                  final col = index % gridColumns;
                  final isHit = _hitCells[row][col];
                  final pin = getPhotoPinForCell(row, col);
                  
                  // Debug print for hit cells
                  if (isHit) {
                    print('[DEBUG] Grid cell (row=$row, col=$col) is marked as HIT');
                  }
                  
                  // Create a gradient based on position
                  final isCenter = (row == 1 || row == 2) && (col == 1 || col == 2);
                  final isInner = (row == 0 || row == 3) && (col == 0 || col == 3);
                  
                  return Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: isHit 
                          ? [Colors.blue.withOpacity(0.3), Colors.blue.withOpacity(0.1)]
                          : isCenter
                            ? [Colors.blue.withOpacity(0.1), Colors.blue.withOpacity(0.05)]
                            : isInner
                              ? [Colors.blue.withOpacity(0.05), Colors.blue.withOpacity(0.02)]
                              : [Colors.grey[100]!, Colors.grey[50]!],
                      ),
                      border: Border.all(
                        color: isHit 
                          ? Colors.blue.withOpacity(0.5)
                          : Colors.grey[300]!,
                        width: isHit ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
              ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (isHit)
                            Icon(
                              Icons.gps_fixed,
                              color: Colors.blue.withOpacity(0.7),
                              size: 20,
                            ),
                          Text(
                            channelGridMap[row][col].toString(), // Show channel number instead of score
                style: GoogleFonts.poppins(
                  fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.black.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact stat tile for grip (with strength text), pitch, score, or bullets.
  Widget _buildSensorBox(String label, String value, String unit, Color color) {
    final isGrip = label.toLowerCase() == 'grip';
    final gripStrengthText = isGrip
        ? _evaluateGripStrength(double.tryParse(value) ?? 0.0, _userGender)
        : '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      constraints: const BoxConstraints(minHeight: 64, minWidth: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$value$unit',
            style: TextStyle(
              fontSize: 16,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          // Always reserve space for the extra line
          SizedBox(
            height: 16,
            child: Center(
              child: Text(
                gripStrengthText,
                style: TextStyle(
                  fontSize: 10,
                  color: color.withOpacity(0.7),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Disconnects gun and target, then shows the completion dialog (avoids double navigation).
  Future<void> _completeTrainingAndNavigate() async {
    // Set flag to prevent navigation from disconnect handler
    _navigatedAfterTraining = true;

    // Disconnect both devices and wait for them to finish
    try {
      await widget.device.disconnect();
      print('[DEBUG] Disconnected from gun device after training complete.');
    } catch (e) {
      print('[ERROR] Failed to disconnect from gun device: $e');
    }
    if (_targetDevice != null) {
      try {
        await _targetDevice!.disconnect();
        print('[DEBUG] Disconnected from target device after training complete.');
      } catch (e) {
        print('[ERROR] Failed to disconnect from target device: $e');
      }
    }

    // Now show the dialog
    _showTrainingCompleteDialog();
  }

  /// Presents final stats; OK saves session (if not practice) and resets navigation to History tab.
  void _showTrainingCompleteDialog() {
    // Calculate shots fired based on the difference between initial and remaining bullets
    final shotsFired = TOTAL_BULLETS - _bulletCount;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Training Complete!'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total Score: $_totalScore'),
              Text('Shots Fired: $shotsFired'),
              Text('Remaining Bullets: $_bulletCount'),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () async {
                Navigator.of(context).pop();
                await _saveSessionAndNavigate(); // Save session before navigating
                // Navigate to HomePage (History tab)
                print('[DEBUG] Navigating to HomePage (History tab) after training complete (using global navigatorKey).');
                navigatorKey.currentState?.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => HomePage(initialTab: 1)),
                  (route) => false,
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// Paints concentric scoring rings and red hit dots per cell (optional/alternate target view).
class TargetPainter extends CustomPainter {
  final List<Color> rings;
  final List<List<bool>> hitCells;
  final int gridRows;
  final int gridColumns;

  TargetPainter({
    required this.rings,
    required this.hitCells,
    required this.gridRows,
    required this.gridColumns,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Ring stack from outside in, then overlay hit markers aligned to the grid.
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Draw rings with adjusted spacing to fill the entire space
    for (int i = 0; i < rings.length; i++) {
      final radius = maxRadius * (1 - (i * 0.12)); // Adjusted spacing between rings
      final paint = Paint()
        ..color = rings[i]
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, paint);
    }

    // Draw hit cells with adjusted size
    final cellWidth = size.width / gridColumns;
    final cellHeight = size.height / gridRows;
    
    for (int row = 0; row < gridRows; row++) {
      for (int col = 0; col < gridColumns; col++) {
        if (hitCells[row][col]) {
          final paint = Paint()
            ..color = Colors.red
            ..style = PaintingStyle.fill;
          
          final x = center.dx - (size.width / 2) + (col * cellWidth) + (cellWidth / 2);
          final y = center.dy - (size.height / 2) + (row * cellHeight) + (cellHeight / 2);
          
          // Adjusted hit mark size
          canvas.drawCircle(
            Offset(x, y),
            min(cellWidth, cellHeight) / 2, // Larger hit marks to fill cells better
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(TargetPainter oldDelegate) {
    return true;
  }
} 