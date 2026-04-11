import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:io';
import '../pages/connected_page.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:convert';
import 'package:flutter/rendering.dart';

/// Profile tab: edit user info and photo, scan/connect Gripshot BLE targets, and
/// view training analytics (metrics + charts) for sessions in a chosen time window.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with AutomaticKeepAliveClientMixin {
  // --- Profile (SharedPreferences: profile_* keys) ---
  String? name;
  int? age;
  String? sex;
  String? profileImagePath;
  /// Avatar path while the create/edit dialog is open (committed on Save).
  String? _tempImagePath;
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  String? _selectedSex;
  final _imagePicker = ImagePicker();
  bool hasShownWelcome = false;

  // --- BLE: scan list + connection UI state ---
  bool isScanning = false;
  List<ScanResult> scanResults = [];
  BluetoothDevice? connectedDevice;
  bool isConnecting = false;

  // --- Progress panel: sessions filtered by [_selectedTimePeriod] ---
  String _selectedTimePeriod = '1d';
  List<Map<String, dynamic>> _trainingSessions = [];
  bool _isLoadingProgress = false;
  bool _hasLoadedSessions = false;

  /// Keeps this tab’s state when switching away on the home [NavigationBar].
  @override
  bool get wantKeepAlive => true;

  /// Loads profile from prefs, resets progress state, and defers [_loadTrainingSessions] slightly for stability.
  @override
  void initState() {
    super.initState();
    print('ProfilePage initState called');
    _loadProfile();
    _selectedTimePeriod = '1d';
    _hasLoadedSessions = false;
    _trainingSessions = [];
    _isLoadingProgress = false;
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
    _loadTrainingSessions();
      }
    });
  }

  /// Re-loads session aggregates when the tab becomes visible again if the first load was skipped.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedTimePeriod.isEmpty) {
      _selectedTimePeriod = '1d';
    }
    if (!_hasLoadedSessions && !_isLoadingProgress) {
      _loadTrainingSessions();
    }
  }

  /// Pulls profile + welcome flags from prefs; on first install with no name, shows welcome flow.
  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final isFirstInstall = prefs.getBool('is_first_install') ?? true;
    
    setState(() {
      name = prefs.getString('profile_name');
      sex = prefs.getString('profile_sex');
      age = prefs.getInt('profile_age');
      profileImagePath = prefs.getString('profile_image_path');
      hasShownWelcome = prefs.getBool('has_shown_welcome') ?? false;
    });

    if (isFirstInstall && name == null) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        _showWelcomeDialog();
      }
    }
  }

  /// Parses `training_sessions` JSON strings, keeps rows in [_selectedTimePeriod] window, sorts newest first.
  Future<void> _loadTrainingSessions() async {
    if (name == null) {
      print('Profile not set up yet, skipping session load');
      return;
    }
    if (_isLoadingProgress) {
      print('Already loading sessions, skipping');
      return;
    }
    
    print('Starting to load training sessions...');
    setState(() {
      _isLoadingProgress = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionsJson = prefs.getStringList('training_sessions') ?? [];
      print('Found ${sessionsJson.length} total sessions');
      
      final now = DateTime.now();
      print('Current time: $now');
      print('Selected time period: $_selectedTimePeriod');
      
      final sessions = sessionsJson
          .map((json) => Map<String, dynamic>.from(jsonDecode(json)))
          .where((session) {
            final sessionDate = DateTime.parse(session['date']);
            final difference = now.difference(sessionDate);
            final hoursDiff = difference.inHours;
            print('Session date: $sessionDate, Hours difference: $hoursDiff');
            
            bool include = false;
            switch (_selectedTimePeriod) {
              case '1d':
                include = hoursDiff <= 24; // Last 24 hours
                break;
              case '3d':
                include = hoursDiff <= 72; // Last 72 hours (3 days)
                break;
              case '7d':
                include = hoursDiff <= 168; // Last 168 hours (7 days)
                break;
              default:
                include = hoursDiff <= 24;
                break;
            }
            print('Include session: $include');
            return include;
          })
          .toList()
        ..sort((a, b) => DateTime.parse(b['date']).compareTo(DateTime.parse(a['date'])));
      
      print('Filtered to ${sessions.length} sessions in selected time period');

      if (mounted) {
        setState(() {
          _trainingSessions = sessions;
          _isLoadingProgress = false;
          _hasLoadedSessions = true;
        });
        print('Sessions loaded successfully');
      }
    } catch (e) {
      print('Error loading training sessions: $e');
      if (mounted) {
        setState(() {
          _isLoadingProgress = false;
          _hasLoadedSessions = true;
        });
      }
    }
  }

  /// Forces another [_loadTrainingSessions] pass (e.g. after changing the time window).
  Future<void> _refreshTrainingSessions() async {
    _hasLoadedSessions = false;
    await _loadTrainingSessions();
  }

  /// Aggregates [_trainingSessions]: score/accuracy/shots/best, mean grip (per-session mean of samples),
  /// and muzzle stability (10 minus scaled pitch variance per session, then averaged).
  Map<String, dynamic> _calculateProgressMetrics() {
    if (_trainingSessions.isEmpty) {
      return {
        'totalSessions': 0,
        'averageScore': 0.0,
        'averageAccuracy': 0.0,
        'totalShots': 0,
        'bestScore': 0,
        'averageGripStrength': 0.0,
        'averageMuzzleStability': 0.0,
      };
    }

    final totalSessions = _trainingSessions.length;
    final totalScore = _trainingSessions.fold<int>(
      0, 
      (sum, session) => sum + (session['totalScore'] as int)
    );
    final totalAccuracy = _trainingSessions.fold<double>(
      0, 
      (sum, session) => sum + (session['accuracy'] as int).toDouble()
    );
    final totalShots = _trainingSessions.fold<int>(
      0, 
      (sum, session) => sum + (session['shotsFired'] as int)
    );
    final bestScore = _trainingSessions
        .map((s) => s['totalScore'] as int)
        .reduce((a, b) => a > b ? a : b);

    // Calculate average grip strength and muzzle stability
    double totalGripStrength = 0.0;
    double totalMuzzleStability = 0.0;
    int sessionsWithGripData = 0;
    int sessionsWithPitchData = 0;

    for (final session in _trainingSessions) {
      // Calculate average grip strength for this session
      final gripHistory = session['gripHistory'] as List<dynamic>? ?? [];
      if (gripHistory.isNotEmpty) {
        final sessionGripSum = gripHistory.fold<double>(
          0.0, 
          (sum, entry) => sum + (entry['value'] as double? ?? 0.0)
        );
        totalGripStrength += sessionGripSum / gripHistory.length;
        sessionsWithGripData++;
      }

      // Calculate average muzzle stability (lower pitch variation = better stability)
      final pitchHistory = session['pitchHistory'] as List<dynamic>? ?? [];
      if (pitchHistory.isNotEmpty) {
        final pitchValues = pitchHistory.map((entry) => entry['value'] as double? ?? 0.0).toList();
        final averagePitch = pitchValues.reduce((a, b) => a + b) / pitchValues.length;
        final pitchVariance = pitchValues.fold<double>(
          0.0, 
          (sum, pitch) => sum + ((pitch - averagePitch) * (pitch - averagePitch))
        ) / pitchValues.length;
        final pitchStability = 10.0 - (pitchVariance / 10.0).clamp(0.0, 10.0);
        totalMuzzleStability += pitchStability;
        sessionsWithPitchData++;
      }
    }

    final averageGripStrength = sessionsWithGripData > 0 ? totalGripStrength / sessionsWithGripData : 0.0;
    final averageMuzzleStability = sessionsWithPitchData > 0 ? totalMuzzleStability / sessionsWithPitchData : 0.0;

    return {
      'totalSessions': totalSessions,
      'averageScore': totalScore / totalSessions,
      'averageAccuracy': totalAccuracy / totalSessions,
      'totalShots': totalShots,
      'bestScore': bestScore,
      'averageGripStrength': averageGripStrength,
      'averageMuzzleStability': averageMuzzleStability,
    };
  }

  /// 24h / 3d / 7d filter for progress data; changing value clears load flag and reloads sessions.
  Widget _buildTimePeriodDropdown() {
    return DropdownButton<String>(
      value: _selectedTimePeriod,
      items: [
        DropdownMenuItem(
          value: '1d',
          child: Text(
            'Last 24h',
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: _selectedTimePeriod == '1d' 
                  ? Theme.of(context).colorScheme.primary 
                  : Theme.of(context).colorScheme.onSurface,
              fontWeight: _selectedTimePeriod == '1d' 
                  ? FontWeight.w600 
                  : FontWeight.normal,
            ),
          ),
        ),
        DropdownMenuItem(
          value: '3d',
          child: Text(
            'Last 3 days',
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: _selectedTimePeriod == '3d' 
                  ? Theme.of(context).colorScheme.primary 
                  : Theme.of(context).colorScheme.onSurface,
              fontWeight: _selectedTimePeriod == '3d' 
                  ? FontWeight.w600 
                  : FontWeight.normal,
            ),
          ),
        ),
        DropdownMenuItem(
          value: '7d',
          child: Text(
            'Last 7 days',
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: _selectedTimePeriod == '7d' 
                  ? Theme.of(context).colorScheme.primary 
                  : Theme.of(context).colorScheme.onSurface,
              fontWeight: _selectedTimePeriod == '7d' 
                  ? FontWeight.w600 
                  : FontWeight.normal,
            ),
          ),
        ),
      ],
      onChanged: (value) {
        if (value != null && value != _selectedTimePeriod) {
          setState(() {
            _selectedTimePeriod = value;
            _hasLoadedSessions = false;
          });
          _loadTrainingSessions();
        }
      },
      underline: Container(),
      icon: Icon(
        Icons.arrow_drop_down,
        color: Theme.of(context).colorScheme.primary,
        size: 20,
      ),
      style: GoogleFonts.poppins(
        fontSize: 13,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  /// Placeholder CTA when no profile; else metrics, refresh, technique charts, and score trend.
  Widget _buildProgressSection() {
    if (name == null) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.analytics,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Training Progress',
              style: GoogleFonts.orbitron(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Set up your profile using the button above to start tracking your training progress and earn achievements',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                height: 1.5,
              ),
            ),
          ],
        ),
      );
    }

    print('Building progress section: isLoading=$_isLoadingProgress, hasLoaded=$_hasLoadedSessions, sessions=${_trainingSessions.length}');

    final metrics = _calculateProgressMetrics();

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                'Training Progress',
                style: GoogleFonts.orbitron(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildTimePeriodDropdown(),
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                    setState(() {
                          _hasLoadedSessions = false;
                          _isLoadingProgress = false;
                    });
                    _loadTrainingSessions();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.refresh,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_isLoadingProgress)
            const Center(child: CircularProgressIndicator())
          else if (_trainingSessions.isEmpty)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.gps_fixed,
                    size: 48,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                                    Text(
                    _selectedTimePeriod == '1d'
                        ? 'No training sessions in the last 24 hours'
                        : _selectedTimePeriod == '3d'
                            ? 'No training sessions in the last 3 days'
                            : 'No training sessions in the last 7 days',
                    style: GoogleFonts.poppins(
                      color: Colors.grey[600],
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Complete a training session to see your progress',
                    style: GoogleFonts.poppins(
                      color: Colors.grey[500],
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    'Sessions',
                    metrics['totalSessions'].toString(),
                    '',
                    'Total',
                    Colors.blue,
                    Icons.calendar_today,
                    Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricCard(
                    'Avg Score',
                    metrics['averageScore'].toStringAsFixed(1),
                    'pts',
                    'Average',
                    Colors.orange,
                    Icons.stars,
                    Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricCard(
                    'Accuracy',
                    metrics['averageAccuracy'].toStringAsFixed(1),
                    '%',
                    'Overall',
                    Colors.green,
                    Icons.percent,
                    Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Second row of metric cards for grip strength and muzzle stability
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    'Grip Strength',
                    metrics['averageGripStrength'].toStringAsFixed(1),
                    'kg',
                    'Average',
                    Colors.blue,
                    Icons.fitness_center,
                    Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricCard(
                    'Muzzle Stability',
                    metrics['averageMuzzleStability'].toStringAsFixed(1),
                    '/10',
                    'Score',
                    Colors.orange,
                    Icons.straighten,
                    Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricCard(
                    'Best Score',
                    metrics['bestScore'].toString(),
                    'pts',
                    'Session',
                    Colors.purple,
                    Icons.emoji_events,
                    Colors.purple,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Grip Strength and Muzzle Stability Charts (Prominent)
            Text(
              'Technique Analysis',
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            
            // Grip Strength Chart (Full width)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Grip Strength Trend',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: _buildGripStrengthChart(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            
            // Muzzle Stability Chart (Full width)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Muzzle Stability Trend',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: _buildMuzzleStabilityChart(),
                ),
              ],
            ),
            
            // Score Trend (Less prominent)
            Text(
              'Score Trend',
              style: GoogleFonts.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: _buildScoreChart(),
            ),
          ],
        ],
      ),
    );
  }

  /// Compact stat tile: icon, main number, small subtitle (used in the progress grid).
  Widget _buildMetricCard(String title, String value, String unit, String subtitle, Color color, IconData icon, Color iconColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            size: 20,
            color: iconColor,
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.orbitron(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// Line chart of [totalScore] per session, X = chronological session index (oldest first).
  Widget _buildScoreChart() {
    print('Called _buildScoreChart');
    if (_trainingSessions.isEmpty) return const SizedBox.shrink();

    // Always sort sessions in ascending order (oldest to newest) for correct chart order
    final sessionsChronological = List<Map<String, dynamic>>.from(_trainingSessions)
      ..sort((a, b) => DateTime.parse(a['date']).compareTo(DateTime.parse(b['date'])));
    print('Session order for Score Chart:');
    for (var session in sessionsChronological) {
      print(session['date']);
    }
    final spots = sessionsChronological.asMap().entries.map((entry) {
      return FlSpot(
        entry.key.toDouble(),
        (entry.value['totalScore'] as int).toDouble(),
      );
    }).toList();

    // Handle empty spots
    if (spots.isEmpty) return const SizedBox.shrink();

    // Calculate min and max for better Y-axis scaling
    final minY = spots.map((spot) => spot.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((spot) => spot.y).reduce((a, b) => a > b ? a : b);
    final yRange = maxY - minY;
    final yPadding = yRange * 0.1;
    // Handle edge case where min and max are the same
    final adjustedMinY = yRange == 0 ? (minY - 1.0).clamp(0.0, double.infinity) : (minY - yPadding).clamp(0.0, double.infinity);
    final adjustedMaxY = yRange == 0 ? (maxY + 1.0) : maxY + yPadding;

    // Use a fixed interval for Y-axis labels to avoid repeated labels
    final yInterval = ((adjustedMaxY - adjustedMinY) / 5).clamp(1, double.infinity).toDouble();

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey[300]!,
              strokeWidth: 1,
            );
          },
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 35,
              interval: spots.length > 5 ? spots.length / 5 : 1,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= spots.length) return const Text('');
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'Session ${value.toInt() + 1}', // Session 1 = oldest
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: Colors.grey[600],
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: yInterval,
              getTitlesWidget: (value, meta) {
                // Only show label if it's a multiple of yInterval from adjustedMinY
                if (((value - adjustedMinY) % yInterval).abs() < 0.01 || (value - adjustedMinY).abs() < 0.01) {
                  return Text(
                    '${value.toInt()} pts',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: Colors.grey[600],
                    ),
                  );
                } else {
                  return const SizedBox.shrink();
                }
              },
              reservedSize: 60,
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: Colors.grey[300]!),
        ),
        minX: 0,
        maxX: spots.length - 1.0,
        minY: adjustedMinY,
        maxY: adjustedMaxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Theme.of(context).colorScheme.primary,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 4,
                  color: Theme.of(context).colorScheme.primary,
                  strokeWidth: 2,
                  strokeColor: Colors.white,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
            ),
          ),
        ],
      ),
    );
  }

  /// One Y point per session: mean of [gripHistory] values (0 if missing).
  Widget _buildGripStrengthChart() {
    print('Called _buildGripStrengthChart');
    if (_trainingSessions.isEmpty) return const SizedBox.shrink();

    // Always sort sessions in ascending order (oldest to newest) for correct chart order
    final sessionsChronological = List<Map<String, dynamic>>.from(_trainingSessions)
      ..sort((a, b) => DateTime.parse(a['date']).compareTo(DateTime.parse(b['date'])));
    print('Session order for Grip Strength Chart:');
    for (var session in sessionsChronological) {
      print(session['date']);
    }
    final spots = sessionsChronological.asMap().entries.map((entry) {
      final session = entry.value;
      final gripHistory = session['gripHistory'] as List<dynamic>? ?? [];
      if (gripHistory.isNotEmpty) {
        final gripValues = gripHistory.map((entry) => entry['value'] as double? ?? 0.0).toList();
        final averageGrip = gripValues.reduce((a, b) => a + b) / gripValues.length;
        return FlSpot(entry.key.toDouble(), averageGrip);
      }
      return FlSpot(entry.key.toDouble(), 0.0);
    }).toList();

    // Handle empty spots
    if (spots.isEmpty) return const SizedBox.shrink();

    // Calculate min and max for better Y-axis scaling
    final minY = spots.map((spot) => spot.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((spot) => spot.y).reduce((a, b) => a > b ? a : b);
    final yRange = maxY - minY;
    final yPadding = yRange * 0.1;
    // Handle edge case where min and max are the same
    final adjustedMinY = yRange == 0 ? (minY - 0.5).clamp(0.0, double.infinity) : (minY - yPadding).clamp(0.0, double.infinity);
    final adjustedMaxY = yRange == 0 ? (maxY + 0.5) : maxY + yPadding;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: (adjustedMaxY - adjustedMinY) / 5,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey[300]!,
              strokeWidth: 1,
            );
          },
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 35,
              interval: spots.length > 5 ? spots.length / 5 : 1,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= spots.length) return const Text('');
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'Session ${spots.length - value.toInt()}', // Session 1 = most recent
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: Colors.grey[600],
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (adjustedMaxY - adjustedMinY) / 5,
              getTitlesWidget: (value, meta) {
                return Text(
                  '${value.toStringAsFixed(1)} kg',
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: Colors.grey[600],
                  ),
                );
              },
              reservedSize: 60,
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: Colors.grey[300]!),
        ),
        minX: 0,
        maxX: spots.length - 1.0,
        minY: adjustedMinY,
        maxY: adjustedMaxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Colors.blue,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 4,
                  color: Colors.blue,
                  strokeWidth: 2,
                  strokeColor: Colors.white,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.blue.withOpacity(0.1),
            ),
          ),
        ],
      ),
    );
  }

  /// Per-session stability score (0–10) from pitch variance, same formula as [_calculateProgressMetrics].
  Widget _buildMuzzleStabilityChart() {
    print('Called _buildMuzzleStabilityChart');
    if (_trainingSessions.isEmpty) return const SizedBox.shrink();

    // Always sort sessions in ascending order (oldest to newest) for correct chart order
    final sessionsChronological = List<Map<String, dynamic>>.from(_trainingSessions)
      ..sort((a, b) => DateTime.parse(a['date']).compareTo(DateTime.parse(b['date'])));
    print('Session order for Muzzle Stability Chart:');
    for (var session in sessionsChronological) {
      print(session['date']);
    }
    final spots = sessionsChronological.asMap().entries.map((entry) {
      final session = entry.value;
      final pitchHistory = session['pitchHistory'] as List<dynamic>? ?? [];
      if (pitchHistory.isNotEmpty) {
        final pitchValues = pitchHistory.map((entry) => entry['value'] as double? ?? 0.0).toList();
        final averagePitch = pitchValues.reduce((a, b) => a + b) / pitchValues.length;
        final pitchVariance = pitchValues.fold<double>(
          0.0, 
          (sum, pitch) => sum + ((pitch - averagePitch) * (pitch - averagePitch))
        ) / pitchValues.length;
        final pitchStability = 10.0 - (pitchVariance / 10.0).clamp(0.0, 10.0);
        return FlSpot(entry.key.toDouble(), pitchStability);
      }
      return FlSpot(entry.key.toDouble(), 0.0);
    }).toList();

    // Handle empty spots
    if (spots.isEmpty) return const SizedBox.shrink();

    // Calculate min and max for better Y-axis scaling
    final minY = spots.map((spot) => spot.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((spot) => spot.y).reduce((a, b) => a > b ? a : b);
    final yRange = maxY - minY;
    final yPadding = yRange * 0.1;
    // Handle edge case where min and max are the same
    final adjustedMinY = yRange == 0 ? (minY - 1.0).clamp(0.0, 10.0) : (minY - yPadding).clamp(0.0, 10.0);
    final adjustedMaxY = yRange == 0 ? (maxY + 1.0).clamp(0.0, 10.0) : (maxY + yPadding).clamp(0.0, 10.0);

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: (adjustedMaxY + 0.5 - (adjustedMinY - 0.5)) / 5,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey[300]!,
              strokeWidth: 1,
            );
          },
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 35,
              interval: spots.length > 5 ? spots.length / 5 : 1,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= spots.length) return const Text('');
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'Session ${spots.length - value.toInt() + 1}', // Session 1 = oldest
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: Colors.grey[600],
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (adjustedMaxY + 0.5 - (adjustedMinY - 0.5)) / 5,
              getTitlesWidget: (value, meta) {
                return Text(
                  '${value.toStringAsFixed(1)}/10',
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: Colors.grey[600],
                  ),
                );
              },
              reservedSize: 60,
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: Colors.grey[300]!),
        ),
        minX: 0,
        maxX: spots.length - 1.0,
        minY: adjustedMinY,
        maxY: adjustedMaxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Colors.orange,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 4,
                  color: Colors.orange,
                  strokeWidth: 2,
                  strokeColor: Colors.white,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.orange.withOpacity(0.1),
            ),
          ),
        ],
      ),
    );
  }

  /// First-run modal; leads into [_showProfileForm]. Cannot dismiss by tapping outside.
  void _showWelcomeDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          'Welcome to Gripshot',
          style: GoogleFonts.orbitron(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),
        content: Text(
          'Let\'s set up your profile to start your training journey.',
          style: GoogleFonts.poppins(
            fontSize: 15,
            color: Theme.of(context).colorScheme.onSurface,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showProfileForm();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(
                  'Get Started',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Create/edit dialog with gallery avatar, validated name/sex/age; writes prefs and updates state on Save.
  void _showProfileForm() async {
    _nameController.text = name ?? '';
    _selectedSex = sex;
    _ageController.text = age?.toString() ?? '';
    _tempImagePath = profileImagePath;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_shown_welcome', true);
    await prefs.setBool('is_first_install', false);

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(
              name == null ? 'Create Profile' : 'Edit Profile',
              style: GoogleFonts.orbitron(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            content: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () async {
                        try {
                          final pickedFile = await _imagePicker.pickImage(
                            source: ImageSource.gallery,
                            maxWidth: 500,
                            maxHeight: 500,
                            imageQuality: 85,
                          );

                          if (pickedFile != null) {
                            setDialogState(() {
                              _tempImagePath = pickedFile.path;
                            });
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error picking image: ${e.toString()}'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.surface,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.secondary,
                            width: 2,
                          ),
                        ),
                        child: _tempImagePath != null
                            ? ClipOval(
                                child: Image.file(
                                  File(_tempImagePath!),
                                  width: 120,
                                  height: 120,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Icon(
                                Icons.add_a_photo,
                                size: 40,
                                color: Theme.of(context).colorScheme.secondary,
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Tap to change profile picture',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        border: OutlineInputBorder(),
                        hintText: 'Enter your full name',
                      ),
                      textCapitalization: TextCapitalization.words,
                      validator: _validateName,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _selectedSex,
                      decoration: const InputDecoration(
                        labelText: 'Sex',
                        border: OutlineInputBorder(),
                      ),
                      dropdownColor: Theme.of(context).brightness == Brightness.light 
                          ? Colors.white 
                          : const Color(0xFF2C2C2C),
                      style: GoogleFonts.orbitron(
                        color: Theme.of(context).brightness == Brightness.light 
                            ? const Color(0xFF424242) 
                            : const Color(0xFFE0E0E0),
                        fontSize: 16,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'Male',
                          child: Text(
                            'Male',
                            style: GoogleFonts.orbitron(
                              fontSize: 16,
                              color: Theme.of(context).brightness == Brightness.light 
                                  ? const Color(0xFF424242) 
                                  : const Color(0xFFE0E0E0),
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Female',
                          child: Text(
                            'Female',
                            style: GoogleFonts.orbitron(
                              fontSize: 16,
                              color: Theme.of(context).brightness == Brightness.light 
                                  ? const Color(0xFF424242) 
                                  : const Color(0xFFE0E0E0),
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Other',
                          child: Text(
                            'Other',
                            style: GoogleFonts.orbitron(
                              fontSize: 16,
                              color: Theme.of(context).brightness == Brightness.light 
                                  ? const Color(0xFF424242) 
                                  : const Color(0xFFE0E0E0),
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          _selectedSex = value;
                        });
                      },
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please select your sex';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _ageController,
                      decoration: const InputDecoration(
                        labelText: 'Age',
                        border: OutlineInputBorder(),
                        hintText: 'Enter your age (13-100)',
                      ),
                      keyboardType: TextInputType.number,
                      validator: _validateAge,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _tempImagePath = null;
                  });
                  Navigator.of(context).pop();
                },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (!_formKey.currentState!.validate()) {
                    return;
                  }

                  try {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('profile_name', _nameController.text.trim());
                    await prefs.setString('profile_sex', _selectedSex ?? '');
                    await prefs.setInt('profile_age', int.parse(_ageController.text.trim()));
                    
                    if (_tempImagePath != profileImagePath) {
                      await prefs.setString('profile_image_path', _tempImagePath ?? '');
                      setState(() {
                        profileImagePath = _tempImagePath;
                      });
                    }
                    
                    setState(() {
                      name = _nameController.text.trim();
                      sex = _selectedSex;
                      age = int.tryParse(_ageController.text.trim());
                    });

                    if (mounted) {
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Profile saved successfully'),
                          backgroundColor: Color(0xFF2196F3),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error saving profile: ${e.toString()}'),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    }
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Allows letters, spaces, hyphen, apostrophe, period; length 2–50.
  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your name';
    }
    
    final nameRegex = RegExp("[a-zA-Z\\s\\-\\.\\']");
    if (!nameRegex.hasMatch(value.trim())) {
      return 'Name should only contain letters, spaces, hyphens, apostrophes, and periods';
    }

    if (value.trim().length < 2) {
      return 'Name should be at least 2 characters long';
    }

    if (value.trim().length > 50) {
      return 'Name should not exceed 50 characters';
    }

    return null;
  }

  /// Integer age between 13 and 100 inclusive.
  String? _validateAge(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your age';
    }

    final age = int.tryParse(value.trim());
    if (age == null) {
      return 'Please enter a valid number';
    }

    if (age < 13 || age > 100) {
      return 'Age must be between 13 and 100';
    }

    return null;
  }

  /// Reserved for header avatar tap; image picking is implemented inside [_showProfileForm].
  void _pickImage() {
    // Implementation of _pickImage method
  }

  /// Hook for live device payloads (e.g. ESP32); not wired from this page yet.
  void updateSensorData(String data) {
    // Example data format: "pitch:45.5,status:SAFE,grip:2.3kg"
    // Call this function whenever you receive new data from ESP32
  }

  /// Starts BLE scan, filters names containing `gripshot target`, then opens [_showScanResults] after a delay.
  Future<void> _startScan() async {
    if (isScanning) return;

    setState(() {
      isScanning = true;
      scanResults.clear();
    });

    try {
      if (await FlutterBluePlus.isAvailable == false) {
        throw Exception('Bluetooth is not available on this device');
      }

      if (await FlutterBluePlus.isOn == false) {
        throw Exception('Please turn on Bluetooth');
      }

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 4),
        androidUsesFineLocation: true,
      );

      FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          scanResults = results.where((result) {
            final deviceName = result.device.platformName;
            return deviceName.toLowerCase().contains('gripshot target');
          }).toList();
        });
      });

      await Future.delayed(const Duration(seconds: 10));
      
      if (mounted) {
        _showScanResults();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error scanning: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isScanning = false;
        });
      }
    }
  }

  /// Shows blocking dialog, [BluetoothDevice.connect], stores `last_connected_device`, pushes [ConnectedPage].
  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (isConnecting) return;

    setState(() {
      isConnecting = true;
    });

    try {
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

      await device.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );

      setState(() {
        connectedDevice = device;
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_connected_device', device.remoteId.str);

      if (mounted) {
        Navigator.pop(context);
        Navigator.pop(context);

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ConnectedPage(device: device),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isConnecting = false;
        });
      }
    }
  }

  /// Lists filtered [scanResults]; tap row calls [_connectToDevice] unless already connected to that device.
  void _showScanResults() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Available Targets',
          style: GoogleFonts.orbitron(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: scanResults.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.gps_fixed,
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
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: scanResults.length,
                  itemBuilder: (context, index) {
                    final result = scanResults[index];
                    final device = result.device;
                    final isConnected = connectedDevice?.remoteId == device.remoteId;
                    
                    return ListTile(
                      leading: Icon(
                        isConnected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                        color: isConnected 
                            ? Theme.of(context).colorScheme.primary 
                            : Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      ),
                      title: Text(
                        device.platformName,
                        style: GoogleFonts.poppins(
                          fontWeight: FontWeight.w500,
                          color: isConnected 
                              ? Theme.of(context).colorScheme.primary 
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Signal Strength: ${result.rssi} dBm',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                            ),
                          ),
                          if (isConnected)
                            Text(
                              'Connected',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                      trailing: isConnected
                          ? Icon(
                              Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () {
                        if (!isConnected) {
                          _connectToDevice(device);
                        }
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
          if (scanResults.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _startScan();
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Scan Again'),
            ),
        ],
      ),
    );
  }

  /// Gradient header (avatar + profile CTA or summary) and scrollable [_buildProgressSection] below.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF1A1A1A),
                  const Color(0xFF2C3E50).withOpacity(0.95),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: _pickImage,
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(
                        color: const Color(0xFF5B7A9D).withOpacity(0.3),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: profileImagePath != null
                        ? ClipOval(
                            child: Image.file(
                              File(profileImagePath!),
                              width: 100,
                              height: 100,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Icon(
                            Icons.person,
                            size: 60,
                            color: const Color(0xFF5B7A9D).withOpacity(0.5),
                          ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (name != null && sex != null && age != null) ...[
                        Text(
                          name!,
                          style: GoogleFonts.orbitron(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              sex!,
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                color: Colors.white.withOpacity(0.8),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '$age years old',
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                color: Colors.white.withOpacity(0.8),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: _showProfileForm,
                          icon: const Icon(Icons.edit, size: 18),
                          label: Text(
                            'Edit Profile',
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF5B7A9D).withOpacity(0.2),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                        ),
                      ] else ...[
                        Text(
                          'Welcome to Gripshot!',
                          style: GoogleFonts.orbitron(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Set up your profile and start earning achievements',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            color: Colors.white.withOpacity(0.8),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _showProfileForm,
                          icon: const Icon(Icons.person_add, size: 18),
                          label: Text(
                            'Set Up Profile',
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF5B7A9D).withOpacity(0.2),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildProgressSection(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
} 