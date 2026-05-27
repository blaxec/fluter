import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'database_helper.dart';
import 'excel_engine.dart';

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

class SyncService {
  static final SyncService instance = SyncService._init();
  SyncService._init() {
    // Listen for internet connectivity changes to auto-sync unsynced sessions
    Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
      if (result != ConnectivityResult.none) {
        syncPendingSessions();
      }
    });
  }

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      drive.DriveApi.driveFileScope,
      drive.DriveApi.driveAppdataScope,
    ],
  );

  GoogleSignInAccount? _currentUser;
  drive.DriveApi? _driveApi;

  // Triggers user authentication flow
  Future<bool> signIn() async {
    try {
      _currentUser = await _googleSignIn.signInSilently();
      _currentUser ??= await _googleSignIn.signIn();
      
      if (_currentUser != null) {
        final authHeaders = await _currentUser!.authHeaders;
        final authClient = GoogleAuthClient(authHeaders);
        _driveApi = drive.DriveApi(authClient);
        return true;
      }
      return false;
    } catch (e) {
      print("GOOGLE DRIVE SIGN-IN ERROR: $e");
      return false;
    }
  }

  // Signs out from Google Account
  Future<void> signOut() async {
    await _googleSignIn.disconnect();
    _currentUser = null;
    _driveApi = null;
  }

  bool get isAuthenticated => _currentUser != null;

  // Search, download, or upload Excel spreadsheet to Google Drive
  Future<String?> _findExcelFileId() async {
    if (_driveApi == null) return null;
    
    try {
      final fileList = await _driveApi!.files.list(
        q: "name = 'Новая таблица.xlsx' and trashed = false",
        spaces: 'drive',
      );
      
      if (fileList.files != null && fileList.files!.isNotEmpty) {
        return fileList.files!.first.id;
      }
      return null;
    } catch (e) {
      print("FIND FILE ERROR: $e");
      return null;
    }
  }

  // Synchronizes local file with Google Drive copy
  Future<bool> syncExcelFile() async {
    if (_driveApi == null) {
      final signedIn = await signIn();
      if (!signedIn) return false;
    }

    try {
      final localFile = await ExcelEngine.instance.getLocalExcelFile();
      final fileId = await _findExcelFileId();

      if (fileId == null) {
        // File does not exist on Drive; upload current local file
        if (await localFile.exists()) {
          final driveFile = drive.File()..name = 'Новая таблица.xlsx';
          final media = drive.Media(
            localFile.openRead(),
            await localFile.length(),
            contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          );
          
          await _driveApi!.files.create(driveFile, uploadMedia: media);
          print("UPLOADED INITIAL FILE TO DRIVE");
          return true;
        }
      } else {
        // File exists on Drive; we check timestamps
        final driveMetadata = await _driveApi!.files.get(
          fileId,
          $fields: 'id, name, modifiedTime',
        ) as drive.File;

        final DateTime? driveModified = driveMetadata.modifiedTime;
        
        if (!await localFile.exists()) {
          return await _downloadFromDrive(fileId, localFile);
        } else {
          final DateTime localModified = await localFile.lastModified();
          
          // If Drive is newer than local (by more than a small buffer to avoid jitter)
          if (driveModified != null && driveModified.isAfter(localModified.add(const Duration(seconds: 2)))) {
            print("REMOTE FILE IS NEWER, DOWNLOADING BEFORE UPDATE");
            await _downloadFromDrive(fileId, localFile);
          }

          // Now push local changes to Drive (they are now merged if we downloaded)
          final media = drive.Media(
            localFile.openRead(),
            await localFile.length(),
            contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          );
          
          final driveFile = drive.File();
          await _driveApi!.files.update(
            driveFile,
            fileId,
            uploadMedia: media,
          );
          print("UPDATED DRIVE WORKBOOK WITH LOCAL PROGRESS");
          return true;
        }
      }
    } catch (e) {
      print("SYNC WORKBOOK ERROR: $e");
    }
    return false;
  }

  Future<bool> _downloadFromDrive(String fileId, File localFile) async {
    final mediaResponse = await _driveApi!.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    
    final List<int> dataBytes = [];
    await for (var chunk in mediaResponse.stream) {
      dataBytes.addAll(chunk);
    }
    
    if (!await localFile.exists()) {
      await localFile.create(recursive: true);
    }
    await localFile.writeAsBytes(dataBytes, flush: true);
    print("DOWNLOADED WORKBOOK FROM DRIVE");
    return true;
  }

  // Background queue worker to process offline saved sessions
  Future<void> syncPendingSessions() async {
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity == ConnectivityResult.none) return;

    final unsynced = await DatabaseHelper.instance.getUnsyncedSessions();
    if (unsynced.isEmpty) return;

    final signedIn = await signIn();
    if (!signedIn) return;

    for (var session in unsynced) {
      final sId = session['id'] as int;
      final String day = session['day_name'] as String;
      final List<Map<String, dynamic>> results = List<Map<String, dynamic>>.from(session['results']);

      try {
        // First sync/download latest sheet
        await syncExcelFile();

        // Write session data to the local copy
        await ExcelEngine.instance.saveWorkoutToExcel(day: day, results: results);

        // Upload the updated spreadsheet to Drive
        final uploaded = await syncExcelFile();
        if (uploaded) {
          await DatabaseHelper.instance.markSessionSynced(sId);
          print("SESSION $sId SUCCESSFULLY SYNCED IN BACKGROUND");
        }
      } catch (e) {
        print("SESSION $sId SYNC FAILURE: $e");
      }
    }
  }
}
