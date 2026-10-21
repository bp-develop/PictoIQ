import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pictoiq_mobile/folder_duplicate_scanner.dart';
import 'package:saf/saf.dart';

class _MemorySaf extends Saf {
  _MemorySaf(this.bytes);
  final Uint8List bytes;

  @override
  Stream<SafWalkEntry> walk(String dirUri) async* {
    for (var index = 0; index < 2; index++) {
      yield SafWalkEntry(
        relativePath: '$index.jpg',
        file: SafDocumentFile(
          uri: 'content://test/$index',
          name: '$index.jpg',
          isDir: false,
          length: bytes.length,
          lastModified: 1700000000000 + index * 1000,
          mimeType: 'image/jpeg',
        ),
      );
    }
  }

  @override
  Future<Stream<Uint8List>> readFileStream(
    String uri, {
    int? start,
    int bufferSize = 4194304,
  }) async => Stream.value(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const faceChannel = MethodChannel('google_mlkit_face_detector');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  final facePaths = <String>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('pictoiq-test-');
    facePaths.clear();
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return temporary.path;
      throw UnsupportedError(call.method);
    });
    messenger.setMockMethodCallHandler(faceChannel, (call) async {
      if (call.method == 'vision#closeFaceDetector') return null;
      final arguments = call.arguments as Map;
      final imageData = arguments['imageData'] as Map;
      final path = imageData['path'] as String;
      facePaths.add(path);
      final image = img.decodeJpg(await File(path).readAsBytes())!;
      expect(image.width, lessThanOrEqualTo(1024));
      expect(image.height, lessThanOrEqualTo(1024));
      return <Object>[];
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(faceChannel, null);
    messenger.setMockMethodCallHandler(pathChannel, null);
    await temporary.delete(recursive: true);
  });

  test(
    'best-shot scan skips SHA, bounds face input, and allows UI events',
    () async {
      final bytes = img.encodeJpg(img.Image(width: 2400, height: 1200));
      final scanner = FolderDuplicateScanner(saf: _MemorySaf(bytes));
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      final watch = Stopwatch()..start();
      try {
        final result = await scanner.scanUri(
          'content://test',
          folderName: 'test',
          bestShotsScan: true,
        );
        expect(result.imagesScanned, 2);
        expect(result.imagesSkipped, 0);
        expect(result.duplicateGroups, hasLength(1));
        final group = result.duplicateGroups.single;
        expect(group.id, startsWith('content://test/'));
        expect(group.photos.every((photo) => photo.sha256 == null), isTrue);
        expect(
          group.photos.every((photo) => photo.previewBytes != null),
          isTrue,
        );
        expect(facePaths, hasLength(2));
        expect(facePaths.every((path) => !File(path).existsSync()), isTrue);
        expect(ticks, greaterThan(0));
        // Diagnostic only: wall-clock performance depends on the test machine.
        // ignore: avoid_print
        print(
          'Best-shot sample: ${watch.elapsedMilliseconds} ms, $ticks UI ticks',
        );
      } finally {
        timer.cancel();
        await scanner.dispose();
      }
    },
  );

  test('exact duplicates retain content SHA and never invoke faces', () async {
    final bytes = img.encodePng(img.Image(width: 30, height: 20));
    final scanner = FolderDuplicateScanner(saf: _MemorySaf(bytes));
    try {
      final result = await scanner.scanUri(
        'content://test',
        folderName: 'test',
      );
      final group = result.duplicateGroups.single;
      expect(group.id, sha256.convert(bytes).toString());
      expect(group.photos.every((photo) => photo.sha256 == group.id), isTrue);
      expect(result.reclaimableBytes, bytes.length);
      expect(facePaths, isEmpty);
    } finally {
      await scanner.dispose();
    }
  });

  test('unsupported best-shot inputs are skipped and never grouped', () async {
    final scanner = FolderDuplicateScanner(
      saf: _MemorySaf(Uint8List.fromList([1, 2, 3])),
    );
    try {
      final result = await scanner.scanUri(
        'content://test',
        folderName: 'test',
        bestShotsScan: true,
      );
      expect(result.imagesScanned, 0);
      expect(result.imagesSkipped, 2);
      expect(result.duplicateGroups, isEmpty);
      expect(facePaths, isEmpty);
    } finally {
      await scanner.dispose();
    }
  });
}
