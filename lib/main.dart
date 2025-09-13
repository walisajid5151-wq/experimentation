// main.dart
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:workmanager/workmanager.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase (placeholder - replace with your config)
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "YOUR_API_KEY",
      appId: "YOUR_APP_ID",
      messagingSenderId: "YOUR_MESSAGING_SENDER_ID",
      projectId: "your-project-id-placeholder",
      storageBucket: "your-project-id-placeholder.appspot.com",
    ),
  );

  // Initialize WorkManager
  Workmanager.initialize(
    callbackDispatcher,
    isInDebugMode: false,
  );

  // Initialize database
  final database = await initDatabase();

  runApp(MyApp(database: database));
}

class MyApp extends StatelessWidget {
  final Database database;

  const MyApp({super.key, required this.database});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Recorder',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: HomeScreen(database: database),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final Database database;

  const HomeScreen({super.key, required this.database});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool isRecording = false;
  String? currentCaseId;
  List<Map<String, dynamic>> recentCases = [];

  @override
  void initState() {
    super.initState();
    loadRecentCases();
  }

  Future<void> loadRecentCases() async {
    final cases = await widget.database.query(
      'cases',
      orderBy: 'date DESC',
      limit: 10,
    );
    setState(() {
      recentCases = cases;
    });
  }

  Future<void> startRecording() async {
    if (!await _checkPermissions()) return;

    final caseId = DateTime.now().toString().replaceAll(RegExp(r'[^0-9A-Za-z]'), '_');
    final caseDir = _getCaseDirectory(caseId);

    // Create directory structure
    await Directory(caseDir).create(recursive: true);

    // Show consent dialog
    final shouldProceed = await _showConsentDialog();
    if (!shouldProceed) return;

    // Start recording
    try {
      final recorder = AudioRecorder();
      final audioPath = '$caseDir/raw.m4a';
      
      await recorder.start(
        outputFormat: OutputFormat.aacAdts, // Note: AAC in .m4a container
        sampleRate: 48000,
        channels: 1,
        bitRate: 64000,
        outputFilePath: audioPath,
      );

      setState(() {
        isRecording = true;
        currentCaseId = caseId;
      });

      // Save case to DB with pending status
      await widget.database.insert(
        'cases',
        {
          'caseId': caseId,
          'date': DateTime.now().toIso8601String(),
          'audioFilePath': audioPath,
          'transcriptPath': '$caseDir/transcript.txt',
          'status': 'recording',
          'consent_given': shouldProceed ? 1 : 0,
        },
      );

      // Trigger background upload after stop
      Workmanager.registerOneOffTask(
        'upload-task-$caseId',
        'uploadTask',
        initialDelay: const Duration(seconds: 1),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresCharging: false,
        ),
      );

    } catch (e) {
      print('Recording error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Recording failed: $e')),
      );
    }
  }

  Future<void> stopRecording() async {
    if (!isRecording || currentCaseId == null) return;

    final recorder = AudioRecorder();
    await recorder.stop();

    // Update status in DB
    await widget.database.update(
      'cases',
      {'status': 'uploaded'}, // Will be updated by background task
      where: 'caseId = ?', 
      whereArgs: [currentCaseId],
    );

    setState(() {
      isRecording = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Recording saved. Uploading in background...')),
    );

    // Reload cases list
    loadRecentCases();
  }

  Future<bool> _checkPermissions() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<bool> _showConsentDialog() async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Consent'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'We are recording this visit for research. Your identity will not be stored. Do you consent?',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              'ہم آج کی ملاقات تحقیق کے لیے ریکارڈ کر رہے ہیں۔ آپ کی شناخت محفوظ نہیں کی جائے گی۔ کیا آپ اجازت دیتے ہیں؟',
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'NotoNaskhArabic'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    ) ?? false;
  }

  String _getCaseDirectory(String caseId) {
    return '${_getAppDataDirectory()}/Cases/$caseId';
  }

  String _getAppDataDirectory() {
    return Platform.isAndroid ? '/data/data/${Platform.packageName}' : '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Recorder')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton.icon(
              onPressed: isRecording ? stopRecording : startRecording,
              icon: Icon(isRecording ? Icons.stop : Icons.mic),
              label: Text(isRecording ? 'Stop Recording' : 'Start Recording'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isRecording ? Colors.red : Colors.blue,
                minimumSize: const Size.fromHeight(80),
                textStyle: const TextStyle(fontSize: 20),
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: recentCases.length,
                itemBuilder: (context, index) {
                  final caseItem = recentCases[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Icon(Icons.history),
                      title: Text(caseItem['caseId']),
                      subtitle: Text('${caseItem['status']}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => CaseDetailScreen(
                                caseId: caseItem['caseId'],
                                database: widget.database,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CaseDetailScreen extends StatefulWidget {
  final String caseId;
  final Database database;

  const CaseDetailScreen({
    super.key,
    required this.caseId,
    required this.database,
  });

  @override
  State<CaseDetailScreen> createState() => _CaseDetailScreenState();
}

class _CaseDetailScreenState extends State<CaseDetailScreen> {
  late String transcriptText;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTranscript();
  }

  Future<void> _loadTranscript() async {
    final caseDir = '${_getAppDataDirectory()}/Cases/${widget.caseId}';
    final transcriptPath = '$caseDir/transcript.txt';

    try {
      final file = File(transcriptPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        setState(() {
          transcriptText = content;
          isLoading = false;
        });
      } else {
        setState(() {
          transcriptText = 'Transcript not available yet.';
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        transcriptText = 'Error loading transcript: $e';
        isLoading = false;
      });
    }
  }

  String _getAppDataDirectory() {
    return Platform.isAndroid ? '/data/data/${Platform.packageName}' : '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Case: ${widget.caseId}')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Transcript:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            if (isLoading)
              const CircularProgressIndicator()
            else
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    transcriptText,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () async {
                final caseDir = '${_getAppDataDirectory()}/Cases/${widget.caseId}';
                final filePath = '$caseDir/transcript.txt';
                final file = File(filePath);
                if (await file.exists()) {
                  // Open file (basic implementation - use file_opener or similar)
                  final result = await OpenFile.open(filePath);
                  if (result.type != OpenFileType.success) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to open file')),
                    );
                  }
                }
              },
              icon: const Icon(Icons.file_open),
              label: const Text('Open Transcript File'),
            ),
          ],
        ),
      ),
    );
  }
}

// Background worker - runs even when app is closed
void callbackDispatcher() {
  Workmanager.executeTask((task, inputData) async {
    switch (task) {
      case 'uploadTask':
        await _uploadAndTranscribe();
        break;
    }
    return Future.value(true);
  });
}

Future<void> _uploadAndTranscribe() async {
  try {
    final db = await _getDatabase();
    final pendingCases = await db.query(
      'cases',
      where: 'status = ? OR status = ?', 
      whereArgs: ['recording', 'uploaded'],
    );

    for (final caseRecord in pendingCases) {
      final caseId = caseRecord['caseId'] as String;
      final audioPath = caseRecord['audioFilePath'] as String;
      final file = File(audioPath);

      if (!await file.exists()) continue;

      // Upload to Firebase Storage (placeholder)
      final storageRef = FirebaseStorage.instance
          .ref('cases/$caseId/raw.m4a');

      try {
        await storageRef.putFile(file);
        final downloadUrl = await storageRef.getDownloadURL();

        // Call backend transcription API
        final response = await http.post(
          Uri.parse('https://your-backend-api-placeholder.com/transcribe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'audio_url': downloadUrl,
            'task': 'translate',
            'speaker_labels': true,
            'language_detection': true,
          }),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final transcript = _formatTranscript(data['speakers']);

          // Save transcript locally
          final caseDir = '${_getAppDataDirectory()}/Cases/$caseId';
          final transcriptPath = '$caseDir/transcript.txt';
          await Directory(caseDir).create(recursive: true);
          await File(transcriptPath).writeAsString(transcript);

          // Update DB
          await db.update(
            'cases',
            {
              'status': 'completed',
              'transcriptPath': transcriptPath,
              'transcript_json': jsonEncode(data),
            },
            where: 'caseId = ?',
            whereArgs: [caseId],
          );
        } else {
          // Retry later - leave status as 'uploaded'
          continue;
        }
      } catch (e) {
        print('Upload/transcription failed for $caseId: $e');
        // Will retry via WorkManager due to failure
      }
    }
  } catch (e) {
    print('Background task failed: $e');
  }
}

String _formatTranscript(List<dynamic> speakers) {
  final lines = <String>[];
  for (final speaker in speakers) {
    final speakerLabel = speaker['speaker'] == 'A' ? 'Doctor:' : 'Patient:';
    lines.add('$speakerLabel ${speaker['text']}');
  }
  return lines.join('\n\n');
}

String _getAppDataDirectory() {
  return Platform.isAndroid ? '/data/data/${Platform.packageName}' : '';
}

Future<Database> _getDatabase() async {
  final databasePath = await getDatabasesPath();
  final pathToDb = path.join(databasePath, 'audio_cases.db');
  return await openDatabase(pathToDb, version: 1, onCreate: _onCreate);
}

Future<void> _onCreate(Database db, int version) async {
  await db.execute('''
    CREATE TABLE cases (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      caseId TEXT UNIQUE NOT NULL,
      date TEXT NOT NULL,
      audioFilePath TEXT NOT NULL,
      transcriptPath TEXT,
      status TEXT DEFAULT 'pending',
      consent_given INTEGER DEFAULT 0,
      transcript_json TEXT
    )
  ''');
}

Future<Database> initDatabase() async {
  final databasePath = await getDatabasesPath();
  final pathToDb = path.join(databasePath, 'audio_cases.db');
  return await openDatabase(pathToDb, version: 1, onCreate: _onCreate);
}// android/app/src/main/kotlin/com/example/audio_recorder_app/MainActivity.kt
package com.example.audio_recorder_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
}
