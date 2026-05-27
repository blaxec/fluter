import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:vibration/vibration.dart';
import 'core/database_helper.dart';
import 'core/excel_engine.dart';
import 'core/sync_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set system UI navigation bar and status bar to pitch black matching the theme
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.white,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.white,
  ));

  // Lock phone orientation to vertical for better athlete usage
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const PowerFlowApp());
}

class PowerFlowApp extends StatelessWidget {
  const PowerFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PowerFlow Workout Engine',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: const Color(0xFF3B82F6),
      ),
      home: const WorkoutScreen(),
    );
  }
}

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Pitch black web view frame
            InAppWebView(
              initialFile: 'assets/index.html',
              initialSettings: InAppWebViewSettings(
                allowFileAccessFromFileURLs: true,
                allowUniversalAccessFromFileURLs: true,
                useShouldOverrideUrlLoading: true,
                mediaPlaybackRequiresUserGesture: false,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                supportZoom: false,
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                _registerJavaScriptBridge(controller);
              },
              onLoadStart: (controller, url) {
                setState(() => _isLoading = true);
              },
              onLoadStop: (controller, url) async {
                setState(() => _isLoading = false);
                
                // Initialize default spreadsheet from assets if not present in app docs folder
                try {
                  final ByteData templateData = await rootBundle.load('assets/Новая таблица.xlsx');
                  final List<int> bytes = templateData.buffer.asUint8List(templateData.offsetInBytes, templateData.lengthInBytes);
                  await ExcelEngine.instance.ensureExcelExists(bytes);
                } catch (e) {
                  print("TEMPLATE LOAD FAILED: $e (Ignoring if user plans to upload custom sheet)");
                }

                // Silently trigger background synchronization tasks when app boots
                SyncService.instance.syncPendingSessions();
              },
              onConsoleMessage: (controller, consoleMessage) {
                print("WEBVIEW CONSOLE LOG: [${consoleMessage.messageLevel}] ${consoleMessage.message}");
              },
            ),
            
            // AMOLED Black loading splash overlay
            if (_isLoading)
              Container(
                color: Colors.black,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF3B82F6), Color(0xFF6366F1)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF3B82F6).withOpacity(0.3),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            )
                          ],
                        ),
                        child: const Icon(
                          Icons.fitness_center_rounded,
                          size: 32,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        "POWERFLOW",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Круговая тренировка",
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 32),
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Set up Javascript Bridge endpoints to receive web execution payloads
  void _registerJavaScriptBridge(InAppWebViewController controller) {
    // 1. Fetch persistent configuration from native SQLite
    controller.addJavaScriptHandler(
      handlerName: 'loadConfig',
      callback: (args) async {
        try {
          final config = await DatabaseHelper.instance.loadConfig();
          return jsonEncode(config);
        } catch (e) {
          print("NATIVE LOAD CONFIG ERROR: $e");
          return null;
        }
      },
    );

    // 2. Overwrite persistent configurations in native SQLite
    controller.addJavaScriptHandler(
      handlerName: 'saveConfig',
      callback: (args) async {
        try {
          if (args.isEmpty || args[0] is! String) {
            print("NATIVE SAVE CONFIG ERROR: Invalid arguments");
            return false;
          }
          final String configJson = args[0] as String;
          final Map<String, dynamic> configMap = jsonDecode(configJson);
          
          // Basic validation: ensure all values are integers
          final Map<String, int> validatedMap = {};
          configMap.forEach((key, value) {
            if (value is int) {
              validatedMap[key] = value;
            } else if (value is String) {
              final parsed = int.tryParse(value);
              if (parsed != null) validatedMap[key] = parsed;
            }
          });

          if (validatedMap.isEmpty) return false;

          await DatabaseHelper.instance.saveConfig(validatedMap);
          return true;
        } catch (e) {
          print("NATIVE SAVE CONFIG ERROR: $e");
          return false;
        }
      },
    );

    // 3. Persist and write workout records to local SQLite & Excel, then queue cloud sync
    controller.addJavaScriptHandler(
      handlerName: 'saveWorkout',
      callback: (args) async {
        try {
          final String workoutJson = args[0] as String;
          final Map<String, dynamic> workoutData = jsonDecode(workoutJson);
          
          final String day = workoutData['day'] as String? ?? 'tuesday';
          final List<dynamic> resultsList = workoutData['results'] as List<dynamic>? ?? [];
          
          final List<Map<String, dynamic>> results = resultsList.map((item) {
            return Map<String, dynamic>.from(item as Map);
          }).toList();

          // Check if session is shifted (+10% load)
          final today = DateTime.now().weekday;
          bool isShifted = false;
          if (day == 'tuesday' && today == 3) isShifted = true;
          if (day == 'thursday' && today == 5) isShifted = true;
          if (day == 'friday' && today == 7) isShifted = true; // Labeled Friday but is Saturday shifted to Sun

          // 1. Save session details in local SQLite
          final sessionId = await DatabaseHelper.instance.insertSession(day, isShifted);
          for (var r in results) {
            await DatabaseHelper.instance.insertResult(
              sessionId,
              r['exercise'] as String? ?? '',
              r['sub_category'] as String? ?? '',
              r['circuit'] as int? ?? 1,
              r['value'] as int? ?? 0,
            );
          }

          // 2. Write details in local .xlsx workbook natively using excel package
          await ExcelEngine.instance.saveWorkoutToExcel(day: day, results: results);

          // 3. Fire Google Drive asynchronous upload tasks
          SyncService.instance.syncPendingSessions();

          return {
            "status": "success",
            "written": results.length,
            "sessionId": sessionId
          };
        } catch (e) {
          print("NATIVE SAVE WORKOUT ERROR: $e");
          return {
            "status": "error",
            "message": e.toString()
          };
        }
      },
    );

    // 4. Trigger smartphone haptic vibration
    controller.addJavaScriptHandler(
      handlerName: 'vibrate',
      callback: (args) async {
        try {
          final int duration = args[0] as int? ?? 500;
          if (await Vibration.hasVibrator() ?? false) {
            Vibration.vibrate(duration: duration);
          }
          return true;
        } catch (e) {
          print("NATIVE VIBRATION ERROR: $e");
          return false;
        }
      },
    );
  }
}
