import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pictoiq_mobile/folder_duplicate_scanner.dart';
import 'package:saf/saf.dart';

const _baseTime = 1700000000000;

enum _Failure { throwsOnOpen, streamError }

/// One file in the fake folder. [bytes] and [modifiedAt] can be changed
/// between scans to simulate the user editing a file.
class _FakeFile {
  _FakeFile(
    this.path,
    this.bytes, {
    this.modifiedAt = _baseTime,
    this.mimeType = 'image/jpeg',
    this.failure,
  });

  final String path;
  Uint8List bytes;
  int modifiedAt;
  final String mimeType;
  final _Failure? failure;

  String get uri => 'content://test/$path';
  String get name => path.split('/').last;
}

class _FakeSaf extends Saf {
  _FakeSaf(this.files);

  final List<_FakeFile> files;

  @override
  Stream<SafWalkEntry> walk(String dirUri) async* {
    for (final file in files) {
      yield SafWalkEntry(
        relativePath: file.path,
        file: SafDocumentFile(
          uri: file.uri,
          name: file.name,
          isDir: false,
          length: file.bytes.length,
          lastModified: file.modifiedAt,
          mimeType: file.mimeType,
        ),
      );
    }
  }

  @override
  Future<Stream<Uint8List>> readFileStream(
    String uri, {
    int? start,
    int bufferSize = 4194304,
  }) async {
    final file = files.firstWhere((candidate) => candidate.uri == uri);
    if (file.failure == _Failure.throwsOnOpen) {
      throw StateError('Access denied: ${file.path}');
    }
    if (file.failure == _Failure.streamError) {
      return Stream<Uint8List>.error(StateError('Read failed: ${file.path}'));
    }
    return Stream.value(file.bytes);
  }
}

/// Filler content. Kept under 18 bytes so no image decoder can mistake it for
/// a real picture, which keeps these tests fast and predictable.
Uint8List _bytes(int seed, int length) =>
    Uint8List.fromList(List.filled(length, seed));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const faceChannel = MethodChannel('google_mlkit_face_detector');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final faceCalls = <String>[];

  setUp(() {
    faceCalls.clear();
    messenger.setMockMethodCallHandler(faceChannel, (call) async {
      faceCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(faceChannel, null);
  });

  Future<FolderScanResult> scan(List<_FakeFile> files) async {
    final scanner = FolderDuplicateScanner(saf: _FakeSaf(files));
    try {
      return await scanner.scanUri('content://test', folderName: 'test');
    } finally {
      await scanner.dispose();
    }
  }

  // ---------------------------------------------------------------------
  // Identical content
  // ---------------------------------------------------------------------

  test('identical files in different folders form one group', () async {
    final content = _bytes(7, 12);
    final result = await scan([
      _FakeFile('c/photo.jpg', content, modifiedAt: _baseTime + 3000),
      _FakeFile('a/photo.jpg', content, modifiedAt: _baseTime + 1000),
      _FakeFile('b/photo.jpg', content, modifiedAt: _baseTime + 2000),
    ]);

    expect(result.imagesScanned, 3);
    expect(result.imagesSkipped, 0);
    final group = result.duplicateGroups.single;
    expect(group.id, sha256.convert(content).toString());
    expect(group.photos, hasLength(3));
    expect(group.photos.every((photo) => photo.sha256 == group.id), isTrue);

    // The oldest copy is kept; the others are the removal candidates.
    expect(group.original.relativePath, 'a/photo.jpg');
    expect(result.removablePhotos.map((photo) => photo.relativePath), [
      'b/photo.jpg',
      'c/photo.jpg',
    ]);
    expect(result.reclaimableBytes, 24);

    // Exact scans must never run face detection (only the shutdown call).
    expect(faceCalls.where((method) => method != 'vision#closeFaceDetector'),
        isEmpty);
  });

  // ---------------------------------------------------------------------
  // Renamed files
  // ---------------------------------------------------------------------

  test('a renamed copy is still detected as the same content', () async {
    final content = _bytes(9, 12);
    final result = await scan([
      _FakeFile('IMG_0001.jpg', content, modifiedAt: _baseTime),
      _FakeFile('Holiday/Beach day.jpg', content, modifiedAt: _baseTime + 5000),
    ]);

    final group = result.duplicateGroups.single;
    expect(
      group.photos.map((photo) => photo.name),
      unorderedEquals(['IMG_0001.jpg', 'Beach day.jpg']),
    );
    expect(group.original.name, 'IMG_0001.jpg');
  });

  // ---------------------------------------------------------------------
  // Changed files
  // ---------------------------------------------------------------------

  test('same name and size but different content are not grouped', () async {
    final result = await scan([
      _FakeFile('a/photo.jpg', Uint8List.fromList([1, 2, 3, 4])),
      _FakeFile('b/photo.jpg', Uint8List.fromList([1, 2, 3, 5])),
    ]);

    expect(result.imagesScanned, 2);
    expect(result.duplicateGroups, isEmpty);
    expect(result.removablePhotos, isEmpty);
    expect(result.reclaimableBytes, 0);
  });

  test('editing one copy between scans removes it from the group', () async {
    final content = _bytes(4, 12);
    final copy = _FakeFile('copy.jpg', Uint8List.fromList(content));
    final files = [_FakeFile('original.jpg', content), copy];

    expect((await scan(files)).duplicateGroups, hasLength(1));

    copy
      ..bytes = _bytes(5, 12)
      ..modifiedAt = _baseTime + 60000;
    final rescanned = await scan(files);

    expect(rescanned.duplicateGroups, isEmpty);
    expect(rescanned.reclaimableBytes, 0);
  });

  // ---------------------------------------------------------------------
  // Inaccessible media
  // ---------------------------------------------------------------------

  for (final failure in _Failure.values) {
    test('an unreadable file (${failure.name}) is skipped, never deleted',
        () async {
      final content = _bytes(6, 12);
      final result = await scan([
        _FakeFile('a.jpg', content),
        _FakeFile('b.jpg', content),
        _FakeFile('locked.jpg', content, failure: failure),
      ]);

      expect(result.imagesScanned, 2);
      expect(result.imagesSkipped, 1);
      final group = result.duplicateGroups.single;
      expect(
        group.photos.map((photo) => photo.relativePath),
        unorderedEquals(['a.jpg', 'b.jpg']),
      );
      expect(
        result.removablePhotos.any((photo) => photo.relativePath == 'locked.jpg'),
        isFalse,
      );
    });

    test('an unreadable twin (${failure.name}) leaves the readable copy alone',
        () async {
      final content = _bytes(6, 12);
      final result = await scan([
        _FakeFile('a.jpg', content),
        _FakeFile('locked.jpg', content, failure: failure),
      ]);

      expect(result.imagesScanned, 1);
      expect(result.imagesSkipped, 1);
      expect(result.duplicateGroups, isEmpty);
      expect(result.removablePhotos, isEmpty);
    });
  }

  test('a folder where nothing can be read reports the failure', () async {
    await expectLater(
      scan([
        _FakeFile('a.jpg', _bytes(1, 8), failure: _Failure.throwsOnOpen),
        _FakeFile('b.jpg', _bytes(1, 8), failure: _Failure.streamError),
      ]),
      throwsStateError,
    );
  });

  test('an empty folder returns no groups and no error', () async {
    final result = await scan([]);

    expect(result.imagesScanned, 0);
    expect(result.imagesSkipped, 0);
    expect(result.duplicateGroups, isEmpty);
  });

  // ---------------------------------------------------------------------
  // Which files are scanned
  // ---------------------------------------------------------------------

  test('non-images and thumbnail folders are ignored; HEIC is hashed', () async {
    final content = _bytes(3, 12);
    final result = await scan([
      _FakeFile('a.jpg', content),
      _FakeFile('notes.txt', content, mimeType: 'text/plain'),
      _FakeFile('.thumbnails/a.jpg', content),
      _FakeFile('Camera/b.HEIC', content, mimeType: 'application/octet-stream'),
    ]);

    expect(result.imagesScanned, 2);
    expect(
      result.duplicateGroups.single.photos.map((photo) => photo.relativePath),
      unorderedEquals(['a.jpg', 'Camera/b.HEIC']),
    );
  });

  // ---------------------------------------------------------------------
  // Previews, counts and recoverable size
  // ---------------------------------------------------------------------

  test('decodable duplicates get previews; undecodable ones still group',
      () async {
    final png = img.encodePng(img.Image(width: 30, height: 20));
    final withPreviews = await scan([
      _FakeFile('a.png', png, mimeType: 'image/png'),
      _FakeFile('b.png', png, mimeType: 'image/png'),
    ]);
    expect(
      withPreviews.duplicateGroups.single.photos
          .every((photo) => photo.previewBytes != null),
      isTrue,
    );

    final raw = _bytes(2, 10);
    final withoutPreviews = await scan([
      _FakeFile('a.heic', raw),
      _FakeFile('b.heic', raw),
    ]);
    final group = withoutPreviews.duplicateGroups.single;
    expect(group.photos, hasLength(2));
    expect(group.photos.every((photo) => photo.previewBytes == null), isTrue);
  });

  test('group counts and recoverable space add up across groups', () async {
    final result = await scan([
      _FakeFile('a1.jpg', _bytes(1, 10), modifiedAt: _baseTime + 1),
      _FakeFile('a2.jpg', _bytes(1, 10), modifiedAt: _baseTime + 2),
      _FakeFile('a3.jpg', _bytes(1, 10), modifiedAt: _baseTime + 3),
      _FakeFile('b1.jpg', _bytes(2, 5), modifiedAt: _baseTime + 1),
      _FakeFile('b2.jpg', _bytes(2, 5), modifiedAt: _baseTime + 2),
      _FakeFile('single.jpg', _bytes(3, 17)),
    ]);

    expect(result.duplicateGroups, hasLength(2));
    expect(result.duplicateFileCount, 5);
    expect(result.removablePhotos, hasLength(3));
    // Two removable 10-byte copies plus one removable 5-byte copy.
    expect(result.reclaimableBytes, 25);
  });

  // ---------------------------------------------------------------------
  // Repeatability
  // ---------------------------------------------------------------------

  test('results are identical across scans and independent of walk order',
      () async {
    List<_FakeFile> build() => [
      _FakeFile('z/dup1.jpg', _bytes(1, 10), modifiedAt: _baseTime + 2000),
      _FakeFile('a/dup1.jpg', _bytes(1, 10), modifiedAt: _baseTime + 1000),
      _FakeFile('m/pair.jpg', _bytes(2, 6), modifiedAt: _baseTime),
      _FakeFile('b/pair.jpg', _bytes(2, 6), modifiedAt: _baseTime),
      _FakeFile('unique.jpg', _bytes(3, 8)),
    ];
    List<String> signature(FolderScanResult result) => [
      for (final group in result.duplicateGroups)
        '${group.id}: ${group.oldestFirst.map((photo) => photo.uri).join(', ')}',
    ];

    final first = await scan(build());
    final second = await scan(build());
    final reversed = await scan(build().reversed.toList());

    expect(first.duplicateGroups, hasLength(2));
    expect(signature(second), signature(first));
    expect(signature(reversed), signature(first));
    expect(reversed.reclaimableBytes, first.reclaimableBytes);

    // Equal timestamps fall back to the path, so the kept copy is stable.
    final pair = first.duplicateGroups.firstWhere(
      (group) => group.photos.first.name == 'pair.jpg',
    );
    expect(pair.original.relativePath, 'b/pair.jpg');
  });
}
