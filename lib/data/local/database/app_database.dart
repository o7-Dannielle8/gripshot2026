import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Singleton sqflite access for `gripshot.db`: opens once, exposes v1 tables for users,
/// media “shots,” categories, likes, and comments (epoch-ms timestamps).
class AppDatabase {
  static final AppDatabase _instance = AppDatabase._internal();

  /// Cached connection; nulled after [close].
  static Database? _database;

  factory AppDatabase() => _instance;

  AppDatabase._internal();

  /// Opens the DB on first use, then returns the same instance.
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Opens `gripshot.db` under the platform database directory at schema [version] 1.
  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'gripshot.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  /// Runs on first DB creation: `users`, `shots`, `categories`, `likes`, `comments` with FKs
  /// and UNIQUE constraints where defined; times are INTEGER Unix milliseconds.
  Future<void> _onCreate(Database db, int version) async {
    // Users table
    await db.execute('''
      CREATE TABLE users(
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        email TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        profile_image_path TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Shots table
    await db.execute('''
      CREATE TABLE shots(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT,
        image_path TEXT NOT NULL,
        category_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
        FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE SET NULL
      )
    ''');

    // Categories table
    await db.execute('''
      CREATE TABLE categories(
        id TEXT PRIMARY KEY,
        name TEXT UNIQUE NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Likes table
    await db.execute('''
      CREATE TABLE likes(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        shot_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
        FOREIGN KEY (shot_id) REFERENCES shots (id) ON DELETE CASCADE,
        UNIQUE(user_id, shot_id)
      )
    ''');

    // Comments table
    await db.execute('''
      CREATE TABLE comments(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        shot_id TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
        FOREIGN KEY (shot_id) REFERENCES shots (id) ON DELETE CASCADE
      )
    ''');
  }

  /// Closes the singleton connection and clears [_database] so the next [database] access reopens.
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
} 