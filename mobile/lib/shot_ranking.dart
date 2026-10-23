import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'scan_image_processing.dart' show resizeLongestEdge;

/// Longest edge, in pixels, that sharpness and exposure are measured at. The
/// same size is used for every photo, so scores are comparable.
const _measureEdge = 512;

/// Pixel-level measurements of one photo.
class ImageSignals {
  const ImageSignals({
    required this.sharpness,
    required this.meanLuma,
    required this.highlightClip,
    required this.shadowClip,
  });

  /// Nothing measured; used when a photo has no analysis data.
  static const unknown = ImageSignals(
    sharpness: 0,
    meanLuma: 128,
    highlightClip: 0,
    shadowClip: 0,
  );

  /// Variance of the Laplacian at [_measureEdge] pixels. Only meaningful when
  /// compared with other photos of the same scene: higher means sharper.
  final double sharpness;

  /// Average brightness, 0 (black) to 255 (white).
  final double meanLuma;

  /// Share of pixels that are almost white (0-1).
  final double highlightClip;

  /// Share of pixels that are almost black (0-1).
  final double shadowClip;

  /// 0-100. Penalises a mean brightness far from mid-grey and large areas of
  /// pure white or pure black. Highlights count against a photo more than
  /// shadows because blown highlights cannot be recovered.
  double get exposureScore {
    final tonal = 100 - math.min(60, (meanLuma - 120).abs() * 0.8);
    final clipPenalty = math.min(
      40,
      highlightClip * 100 * 4 + shadowClip * 100 * 1.5,
    );
    return (tonal - clipPenalty).clamp(0, 100).toDouble();
  }
}

/// Measures sharpness and exposure of [image] at a fixed working size.
ImageSignals measureImage(img.Image image) {
  final small = resizeLongestEdge(image, _measureEdge);
  final width = small.width;
  final height = small.height;
  final count = width * height;
  if (count == 0) return ImageSignals.unknown;

  final luma = Float64List(count);
  var sum = 0.0;
  var highlights = 0;
  var shadows = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final value = small.getPixel(x, y).luminanceNormalized * 255;
      luma[y * width + x] = value.toDouble();
      sum += value;
      if (value >= 250) highlights++;
      if (value <= 5) shadows++;
    }
  }

  var variance = 0.0;
  if (width >= 3 && height >= 3) {
    var lapSum = 0.0;
    var lapSquares = 0.0;
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final i = y * width + x;
        final laplacian =
            luma[i - width] +
            luma[i + width] +
            luma[i - 1] +
            luma[i + 1] -
            4 * luma[i];
        lapSum += laplacian;
        lapSquares += laplacian * laplacian;
      }
    }
    final samples = (width - 2) * (height - 2);
    final mean = lapSum / samples;
    variance = math.max(0.0, lapSquares / samples - mean * mean);
  }

  return ImageSignals(
    sharpness: variance,
    meanLuma: sum / count,
    highlightClip: highlights / count,
    shadowClip: shadows / count,
  );
}

/// What face detection found in one photo.
class FaceSignals {
  const FaceSignals({
    required this.count,
    required this.eyesOpenMin,
    required this.smileAverage,
  });

  static const none = FaceSignals(
    count: 0,
    eyesOpenMin: null,
    smileAverage: null,
  );

  final int count;

  /// Lowest eye-open probability (0-1) over all faces and both eyes, so one
  /// blinking or winking person is enough to lower it. Null when unknown.
  final double? eyesOpenMin;

  /// Average smile probability (0-1) over the faces that report one.
  final double? smileAverage;
}

/// Everything the ranking needs to know about one photo.
class ShotFeatures {
  const ShotFeatures({
    required this.signals,
    required this.megapixels,
    this.faces,
  });

  static const unknown = ShotFeatures(
    signals: ImageSignals.unknown,
    megapixels: 0,
  );

  final ImageSignals signals;

  /// Size of the original image in millions of pixels.
  final double megapixels;

  /// Null when face detection was turned off or failed for this photo.
  final FaceSignals? faces;
}

/// One photo handed to [rankShots].
class ShotInput {
  const ShotInput({
    required this.id,
    required this.features,
    required this.tieBreaker,
  });

  final String id;
  final ShotFeatures features;

  /// Stable ordering key (for example the relative path) for equal scores.
  final String tieBreaker;
}

class RankedShot {
  const RankedShot({
    required this.id,
    required this.rank,
    required this.score,
    required this.strengths,
    required this.concerns,
    required this.features,
  });

  final String id;

  /// 1 for the best shot.
  final int rank;

  /// 0-100, relative to the other photos in the same group. It says which
  /// shot is best here, not how good the photo is in absolute terms.
  final int score;

  /// Reasons in this photo's favour, compared with the rest of the group.
  final List<String> strengths;

  /// Reasons against it.
  final List<String> concerns;

  final ShotFeatures features;

  /// One line for a list row.
  String get summary {
    if (strengths.isEmpty && concerns.isEmpty) return 'Similar to the others';
    return [...strengths.take(2), ...concerns.take(1)].join(' · ');
  }
}

class GroupRanking {
  const GroupRanking({required this.shots, required this.usedFaceSignals});

  /// Best first.
  final List<RankedShot> shots;

  /// Whether face and eye signals contributed to the scores.
  final bool usedFaceSignals;

  RankedShot get best => shots.first;

  RankedShot? shotFor(String id) {
    for (final shot in shots) {
      if (shot.id == id) return shot;
    }
    return null;
  }

  /// Points between the best and second-best shot.
  int get margin => shots.length < 2 ? 100 : shots[0].score - shots[1].score;

  /// False when the top two shots are too close to call, in which case the
  /// app should not choose between them without the user's help.
  bool get isClearWinner => margin >= clearWinnerMargin;

  /// Minimum score gap for [isClearWinner].
  static const clearWinnerMargin = 6;

  /// Short explanation of the recommendation.
  String get headline {
    if (!isClearWinner) return 'These shots are very close; you decide';
    final reasons = best.strengths.take(2).toList();
    return reasons.isEmpty
        ? 'Best overall balance'
        : 'Recommended: ${reasons.join(', ').toLowerCase()}';
  }
}

// Score weights. They add up to 100 when faces are used, 70 when not.
const _sharpnessWeight = 40.0;
const _exposureWeight = 20.0;
const _resolutionWeight = 10.0;
const _faceWeight = 30.0;

/// Ranks photos of the same scene and explains why.
///
/// Sharpness is compared with the sharpest photo in the group, because the
/// raw value depends on the scene. Face signals only count when every photo
/// was assessed and at least one shows a face; otherwise their weight is left
/// out rather than guessed.
GroupRanking rankShots(List<ShotInput> inputs) {
  if (inputs.isEmpty) {
    return const GroupRanking(shots: [], usedFaceSignals: false);
  }

  final maxSharpness = inputs.map((i) => i.features.signals.sharpness).reduce(
    math.max,
  );
  final maxMegapixels = inputs.map((i) => i.features.megapixels).reduce(
    math.max,
  );
  final minMegapixels = inputs.map((i) => i.features.megapixels).reduce(
    math.min,
  );
  final allAssessed = inputs.every((i) => i.features.faces != null);
  final maxFaces = allAssessed
      ? inputs.map((i) => i.features.faces!.count).reduce(math.max)
      : 0;
  final minFaces = allAssessed
      ? inputs.map((i) => i.features.faces!.count).reduce(math.min)
      : 0;
  final useFaces = allAssessed && maxFaces > 0;
  final possible =
      _sharpnessWeight +
      _exposureWeight +
      _resolutionWeight +
      (useFaces ? _faceWeight : 0);

  final scored = <({ShotInput input, double points})>[];
  for (final input in inputs) {
    final features = input.features;
    final sharpRatio = maxSharpness <= 0
        ? 1.0
        : features.signals.sharpness / maxSharpness;
    final resolutionRatio = maxMegapixels <= 0
        ? 1.0
        : features.megapixels / maxMegapixels;
    var points =
        _sharpnessWeight * math.sqrt(sharpRatio.clamp(0, 1)) +
        _exposureWeight * features.signals.exposureScore / 100 +
        _resolutionWeight * resolutionRatio.clamp(0, 1);
    if (useFaces) {
      final faces = features.faces!;
      if (faces.count > 0) {
        final eyes = faces.eyesOpenMin ?? 0.5;
        final smile = faces.smileAverage ?? 0.5;
        final presence = faces.count / maxFaces;
        points += _faceWeight * (0.55 * eyes + 0.25 * smile + 0.20 * presence);
      }
    }
    scored.add((input: input, points: points));
  }

  final shots = <RankedShot>[];
  for (final entry in scored) {
    final features = entry.input.features;
    final strengths = <String>[];
    final concerns = <String>[];

    final sharpRatio = maxSharpness <= 0
        ? 1.0
        : features.signals.sharpness / maxSharpness;
    if (inputs.length > 1 && maxSharpness > 0) {
      if (sharpRatio >= 0.995) {
        strengths.add('Sharpest in the group');
      } else if (sharpRatio >= 0.9) {
        strengths.add('Nearly as sharp as the best shot');
      } else {
        concerns.add(
          'Softer: sharpness is ${(sharpRatio * 100).round()}% of the best shot',
        );
      }
    }

    final signals = features.signals;
    if (signals.highlightClip > 0.03) {
      concerns.add(
        'Bright areas washed out (${(signals.highlightClip * 100).round()}% of the picture)',
      );
    }
    if (signals.shadowClip > 0.15) {
      concerns.add(
        'Dark areas lose detail (${(signals.shadowClip * 100).round()}% of the picture)',
      );
    }
    if (signals.meanLuma < 60) {
      concerns.add('Looks underexposed');
    } else if (signals.meanLuma > 200) {
      concerns.add('Looks overexposed');
    }
    if (signals.exposureScore >= 85 &&
        signals.highlightClip <= 0.03 &&
        signals.shadowClip <= 0.15) {
      strengths.add('Well exposed');
    }

    if (minMegapixels < maxMegapixels * 0.95) {
      if (features.megapixels >= maxMegapixels * 0.999) {
        strengths.add('Highest resolution (${_mp(features.megapixels)})');
      } else if (features.megapixels < maxMegapixels * 0.95) {
        concerns.add(
          'Lower resolution (${_mp(features.megapixels)} vs ${_mp(maxMegapixels)})',
        );
      }
    }

    if (useFaces) {
      final faces = features.faces!;
      if (faces.count == 0) {
        concerns.add('No face found (other shots show $maxFaces)');
      } else {
        final eyes = faces.eyesOpenMin;
        if (eyes != null && eyes < 0.4) {
          concerns.add('Someone may have their eyes closed');
        } else if (eyes != null && eyes >= 0.65) {
          strengths.add(
            faces.count == 1 ? 'Eyes look open' : 'Everyone’s eyes look open',
          );
        }
        final smile = faces.smileAverage;
        if (smile != null && smile >= 0.55) {
          strengths.add(faces.count == 1 ? 'Smiling' : 'Mostly smiling');
        }
        if (faces.count < maxFaces) {
          concerns.add(
            'Fewer faces visible than other shots (${faces.count} of $maxFaces)',
          );
        } else if (minFaces < maxFaces) {
          strengths.add('Everyone in frame ($maxFaces faces)');
        }
      }
    }

    shots.add(
      RankedShot(
        id: entry.input.id,
        rank: 0,
        score: (100 * entry.points / possible).round().clamp(0, 100).toInt(),
        strengths: List.unmodifiable(strengths),
        concerns: List.unmodifiable(concerns),
        features: features,
      ),
    );
  }

  final tieBreakers = {for (final input in inputs) input.id: input.tieBreaker};
  shots.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final bySharpness = b.features.signals.sharpness.compareTo(
      a.features.signals.sharpness,
    );
    if (bySharpness != 0) return bySharpness;
    return tieBreakers[a.id]!.compareTo(tieBreakers[b.id]!);
  });

  return GroupRanking(
    shots: List.unmodifiable([
      for (var i = 0; i < shots.length; i++)
        RankedShot(
          id: shots[i].id,
          rank: i + 1,
          score: shots[i].score,
          strengths: shots[i].strengths,
          concerns: shots[i].concerns,
          features: shots[i].features,
        ),
    ]),
    usedFaceSignals: useFaces,
  );
}

String _mp(double megapixels) => '${megapixels.toStringAsFixed(1)} MP';
