import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';

class FolderScanPhoto {
  const FolderScanPhoto({
    required this.uri,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modifiedAt,
    required this.sha256,
    required this.visualHash,
    required this.qualityScore,
    required this.qualityNotes,
    required this.previewBytes,
  });

  final String uri;
  final String name;
  final String relativePath;
  final int size;
  final int modifiedAt;
  final String sha256;
  final int visualHash;
  final int qualityScore;
  final List<String> qualityNotes;
  final Uint8List? previewBytes;

  DateTime? get modifiedDate =>
      modifiedAt <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(modifiedAt);
}

class FolderDuplicateGroup {
  FolderDuplicateGroup({
    required this.sha256,
    required List<FolderScanPhoto> photos,
  }) : photos = List.unmodifiable(photos);

  final String sha256;
  final List<FolderScanPhoto> photos;

  List<FolderScanPhoto> get oldestFirst {
    final sorted = [...photos];
    sorted.sort((left, right) {
      final leftDate = left.modifiedAt > 0
          ? left.modifiedAt
          : 0x7fffffffffffffff;
      final rightDate = right.modifiedAt > 0
          ? right.modifiedAt
          : 0x7fffffffffffffff;
      final byDate = leftDate.compareTo(rightDate);
      if (byDate != 0) return byDate;
      return left.relativePath.compareTo(right.relativePath);
    });
    return sorted;
  }

  FolderScanPhoto get original => oldestFirst.first;
  List<FolderScanPhoto> get newerCopies => oldestFirst.skip(1).toList();
  List<FolderScanPhoto> get bestFirst {
    final sorted = [...photos];
    sorted.sort((a, b) {
      final byQuality = b.qualityScore.compareTo(a.qualityScore);
      return byQuality != 0
          ? byQuality
          : a.relativePath.compareTo(b.relativePath);
    });
    return sorted;
  }

  FolderScanPhoto get recommended => bestFirst.first;
  List<FolderScanPhoto> get otherShots => bestFirst.skip(1).toList();
}

class FolderScanResult {
  const FolderScanResult({
    required this.folderUri,
    required this.folderName,
    required this.imagesScanned,
    required this.duplicateGroups,
    required this.bestShotsScan,
  });

  final String folderUri;
  final String folderName;
  final int imagesScanned;
  final List<FolderDuplicateGroup> duplicateGroups;
  final bool bestShotsScan;

  int get duplicateFileCount =>
      duplicateGroups.fold(0, (count, group) => count + group.photos.length);
}

class FolderDuplicateScanner {
  FolderDuplicateScanner({Saf? saf}) : _saf = saf ?? Saf();

  final Saf _saf;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  static const _imageExtensions = {
    '.avif',
    '.bmp',
    '.dng',
    '.gif',
    '.heic',
    '.heif',
    '.jfif',
    '.jpe',
    '.jpeg',
    '.jpg',
    '.png',
    '.tif',
    '.tiff',
    '.webp',
  };

  Future<FolderScanResult?> pickAndScan({
    void Function(int imagesScanned)? onProgress,
  }) async {
    final folder = await _saf.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (folder == null) return null;
    return scanUri(folder.uri, folderName: folder.name, onProgress: onProgress);
  }

  Future<FolderScanResult?> pickAndScanBestShots({
    void Function(int imagesScanned)? onProgress,
  }) async {
    final folder = await _saf.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (folder == null) return null;
    return scanUri(
      folder.uri,
      folderName: folder.name,
      bestShotsScan: true,
      onProgress: onProgress,
    );
  }

  Future<FolderScanResult> scanUri(
    String folderUri, {
    required String folderName,
    bool bestShotsScan = false,
    void Function(int imagesScanned)? onProgress,
  }) async {
    final images = <FolderScanPhoto>[];
    var imagesScanned = 0;

    await for (final entry in _saf.walk(folderUri)) {
      final file = entry.file;
      if (file.isDir ||
          _isSystemThumbnail(entry.relativePath) ||
          !_isImage(file.name, file.mimeType)) {
        continue;
      }

      final bytes = await (await _saf.readFileStream(file.uri))
          .fold<List<int>>(<int>[], (all, part) => all..addAll(part));
      final digest = sha256.convert(bytes);
      final fileBytes = Uint8List.fromList(bytes);
      final decoded = bestShotsScan ? img.decodeImage(fileBytes) : null;
      final visualHash = bestShotsScan && decoded != null
          ? _averageHash(decoded)
          : 0;
      final quality = bestShotsScan
          ? await _qualityScore(fileBytes, file.name, decoded)
          : (0, <String>[]);
      final photo = FolderScanPhoto(
        uri: file.uri,
        name: file.name,
        relativePath: entry.relativePath,
        size: file.length,
        modifiedAt: file.lastModified,
        sha256: digest.toString(),
        visualHash: visualHash,
        qualityScore: quality.$1,
        qualityNotes: quality.$2,
        previewBytes: !bestShotsScan || decoded == null
            ? null
            : Uint8List.fromList(
                img.encodeJpg(img.copyResize(decoded, width: 360), quality: 78),
              ),
      );
      images.add(photo);
      imagesScanned += 1;
      onProgress?.call(imagesScanned);
    }

    final duplicates = <FolderDuplicateGroup>[];
    if (bestShotsScan) {
      final ungrouped = [...images];
      while (ungrouped.isNotEmpty) {
        final seed = ungrouped.removeAt(0);
        final cluster = <FolderScanPhoto>[seed];
        for (var i = ungrouped.length - 1; i >= 0; i--) {
          if (_hammingDistance(seed.visualHash, ungrouped[i].visualHash) <= 8) {
            cluster.add(ungrouped.removeAt(i));
          }
        }
        if (cluster.length > 1) {
          duplicates.add(
            FolderDuplicateGroup(sha256: seed.sha256, photos: cluster),
          );
        }
      }
      duplicates.sort(
        (a, b) => a.recommended.name.compareTo(b.recommended.name),
      );
    } else {
      final exactGroups = <String, List<FolderScanPhoto>>{};
      for (final photo in images) {
        exactGroups.putIfAbsent(photo.sha256, () => []).add(photo);
      }
      duplicates.addAll(
        exactGroups.entries
            .where((entry) => entry.value.length > 1)
            .map(
              (entry) =>
                  FolderDuplicateGroup(sha256: entry.key, photos: entry.value),
            ),
      );
      duplicates.sort((a, b) => a.original.name.compareTo(b.original.name));
    }

    return FolderScanResult(
      folderUri: folderUri,
      folderName: folderName,
      imagesScanned: imagesScanned,
      duplicateGroups: List.unmodifiable(duplicates),
      bestShotsScan: bestShotsScan,
    );
  }

  Future<void> deleteFile(String uri) => _saf.delete(uri);

  Future<void> dispose() => _faceDetector.close();

  Future<(int, List<String>)> _qualityScore(
    List<int> bytes,
    String name,
    img.Image? decoded,
  ) async {
    final temp = await getTemporaryDirectory();
    final safeName =
        '${DateTime.now().microsecondsSinceEpoch}_${p.basename(name)}';
    final file = File(p.join(temp.path, safeName));
    try {
      await file.writeAsBytes(bytes, flush: true);
      final faces = await _faceDetector.processImage(
        InputImage.fromFilePath(file.path),
      );
      final (clarity, exposure) = decoded == null
          ? (50, 50)
          : _technicalQuality(decoded);
      if (faces.isEmpty) {
        return (
          (35 + clarity * .35 + exposure * .15).round(),
          [
            'No clear face detected',
            'Clarity $clarity/100',
            'Lighting $exposure/100',
          ],
        );
      }
      var faceScore = 0.0;
      var eyes = 0;
      var smiles = 0;
      for (final face in faces) {
        final eye = [
          face.leftEyeOpenProbability,
          face.rightEyeOpenProbability,
        ].whereType<double>().toList();
        final eyeScore = eye.isEmpty
            ? .45
            : eye.reduce((a, b) => a + b) / eye.length;
        final smile = face.smilingProbability ?? .45;
        if (eyeScore >= .65) eyes++;
        if (smile >= .55) smiles++;
        faceScore += eyeScore * .65 + smile * .35;
      }
      final faceQuality = (faces.length * 12 + faceScore / faces.length * 45)
          .clamp(0, 60);
      final score = (faceQuality + clarity * .25 + exposure * .15)
          .round()
          .clamp(0, 100)
          .toInt();
      return (
        score,
        [
          '${faces.length} face${faces.length == 1 ? '' : 's'} detected',
          '$eyes with eyes likely open',
          '$smiles smiling',
          'Clarity $clarity/100',
          'Lighting $exposure/100',
        ],
      );
    } catch (_) {
      return (35, ['Face quality could not be assessed']);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  (int, int) _technicalQuality(img.Image image) {
    final small = img.copyResize(image, width: 64, height: 64);
    final luminance = <double>[];
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final pixel = small.getPixel(x, y);
        luminance.add((pixel.r * 299 + pixel.g * 587 + pixel.b * 114) / 1000);
      }
    }
    var laplacianVariance = 0.0;
    var sum = 0.0;
    var sumSquares = 0.0;
    for (var y = 1; y < 63; y++) {
      for (var x = 1; x < 63; x++) {
        final i = y * 64 + x;
        final center = luminance[i];
        final laplacian =
            luminance[i - 64] +
            luminance[i + 64] +
            luminance[i - 1] +
            luminance[i + 1] -
            4 * center;
        sum += laplacian;
        sumSquares += laplacian * laplacian;
      }
    }
    const samples = 62 * 62;
    laplacianVariance =
        sumSquares / samples - (sum / samples) * (sum / samples);
    final clarity = (laplacianVariance / 2.5).round().clamp(0, 100).toInt();
    final average = luminance.reduce((a, b) => a + b) / luminance.length;
    final exposure = (100 - ((average - 128).abs() * .75))
        .round()
        .clamp(0, 100)
        .toInt();
    return (clarity, exposure);
  }

  int _averageHash(img.Image image) {
    final small = img.copyResize(image, width: 8, height: 8);
    final luminances = <int>[];
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final pixel = small.getPixel(x, y);
        luminances.add(
          (pixel.r.toInt() * 299 +
                  pixel.g.toInt() * 587 +
                  pixel.b.toInt() * 114) ~/
              1000,
        );
      }
    }
    final average = luminances.reduce((a, b) => a + b) / luminances.length;
    var hash = 0;
    for (final value in luminances) {
      hash = (hash << 1) | (value >= average ? 1 : 0);
    }
    return hash;
  }

  int _hammingDistance(int left, int right) {
    var value = left ^ right;
    var bits = 0;
    for (var bit = 0; bit < 64; bit++) {
      if (value == 0) break;
      bits += value & 1;
      value >>= 1;
    }
    return bits;
  }

  bool _isImage(String name, String? mimeType) {
    if (mimeType?.toLowerCase().startsWith('image/') ?? false) return true;
    return _imageExtensions.contains(p.extension(name).toLowerCase());
  }

  bool _isSystemThumbnail(String relativePath) => p
      .split(relativePath)
      .any((segment) => segment.toLowerCase() == '.thumbnails');
}
