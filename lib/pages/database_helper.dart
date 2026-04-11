import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Singleton around a local SQLite database (`gripshot.db`) that persists
/// completed training sessions (scores and per-session history blobs as TEXT).
class DatabaseHelper {
  /// Shared app-wide accessor; use [instance] instead of constructing directly.
  static final DatabaseHelper instance = DatabaseHelper._init();

  /// Lazily opened connection; kept open after first [database] access.
  static Database? _database;

  DatabaseHelper._init();

  /// Returns the open DB, opening it on the platform app documents path if needed.
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('gripshot.db');
    return _database!;
  }

  /// Resolves the sqflite folder, joins [filePath], and opens v1 with [_createDB] on first create.
  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  /// Creates the `training_sessions` table: one row per session with numeric score
  /// and three TEXT columns for hit/grip/pitch history (caller-defined string format).
  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE training_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        total_score INTEGER NOT NULL,
        hit_history TEXT NOT NULL,
        grip_history TEXT NOT NULL,
        pitch_history TEXT NOT NULL
      )
    ''');
  }

  /// Inserts one row; coerces `hit_history`, `grip_history`, and `pitch_history`
  /// with [Object.toString] so list/map values become storable TEXT.
  Future<int> insertSession(Map<String, dynamic> session) async {
    final db = await database;
    
    // Convert lists to JSON strings
    final hitHistoryJson = session['hit_history'].toString();
    final gripHistoryJson = session['grip_history'].toString();
    final pitchHistoryJson = session['pitch_history'].toString();

    final data = {
      'timestamp': session['timestamp'],
      'total_score': session['total_score'],
      'hit_history': hitHistoryJson,
      'grip_history': gripHistoryJson,
      'pitch_history': pitchHistoryJson,
    };

    return await db.insert('training_sessions', data);
  }

  /// Loads every session row as maps, newest first by `timestamp` string.
  Future<List<Map<String, dynamic>>> getAllSessions() async {
    final db = await database;
    return await db.query('training_sessions', orderBy: 'timestamp DESC');
  }

  /// Removes the session whose primary key matches [id].
  Future<void> deleteSession(int id) async {
    final db = await database;
    await db.delete(
      'training_sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
} 