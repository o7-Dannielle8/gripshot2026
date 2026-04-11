import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

/// Singleton that stores user media under `<app documents>/media/` with UUID file names.
class MediaStorage {
  static final MediaStorage _instance = MediaStorage._internal();
  factory MediaStorage() => _instance;
  MediaStorage._internal();

  // Get the app's local storage directory
  Future<Directory> get _localDirectory async {
    final directory = await getApplicationDocumentsDirectory();
    final mediaDir = Directory('${directory.path}/media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    return mediaDir;
  }

  /// Copies [imageFile] into [_localDirectory] as `image_<uuid>.<ext>`; returns the new absolute path.
  Future<String> saveImage(File imageFile) async {
    final directory = await _localDirectory;
    final uuid = const Uuid().v4();
    final extension = path.extension(imageFile.path);
    final fileName = 'image_$uuid$extension';
    final savedFile = await imageFile.copy('${directory.path}/$fileName');
    return savedFile.path;
  }

  /// Returns a [File] for [imagePath] if it exists on disk, otherwise `null`.
  Future<File?> getImage(String imagePath) async {
    final file = File(imagePath);
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  /// Removes the file at [imagePath] if present; `true` on success, `false` if missing or on error.
  Future<bool> deleteImage(String imagePath) async {
    try {
      final file = File(imagePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Lists regular files in [_localDirectory] whose extension is `.jpg`, `.jpeg`, or `.png` (case-insensitive).
  Future<List<File>> getAllImages() async {
    final directory = await _localDirectory;
    final List<FileSystemEntity> files = await directory.list().toList();
    return files
        .whereType<File>()
        .where((file) => path.extension(file.path).toLowerCase() == '.jpg' ||
            path.extension(file.path).toLowerCase() == '.jpeg' ||
            path.extension(file.path).toLowerCase() == '.png')
        .toList();
  }

  /// Deletes the entire `media` folder recursively, then recreates an empty directory.
  Future<void> clearAllMedia() async {
    final directory = await _localDirectory;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
      await directory.create();
    }
  }
} 