import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const maxAnalysisEdge = 1024;
const maxEncodedImageBytes = 64 * 1024 * 1024;
const maxFallbackPixels = 24 * 1024 * 1024;
const maxJpegPixels = 64 * 1024 * 1024;

Future<Uint8List> collectImageBytes(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (builder.length + chunk.length > maxEncodedImageBytes) {
      throw const FormatException('Image exceeds the 64 MiB analysis limit.');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Width and height of the encoded image, read from its header without
/// decoding any pixels. Returns null for unsupported data.
(int, int)? readImageSize(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (decoder == null || info == null) return null;
  return (info.width, info.height);
}

/// JPEGs are subsampled during decoding; other formats have a pixel budget
/// because their decoders still allocate a full frame before resizing.
img.Image? decodeAnalysisImage(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (decoder == null || info == null) return null;
  final longestEdge = math.max(info.width, info.height);
  img.Image? image;
  if (decoder is img.JpegDecoder) {
    if (info.width * info.height > maxJpegPixels) {
      throw const FormatException('JPEG exceeds the source pixel budget.');
    }
    var scale = 1;
    while (scale < 8 && longestEdge / (scale * 2) >= maxAnalysisEdge) {
      scale *= 2;
    }
    if (((info.width + scale - 1) ~/ scale) *
            ((info.height + scale - 1) ~/ scale) >
        maxFallbackPixels) {
      throw const FormatException('Image exceeds the decoded pixel budget.');
    }
    image = img.JpegDecoder(
      scale: scale,
      maxPixels: maxJpegPixels,
    ).decode(bytes, frame: 0);
  } else {
    if (info.width * info.height > maxFallbackPixels) {
      throw const FormatException('Image exceeds the decoded pixel budget.');
    }
    image = decoder.decode(bytes, frame: 0);
  }
  if (image == null) return null;
  return resizeLongestEdge(img.bakeOrientation(image), maxAnalysisEdge);
}

img.Image resizeLongestEdge(img.Image image, int edge) {
  if (image.width <= edge && image.height <= edge) return image;
  return img.copyResize(
    image,
    width: image.width >= image.height ? edge : null,
    height: image.height > image.width ? edge : null,
    interpolation: img.Interpolation.average,
  );
}

Uint8List encodePreview(img.Image image, {int edge = 360, int quality = 78}) =>
    img.encodeJpg(resizeLongestEdge(image, edge), quality: quality);
