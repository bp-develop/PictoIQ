import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pictoiq_mobile/shot_ranking.dart';

ShotInput _shot(
  String id, {
  double sharpness = 100,
  double meanLuma = 120,
  double highlightClip = 0,
  double shadowClip = 0,
  double megapixels = 12,
  FaceSignals? faces,
}) => ShotInput(
  id: id,
  tieBreaker: id,
  features: ShotFeatures(
    signals: ImageSignals(
      sharpness: sharpness,
      meanLuma: meanLuma,
      highlightClip: highlightClip,
      shadowClip: shadowClip,
    ),
    megapixels: megapixels,
    faces: faces,
  ),
);

img.Image _checkerboard() {
  final image = img.Image(width: 200, height: 200);
  for (var y = 0; y < 200; y++) {
    for (var x = 0; x < 200; x++) {
      final value = ((x ~/ 4) + (y ~/ 4)).isEven ? 0 : 255;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return image;
}

img.Image _solid(int value) {
  final image = img.Image(width: 100, height: 100);
  img.fill(image, color: img.ColorRgb8(value, value, value));
  return image;
}

void main() {
  group('rankShots', () {
    test('ranks the sharper photo first and explains why', () {
      final ranking = rankShots([
        _shot('soft', sharpness: 25),
        _shot('sharp', sharpness: 100),
      ]);
      expect(ranking.shots.map((s) => s.id), ['sharp', 'soft']);
      expect(ranking.shots.map((s) => s.rank), [1, 2]);
      expect(ranking.best.strengths, contains('Sharpest in the group'));
      expect(
        ranking.shotFor('soft')!.concerns.join(' '),
        contains('Softer'),
      );
      expect(ranking.isClearWinner, isTrue);
      expect(ranking.headline, startsWith('Recommended'));
    });

    test('near-equal photos are too close to call', () {
      final ranking = rankShots([
        _shot('a', sharpness: 100),
        _shot('b', sharpness: 98),
      ]);
      expect(ranking.margin, lessThan(GroupRanking.clearWinnerMargin));
      expect(ranking.isClearWinner, isFalse);
      expect(ranking.headline, contains('you decide'));
    });

    test('flags blown highlights', () {
      final ranking = rankShots([
        _shot('clean'),
        _shot('blown', highlightClip: 0.1),
      ]);
      expect(ranking.best.id, 'clean');
      expect(
        ranking.shotFor('blown')!.concerns.join(' '),
        contains('washed out'),
      );
    });

    test('prefers higher resolution and says so', () {
      final ranking = rankShots([
        _shot('small', megapixels: 8),
        _shot('large', megapixels: 12),
      ]);
      expect(ranking.best.id, 'large');
      expect(ranking.best.strengths, contains('Highest resolution (12.0 MP)'));
      expect(
        ranking.shotFor('small')!.concerns,
        contains('Lower resolution (8.0 MP vs 12.0 MP)'),
      );
    });

    test('open eyes can outweigh a slightly sharper photo', () {
      const open = FaceSignals(count: 2, eyesOpenMin: 0.9, smileAverage: null);
      const blink = FaceSignals(count: 2, eyesOpenMin: 0.1, smileAverage: null);
      final ranking = rankShots([
        _shot('blink', sharpness: 100, faces: blink),
        _shot('open', sharpness: 90, faces: open),
      ]);
      expect(ranking.usedFaceSignals, isTrue);
      expect(ranking.best.id, 'open');
      expect(
        ranking.shotFor('blink')!.concerns,
        contains('Someone may have their eyes closed'),
      );
    });

    test('face signals are ignored unless every photo was assessed', () {
      const face = FaceSignals(count: 1, eyesOpenMin: 0.9, smileAverage: 0.9);
      final partial = rankShots([
        _shot('a', faces: face),
        _shot('b', sharpness: 60),
      ]);
      expect(partial.usedFaceSignals, isFalse);
      final noFaces = rankShots([
        _shot('a', faces: FaceSignals.none),
        _shot('b', faces: FaceSignals.none),
      ]);
      expect(noFaces.usedFaceSignals, isFalse);
    });

    test('equal photos keep a stable order', () {
      final ranking = rankShots([_shot('b'), _shot('a')]);
      expect(ranking.shots.map((s) => s.id), ['a', 'b']);
    });

    test('handles one photo and none', () {
      final single = rankShots([_shot('only')]);
      expect(single.best.rank, 1);
      expect(single.margin, 100);
      expect(rankShots(const []).shots, isEmpty);
    });

    test('scores stay within 0-100', () {
      final ranking = rankShots([
        _shot('a', sharpness: 0, meanLuma: 255, highlightClip: 1, megapixels: 0),
        _shot('b', sharpness: 500),
      ]);
      for (final shot in ranking.shots) {
        expect(shot.score, inInclusiveRange(0, 100));
      }
    });
  });

  group('measureImage', () {
    test('a crisp image measures sharper than a blurred copy', () {
      final crisp = measureImage(_checkerboard());
      final blurred = measureImage(img.gaussianBlur(_checkerboard(), radius: 3));
      expect(crisp.sharpness, greaterThan(blurred.sharpness * 2));
    });

    test('detects blown highlights and crushed shadows', () {
      final white = measureImage(_solid(255));
      expect(white.highlightClip, closeTo(1, 0.01));
      expect(white.meanLuma, closeTo(255, 1));
      expect(white.exposureScore, lessThan(40));
      final black = measureImage(_solid(0));
      expect(black.shadowClip, closeTo(1, 0.01));
      expect(black.exposureScore, lessThan(60));
    });

    test('mid-grey with no clipping scores full exposure', () {
      final grey = measureImage(_solid(120));
      expect(grey.highlightClip, 0);
      expect(grey.shadowClip, 0);
      expect(grey.exposureScore, closeTo(100, 1));
      expect(grey.sharpness, 0);
    });
  });
}
