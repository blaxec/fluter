import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('powerflow.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Configs Table for on-device configurations
    await db.execute('''
      CREATE TABLE configs (
        key TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      )
    ''');

    // Sessions Table to record history logs
    await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        day_name TEXT NOT NULL,
        is_shifted INTEGER NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Individual exercise results
    await db.execute('''
      CREATE TABLE results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        exercise_name TEXT NOT NULL,
        sub_category TEXT NOT NULL,
        circuit INTEGER NOT NULL,
        actual_value INTEGER NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
      )
    ''');

    // Populate Default Configurations
    final Map<String, int> defaultConfigs = {
      "prepTime": 5,
      "circuitsCount": 3,
      "tueDeepPushupsReps": 13,
      "tueAnglePushupsReps": 8,
      "tueDiamondPushupsReps": 7,
      "tueElevatedPushupsReps": 14,
      "tueCircuitRest": 60,
      "thuLungesReps": 21,
      "thuSquatsReps": 21,
      "thuCalvesReps": 40,
      "thuAbsReps": 16,
      "thuCircuitRest": 60,
      "friNegTime1": 5,
      "friNegTime2": 5,
      "friNegTime3": 5,
      "friRestNeg": 10,
      "friRowReps": 30,
      "friNarrowReps": 4,
      "friCircuitRest": 60
    };

    final batch = db.batch();
    defaultConfigs.forEach((k, v) {
      batch.insert('configs', {'key': k, 'value': v});
    });
    await batch.commit(noResult: true);
  }

  // Configuration Getters & Setters
  Future<Map<String, int>> loadConfig() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('configs');
    
    final Map<String, int> config = {};
    for (var map in maps) {
      config[map['key'] as String] = map['value'] as int;
    }
    return config;
  }

  Future<void> saveConfig(Map<String, dynamic> configMap) async {
    final db = await database;
    final batch = db.batch();
    configMap.forEach((k, v) {
      if (v is int) {
        batch.insert(
          'configs',
          {'key': k, 'value': v},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    await batch.commit(noResult: true);
  }

  // Logging Sessions and Results
  Future<int> insertSession(String dayName, bool isShifted) async {
    final db = await database;
    final dateStr = DateTime.now().toIso8601String().substring(0, 10);
    
    return await db.insert('sessions', {
      'date': dateStr,
      'day_name': dayName,
      'is_shifted': isShifted ? 1 : 0,
      'synced': 0
    });
  }

  Future<void> insertResult(int sessionId, String exerciseName, String subCategory, int circuit, int actualValue) async {
    final db = await database;
    await db.insert('results', {
      'session_id': sessionId,
      'exercise_name': exerciseName,
      'sub_category': subCategory,
      'circuit': circuit,
      'actual_value': actualValue
    });
  }

  Future<void> markSessionSynced(int sessionId) async {
    final db = await database;
    await db.update(
      'sessions',
      {'synced': 1},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<List<Map<String, dynamic>>> getUnsyncedSessions() async {
    final db = await database;
    final List<Map<String, dynamic>> sessions = await db.query(
      'sessions',
      where: 'synced = 0',
    );

    final List<Map<String, dynamic>> fullSessions = [];
    for (var session in sessions) {
      final sId = session['id'];
      final List<Map<String, dynamic>> results = await db.query(
        'results',
        where: 'session_id = ?',
        whereArgs: [sId],
      );

      final Map<String, dynamic> sessionData = Map<String, dynamic>.from(session);
      sessionData['results'] = results;
      fullSessions.add(sessionData);
    }
    return fullSessions;
  }
}
