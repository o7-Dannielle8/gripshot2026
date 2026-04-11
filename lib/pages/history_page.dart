import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:convert';

/// Lists past training sessions from SharedPreferences and opens a detail dialog
/// with summary stats, fl_chart line graphs (grip, pitch, touch), and simple
/// safety/consistency labels derived from averages and profile gender.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  /// Parsed session maps (newest first after [_loadSessions]).
  List<Map<String, dynamic>> _sessions = [];

  /// From `profile_sex`; used to pick grip-force band thresholds (female vs male default).
  String? _userGender;

  @override
  void initState() {
    super.initState();
    _loadUserGender();
    _loadSessions();
  }

  /// Loads sex from profile prefs so grip charts can use gender-specific kg bands.
  Future<void> _loadUserGender() async {
    final prefs = await SharedPreferences.getInstance();
    final gender = prefs.getString('profile_sex');
    setState(() {
      _userGender = gender;
    });
  }

  /// Reads `training_sessions` as a list of JSON strings, normalizes keys/types,
  /// drops corrupt entries to a zeroed placeholder, then sorts newest-first by `date`.
  Future<void> _loadSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList('training_sessions') ?? [];
    
    setState(() {
      _sessions = sessionsJson
          .map((json) {
            try {
              final session = Map<String, dynamic>.from(jsonDecode(json));
              // Ensure all required fields have default values and proper types
              return {
                'date': session['date']?.toString() ?? DateTime.now().toIso8601String(),
                'totalScore': (session['totalScore'] ?? 0) as int,
                'hitHistory': session['hitHistory'] ?? [],
                'duration': (session['duration'] ?? 0) as int,
                'accuracy': (session['accuracy'] ?? 0) as int,
                'shotsFired': (session['shotsFired'] ?? 0) as int,
                'averageScore': (session['averageScore'] ?? 0.0) as double,
                'deviceName': session['deviceName']?.toString() ?? 'Unknown Device',
                'gripHistory': session['gripHistory'] ?? [],
                'pitchHistory': session['pitchHistory'] ?? [],
                'touchHistory': session['touchHistory'] ?? [],
              };
            } catch (e) {
              print('Error parsing session: $e');
              return {
                'date': DateTime.now().toIso8601String(),
                'totalScore': 0,
                'hitHistory': [],
                'duration': 0,
                'accuracy': 0,
                'shotsFired': 0,
                'averageScore': 0.0,
                'deviceName': 'Unknown Device',
                'gripHistory': [],
                'pitchHistory': [],
                'touchHistory': [],
              };
            }
          })
          .toList()
        ..sort((a, b) => DateTime.parse(b['date']).compareTo(DateTime.parse(a['date'])));
    });
  }

  /// `d/m/y H:MM` for display, or a fallback if parsing fails.
  String _formatDate(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return 'Invalid Date';
    }
  }

  /// Rounds total seconds down to `m:ss` for session duration chips.
  String _formatDuration(int seconds) {
    try {
      final minutes = seconds ~/ 60;
      final remainingSeconds = seconds % 60;
      return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
    } catch (e) {
      return '0:00';
    }
  }

  /// Modal with scrollable metrics plus three charts; each chart shows average
  /// and a text verdict (grip: weak/moderate/excessive by gender bands; pitch:
  /// safe if avg within ±5°; touch: consistent/intermittent/none by avg 0–1).
  void _showSessionDetails(Map<String, dynamic> session) async {
    // Wait for gender to load if not yet available
    if (_userGender == null) {
      await _loadUserGender();
    }
    showDialog(
      context: context,
      builder: (context) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
        ),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                'Session Details',
                style: GoogleFonts.poppins(
                    fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Date: ${_formatDate(session['date'])}',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    color: Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 16),
                _buildDetailRow('Device', session['deviceName']),
                _buildDetailRow('Duration', _formatDuration(session['duration'])),
                _buildDetailRow('Total Score', '${session['totalScore']} points'),
                _buildDetailRow('Average Score', '${session['averageScore'].toStringAsFixed(1)} points'),
                _buildDetailRow('Accuracy', '${session['accuracy']}%'),
                _buildDetailRow('Shots Fired', '${session['shotsFired']}'),
                const SizedBox(height: 24),
                
                // Grip Chart
                Text(
                  'Grip Force Over Time',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: _buildSensorChart(
                    session['gripHistory'] ?? [],
                    Colors.blue,
                    'kg',
                  ),
                ),
                const SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final gripData = session['gripHistory'] ?? [];
                    final gripValues = gripData.map((e) => (e['value'] as num).toDouble()).toList();
                    if (gripValues.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 24.0),
                        child: Text(
                          'No grip data available',
                          style: GoogleFonts.poppins(fontSize: 14, color: Colors.red, fontWeight: FontWeight.w600),
                        ),
                      );
                    }
                    double avg = gripValues.reduce((a, b) => a + b) / gripValues.length;
                    String? eval;
                    final gender = _userGender?.toLowerCase();
                    // Female vs male kg bands; unknown gender uses male-scale thresholds.
                    if (gender == 'female') {
                      if (avg < 20) eval = 'Weak';
                      else if (avg <= 25) eval = 'Moderate';
                      else if (avg <= 29) eval = 'Excessive';
                      else eval = 'Excessive';
                    } else if (gender == 'male') {
                      if (avg < 40) eval = 'Weak';
                      else if (avg <= 45) eval = 'Moderate';
                      else if (avg <= 53) eval = 'Excessive';
                      else eval = 'Excessive';
                    } else {
                      if (avg < 40) eval = 'Weak';
                      else if (avg <= 45) eval = 'Moderate';
                      else if (avg <= 53) eval = 'Excessive';
                      else eval = 'Excessive';
                    }
                    Color evalColor = Colors.purple;
                    if (eval == 'Moderate') evalColor = Colors.green;
                    else if (eval == 'Weak' || eval == 'Excessive') evalColor = Colors.red;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 24.0),
                      child: Text(
                        'Average: ${avg.toStringAsFixed(2)} kg — $eval',
                        style: GoogleFonts.poppins(fontSize: 14, color: evalColor, fontWeight: FontWeight.w600),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, thickness: 1, color: Color(0x11000000)),
                const SizedBox(height: 16),
                // Pitch Chart
                Text(
                  'Muzzle Pitch Over Time',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: _buildSensorChart(
                    session['pitchHistory'] ?? [],
                    Colors.orange,
                    '°',
                  ),
                ),
                const SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final pitchData = session['pitchHistory'] ?? [];
                    final pitchValues = pitchData.map((e) => (e['value'] as num).toDouble()).toList();
                    if (pitchValues.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 24.0),
                        child: Text(
                          'No pitch data available',
                          style: GoogleFonts.poppins(fontSize: 14, color: Colors.red, fontWeight: FontWeight.w600),
                        ),
                      );
                    }
                    double avg = pitchValues.reduce((a, b) => a + b) / pitchValues.length;
                    String eval = (avg < -5.0 || avg > 5.0) ? 'Unsafe' : 'Safe';
                    Color evalColor = eval == 'Safe' ? Colors.green : Colors.red;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 24.0),
                      child: Text(
                        'Average: ${avg.toStringAsFixed(2)}° — $eval',
                        style: GoogleFonts.poppins(fontSize: 14, color: evalColor, fontWeight: FontWeight.w600),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, thickness: 1, color: Color(0x11000000)),
                const SizedBox(height: 16),
                Text(
                  'Touch Sensor Activity',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.purple,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: _buildTouchSensorChart(
                    session['touchHistory'] ?? [],
                  ),
                ),
                const SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final touchData = session['touchHistory'] ?? [];
                    final touchValues = touchData.map((e) => (e['value'] as num).toDouble()).toList();
                    if (touchValues.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: Text(
                          'No touch data available',
                          style: GoogleFonts.poppins(fontSize: 14, color: Colors.red, fontWeight: FontWeight.w600),
                        ),
                      );
                    }
                    double avg = touchValues.reduce((a, b) => a + b) / touchValues.length;
                    String eval;
                    if (avg > 0.8) eval = 'Consistent';
                    else if (avg > 0.2) eval = 'Intermittent';
                    else eval = 'No Touch';
                    Color evalColor = eval == 'Consistent' ? Colors.green : (eval == 'Intermittent' ? Colors.orange : Colors.red);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: Text(
                        'Average: ${(avg * 100).toStringAsFixed(1)}% — $eval',
                        style: GoogleFonts.poppins(fontSize: 14, color: evalColor, fontWeight: FontWeight.w600),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Close',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.secondary,
                    ),
                ),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  /// Single summary line: muted label on the left, value on the right.
  Widget _buildDetailRow(String label, String value) {
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

  /// Line chart of `{value}` samples over sample index; auto-scales Y with padding.
  /// Touch tooltips reuse [evaluate] for grip (kg + gender) or pitch (° safe/unsafe).
  Widget _buildSensorChart(List<dynamic> data, Color color, String unit) {
    if (data.isEmpty) {
      return Center(
        child: Text(
          'No data available',
          style: GoogleFonts.poppins(
            fontSize: 14,
            color: Colors.grey[600],
          ),
        ),
      );
    }

    // Convert data to spots
    final spots = data.asMap().entries.map((entry) {
      final value = entry.value['value'] as double;
      return FlSpot(entry.key.toDouble(), value);
    }).toList();

    // Helper for evaluation
    String? evaluate(double value, String unit) {
      if (unit == 'kg') {
        final gender = _userGender?.toLowerCase();
        if (gender == 'female') {
          if (value < 20) return 'Weak';
          if (value <= 25) return 'Moderate';
          if (value <= 29) return 'Excessive';
          return 'Excessive';
        } else if (gender == 'male') {
          if (value < 40) return 'Weak';
          if (value <= 45) return 'Moderate';
          if (value <= 53) return 'Excessive';
          return 'Excessive';
        } else {
          // Default to male scaling if gender is unknown
          if (value < 40) return 'Weak';
          if (value <= 45) return 'Moderate';
          if (value <= 53) return 'Excessive';
          return 'Excessive';
        }
      } else if (unit == '°') {
        if (value < -5.0 || value > 5.0) return 'Unsafe';
        return 'Safe';
      }
      return null;
    }

    // Find min and max values for y-axis
    final minY = spots.map((spot) => spot.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((spot) => spot.y).reduce((a, b) => a > b ? a : b);
    
    // Handle cases where min and max are the same or very close
    final yRange = maxY - minY;
    final yPadding = yRange * 0.1; // Add 10% padding
    final adjustedMinY = minY - yPadding;
    final adjustedMaxY = maxY + yPadding;
    
    // Ensure there's always a reasonable range for the y-axis
    final finalMinY = yRange < 0.1 ? adjustedMinY - 0.5 : adjustedMinY;
    final finalMaxY = yRange < 0.1 ? adjustedMaxY + 0.5 : adjustedMaxY;
    
    // Calculate a reasonable interval for grid lines
    final yInterval = (finalMaxY - finalMinY) / 5;
    final safeYInterval = yInterval < 0.1 ? 0.1 : yInterval;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: safeYInterval,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey[300],
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
              reservedSize: 30,
              interval: spots.length > 10 ? spots.length / 5 : 1,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= spots.length) return const Text('');
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    '${value.toInt() + 1}',
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
              interval: safeYInterval,
              getTitlesWidget: (value, meta) {
                return Text(
                  '${value.toStringAsFixed(1)}$unit',
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: Colors.grey[600],
                  ),
                );
              },
              reservedSize: 40,
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: Colors.grey[300]!),
        ),
        minX: 0,
        maxX: spots.length - 1.0,
        minY: finalMinY,
        maxY: finalMaxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: color,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: false,
            ),
            belowBarData: BarAreaData(
              show: true,
              color: color.withOpacity(0.1),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            tooltipBgColor: Colors.white,
            tooltipRoundedRadius: 8,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final value = spot.y;
                final eval = evaluate(value, unit);
                Color evalColor = Colors.black;
                if (eval == 'Safe' || eval == 'Moderate') evalColor = Colors.green;
                else if (eval == 'Weak' || eval == 'Excessive' || eval == 'Unsafe') evalColor = Colors.red;
                return LineTooltipItem(
                  '${value.toStringAsFixed(2)}$unit\n${eval ?? ''}',
                  GoogleFonts.poppins(
                    fontSize: 14,
                    color: eval != null ? evalColor : color,
                    fontWeight: FontWeight.w600,
                  ),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  /// Binary-ish touch trace (0/1) as a stepped line with fixed Y 0–1 axis labels.
  Widget _buildTouchSensorChart(List<dynamic> data) {
    if (data.isEmpty) {
      return Center(
        child: Text(
          'No touch data available',
          style: GoogleFonts.poppins(
            fontSize: 14,
            color: Colors.grey[600],
          ),
        ),
      );
    }

    // Convert data to spots for step chart
    final spots = data.asMap().entries.map((entry) {
      final value = entry.value['value'] as double;
      return FlSpot(entry.key.toDouble(), value);
    }).toList();

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 0.5,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey[300],
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
              reservedSize: 30,
              interval: spots.length > 10 ? spots.length / 5 : 1,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= spots.length) return const Text('');
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    '${value.toInt() + 1}',
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
              interval: 0.5,
              getTitlesWidget: (value, meta) {
                if (value == 0.0) return const Text('Not Touched');
                if (value == 1.0) return const Text('Touched');
                return const Text('');
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
        minY: -0.1,
        maxY: 1.1,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false, // Use straight lines for step-like appearance
            color: Colors.purple,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 3,
                  color: Colors.purple,
                  strokeWidth: 2,
                  strokeColor: Colors.white,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.purple.withOpacity(0.2),
            ),
          ),
        ],
      ),
    );
  }

  /// Empty state vs scrollable cards; tap opens [_showSessionDetails].
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _sessions.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.history,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No training sessions yet',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final session = _sessions[index];
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: Colors.grey[200]!,
                      width: 1,
                    ),
                  ),
                  child: InkWell(
                    onTap: () => _showSessionDetails(session),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDate(session['date']),
                                style: GoogleFonts.poppins(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.grey[700],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.secondary.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${session['totalScore']} pts',
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Theme.of(context).colorScheme.secondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              _buildSessionStat(
                                Icons.timer,
                                _formatDuration(session['duration']),
                              ),
                              const SizedBox(width: 16),
                              _buildSessionStat(
                                Icons.percent,
                                '${session['accuracy']}%',
                              ),
                              const SizedBox(width: 16),
                              _buildSessionStat(
                                Icons.gps_fixed,
                                '${session['shotsFired']} shots',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// Small icon + text row used on session list cards for duration/accuracy/shots.
  Widget _buildSessionStat(IconData icon, String value) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: Colors.grey[600],
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: GoogleFonts.poppins(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }
} 