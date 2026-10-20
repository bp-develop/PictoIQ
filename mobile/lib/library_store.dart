import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'photo_asset.dart';

class LibraryStore {
  LibraryStore._();

  static final LibraryStore instance = LibraryStore._();
  Database? _database;

  Future<Database> get _db async {
    if (_database != null) return _database!;
    final databasePath = p.join(await getDatabasesPath(), 'pictoiq.db');
    _database = await openDatabase(
      databasePath,
      version: 1,
      onCreate: (database, version) => database.execute('''
        CREATE TABLE photos (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          modifiedAt INTEGER,
          sha256 TEXT NOT NULL
        )
      '''),
    );
    return _database!;
  }

  Future<List<PhotoAsset>> getPhotos() async {
    final rows = await (await _db).query('photos', orderBy: 'id DESC');
    return rows.map(PhotoAsset.fromMap).toList();
  }

  Future<PhotoAsset> importPhoto(XFile selected, int sequence) async {
    final documents = await getApplicationDocumentsDirectory();
    final photoDirectory = Directory(p.join(documents.path, 'pictoiq_photos'));
    await photoDirectory.create(recursive: true);

    final extension = p.extension(selected.name);
    final filename =
        '${DateTime.now().microsecondsSinceEpoch}_$sequence$extension';
    final destination = File(p.join(photoDirectory.path, filename));
    await File(selected.path).copy(destination.path);

    try {
      final digest = await sha256.bind(destination.openRead()).first;
      final modifiedAt = await selected.lastModified();
      final size = await destination.length();
      final values = <String, Object?>{
        'name': selected.name,
        'path': destination.path,
        'size': size,
        'modifiedAt': modifiedAt.millisecondsSinceEpoch,
        'sha256': digest.toString(),
      };
      final id = await (await _db).insert('photos', values);
      return PhotoAsset(
        id: id,
        name: selected.name,
        path: destination.path,
        size: size,
        modifiedAt: modifiedAt,
        sha256: digest.toString(),
      );
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  Future<void> removePhoto(PhotoAsset photo) async {
    await (await _db).delete('photos', where: 'id = ?', whereArgs: [photo.id]);
    final file = File(photo.path);
    if (await file.exists()) await file.delete();
  }
}
