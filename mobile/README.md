# PictoIQ mobile

Local-first Android photo review and best-shot recommendations.

## Folder scan performance

- Visual-analysis SAF streams use `BytesBuilder` instead of growable integer lists. Exact duplicate SHA-256 is streamed without buffering the entire file.
- Best-shot analysis does not compute SHA-256. Similar groups use a member URI as their local group ID; exact groups retain the content hash.
- Decode, orientation normalization, resizing, visual hashing, technical scoring, and JPEG encoding run in `Isolate.run`, one image at a time. Native face detection remains on the plugin's platform channel.
- JPEG decoding uses subsampling when appropriate. Analysis and ML Kit input images are capped at 1024 pixels on the longest edge, preserving aspect ratio and never upscaling small images.
- Previews have a maximum edge of 360 pixels for best shots and 480 for exact duplicates. Temporary face images are JPEG files and are deleted after processing.
- Visual analysis rejects encoded files over 64 MiB, JPEG sources over 67,108,864 pixels, and other formats over 25,165,824 pixels before decoding pixel data. Other formats still require full-frame decoding inside the worker before resizing. These safeguards do not guarantee a particular peak-memory footprint.
- Failed or unsupported best-shot files increment the existing skipped count and cannot become deletion candidates. Exact duplicates can still be detected by streaming SHA-256 if their previews exceed these limits.

Downscaling can change quality signals and hide small faces. Recommendations remain advisory; evaluate grouping and ranking against representative burst photos before release.

### Focused validation

```powershell
flutter analyze lib\folder_duplicate_scanner.dart lib\scan_image_processing.dart test\scan_image_processing_test.dart test\folder_scanner_performance_test.dart
flutter test test\scan_image_processing_test.dart test\folder_scanner_performance_test.dart
```

Tests cover typed byte collection, encoded memory limits, image dimensions, EXIF preservation/orientation, exact hashes, best-shot grouping without content hashes, skipped inputs, temporary-file cleanup, and bounded face-detector input. The native detector is mocked; its real latency and accuracy are not measured here.

For device profiling, run `flutter run --profile` on a physical Android device and compare the same large folder before/after with DevTools CPU, memory, and frame timelines. Record peak memory, scan duration, skipped count, and frames over the device frame budget. Synthetic timings are diagnostics, not device performance guarantees.

## Similar-photo grouping

- Similar photos are grouped by a 64-bit difference hash plus capture time (EXIF time when present, file time otherwise; the two are never compared). They are kept separate from exact duplicates and are never described as guaranteed duplicates.
- Each group shows a High, Medium or Low match label with the facts behind it (hash spread, time span, time source). A chain of look-alikes whose ends differ a lot is marked Low.
- Default selection is conservative: every thumbs-up photo is kept; otherwise the top-ranked photo is suggested. Bulk deletion only touches groups that are High match with a clear top photo, or groups where you chose.
- Thresholds are starting points. Measure them on your own photos with `dart run tool/evaluate_similarity.dart <folder> <labels.csv>`; `test/similarity_evaluation_test.dart` is a synthetic regression set, not a measurement.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
