import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pictoiq_mobile/scan_image_processing.dart';

void main() {
  test('collects stream chunks as typed bytes without changing content', () async {
    final bytes = await collectImageBytes(
      Stream.fromIterable([
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3, 4]),
      ]),
    );
    expect(bytes, isA<Uint8List>());
    expect(bytes, [1, 2, 3, 4]);
  });

  test('stops reading encoded images beyond the memory budget', () async {
    final chunk = Uint8List(1024 * 1024);
    await expectLater(
      collectImageBytes(Stream.fromIterable(List.filled(65, chunk))),
      throwsFormatException,
    );
  });

  for (final portrait in [false, true]) {
    test('bounds ${portrait ? 'portrait' : 'landscape'} JPEG and preview', () {
      final original = img.Image(
        width: portrait ? 800 : 2400,
        height: portrait ? 2400 : 800,
      );
      final decoded = decodeAnalysisImage(img.encodeJpg(original))!;
      expect(decoded.width, portrait ? 341 : 1024);
      expect(decoded.height, portrait ? 1024 : 341);
      final preview = img.decodeJpg(encodePreview(decoded))!;
      expect(preview.width, lessThanOrEqualTo(360));
      expect(preview.height, lessThanOrEqualTo(360));
    });
  }

  test('does not upscale small photos', () {
    final decoded = decodeAnalysisImage(
      img.encodePng(img.Image(width: 24, height: 16)),
    )!;
    expect((decoded.width, decoded.height), (24, 16));
  });

  test('bounds non-JPEG analysis images without changing aspect ratio', () {
    final decoded = decodeAnalysisImage(
      img.encodePng(img.Image(width: 1600, height: 800)),
    )!;
    expect((decoded.width, decoded.height), (1024, 512));
  });

  test('stream errors remain visible to the scan coordinator', () async {
    await expectLater(
      collectImageBytes(Stream.error(StateError('Read failed'))),
      throwsStateError,
    );
  });

  test('preserves EXIF capture metadata and normalizes orientation', () {
    final original = img.Image(width: 120, height: 80);
    original.exif.imageIfd.orientation = 6;
    original.exif.exifIfd[0x9003] = img.IfdValueAscii('2026:10:21 12:34:56');
    final decoded = decodeAnalysisImage(img.encodeJpg(original))!;
    expect((decoded.width, decoded.height), (80, 120));
    expect(
      decoded.exif.exifIfd[0x9003].toString(),
      '2026:10:21 12:34:56',
    );
  });

  test('unsupported data is not assigned a visual fingerprint', () {
    expect(decodeAnalysisImage(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
