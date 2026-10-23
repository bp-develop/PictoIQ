import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pictoiq_mobile/similarity_grouping.dart';

const _t0 = 1700000000000;

SimilarityCandidate _shot(
  String name,
  int hash,
  int secondsAfterStart, {
  int source = CaptureSource.exif,
}) => SimilarityCandidate(
  visualHash: hash,
  capturedAt: source == CaptureSource.unknown ? 0 : _t0 + secondsAfterStart * 1000,
  captureSource: source,
  tieBreaker: name,
);

/// Sets the lowest [bits] bits, so two hashes built this way differ by
/// exactly the difference between their bit counts.
int _bits(int bits) => bits == 0 ? 0 : (1 << bits) - 1;

List<List<String>> _names(
  List<SimilarityCandidate> shots,
  List<SimilarityCluster> clusters,
) => [
  for (final cluster in clusters)
    [for (final index in cluster.members) shots[index].tieBreaker]..sort(),
]..sort((a, b) => a.first.compareTo(b.first));

img.Image _gradient({bool flipped = false}) {
  final image = img.Image(width: 90, height: 80);
  for (var y = 0; y < 80; y++) {
    for (var x = 0; x < 90; x++) {
      final value = flipped ? 255 - (x * 255 ~/ 89) : x * 255 ~/ 89;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return image;
}

void main() {
  group('hash helpers', () {
    test('hammingDistance counts differing bits', () {
      expect(hammingDistance(0, 0), 0);
      expect(hammingDistance(0, 1), 1);
      expect(hammingDistance(0, _bits(10)), 10);
      expect(hammingDistance(0, -1), 64);
      expect(hammingDistance(-1, -1), 0);
    });

    test('differenceHash is stable and reacts to image structure', () {
      expect(differenceHash(_gradient()), differenceHash(_gradient()));
      expect(
        hammingDistance(
          differenceHash(_gradient()),
          differenceHash(_gradient(flipped: true)),
        ),
        greaterThan(32),
      );
    });
  });

  group('clusterSimilar', () {
    test('groups near-identical shots taken seconds apart as high confidence', () {
      final shots = [
        _shot('a', _bits(0), 0),
        _shot('b', _bits(2), 2),
        _shot('c', _bits(1), 4),
      ];
      final clusters = clusterSimilar(shots);
      expect(_names(shots, clusters), [
        ['a', 'b', 'c'],
      ]);
      expect(clusters.single.evidence.confidence, SimilarityConfidence.high);
      expect(clusters.single.evidence.maxDistance, 2);
      expect(clusters.single.evidence.spanMs, 4000);
    });

    test('does not group look-alikes taken far apart', () {
      final shots = [_shot('a', 0, 0), _shot('b', 0, 31)];
      expect(clusterSimilar(shots), isEmpty);
    });

    test('does not group different-looking shots taken together', () {
      final shots = [_shot('a', 0, 0), _shot('b', _bits(20), 1)];
      expect(clusterSimilar(shots), isEmpty);
    });

    test('never compares capture times from different sources', () {
      final shots = [
        _shot('a', 0, 0),
        _shot('b', 0, 0, source: CaptureSource.modified),
      ];
      expect(clusterSimilar(shots), isEmpty);
    });

    test('file-time-only groups are at most medium confidence', () {
      final shots = [
        _shot('a', 0, 0, source: CaptureSource.modified),
        _shot('b', 0, 1, source: CaptureSource.modified),
      ];
      expect(
        clusterSimilar(shots).single.evidence.confidence,
        SimilarityConfidence.medium,
      );
    });

    test('moderate hash differences or a long span lower confidence', () {
      final moderate = [_shot('a', 0, 0), _shot('b', _bits(6), 1)];
      expect(
        clusterSimilar(moderate).single.evidence.confidence,
        SimilarityConfidence.medium,
      );
      final slow = [_shot('a', 0, 0), _shot('b', 0, 15)];
      expect(
        clusterSimilar(slow).single.evidence.confidence,
        SimilarityConfidence.medium,
      );
    });

    test('a chain of look-alikes is flagged low confidence', () {
      // a-b and b-c are within the link limit, but a and c differ by 16 bits.
      final shots = [
        _shot('a', _bits(0), 0),
        _shot('b', _bits(8), 1),
        _shot('c', _bits(16), 2),
      ];
      final clusters = clusterSimilar(shots);
      expect(_names(shots, clusters), [
        ['a', 'b', 'c'],
      ]);
      expect(clusters.single.evidence.maxDistance, 16);
      expect(clusters.single.evidence.confidence, SimilarityConfidence.low);
    });

    test('photos with no capture time group by appearance but are low confidence', () {
      final shots = [
        _shot('a', 0, 0, source: CaptureSource.unknown),
        _shot('b', _bits(1), 0, source: CaptureSource.unknown),
      ];
      final cluster = clusterSimilar(shots).single;
      expect(cluster.evidence.confidence, SimilarityConfidence.low);
      expect(cluster.evidence.spanMs, isNull);
      expect(cluster.evidence.notes.join(' '), contains('No capture time'));
    });

    test('result does not depend on input order', () {
      final shots = [
        _shot('a', 0, 0),
        _shot('b', _bits(2), 3),
        _shot('c', _bits(3), 6),
        _shot('d', 0, 100),
        _shot('e', _bits(1), 102),
        _shot('f', _bits(30), 50),
      ];
      final expected = _names(shots, clusterSimilar(shots));
      final reversed = shots.reversed.toList();
      expect(_names(reversed, clusterSimilar(reversed)), expected);
      expect(expected, [
        ['a', 'b', 'c'],
        ['d', 'e'],
      ]);
    });

    test('identical hashes taken together are high confidence', () {
      final shots = [_shot('a', 12345, 0), _shot('b', 12345, 0)];
      expect(
        clusterSimilar(shots).single.evidence.confidence,
        SimilarityConfidence.high,
      );
    });
  });

  group('evaluateGrouping', () {
    test('counts pairwise precision and recall', () {
      final metrics = evaluateGrouping(
        truth: {'a': 's1', 'b': 's1', 'c': 's1', 'd': 's2'},
        predicted: [
          ['a', 'b'],
          ['c', 'd'],
        ],
      );
      expect(metrics.truePositives, 1);
      expect(metrics.falsePositives, 1);
      expect(metrics.falseNegatives, 2);
      expect(metrics.precision, 0.5);
      expect(metrics.recall, closeTo(1 / 3, 1e-9));
    });

    test('perfect grouping scores 1', () {
      final metrics = evaluateGrouping(
        truth: {'a': 's1', 'b': 's1', 'c': 's2'},
        predicted: [
          ['a', 'b'],
        ],
      );
      expect(metrics.precision, 1);
      expect(metrics.recall, 1);
      expect(metrics.f1, 1);
    });

    test('rejects predicted ids that have no label', () {
      expect(
        () => evaluateGrouping(
          truth: {'a': 's1'},
          predicted: [
            ['a', 'zzz'],
          ],
        ),
        throwsArgumentError,
      );
    });
  });
}
