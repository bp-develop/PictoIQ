import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';

import 'scan_image_processing.dart';

class _ShotAnalysis {
  const _ShotAnalysis({
    required this.visualHash,
    required this.captureTime,
    required this.technicalQuality,
    required this.preview,
    required this.faceImage,
  });

  final int visualHash;
  final (int, int) captureTime;
  final (int, int) technicalQuality;
  final Uint8List preview;
  final Uint8List faceImage;
}

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
    this.capturedAt = 0,
    this.captureSource = captureSourceUnknown,
  });

  /// Where [capturedAt] came from. Times from different sources are never
  /// compared with each other, because EXIF stores local wall-clock time while
  /// the file's modified time is a real instant.
  static const captureSourceUnknown = 0;
  static const captureSourceExif = 1;
  static const captureSourceModified = 2;

  final String uri;
  final String name;
  final String relativePath;
  final int size;
  final int modifiedAt;
  final String? sha256;
  final int visualHash;
  final int qualityScore;
  final List<String> qualityNotes;
  final Uint8List? previewBytes;

  /// Capture time in milliseconds, or 0 when unknown.
  final int capturedAt;
  final int captureSource;

  FolderScanPhoto withPreviewBytes(Uint8List? bytes) => FolderScanPhoto(
    uri: uri,
    name: name,
    relativePath: relativePath,
    size: size,
    modifiedAt: modifiedAt,
    sha256: sha256,
    visualHash: visualHash,
    qualityScore: qualityScore,
    qualityNotes: qualityNotes,
    previewBytes: bytes,
    capturedAt: capturedAt,
    captureSource: captureSource,
  );

  DateTime? get modifiedDate =>
      modifiedAt <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(modifiedAt);
}

enum FolderDateRange {
  today('Today'),
  week('Last 7 days'),
  month('Last 30 days'),
  currentFolder('Current folder');

  const FolderDateRange(this.label);

  final String label;
}

class FolderSelection {
  const FolderSelection({required this.uri, required this.name});

  final String uri;
  final String name;
}

class FolderDuplicateGroup {
  FolderDuplicateGroup({
    required this.id,
    required List<FolderScanPhoto> photos,
  }) : photos = List.unmodifiable(photos);

  final String id;
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
    required this.dateRange,
    this.imagesSkipped = 0,
  });

  final String folderUri;
  final String folderName;
  final int imagesScanned;
  final List<FolderDuplicateGroup> duplicateGroups;
  final bool bestShotsScan;
  final FolderDateRange dateRange;

  /// Images that could not be read or decoded (for example HEIC files) and
  /// were left out of the scan, so they can never be offered for deletion.
  final int imagesSkipped;

  int get duplicateFileCount =>
      duplicateGroups.fold(0, (count, group) => count + group.photos.length);

  List<FolderScanPhoto> get removablePhotos => duplicateGroups
      .expand((group) => bestShotsScan ? group.otherShots : group.newerCopies)
      .toList(growable: false);

  int get reclaimableBytes =>
      removablePhotos.fold(0, (total, photo) => total + photo.size);
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

  /// Photos with a known capture time are only grouped when taken within this
  /// many milliseconds of each other. Tune to taste.
  static const _similarShotWindowMs = 30 * 1000;

  /// Maximum differing bits (out of 64) for two photos to count as similar.
  static const _maxHashDistance = 10;

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

  Future<FolderSelection?> pickFolder() async {
    final folder = await _saf.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (folder == null) return null;
    return FolderSelection(uri: folder.uri, name: folder.name);
  }

  Future<FolderScanResult?> pickAndScan({
    FolderDateRange dateRange = FolderDateRange.currentFolder,
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
      dateRange: dateRange,
      onProgress: onProgress,
    );
  }

  Future<FolderScanResult?> pickAndScanBestShots({
    FolderDateRange dateRange = FolderDateRange.currentFolder,
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
      dateRange: dateRange,
      onProgress: onProgress,
    );
  }

  Future<FolderScanResult> scanUri(
    String folderUri, {
    required String folderName,
    bool bestShotsScan = false,
    FolderDateRange dateRange = FolderDateRange.currentFolder,
    void Function(int imagesScanned)? onProgress,
  }) async {
    final images = <FolderScanPhoto>[];
    var imagesScanned = 0;
    var imagesSkipped = 0;
    Object? firstError;
    final now = DateTime.now();
    final dateThreshold = switch (dateRange) {
      FolderDateRange.today => DateTime(now.year, now.month, now.day),
      FolderDateRange.week => now.subtract(const Duration(days: 7)),
      FolderDateRange.month => now.subtract(const Duration(days: 30)),
      FolderDateRange.currentFolder => null,
    };

    await for (final entry in _saf.walk(folderUri)) {
      final file = entry.file;
      if (file.isDir ||
          _isSystemThumbnail(entry.relativePath) ||
          !_isImage(file.name, file.mimeType)) {
        continue;
      }
      if (dateThreshold != null &&
          (file.lastModified <= 0 ||
              DateTime.fromMillisecondsSinceEpoch(file.lastModified)
                  .isBefore(dateThreshold))) {
        continue;
      }

      try {
        String? digest;
        _ShotAnalysis? analysis;
        if (bestShotsScan) {
          final bytes = await collectImageBytes(
            await _saf.readFileStream(file.uri),
          );
          final modifiedAt = file.lastModified;
          analysis = await Isolate.run(() => _analyzeShot(bytes, modifiedAt));
        } else {
          digest = (await sha256.bind(await _saf.readFileStream(file.uri)).first)
              .toString();
        }
        if (bestShotsScan && analysis == null) {
          // Formats the decoder cannot read (HEIC, AVIF, RAW...) have no visual
          // fingerprint. Leave them out so they are never grouped together or
          // offered for deletion.
          imagesSkipped += 1;
          onProgress?.call(imagesScanned + imagesSkipped);
          continue;
        }
        final visualHash = analysis?.visualHash ?? 0;
        final (capturedAt, captureSource) = analysis == null
            ? (0, FolderScanPhoto.captureSourceUnknown)
            : analysis.captureTime;
        final quality = analysis != null
            ? await _qualityScore(analysis.faceImage, analysis.technicalQuality)
            : (0, <String>[]);
        final photo = FolderScanPhoto(
          uri: file.uri,
          name: file.name,
          relativePath: entry.relativePath,
          size: file.length,
          modifiedAt: file.lastModified,
          sha256: digest,
          visualHash: visualHash,
          qualityScore: quality.$1,
          qualityNotes: quality.$2,
          previewBytes: analysis?.preview,
          capturedAt: capturedAt,
          captureSource: captureSource,
        );
        images.add(photo);
        imagesScanned += 1;
        onProgress?.call(imagesScanned + imagesSkipped);
      } catch (error) {
        debugPrint('Folder image processing failed: ${error.runtimeType}');
        // One unreadable or corrupt file must not abort the whole scan.
        firstError ??= error;
        imagesSkipped += 1;
        onProgress?.call(imagesScanned + imagesSkipped);
      }
    }

    // If nothing could be read because of errors (for example the folder
    // permission was revoked), surface the failure instead of an empty result.
    final scanError = firstError;
    if (imagesScanned == 0 && scanError != null) throw scanError;

    final duplicates = <FolderDuplicateGroup>[];
    if (bestShotsScan) {
      duplicates.addAll(_groupSimilarShots(images));
      duplicates.sort(
        (a, b) => a.recommended.name.compareTo(b.recommended.name),
      );
    } else {
      final exactGroups = <String, List<FolderScanPhoto>>{};
      for (final photo in images) {
        exactGroups.putIfAbsent(photo.sha256!, () => []).add(photo);
      }
      duplicates.addAll(
        exactGroups.entries
            .where((entry) => entry.value.length > 1)
            .map(
              (entry) =>
                  FolderDuplicateGroup(id: entry.key, photos: entry.value),
            ),
      );
      duplicates.sort((a, b) => a.original.name.compareTo(b.original.name));

      final groupsWithPreviews = <FolderDuplicateGroup>[];
      for (final group in duplicates) {
        final photosWithPreviews = <FolderScanPhoto>[];
        for (final photo in group.photos) {
          photosWithPreviews.add(
            photo.withPreviewBytes(await _previewFor(photo.uri)),
          );
        }
        groupsWithPreviews.add(
          FolderDuplicateGroup(
            id: group.id,
            photos: photosWithPreviews,
          ),
        );
      }
      duplicates
        ..clear()
        ..addAll(groupsWithPreviews);
    }

    return FolderScanResult(
      folderUri: folderUri,
      folderName: folderName,
      imagesScanned: imagesScanned,
      duplicateGroups: List.unmodifiable(duplicates),
      bestShotsScan: bestShotsScan,
      dateRange: dateRange,
      imagesSkipped: imagesSkipped,
    );
  }

  Future<void> deleteFile(String uri) => _saf.delete(uri);

  Future<Uint8List?> _previewFor(String uri) async {
    try {
      final bytes = await collectImageBytes(await _saf.readFileStream(uri));
      return await Isolate.run(() {
        final decoded = decodeAnalysisImage(bytes);
        return decoded == null
            ? null
            : encodePreview(decoded, edge: 480, quality: 82);
      });
    } catch (error) {
      debugPrint('Folder preview unavailable: ${error.runtimeType}');
      return null;
    }
  }

  Future<void> dispose() => _faceDetector.close();

  Future<(int, List<String>)> _qualityScore(
    Uint8List bytes,
    (int, int) technicalQuality,
  ) async {
    final temp = await getTemporaryDirectory();
    final safeName = 'pictoiq-face-${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = File(p.join(temp.path, safeName));
    try {
      await file.writeAsBytes(bytes, flush: true);
      final faces = await _faceDetector.processImage(
        InputImage.fromFilePath(file.path),
      );
      final (clarity, exposure) = technicalQuality;
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
    } catch (error) {
      debugPrint('Face quality unavailable: ${error.runtimeType}');
      return (35, ['Face quality could not be assessed']);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  static _ShotAnalysis? _analyzeShot(Uint8List bytes, int modifiedAt) {
    final decoded = decodeAnalysisImage(bytes);
    if (decoded == null) return null;
    return _ShotAnalysis(
      visualHash: _differenceHash(decoded),
      captureTime: _captureTime(decoded, modifiedAt),
      technicalQuality: _technicalQuality(decoded),
      preview: encodePreview(decoded),
      faceImage: img.encodeJpg(decoded, quality: 90),
    );
  }

  static (int, int) _technicalQuality(img.Image image) {
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

  /// 64-bit difference hash: each bit records whether a pixel is brighter than
  /// its right-hand neighbour in a 9x8 downscale. It reacts to structure rather
  /// than overall brightness, so it separates different scenes better than an
  /// average hash while still matching near-identical burst frames.
  static int _differenceHash(img.Image image) {
    final small = img.copyResize(
      image,
      width: 9,
      height: 8,
      interpolation: img.Interpolation.average,
    );
    int luminance(int x, int y) {
      final pixel = small.getPixel(x, y);
      return (pixel.r.toInt() * 299 +
              pixel.g.toInt() * 587 +
              pixel.b.toInt() * 114) ~/
          1000;
    }

    var hash = 0;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        hash = (hash << 1) | (luminance(x, y) > luminance(x + 1, y) ? 1 : 0);
      }
    }
    return hash;
  }

  /// When the photo was taken: EXIF capture time when present, otherwise the
  /// file's modified time, otherwise unknown (0).
  static (int, int) _captureTime(img.Image image, int modifiedAt) {
    try {
      if (image.hasExif) {
        final raw = image.exif.exifIfd[0x9003]?.toString().trim();
        final match = raw == null
            ? null
            : RegExp(
                r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
              ).firstMatch(raw);
        if (match != null) {
          final year = int.parse(match.group(1)!);
          final month = int.parse(match.group(2)!);
          final day = int.parse(match.group(3)!);
          if (year >= 1990 && month >= 1 && month <= 12 && day >= 1) {
            final time = DateTime(
              year,
              month,
              day,
              int.parse(match.group(4)!),
              int.parse(match.group(5)!),
              int.parse(match.group(6)!),
            );
            return (
              time.millisecondsSinceEpoch,
              FolderScanPhoto.captureSourceExif,
            );
          }
        }
      }
    } catch (_) {
      // Fall back to the file's modified time below.
    }
    if (modifiedAt > 0) {
      return (modifiedAt, FolderScanPhoto.captureSourceModified);
    }
    return (0, FolderScanPhoto.captureSourceUnknown);
  }

  /// Groups visually similar photos that were taken close together.
  ///
  /// Photos are put in capture-time order and linked to earlier neighbours
  /// whose hash is close enough; linked photos form one group, so the result
  /// does not depend on file order. Photos with different time sources (or no
  /// time at all) are never compared with each other, and photos with a known
  /// time must fall within [_similarShotWindowMs] of each other.
  List<FolderDuplicateGroup> _groupSimilarShots(List<FolderScanPhoto> images) {
    final ordered = [...images]
      ..sort((a, b) {
        final bySource = a.captureSource.compareTo(b.captureSource);
        if (bySource != 0) return bySource;
        final byTime = a.capturedAt.compareTo(b.capturedAt);
        if (byTime != 0) return byTime;
        return a.relativePath.compareTo(b.relativePath);
      });

    final parent = List<int>.generate(ordered.length, (index) => index);
    int find(int index) {
      var root = index;
      while (parent[root] != root) {
        parent[root] = parent[parent[root]];
        root = parent[root];
      }
      return root;
    }

    for (var i = 1; i < ordered.length; i++) {
      final current = ordered[i];
      final timed =
          current.captureSource != FolderScanPhoto.captureSourceUnknown;
      for (var j = i - 1; j >= 0; j--) {
        final earlier = ordered[j];
        if (earlier.captureSource != current.captureSource) break;
        final gap = current.capturedAt - earlier.capturedAt;
        if (timed && gap > _similarShotWindowMs) break;
        if (_hammingDistance(earlier.visualHash, current.visualHash) <=
            _maxHashDistance) {
          final rootCurrent = find(i);
          final rootEarlier = find(j);
          if (rootCurrent != rootEarlier) parent[rootCurrent] = rootEarlier;
        }
      }
    }

    final clusters = <int, List<FolderScanPhoto>>{};
    for (var i = 0; i < ordered.length; i++) {
      clusters.putIfAbsent(find(i), () => []).add(ordered[i]);
    }
    return [
      for (final cluster in clusters.values)
        if (cluster.length > 1)
          FolderDuplicateGroup(id: cluster.first.uri, photos: cluster),
    ];
  }

  /// Number of differing bits between two 64-bit hashes.
  int _hammingDistance(int left, int right) {
    var x = left ^ right;
    x = x - ((x >>> 1) & 0x5555555555555555);
    x = (x & 0x3333333333333333) + ((x >>> 2) & 0x3333333333333333);
    x = (x + (x >>> 4)) & 0x0f0f0f0f0f0f0f0f;
    return (x * 0x0101010101010101) >>> 56;
  }

  bool _isImage(String name, String? mimeType) {
    if (mimeType?.toLowerCase().startsWith('image/') ?? false) return true;
    return _imageExtensions.contains(p.extension(name).toLowerCase());
  }

  bool _isSystemThumbnail(String relativePath) => p
      .split(relativePath)
      .any((segment) => segment.toLowerCase() == '.thumbnails');
}
