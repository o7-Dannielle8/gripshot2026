import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'connected_device_page.dart';

/// Screen shown while paired to a Gripshot BLE device: shows live connection
/// state, subscribes to notify characteristics for incoming payload strings,
/// and offers scan/switch and disconnect from the app bar.
class ConnectedPage extends StatefulWidget {
  final BluetoothDevice device;

  const ConnectedPage({
    super.key,
    required this.device,
  });

  @override
  State<ConnectedPage> createState() => _ConnectedPageState();
}

class _ConnectedPageState extends State<ConnectedPage> {
  /// Mirrors BLE link state; drives the status banner and disconnect dialog.
  bool isConnected = true;

  /// Most recent UTF-8 string decoded from a characteristic notification.
  String? lastReceivedData;

  /// Newest-first log of received strings (capped at [maxHistoryItems]).
  List<String> dataHistory = [];
  final int maxHistoryItems = 10;

  @override
  void initState() {
    super.initState();
    _setupConnection();
  }

  /// Watches connection drops, discovers GATT services, and enables notify on
  /// every characteristic that supports it so incoming bytes become strings in state.
  Future<void> _setupConnection() async {
    // Listen for disconnection
    widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        setState(() {
          isConnected = false;
        });
        _showDisconnectedDialog();
      }
    });

    // Discover services
    try {
      List<BluetoothService> services = await widget.device.discoverServices();
      
      // Find the service and characteristic for data
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.notify) {
            // Enable notifications
            await characteristic.setNotifyValue(true);
            
            // Listen for data
            characteristic.onValueReceived.listen((value) {
              if (value.isNotEmpty) {
                String data = String.fromCharCodes(value);
                setState(() {
                  lastReceivedData = data;
                  // Add to history, keeping only the last maxHistoryItems
                  dataHistory.insert(0, data);
                  if (dataHistory.length > maxHistoryItems) {
                    dataHistory.removeLast();
                  }
                });
              }
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error setting up connection: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Non-dismissible alert; OK pops the dialog and the route so the user leaves this screen.
  void _showDisconnectedDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(
          'Connection Lost',
          style: GoogleFonts.orbitron(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
        content: Text(
          'The connection to ${widget.device.platformName} was lost.',
          style: GoogleFonts.poppins(
            fontSize: 16,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Return to profile page
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Drops the BLE session and pops this page on success; shows errors in a snackbar.
  Future<void> _disconnect() async {
    try {
      await widget.device.disconnect();
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error disconnecting: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// App bar with device name, scan-for-targets flow, and disconnect; body shows
  /// connection banner plus latest BLE string and rolling history.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.device.platformName,
          style: GoogleFonts.orbitron(
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          // Opens a modal that lists nearby "Gripshot Target" devices and can switch connection.
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () async {
              // Show scan dialog
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(
                    'Scan for Targets',
                    style: GoogleFonts.orbitron(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  content: SizedBox(
                    width: double.maxFinite,
                    child: StreamBuilder<List<ScanResult>>(
                      stream: FlutterBluePlus.scanResults,
                      initialData: const [],
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        // Only show peripherals whose advertised name looks like a Gripshot target.
                        final results = snapshot.data!.where((result) {
                          final deviceName = result.device.platformName;
                          return deviceName.toLowerCase().contains('gripshot target');
                        }).toList();

                        if (results.isEmpty) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.bluetooth_searching,
                                size: 48,
                                color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No Gripshot Targets found',
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Make sure your target is turned on\nand within range',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.poppins(
                                  fontSize: 14,
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                ),
                              ),
                            ],
                          );
                        }

                        return ListView.builder(
                          shrinkWrap: true,
                          itemCount: results.length,
                          itemBuilder: (context, index) {
                            final result = results[index];
                            final device = result.device;
                            final isCurrentDevice = device.remoteId == widget.device.remoteId;
                            
                            return ListTile(
                              leading: Icon(
                                isCurrentDevice ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                                color: isCurrentDevice 
                                    ? Theme.of(context).colorScheme.primary 
                                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                              ),
                              title: Text(
                                device.platformName,
                                style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.w500,
                                  color: isCurrentDevice 
                                      ? Theme.of(context).colorScheme.primary 
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              subtitle: Text(
                                'Signal Strength: ${result.rssi} dBm',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                ),
                              ),
                              trailing: isCurrentDevice
                                  ? Icon(
                                      Icons.check_circle,
                                      color: Theme.of(context).colorScheme.primary,
                                    )
                                  : const Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () {
                                if (!isCurrentDevice) {
                                  Navigator.pop(context); // Close scan dialog
                                  _disconnect(); // Disconnect from current device
                                  // Navigate to new device
                                  Navigator.pushReplacement(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => ConnectedPage(device: device),
                                    ),
                                  );
                                }
                              },
                            );
                          },
                        );
                      },
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                    // Retriggers a 10s BLE scan (same as when the dialog first opens).
                    TextButton.icon(
                      onPressed: () async {
                        try {
                          await FlutterBluePlus.startScan(
                            timeout: const Duration(seconds: 10),
                            androidUsesFineLocation: true,
                          );
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error scanning: ${e.toString()}'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Scan Again'),
                    ),
                  ],
                ),
              );

              // Start scanning
              try {
                await FlutterBluePlus.startScan(
                  timeout: const Duration(seconds: 10),
                  androidUsesFineLocation: true,
                );
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error scanning: ${e.toString()}'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            tooltip: 'Scan for Targets',
          ),
          // Disconnect button
          IconButton(
            icon: const Icon(Icons.bluetooth_disabled),
            onPressed: _disconnect,
            tooltip: 'Disconnect',
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner: connected vs disconnected styling and copy.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: isConnected 
                ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                : Theme.of(context).colorScheme.error.withOpacity(0.1),
            child: Row(
              children: [
                Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: isConnected 
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  isConnected ? 'Connected' : 'Disconnected',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: isConnected 
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          ),

          // Scrollable area: latest payload plus capped history list.
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (lastReceivedData != null) ...[
                  Text(
                    'Latest Data',
                    style: GoogleFonts.orbitron(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                      ),
                    ),
                    child: Text(
                      lastReceivedData!,
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                
                // Data History
                Text(
                  'Data History',
                  style: GoogleFonts.orbitron(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                if (dataHistory.isEmpty)
                  Center(
                    child: Text(
                      'No data received yet',
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                  )
                else
                  ...dataHistory.map((data) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
                        ),
                      ),
                      child: Text(
                        data,
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  )).toList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Clean up connection when leaving the page
    widget.device.disconnect();
    super.dispose();
  }
} 