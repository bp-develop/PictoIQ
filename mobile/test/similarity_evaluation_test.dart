import 'package:flutter_test/flutter_test.dart';
import 'package:pictoiq_mobile/similarity_grouping.dart';

/// A small labelled set built from synthetic hashes. It guards against
/// regressions in the grouping rules and shows how precision and recall are
/// measured. It does NOT say how accurate grouping is on real photos: run
/// `dart run tool/evaluate_similarity.dart <folder> <labels.csv>` for that.
const _t0 = 1700000000000;

class _Labelled {
  const _Labelled(this.id, this.scene, this.hash, this.seconds);
  final String id;
  final String scene;
  final int hash;
  final int seconds;
}

int _bits(int n) => n == 0 ? 0 : (1 << n) - 1;

// Scene hashes sit far apart; frames of one scene differ by a few bits.
final _sceneA = 0x0F0F0F0F; // burst of 4 frames
final _sceneB = 0x33CC33CC << 8; // burst of 3 frames
// Scene C reuses scene A's framing an hour later.

final _labelled = [
  _Labelled('a1', 'A', _sceneA, 0),
  _Labelled('a2', 'A', _sceneA ^ _bits(1), 1),
  _Labelled('a3', 'A', _sceneA ^ _bits(2), 2),
  _Labelled('a4', 'A', _sceneA ^ _bits(3), 4),
  _Labelled('b1', 'B', _sceneB, 5),
  _Labelled('b2', 'B', _sceneB ^ _bits(2), 6),
  _Labelled('b3', 'B', _sceneB ^ _bits(1), 8),
  // Same framing as scene A, but much later: a different moment.
  _Labelled('c1', 'C', _sceneA ^ _bits(1), 3600),
  _Labelled('c2', 'C', _sceneA ^ _bits(2), 3601),
  // Singles that must stay alone.
  _Labelled('s1', 'S1', 0x7F7F7F7F7F, 9),
  _Labelled('s2', 'S2', 0x1234 << 20, 400),
];

void main() {
  test('synthetic labelled set groups with full precision and recall', () {
    final candidates = [
      for (final item in _labelled)
        SimilarityCandidate(
          visualHash: item.hash,
          capturedAt: _t0 + item.seconds * 1000,
          captureSource: CaptureSource.exif,
          tieBreaker: item.id,
        ),
    ];
    final clusters = clusterSimilar(candidates);
    final metrics = evaluateGrouping(
      truth: {for (final item in _labelled) item.id: item.scene},
      predicted: [
        for (final cluster in clusters)
          [for (final index in cluster.members) _labelled[index].id],
      ],
    );
    expect(metrics.falsePositives, 0, reason: 'different scenes were merged');
    expect(metrics.falseNegatives, 0, reason: 'a scene was split');
    expect(metrics.precision, 1);
    expect(metrics.recall, 1);
  });

  test('raising the link distance trades precision for recall', () {
    // Frames of one scene that differ by 12 bits are only found when the
    // limit is loosened, which also starts merging unrelated shots.
    final candidates = [
      SimilarityCandidate(
        visualHash: 0,
        capturedAt: _t0,
        captureSource: CaptureSource.exif,
        tieBreaker: 'x1',
      ),
      SimilarityCandidate(
        visualHash: _bits(12),
        capturedAt: _t0 + 1000,
        captureSource: CaptureSource.exif,
        tieBreaker: 'x2',
      ),
    ];
    expect(clusterSimilar(candidates), isEmpty);
    expect(
      clusterSimilar(
        candidates,
        thresholds: const SimilarityThresholds(maxLinkDistance: 12),
      ),
      hasLength(1),
    );
  });
}
