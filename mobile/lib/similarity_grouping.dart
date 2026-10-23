import 'package:image/image.dart' as img;

/// Where a capture time came from. Times from different sources are never
/// compared with each other, because EXIF stores local wall-clock time while
/// the file's modified time is a real instant.
abstract final class CaptureSource {
  static const unknown = 0;
  static const exif = 1;
  static const modified = 2;
}

/// Number of differing bits between two 64-bit hashes.
int hammingDistance(int left, int right) {
  var x = left ^ right;
  x = x - ((x >>> 1) & 0x5555555555555555);
  x = (x & 0x3333333333333333) + ((x >>> 2) & 0x3333333333333333);
  x = (x + (x >>> 4)) & 0x0f0f0f0f0f0f0f0f;
  return (x * 0x0101010101010101) >>> 56;
}

/// 64-bit difference hash: each bit records whether a pixel is brighter than
/// its right-hand neighbour in a 9x8 downscale. It reacts to structure rather
/// than overall brightness, so it separates different scenes better than an
/// average hash while still matching near-identical burst frames.
int differenceHash(img.Image image) {
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

/// When the photo was taken, as (milliseconds, [CaptureSource]): EXIF capture
/// time when present, otherwise the file's modified time, otherwise unknown.
(int, int) captureTimeOf(img.Image image, int modifiedAt) {
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
          return (time.millisecondsSinceEpoch, CaptureSource.exif);
        }
      }
    }
  } catch (_) {
    // Fall back to the file's modified time below.
  }
  if (modifiedAt > 0) return (modifiedAt, CaptureSource.modified);
  return (0, CaptureSource.unknown);
}

/// Tunable limits for similar-photo grouping and its confidence levels.
///
/// The defaults are starting points. Measure them on a labelled photo set
/// (see `test/similarity_evaluation_test.dart`) before trusting them.
class SimilarityThresholds {
  const SimilarityThresholds({
    this.maxLinkDistance = 10,
    this.windowMs = 30 * 1000,
    this.highDistance = 4,
    this.highSpanMs = 10 * 1000,
    this.mediumDistance = 8,
    this.maxClusterForDiameter = 300,
  });

  /// Two photos may be linked when their hashes differ by at most this many
  /// bits (out of 64).
  final int maxLinkDistance;

  /// Photos with a known capture time are only linked when taken within this
  /// many milliseconds of each other.
  final int windowMs;

  /// A group is "high" confidence only when every pair differs by at most
  /// this many bits...
  final int highDistance;

  /// ...and the whole group was taken within this many milliseconds, and the
  /// capture time comes from EXIF.
  final int highSpanMs;

  /// Above this pairwise difference a group is always "low" confidence.
  final int mediumDistance;

  /// Groups larger than this are not measured pair by pair and are treated as
  /// low confidence.
  final int maxClusterForDiameter;
}

enum SimilarityConfidence {
  high('High'),
  medium('Medium'),
  low('Low');

  const SimilarityConfidence(this.label);

  final String label;
}

/// Why a group was given its confidence level.
class SimilarityEvidence {
  const SimilarityEvidence({
    required this.confidence,
    required this.maxDistance,
    required this.spanMs,
    required this.captureSource,
    required this.size,
  });

  final SimilarityConfidence confidence;

  /// Largest hash difference between any two photos in the group (0-64).
  final int maxDistance;

  /// Time between the first and last photo, or null when no capture time is
  /// available.
  final int? spanMs;

  final int captureSource;
  final int size;

  /// Plain-language facts behind the confidence level, for the UI.
  List<String> get notes {
    final content = maxDistance <= 4
        ? 'Nearly identical content'
        : (maxDistance <= 8
              ? 'Very similar content'
              : 'Loosely similar content');
    final result = <String>[
      '$content (up to $maxDistance of 64 differences)',
    ];
    final span = spanMs;
    if (span == null) {
      result.add('No capture time, so grouping relied on appearance only');
    } else {
      final seconds = (span / 1000).ceil();
      final basis = captureSource == CaptureSource.exif
          ? 'camera time'
          : 'file time, less reliable';
      result.add(
        seconds <= 0
            ? 'Taken at the same moment ($basis)'
            : 'Taken within $seconds s ($basis)',
      );
    }
    return result;
  }
}

/// What the grouping step needs to know about one photo.
class SimilarityCandidate {
  const SimilarityCandidate({
    required this.visualHash,
    required this.capturedAt,
    required this.captureSource,
    required this.tieBreaker,
  });

  final int visualHash;
  final int capturedAt;
  final int captureSource;

  /// Stable ordering key for photos with identical timestamps (for example
  /// the relative path), so results do not depend on file order.
  final String tieBreaker;
}

class SimilarityCluster {
  const SimilarityCluster({required this.members, required this.evidence});

  /// Indexes into the candidate list passed to [clusterSimilar], in capture
  /// order.
  final List<int> members;
  final SimilarityEvidence evidence;
}

/// Groups visually similar photos that were taken close together.
///
/// Photos are put in capture-time order and linked to earlier neighbours
/// whose hash is close enough; linked photos form one group, so the result
/// does not depend on input order. Photos with different time sources are
/// never compared with each other, and photos with a known time must fall
/// within [SimilarityThresholds.windowMs] of each other.
///
/// Linking is transitive, so a chain of look-alikes can form a group whose
/// first and last photos differ a lot. The returned [SimilarityEvidence]
/// measures the real spread and marks such groups as low confidence.
List<SimilarityCluster> clusterSimilar(
  List<SimilarityCandidate> candidates, {
  SimilarityThresholds thresholds = const SimilarityThresholds(),
}) {
  final order = List<int>.generate(candidates.length, (index) => index)
    ..sort((a, b) {
      final left = candidates[a];
      final right = candidates[b];
      final bySource = left.captureSource.compareTo(right.captureSource);
      if (bySource != 0) return bySource;
      final byTime = left.capturedAt.compareTo(right.capturedAt);
      if (byTime != 0) return byTime;
      return left.tieBreaker.compareTo(right.tieBreaker);
    });

  final parent = List<int>.generate(order.length, (index) => index);
  int find(int index) {
    var root = index;
    while (parent[root] != root) {
      parent[root] = parent[parent[root]];
      root = parent[root];
    }
    return root;
  }

  for (var i = 1; i < order.length; i++) {
    final current = candidates[order[i]];
    final timed = current.captureSource != CaptureSource.unknown;
    for (var j = i - 1; j >= 0; j--) {
      final earlier = candidates[order[j]];
      if (earlier.captureSource != current.captureSource) break;
      final gap = current.capturedAt - earlier.capturedAt;
      if (timed && gap > thresholds.windowMs) break;
      if (hammingDistance(earlier.visualHash, current.visualHash) <=
          thresholds.maxLinkDistance) {
        final rootCurrent = find(i);
        final rootEarlier = find(j);
        if (rootCurrent != rootEarlier) parent[rootCurrent] = rootEarlier;
      }
    }
  }

  final positions = <int, List<int>>{};
  for (var i = 0; i < order.length; i++) {
    positions.putIfAbsent(find(i), () => []).add(i);
  }
  return [
    for (final group in positions.values)
      if (group.length > 1)
        SimilarityCluster(
          members: [for (final position in group) order[position]],
          evidence: _evidenceFor(
            [for (final position in group) candidates[order[position]]],
            thresholds,
          ),
        ),
  ];
}

SimilarityEvidence _evidenceFor(
  List<SimilarityCandidate> members,
  SimilarityThresholds thresholds,
) {
  var maxDistance = 0;
  if (members.length > thresholds.maxClusterForDiameter) {
    maxDistance = 64;
  } else {
    for (var i = 0; i < members.length; i++) {
      for (var j = i + 1; j < members.length; j++) {
        final distance = hammingDistance(
          members[i].visualHash,
          members[j].visualHash,
        );
        if (distance > maxDistance) maxDistance = distance;
      }
    }
  }

  final source = members.first.captureSource;
  int? spanMs;
  if (source != CaptureSource.unknown) {
    var earliest = members.first.capturedAt;
    var latest = earliest;
    for (final member in members) {
      if (member.capturedAt < earliest) earliest = member.capturedAt;
      if (member.capturedAt > latest) latest = member.capturedAt;
    }
    spanMs = latest - earliest;
  }

  final span = spanMs;
  final SimilarityConfidence confidence;
  if (span == null ||
      maxDistance > thresholds.mediumDistance ||
      span > thresholds.windowMs) {
    confidence = SimilarityConfidence.low;
  } else if (maxDistance <= thresholds.highDistance &&
      span <= thresholds.highSpanMs &&
      source == CaptureSource.exif) {
    confidence = SimilarityConfidence.high;
  } else {
    confidence = SimilarityConfidence.medium;
  }

  return SimilarityEvidence(
    confidence: confidence,
    maxDistance: maxDistance,
    spanMs: spanMs,
    captureSource: source,
    size: members.length,
  );
}

/// Pairwise precision and recall of a grouping against labelled truth.
///
/// A "pair" is two photos placed in the same group. Precision is the share of
/// predicted pairs that are truly the same scene; recall is the share of true
/// pairs that were found.
class PairMetrics {
  const PairMetrics({
    required this.truePositives,
    required this.falsePositives,
    required this.falseNegatives,
  });

  final int truePositives;
  final int falsePositives;
  final int falseNegatives;

  double get precision {
    final predicted = truePositives + falsePositives;
    return predicted == 0 ? 1 : truePositives / predicted;
  }

  double get recall {
    final actual = truePositives + falseNegatives;
    return actual == 0 ? 1 : truePositives / actual;
  }

  double get f1 {
    final p = precision;
    final r = recall;
    return p + r == 0 ? 0 : 2 * p * r / (p + r);
  }
}

/// Compares [predicted] groups of photo ids with [truth], a map from photo id
/// to its labelled scene. Photos sharing a label are the same scene; photos
/// with a label nobody else shares are singletons.
///
/// Throws [ArgumentError] if a predicted group contains an id missing from
/// [truth], which usually means the labels file and the scan disagree.
PairMetrics evaluateGrouping({
  required Map<String, String> truth,
  required Iterable<Iterable<String>> predicted,
}) {
  String key(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a\u0000$b' : '$b\u0000$a';

  Set<String> pairsOf(Iterable<String> ids) {
    final list = ids.toList();
    return {
      for (var i = 0; i < list.length; i++)
        for (var j = i + 1; j < list.length; j++) key(list[i], list[j]),
    };
  }

  final byLabel = <String, List<String>>{};
  truth.forEach((id, label) => byLabel.putIfAbsent(label, () => []).add(id));
  final truthPairs = <String>{};
  for (final ids in byLabel.values) {
    truthPairs.addAll(pairsOf(ids));
  }

  final predictedPairs = <String>{};
  for (final group in predicted) {
    final ids = group.toList();
    for (final id in ids) {
      if (!truth.containsKey(id)) {
        throw ArgumentError.value(id, 'predicted', 'has no label in truth');
      }
    }
    predictedPairs.addAll(pairsOf(ids));
  }

  final hits = predictedPairs.intersection(truthPairs).length;
  return PairMetrics(
    truePositives: hits,
    falsePositives: predictedPairs.length - hits,
    falseNegatives: truthPairs.length - hits,
  );
}
