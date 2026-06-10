import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PackingProofApp());
}

class PackingProofApp extends StatelessWidget {
  const PackingProofApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Packing Proof Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.amber,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardColor: const Color(0xFF1E293B),
      ),
      home: const HomeScreen(),
    );
  }
}

// Data Model representing saved proof entries
class PackingProof {
  final int? id;
  final String trackingNumber;
  final String videoPath;
  final String timestamp;

  PackingProof({
    this.id,
    required this.trackingNumber,
    required this.videoPath,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tracking_number': trackingNumber,
      'video_path': videoPath,
      'timestamp': timestamp,
    };
  }

  factory PackingProof.fromMap(Map<String, dynamic> map) {
    return PackingProof(
      id: map['id'],
      trackingNumber: map['tracking_number'],
      videoPath: map['video_path'],
      timestamp: map['timestamp'],
    );
  }
}

// Database Helper for local SQLite ledger storage
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = p.join(documentsDirectory.path, "packing_proofs.db");
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE proofs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tracking_number TEXT NOT NULL,
            video_path TEXT NOT NULL,
            timestamp TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<int> insertProof(PackingProof proof) async {
    final db = await database;
    return await db.insert('proofs', proof.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PackingProof>> getRecentProofs() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('proofs', orderBy: 'id DESC');
    return List.generate(maps.length, (i) => PackingProof.fromMap(maps[i]));
  }

  Future<int> deleteProof(int id) async {
    final db = await database;
    return await db.delete('proofs', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearDatabase() async {
    final db = await database;
    await db.delete('proofs');
  }
}

// State tracking for the unified workspace application
enum AppMode {
  initializing,
  scanning,
  preparingRecord,
  recording,
  saving,
  error
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppMode _mode = AppMode.initializing;
  String? _scannedCode;
  int _secondsRemaining = 15;
  Timer? _countdownTimer;

  // Dual Hardware Camera controller handles
  CameraController? _cameraController;
  final MobileScannerController _scannerController = MobileScannerController();

  // Local SQLite database ledger handler
  final DatabaseHelper _dbHelper = DatabaseHelper();
  List<PackingProof> _recentProofs = [];
  String _statusMessage = "Starting up...";

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _startScanning();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _cameraController?.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final proofs = await _dbHelper.getRecentProofs();
      setState(() {
        _recentProofs = proofs;
      });
    } catch (e) {
      _showErrorSnack("Error loading database history: $e");
    }
  }

  void _startScanning() {
    setState(() {
      _mode = AppMode.scanning;
      _statusMessage = "Align tracking label barcode to auto-trigger recording...";
      _scannedCode = null;
    });
    _scannerController.start();
  }

  Future<void> _onBarcodeDetected(BarcodeCapture capture) async {
    if (_mode != AppMode.scanning) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
      final String code = barcodes.first.rawValue!.trim();
      if (code.isNotEmpty) {
        // Trigger automated recording sequence
        await _triggerRecordingSequence(code);
      }
    }
  }

  Future<void> _triggerRecordingSequence(String barcode) async {
    setState(() {
      _mode = AppMode.preparingRecord;
      _scannedCode = barcode;
      _statusMessage = "Barcode detected: $barcode. Releasing scan lens and booting camera...";
    });

    try {
      // 1. RELEASE scanning framework hardware back camera locks
      await _scannerController.stop();

      // 2. Fetch on-device cameras
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _setStatusError("No physical devices detected.");
        return;
      }

      // 3. Configure back camera for medium high-frequency resolution (480p)
      final selectedCamera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium, // Optimal 480p standard minimizing disk usage
        enableAudio: false,      // High noise environments usually exclude audio tracks
      );

      await _cameraController!.initialize();

      if (!mounted) return;

      // 4. Automated trigger record start
      await _cameraController!.startVideoRecording();

      setState(() {
        _mode = AppMode.recording;
        _secondsRemaining = 15;
        _statusMessage = "AUTOMATION LOOP: RECORDING PROOF ($barcode)";
      });

      // 5. Trigger auto-stop timer loop (15 seconds)
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() {
          if (_secondsRemaining > 1) {
            _secondsRemaining--;
          } else {
            _secondsRemaining = 0;
            _countdownTimer?.cancel();
            _stopAndSave();
          }
        });
      });

    } catch (e) {
      _setStatusError("Recording lens initializing failure: $e");
      _startScanning();
    }
  }

  Future<void> _stopAndSave() async {
    if (_mode != AppMode.recording || _cameraController == null) return;
    _countdownTimer?.cancel();

    setState(() {
      _mode = AppMode.saving;
      _statusMessage = "Wrapping and registering video package...";
    });

    try {
      // 1. Terminate package recording and fetch absolute raw capture file
      final XFile rawFile = await _cameraController!.stopVideoRecording();

      // 2. Locate persistent files folder
      final extDir = await getApplicationDocumentsDirectory();
      final targetDirectory = Directory(p.join(extDir.path, "PackingProofs"));
      if (!await targetDirectory.exists()) {
        await targetDirectory.create(recursive: true);
      }

      // 3. Rename raw file to: [barcode]_[timestamp].mp4 so it aligns with specifications
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String targetFilename = "${_scannedCode}_$timestamp.mp4";
      final String targetPath = p.join(targetDirectory.path, targetFilename);

      // Copy local asset index safely
      final File savedFile = await File(rawFile.path).copy(targetPath);

      // 4. Create structure ledger proof record mapping details
      final PackingProof proof = PackingProof(
        trackingNumber: _scannedCode!,
        videoPath: savedFile.path,
        timestamp: DateTime.now().toLocal().toString().substring(0, 19),
      );

      await _dbHelper.insertProof(proof);

      // 5. Release video recorder camera controller locks
      await _cameraController!.dispose();
      _cameraController = null;

      // 6. Refresh recent list & reset automatic scanning loop
      await _loadHistory();
      _showSuccessSnack("Video registered successfully for $_scannedCode!");
      _startScanning();

    } catch (e) {
      _setStatusError("Automatic storage save failed: $e");
      await _cameraController?.dispose();
      _cameraController = null;
      _startScanning();
    }
  }

  void _setStatusError(String error) {
    setState(() {
      _mode = AppMode.error;
      _statusMessage = "ERROR GATES TRIGGERED: $error";
    });
    _showErrorSnack("Terminal Error: $error");
  }

  void _showErrorSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  void _showSuccessSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.emerald,
      ),
    );
  }

  Future<void> _handleDelete(PackingProof proof) async {
    try {
      final file = File(proof.videoPath);
      if (await file.exists()) {
        await file.delete();
      }

      if (proof.id != null) {
        await _dbHelper.deleteProof(proof.id!);
      }

      _showSuccessSnack("Cleared verification proof tracking: ${proof.trackingNumber}");
      _loadHistory();
    } catch (e) {
      _showErrorSnack("Cleaning exception: $e");
    }
  }

  Future<void> _clearAllProofs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text("Purge Database Ledger?"),
        content: const Text("Are you sure? This deletes ALL video assets from physical storage disks and wipes current SQLite indices."),
        actions: [
          TextButton(
            child: const Text("CANCEL", style: TextStyle(color: Colors.slateGrey)),
            onPressed: () => Navigator.pop(context, false),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text("ERASE LEDGER", style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        for (var proof in _recentProofs) {
          final file = File(proof.videoPath);
          if (await file.exists()) {
            await file.delete();
          }
        }
        await _dbHelper.clearDatabase();
        _loadHistory();
        _showSuccessSnack("Warehouse database flush completed successfully.");
      } catch (e) {
        _showErrorSnack("Ledger purge error: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isWide = MediaQuery.of(context).size.width > 900;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "PACKINGPROOF™ TERMINAL",
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2, fontSize: 15),
        ),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent),
            tooltip: "Wipe Proof Ledger",
            onPressed: _clearAllProofs,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.amber),
            tooltip: "Force Reset Scan Loop",
            onPressed: () {
              _cameraController?.dispose();
              _cameraController = null;
              _startScanning();
            },
          ),
        ],
      ),
      body: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 6,
                  child: _buildCameraViewportPanel(),
                ),
                Expanded(
                  flex: 4,
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(left: BorderSide(color: Color(0xFF1E293B), width: 2)),
                      color: Color(0xFF0F172A),
                    ),
                    child: _buildHistorySidebarPanel(),
                  ),
                ),
              ],
            )
          : Column(
              children: [
                Expanded(
                  flex: 6,
                  child: _buildCameraViewportPanel(),
                ),
                Expanded(
                  flex: 4,
                  child: Container(
                    color: const Color(0xFF0F172A),
                    child: _buildHistorySidebarPanel(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCameraViewportPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildStatusHUDEntry(),
          const SizedBox(height: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                color: Colors.black,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildActiveViewportWidget(),
                    if (_mode == AppMode.scanning) _buildScanningOverlayCircle(),
                    if (_mode == AppMode.recording) _buildRecordingOverlayBanner(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusHUDEntry() {
    Color hudBannerColor = Colors.grey[800]!;
    IconData hudIcon = Icons.info_outline;

    if (_mode == AppMode.scanning) {
      hudBannerColor = const Color(0xFF0F2D37);
      hudIcon = Icons.qr_code_scanner_rounded;
    } else if (_mode == AppMode.recording) {
      hudBannerColor = const Color(0xFF4A1010);
      hudIcon = Icons.videocam_rounded;
    } else if (_mode == AppMode.saving) {
      hudBannerColor = const Color(0xFF1E4620);
      hudIcon = Icons.save_rounded;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hudBannerColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Icon(hudIcon, color: Colors.amber, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusMessage,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildActiveViewportWidget() {
    if (_mode == AppMode.scanning) {
      return MobileScanner(
        controller: _scannerController,
        onDetect: _onBarcodeDetected,
      );
    } else if (_mode == AppMode.recording && _cameraController != null && _cameraController!.value.isInitialized) {
      return AspectRatio(
        aspectRatio: _cameraController!.value.aspectRatio,
        child: CameraPreview(_cameraController!),
      );
    } else if (_mode == AppMode.preparingRecord || _mode == AppMode.saving) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.amber),
            const SizedBox(height: 12),
            Text("PREPARING CAM...", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 11)),
            const SizedBox(height: 2),
            Text("Managing native hardware locks", style: TextStyle(color: Colors.grey, fontSize: 9)),
          ],
        ),
      );
    } else {
      return const Center(
        child: Text("Preparing Hardware Feeds...", style: TextStyle(color: Colors.grey)),
      );
    }
  }

  Widget _buildScanningOverlayCircle() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 250,
            height: 160,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.amber, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: Icon(Icons.qr_code_2_rounded, color: Colors.amber, size: 36),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: Colors.black54,
            child: const Text(
              "ALIGN BARCODE LABEL GATES",
              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingOverlayBanner() {
    return Positioned(
      bottom: 12,
      left: 12,
      right: 12,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.85),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.lens, color: Colors.redAccent, size: 12),
                const SizedBox(width: 6),
                Text(
                  "RECORDING: ${_secondsRemaining}S REMAINING",
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ],
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: _stopAndSave,
              child: const Text("STOP early", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySidebarPanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "RECENT PACKING PROOFS",
                style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 11),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  "${_recentProofs.length} LOGGED",
                  style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9),
                ),
              )
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _recentProofs.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.video_library_rounded, color: Colors.grey, size: 32),
                        SizedBox(height: 4),
                        Text(
                          "No proofs logged yet.",
                          style: TextStyle(color: Colors.grey, fontSize: 11),
                        ),
                        Text(
                          "Detect barcode to automatically record.",
                          style: TextStyle(color: Colors.grey, fontSize: 9),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _recentProofs.length,
                    itemBuilder: (context, index) {
                      final proof = _recentProofs[index];
                      final String fileName = p.basename(proof.videoPath);

                      return Card(
                        color: const Color(0xFF1E293B),
                        margin: const EdgeInsets.only(bottom: 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          leading: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.amber.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(Icons.video_collection, color: Colors.amber, size: 16),
                          ),
                          title: Text(
                            proof.trackingNumber,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "File: $fileName",
                                style: const TextStyle(color: Colors.grey, fontSize: 9),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                proof.timestamp,
                                style: const TextStyle(color: Colors.grey, fontSize: 8),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 18),
                            onPressed: () => _handleDelete(proof),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
