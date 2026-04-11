import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:location/location.dart';
import 'connected_device_page.dart';
import '../utils/permission_handler.dart';

/// Training tab: BLE scan for “Gripshot Gun” peripherals, permission/Bluetooth gating,
/// and navigation to [ConnectedDevicePage] after connect.
class TrainingPage extends StatefulWidget {
  const TrainingPage({super.key});

  @override
  State<TrainingPage> createState() => _TrainingPageState();
}

class _TrainingPageState extends State<TrainingPage> {
  bool _isBluetoothOn = false;
  bool _isCheckingPermissions = true;
  bool _isScanning = false;
  List<ScanResult> _scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  bool _isConnecting = false;
  BluetoothDevice? _connectedDevice;
  final Location _location = Location();

  // Add Gripshot service UUID constant
  static const String GRIPSHOT_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";

  /// Attaches FlutterBluePlus scan stream listeners.
  @override
  void initState() {
    super.initState();
    _setupScanListeners();
  }

  /// Cancels scan streams and stops any in-flight BLE discovery.
  @override
  void dispose() {
    _scanResultsSubscription?.cancel();
    _isScanningSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  /// Subscribes to global scan result and isScanning streams from FlutterBluePlus.
  void _setupScanListeners() {
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _scanResults = results;
      });
    }, onError: (e) {
      print('Error scanning: $e');
    });

    _isScanningSubscription = FlutterBluePlus.isScanning.listen((isScanning) {
      setState(() {
        _isScanning = isScanning;
      });
    });
  }

  /// Requires BT on, location permission, and location services; then starts a 30s scan
  /// and replaces the scan-results subscription with one that logs Gripshot Gun matches.
  Future<void> _startScan() async {
    if (_isScanning) return;

    // First check if Bluetooth is available and enabled
    if (!await FlutterBluePlus.isAvailable) {
      if (mounted) {
        _showBluetoothDialog();
      }
      return;
    }

    // Check Bluetooth state
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      if (mounted) {
        _showBluetoothDialog();
      }
      return;
    }

    // Check location permission
    var locationStatus = await Permission.location.status;
    if (!locationStatus.isGranted) {
      if (mounted) {
        _showLocationPermissionDialog();
      }
      return;
    }

    // Check if location services are enabled
    bool serviceEnabled = await _location.serviceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        _showLocationServicesDialog();
      }
      return;
    }

    setState(() {
      _isScanning = true;
      _scanResults = [];
    });

    try {
      print('Starting Bluetooth scan for Gripshot Gun devices...');
      
      // Start scanning without service UUID filter
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 30),
        androidUsesFineLocation: true,
        androidScanMode: AndroidScanMode.lowLatency, // Keep low latency for faster results
      );

      // Log all discovered devices for debugging
      _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
        print('Scan results updated. Found ${results.length} devices:');
        for (var result in results) {
          final deviceName = result.device.platformName;
          if (deviceName.toLowerCase().contains('gripshot gun')) {
            print('Found Gripshot Gun device: $deviceName (${result.device.remoteId.str})');
          }
        }
        
        setState(() {
          _scanResults = results;
        });
      }, onError: (e) {
        print('Error in scan results subscription: $e');
      });

    } catch (e) {
      print('Error starting scan: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error scanning for devices: ${e.toString()}',
              style: GoogleFonts.poppins(),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Stops the platform scan (errors are logged only).
  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      print('Error stopping scan: $e');
    }
  }

  /// Updates [_isBluetoothOn] after adapter checks; prompts if BT off or unavailable.
  Future<void> _checkBluetoothStatus() async {
    setState(() {
      _isCheckingPermissions = true;
    });

    try {
      // First check if Bluetooth is available
      if (!await FlutterBluePlus.isAvailable) {
        setState(() {
          _isBluetoothOn = false;
          _isCheckingPermissions = false;
        });
        _showBluetoothDialog();
        return;
      }

      // Check Bluetooth state
      final state = await FlutterBluePlus.adapterState.first;
      setState(() {
        _isBluetoothOn = state == BluetoothAdapterState.on;
        _isCheckingPermissions = false;
      });

      if (!_isBluetoothOn) {
        _showBluetoothDialog();
      }
    } catch (e) {
      setState(() {
        _isBluetoothOn = false;
        _isCheckingPermissions = false;
      });
      _showBluetoothDialog();
    }
  }

  /// Explains why BT permissions are needed; “Grant” re-runs [_checkBluetoothStatus].
  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Bluetooth Permissions Required',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Gripshot needs Bluetooth permissions to connect to your training device. '
            'These permissions are required for the app to function properly.',
            style: GoogleFonts.poppins(),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _checkBluetoothStatus();
              },
              child: Text(
                'Grant Permissions',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Android-style requirement: scanning needs location permission; opens system settings.
  void _showLocationPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Location Permission Required',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Location permission is required to scan for Bluetooth devices. '
            'This is a system requirement for Bluetooth scanning.',
            style: GoogleFonts.poppins(),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                'Cancel',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await openAppSettings();
              },
              child: Text(
                'Open Settings',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Master location switch must be on; can trigger platform service request then retry scan.
  void _showLocationServicesDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Location Services Required',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Please enable location services to scan for Bluetooth devices. '
            'This is required for Bluetooth scanning to work properly.',
            style: GoogleFonts.poppins(),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                'Cancel',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _location.requestService();
                _startScan();
              },
              child: Text(
                'Enable Location',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Prompts user to enable adapter; uses [FlutterBluePlus.turnOn] where supported then [_startScan].
  void _showBluetoothDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Bluetooth Required',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Please enable Bluetooth to search for Gripshot devices.',
            style: GoogleFonts.poppins(),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                'Cancel',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await FlutterBluePlus.turnOn();
                _startScan();
              },
              child: Text(
                'Enable Bluetooth',
                style: GoogleFonts.poppins(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Alternative connect path: stop scan, modal, connect + MTU, then [ConnectedDevicePage].
  /// (List tiles currently use their own inline connect logic instead of this method.)
  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _isConnecting = true;
    });

    try {
      // Stop scanning while connecting
      if (_isScanning) {
        await FlutterBluePlus.stopScan();
        setState(() {
          _isScanning = false;
        });
      }

      // Show connecting dialog
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Text(
              'Connecting...',
              style: GoogleFonts.orbitron(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  'Connecting to ${device.platformName}',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      // Connect with increased timeout for Android 11
      await device.connect(
        timeout: const Duration(seconds: 15), // Increased timeout for Android 11
        autoConnect: false,
      );

      // Try to optimize connection parameters
      try {
        // Request a more conservative MTU size for better compatibility
        await device.requestMtu(256);
      } catch (e) {
        print('MTU optimization not available: $e');
      }

      setState(() {
        _connectedDevice = device;
      });

      if (mounted) {
        Navigator.pop(context); // Close connecting dialog
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ConnectedDevicePage(device: device),
          ),
        );
        if (mounted) {
          setState(() {
            _connectedDevice = null;
          });
        }
      }
    } catch (e) {
      print('Error connecting to device: $e');
      if (mounted) {
        Navigator.pop(context); // Close connecting dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to connect: ${e.toString()}',
              style: GoogleFonts.poppins(),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  /// Drops link to [_connectedDevice] and shows feedback (unused while list omits this flow).
  Future<void> _disconnectDevice() async {
    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
        setState(() {
          _connectedDevice = null;
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Device disconnected',
                style: GoogleFonts.poppins(),
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } catch (e) {
        print('Error disconnecting device: $e');
      }
    }
  }

  /// Maps RSSI buckets to a short label (for future UI; list currently shows raw dBm).
  String _getSignalStrength(int rssi) {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -70) return 'Good';
    if (rssi >= -90) return 'Fair';
    return 'Poor';
  }

  /// Companion colors for [_getSignalStrength] tiers.
  Color _getSignalStrengthColor(int rssi) {
    if (rssi >= -50) return Colors.green;
    if (rssi >= -70) return Colors.lightGreen;
    if (rssi >= -90) return Colors.orange;
    return Colors.red;
  }

  /// Empty/scanning placeholder or a list of “Gripshot Gun” devices with per-row Connect.
  Widget _buildDeviceList() {
    if (_scanResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.gps_fixed,
              size: 64,
              color: Theme.of(context).colorScheme.secondary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _isScanning ? 'Searching for devices...' : 'No devices found',
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
      itemCount: _scanResults.length,
      itemBuilder: (context, index) {
        final result = _scanResults[index];
        final deviceName = result.device.platformName;
        
        // Only show devices with "Gripshot Gun" in their name
        if (!deviceName.toLowerCase().contains('gripshot gun')) {
          return const SizedBox.shrink();
        }

        return ListTile(
          leading: const Icon(Icons.gps_fixed),
          title: Text(
            deviceName,
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            'Signal Strength: ${result.rssi} dBm',
            style: GoogleFonts.poppins(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
          trailing: ElevatedButton(
            onPressed: () async {
              try {
                // Stop scanning first
                await _stopScan();
                
                // Show loading indicator
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'Connecting to $deviceName...',
                            style: GoogleFonts.poppins(),
                          ),
                        ],
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }

                // Connect to the device
                await result.device.connect(
                  autoConnect: false,
                );

                // Wait for connection to be established
                await for (final state in result.device.connectionState) {
                  if (state == BluetoothConnectionState.connected) {
                    break;
                  }
                }

                if (mounted) {
                  // Navigate to connected device page
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ConnectedDevicePage(device: result.device),
                    ),
                  );
                }
              } catch (e) {
                print('Error connecting to device: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Failed to connect to device: ${e.toString()}',
                        style: GoogleFonts.poppins(),
                      ),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text(
              'Connect',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Device list plus full-width scan/stop control wired to [_startScan] / [_stopScan].
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildDeviceList(),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _isScanning ? _stopScan : _startScan,
                icon: Icon(_isScanning ? Icons.stop : Icons.search),
                label: Text(
                  _isScanning ? 'Stop Scanning' : 'Scan Gripshot Devices',
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}