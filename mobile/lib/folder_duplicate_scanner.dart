import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';

import 'scan_image_processing.dart';
import 'shot_ranking.dart';
import 'similarity_grouping.dart';

class _ShotAnalysis {
  const _ShotAnalysis({
    required this.visualHash,
    required this.captureTime,
    required this.signals,
    required this.megapixels,
    required this.preview,
    required this.faceImage,
  });

  final int visualHash;
  final (int, int) captureTime;
  final ImageSignals signals;
  final double megapixels;
  final Uint8List preview;

  /// JPEG handed to face detection; null when face signals are turned off.
  final Uint8List? faceImage;
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
    this.features,
  });

  /// Where [capturedAt] came from. Times from different sources are never
  /// compared with each other, because EXIF stores local wall-clock time while
  /// the file's modified time is a real instant.
  static const captureSourceUnknown = CaptureSource.unknown;
  static const captureSourceExif = CaptureSource.exif;
  static const captureSourceModified = CaptureSource.modified;

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

  /// Measurements the best-shot ranking works from. Null for exact-duplicate
  /// scans, which do not analyse pixels.
  final ShotFeatures? features;

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
    features: features,
  );

  /// Copy carrying the group-relative score and reasons from [rankShots].
  FolderScanPhoto withQuality({
    required int score,
    required List<String> notes,
  }) => FolderScanPhoto(
    uri: uri,
    name: name,
    relativePath: relativePath,
    size: size,
    modifiedAt: modifiedAt,
    sha256: sha256,
    visualHash: visualHash,
    qualityScore: score,
    qualityNotes: notes,
    previewBytes: previewBytes,
    capturedAt: capturedAt,
    captureSource: captureSource,
    features: features,
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
    this.evidence,
    this.ranking,
  }) : photos = List.unmodifiable(photos);

  final String id;
  final List<FolderScanPhoto> photos;

  /// How sure PictoIQ is that these are the same scene, and why. Null for
  /// exact-duplicate groups, which are byte-for-byte identical.
  final SimilarityEvidence? evidence;

  /// Why the photos are ordered as they are. Null for exact-duplicate groups.
  final GroupRanking? ranking;

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
    final ranked = ranking;
    if (ranked != null) {
      final byId = {for (final photo in photos) photo.uri: photo};
      final ordered = [
        for (final shot in ranked.shots)
          if (byId[shot.id] != null) byId[shot.id]!,
      ];
      if (ordered.length == photos.length) return ordered;
    }
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
  FolderDuplicateScanner({
    Saf? saf,
    this.thresholds = const SimilarityThresholds(),
  }) : _saf = saf ?? Saf();

  final Saf _saf;

  /// Limits for grouping similar photos and rating the confidence of a group.
  final SimilarityThresholds thresholds;

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
    bool useFaceSignals = true,
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
          analysis = await Isolate.run(
            () => _analyzeShot(bytes, modifiedAt, useFaceSignals),
          );
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
        ShotFeatures? features;
        if (analysis != null) {
          final faceImage = analysis.faceImage;
          features = ShotFeatures(
            signals: analysis.signals,
            megapixels: analysis.megapixels,
            faces: faceImage == null ? null : await _detectFaces(faceImage),
          );
        }
        // Scores are relative to the rest of a group, so they are filled in
        // after grouping (see _groupSimilarShots).
        final photo = FolderScanPhoto(
          uri: file.uri,
          name: file.name,
          relativePath: entry.relativePath,
          size: file.length,
          modifiedAt: file.lastModified,
          sha256: digest,
          visualHash: visualHash,
          qualityScore: 0,
          qualityNotes: const [],
          previewBytes: analysis?.preview,
          capturedAt: capturedAt,
          captureSource: captureSource,
          features: features,
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
      duplicates.sort((a, b) {
        final byName = a.recommended.name.compareTo(b.recommended.name);
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
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
      duplicates.sort((a, b) {
        final byName = a.original.name.compareTo(b.original.name);
        return byName != 0
            ? byName
            : a.original.relativePath.compareTo(b.original.relativePath);
      });

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

  /// Runs face detection on one analysis image. Returns null when detection
  /// fails, so the ranking treats that photo's faces as unknown rather than
  /// absent and ignores face signals for its group.
  Future<FaceSignals?> _detectFaces(Uint8List bytes) async {
    final temp = await getTemporaryDirectory();
    final safeName =
        'pictoiq-face-${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = File(p.join(temp.path, safeName));
    try {
      await file.writeAsBytes(bytes, flush: true);
      final faces = await _faceDetector.processImage(
        InputImage.fromFilePath(file.path),
      );
      if (faces.isEmpty) return FaceSignals.none;
      double? eyesOpenMin;
      var smileTotal = 0.0;
      var smileCount = 0;
      for (final face in faces) {
        final eyes = [
          face.leftEyeOpenProbability,
          face.rightEyeOpenProbability,
        ].whereType<double>();
        for (final eye in eyes) {
          eyesOpenMin = eyesOpenMin == null ? eye : math.min(eyesOpenMin, eye);
        }
        final smile = face.smilingProbability;
        if (smile != null) {
          smileTotal += smile;
          smileCount++;
        }
      }
      return FaceSignals(
        count: faces.length,
        eyesOpenMin: eyesOpenMin,
        smileAverage: smileCount == 0 ? null : smileTotal / smileCount,
      );
    } catch (error) {
      debugPrint('Face signals unavailable: ${error.runtimeType}');
      return null;
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  static _ShotAnalysis? _analyzeShot(
    Uint8List bytes,
    int modifiedAt,
    bool includeFaceImage,
  ) {
    final decoded = decodeAnalysisImage(bytes);
    if (decoded == null) return null;
    final (width, height) =
        readImageSize(bytes) ?? (decoded.width, decoded.height);
    return _ShotAnalysis(
      visualHash: differenceHash(decoded),
      captureTime: captureTimeOf(decoded, modifiedAt),
      signals: measureImage(decoded),
      megapixels: width * height / 1000000,
      preview: encodePreview(decoded),
      faceImage: includeFaceImage ? img.encodeJpg(decoded, quality: 90) : null,
    );
  }

  /// Groups visually similar photos, rates how sure each group is, and ranks
  /// the photos inside it.
  List<FolderDuplicateGroup> _groupSimilarShots(List<FolderScanPhoto> images) {
    final clusters = clusterSimilar(
      [
        for (final photo in images)
          SimilarityCandidate(
            visualHash: photo.visualHash,
            capturedAt: photo.capturedAt,
            captureSource: photo.captureSource,
            tieBreaker: photo.relativePath,
          ),
      ],
      thresholds: thresholds,
    );
    return [
      for (final cluster in clusters)
        _rankedGroup([
          for (final index in cluster.members) images[index],
        ], cluster.evidence),
    ];
  }

  FolderDuplicateGroup _rankedGroup(
    List<FolderScanPhoto> members,
    SimilarityEvidence evidence,
  ) {
    final ranking = rankShots([
      for (final photo in members)
        ShotInput(
          id: photo.uri,
          features: photo.features ?? ShotFeatures.unknown,
          tieBreaker: photo.relativePath,
        ),
    ]);
    final ranked = <FolderScanPhoto>[];
    for (final photo in members) {
      final shot = ranking.shotFor(photo.uri)!;
      ranked.add(
        photo.withQuality(
          score: shot.score,
          notes: [...shot.strengths, ...shot.concerns],
        ),
      );
    }
    return FolderDuplicateGroup(
      id: members.first.uri,
      photos: ranked,
      evidence: evidence,
      ranking: ranking,
    );
  }

  bool _isImage(String name, String? mimeType) {
    if (mimeType?.toLowerCase().startsWith('image/') ?? false) return true;
    return _imageExtensions.contains(p.extension(name).toLowerCase());
  }

  bool _isSystemThumbnail(String relativePath) => p
      .split(relativePath)
      .any((segment) => segment.toLowerCase() == '.thumbnails');
}
