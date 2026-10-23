import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'app_settings.dart';
import 'folder_duplicate_scanner.dart';
import 'library_store.dart';
import 'photo_asset.dart';
import 'selection_policy.dart';
import 'similarity_grouping.dart';

const _ink = Color(0xFF282B25);
const _green = Color(0xFF54744C);
const _canvas = Color(0xFFF7F8F4);

enum _PhotoSort { recent, name, largest }

void main() => runApp(const PictoIqApp());

class PictoIqApp extends StatelessWidget {
  const PictoIqApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PictoIQ',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: _green),
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: _ink,
        displayColor: _ink,
      ),
    ),
    home: const LibraryPage(),
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _picker = ImagePicker();
  final _folderScanner = FolderDuplicateScanner();
  final _settingsStore = SettingsStore();
  final _searchController = TextEditingController();
  final _folderSelectionKey = GlobalKey();
  final Map<String, int> _photoRatings = {};
  AppSettings _settings = const AppSettings();
  List<PhotoAsset> _photos = [];
  FolderSelection? _selectedFolder;
  FolderDateRange _folderDateRange = FolderDateRange.currentFolder;
  FolderScanResult? _folderScan;
  FolderScanResult? _bestShotsScan;
  bool _loading = true;
  bool _importing = false;
  bool _scanningFolder = false;
  bool _scanningBestShots = false;
  bool _duplicatesOnly = false;
  _PhotoSort _sort = _PhotoSort.recent;
  int _folderImagesScanned = 0;
  String? _error;
  String? _folderScanError;
  String? _bestShotsError;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await _settingsStore.load();
    if (mounted) setState(() => _settings = settings);
  }

  /// Applies [settings] at once and saves them in the background.
  Future<void> _updateSettings(AppSettings settings) async {
    setState(() => _settings = settings);
    try {
      await _settingsStore.save(settings);
    } catch (_) {
      if (mounted) _showMessage('PictoIQ could not save that setting.');
    }
  }

  Future<void> _loadPhotos() async {
    try {
      final photos = await LibraryStore.instance.getPhotos();
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'PictoIQ could not open its on-device library.';
      });
    }
  }

  Future<void> _choosePhotos() async {
    if (_importing) return;
    try {
      final selected = await _picker.pickMultiImage();
      if (selected.isEmpty || !mounted) return;
      setState(() => _importing = true);

      var added = 0;
      for (final file in selected) {
        final photo = await LibraryStore.instance.importPhoto(file, added);
        if (!mounted) return;
        setState(() {
          _photos = [photo, ..._photos];
          added += 1;
        });
      }
      if (mounted) {
        _showMessage(
          'Added $added photo${added == 1 ? '' : 's'} to your private library.',
        );
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          'PictoIQ could not import those photos. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _scanFolder() async {
    await _runFolderScan(bestShots: false);
  }

  Future<void> _scanBestShotsFolder() async {
    await _runFolderScan(bestShots: true);
  }

  Future<void> _chooseFolder() async {
    if (_scanningFolder || _importing) return;
    try {
      final selected = await _folderScanner.pickFolder();
      if (selected == null || !mounted) return;
      setState(() {
        _selectedFolder = selected;
        _folderScan = null;
        _bestShotsScan = null;
        _folderScanError = null;
        _bestShotsError = null;
      });
    } catch (error) {
      if (mounted) {
        _showMessage('PictoIQ could not open that folder. Try again.');
      }
    }
  }

  Future<void> _runFolderScan({required bool bestShots}) async {
    final selectedFolder = _selectedFolder;
    if (!Platform.isAndroid ||
        selectedFolder == null ||
        _scanningFolder ||
        _importing) {
      return;
    }
    setState(() {
      _scanningFolder = true;
      _scanningBestShots = bestShots;
      _folderImagesScanned = 0;
      if (bestShots) {
        _bestShotsError = null;
      } else {
        _folderScanError = null;
      }
    });
    try {
      final result = await _folderScanner.scanUri(
        selectedFolder.uri,
        folderName: selectedFolder.name,
        bestShotsScan: bestShots,
        useFaceSignals: _settings.useFaceSignals,
        dateRange: _folderDateRange,
        onProgress: (count) {
          if (mounted) setState(() => _folderImagesScanned = count);
        },
      );
      if (!mounted) return;
      setState(() {
        if (bestShots) {
          _bestShotsScan = result;
        } else {
          _folderScan = result;
        }
      });
      _scrollToFolderSelection();
      _showMessage(
        result.duplicateGroups.isEmpty
            ? bestShots
                  ? 'Scanned ${result.imagesScanned} photos. No similar shots found.${_skippedNote(result.imagesSkipped)}'
                  : 'Scanned ${result.imagesScanned} photos. No exact duplicates found.${_skippedNote(result.imagesSkipped)}'
            : bestShots
            ? 'Found ${result.duplicateGroups.length} similar-photo groups in ${result.folderName}. They are similar, not identical, so review them before deleting.${_skippedNote(result.imagesSkipped)}'
            : 'Found ${result.duplicateGroups.length} exact duplicate groups in ${result.folderName}.${_skippedNote(result.imagesSkipped)}',
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          final message =
              'PictoIQ could not scan that folder. Choose another folder and try again.';
          if (bestShots) {
            _bestShotsError = message;
          } else {
            _folderScanError = message;
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanningFolder = false;
          _scanningBestShots = false;
        });
      }
    }
  }

  void _scrollToFolderSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _folderSelectionKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _setPhotoRating(String key, int rating) {
    setState(() {
      _photoRatings[key] = _photoRatings[key] == rating ? 0 : rating;
    });
  }

  int _photoRating(String key) => _photoRatings[key] ?? 0;

  Set<String> get _likedIds => {
    for (final entry in _photoRatings.entries)
      if (entry.value > 0) entry.key,
  };

  Set<String> get _dislikedIds => {
    for (final entry in _photoRatings.entries)
      if (entry.value < 0) entry.key,
  };

  /// Which photos of [group] to keep. See [decideKeepers] for the rules; in
  /// short, every thumbs-up photo is kept, otherwise the top-ranked photo that
  /// was not thumbed down, and nothing at all when the user prefers to choose.
  KeepDecision _decisionFor(
    FolderDuplicateGroup group, {
    required bool bestShots,
  }) {
    if (!bestShots) {
      // Exact copies are identical, so keeping the oldest is always safe.
      return decideKeepers(
        rankedIds: [for (final photo in group.oldestFirst) photo.uri],
        liked: _likedIds,
        disliked: _dislikedIds,
        manualOnly: false,
        confident: true,
      );
    }
    final confident =
        group.evidence?.confidence == SimilarityConfidence.high &&
        (group.ranking?.isClearWinner ?? false);
    return decideKeepers(
      rankedIds: [for (final photo in group.bestFirst) photo.uri],
      liked: _likedIds,
      disliked: _dislikedIds,
      manualOnly: _settings.manualSelectionOnly,
      confident: confident,
    );
  }

  List<FolderScanPhoto> _groupKeepers(
    FolderDuplicateGroup group, {
    required bool bestShots,
  }) {
    final keepIds = _decisionFor(group, bestShots: bestShots).keepIds;
    return group.photos.where((photo) => keepIds.contains(photo.uri)).toList();
  }

  List<FolderScanPhoto> _groupRemovals(
    FolderDuplicateGroup group, {
    required bool bestShots,
  }) {
    final decision = _decisionFor(group, bestShots: bestShots);
    final remove = decision
        .removals([for (final photo in group.photos) photo.uri])
        .toSet();
    return group.photos.where((photo) => remove.contains(photo.uri)).toList();
  }

  /// Whether a bulk action may act on [group] without a person looking at it:
  /// exact copies always, similar shots only when the user chose the keepers
  /// or the grouping and the ranking are both clear.
  bool _isBulkSafe(FolderDuplicateGroup group, {required bool bestShots}) {
    final decision = _decisionFor(group, bestShots: bestShots);
    return decision.hasDecision && !decision.needsReview;
  }

  List<FolderDuplicateGroup> _bulkGroups(
    FolderScanResult scan, {
    required bool bestShots,
  }) => scan.duplicateGroups
      .where((group) => _isBulkSafe(group, bestShots: bestShots))
      .toList(growable: false);

  /// Groups a bulk action will leave alone because a person should look first.
  int _groupsNeedingReview(FolderScanResult scan, {required bool bestShots}) =>
      scan.duplicateGroups.length -
      _bulkGroups(scan, bestShots: bestShots).length;

  List<FolderScanPhoto> _scanRemovals(
    FolderScanResult scan, {
    required bool bestShots,
  }) => _bulkGroups(
    scan,
    bestShots: bestShots,
  ).expand((group) => _groupRemovals(group, bestShots: bestShots)).toList();

  int _groupRecoveryBytes(
    FolderDuplicateGroup group, {
    required bool bestShots,
  }) => _groupRemovals(
    group,
    bestShots: bestShots,
  ).fold(0, (total, photo) => total + photo.size);

  Widget _photoRatingButtons(String key) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Thumbs up: prefer this photo',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        onPressed: () => _setPhotoRating(key, 1),
        icon: Icon(
          _photoRating(key) > 0 ? Icons.thumb_up : Icons.thumb_up_outlined,
          size: 17,
          color: _photoRating(key) > 0 ? _green : const Color(0xFF77796F),
        ),
      ),
      IconButton(
        tooltip: 'Thumbs down: avoid this photo',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        onPressed: () => _setPhotoRating(key, -1),
        icon: Icon(
          _photoRating(key) < 0 ? Icons.thumb_down : Icons.thumb_down_outlined,
          size: 17,
          color: _photoRating(key) < 0
              ? const Color(0xFFB05F4B)
              : const Color(0xFF77796F),
        ),
      ),
    ],
  );

  Future<void> _deleteNewerCopies(FolderDuplicateGroup group) async {
    final scan = _folderScan;
    if (scan == null) return;
    final keepers = _groupKeepers(group, bestShots: false);
    final newerCopies = _groupRemovals(group, bestShots: false);
    if (keepers.isEmpty || newerCopies.isEmpty) return;
    final recoverableBytes = _groupRecoveryBytes(group, bestShots: false);
    final keptNames = keepers.map((photo) => '"${photo.relativePath}"').join(', ');
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep your preferred copy?'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PictoIQ will keep $keptNames and delete the other identical copies listed below. Nothing is deleted until you confirm.',
                ),
                const SizedBox(height: 12),
                _recoveryEstimate(recoverableBytes),
                const SizedBox(height: 12),
                for (final photo in newerCopies)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      photo.relativePath,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 4),
                const Text(
                  'These files are exact matches. Deleting removes only the newer source copies from this folder. PictoIQ copies are not affected.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF77796F)),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete ${newerCopies.length} copies'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;

    setState(() {
      _scanningFolder = true;
      _scanningBestShots = false;
    });
    var freedBytes = 0;
    try {
      for (final photo in newerCopies) {
        await _folderScanner.deleteFile(photo.uri);
        freedBytes += photo.size;
      }
      final refreshed = await _folderScanner.scanUri(
        scan.folderUri,
        folderName: scan.folderName,
        dateRange: scan.dateRange,
        onProgress: (count) {
          if (mounted) setState(() => _folderImagesScanned = count);
        },
      );
      if (!mounted) return;
      setState(() => _folderScan = refreshed);
      _showMessage(
        'Freed about ${_formatBytes(freedBytes)}; kept ${_keptSummary(keepers)}.',
      );
    } catch (error) {
      if (!mounted) return;
      try {
        final refreshed = await _folderScanner.scanUri(
          scan.folderUri,
          folderName: scan.folderName,
          dateRange: scan.dateRange,
        );
        if (mounted) setState(() => _folderScan = refreshed);
      } catch (_) {
        // Keep the last scan visible if the folder can no longer be read.
      }
      if (mounted) {
        _showMessage(
          'Freed about ${_formatBytes(freedBytes)} so far. PictoIQ could not finish deleting every copy.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanningFolder = false;
          _scanningBestShots = false;
        });
      }
    }
  }

  Future<void> _deleteSimilarShots(FolderDuplicateGroup group) async {
    final scan = _bestShotsScan;
    if (scan == null) return;
    final decision = _decisionFor(group, bestShots: true);
    if (!decision.hasDecision) {
      _showMessage('Give a thumbs-up to the photo you want to keep first.');
      return;
    }
    final keepers = _groupKeepers(group, bestShots: true);
    final remove = _groupRemovals(group, bestShots: true);
    if (remove.isEmpty) return;
    final recoverableBytes = _groupRecoveryBytes(group, bestShots: true);
    final warning = decision.needsReview ? _reviewReason(group) : null;
    var reviewed = warning == null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            decision.isUserChoice
                ? 'Keep your chosen photo?'
                : 'Keep the suggested photo?',
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'These are similar shots, not identical duplicates. Keeping:',
                ),
                const SizedBox(height: 4),
                for (final photo in keepers)
                  Text(
                    '✓ ${photo.relativePath}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                const SizedBox(height: 10),
                Text('Deleting from "${scan.folderName}":'),
                const SizedBox(height: 4),
                for (final photo in remove)
                  Text('• ${photo.relativePath} · ${_shotSummary(group, photo)}'),
                const SizedBox(height: 10),
                _recoveryEstimate(recoverableBytes),
                if (warning != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4E0),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      warning,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF7A5200),
                      ),
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    value: reviewed,
                    onChanged: (value) =>
                        setDialogState(() => reviewed = value ?? false),
                    title: const Text(
                      'I have looked at these photos',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                const Text(
                  'PictoIQ waits for your confirmation before deleting source files.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF77796F)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: reviewed
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(
                'Delete ${remove.length} photo${remove.length == 1 ? '' : 's'}',
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _scanningFolder = true;
      _scanningBestShots = true;
    });
    var freedBytes = 0;
    try {
      for (final photo in remove) {
        await _folderScanner.deleteFile(photo.uri);
        freedBytes += photo.size;
      }
      final refreshed = await _folderScanner.scanUri(
        scan.folderUri,
        folderName: scan.folderName,
        bestShotsScan: true,
        useFaceSignals: _settings.useFaceSignals,
        dateRange: scan.dateRange,
      );
      if (!mounted) return;
      setState(() => _bestShotsScan = refreshed);
      _showMessage(
        'Freed about ${_formatBytes(freedBytes)}; kept ${_keptSummary(keepers)}.',
      );
    } catch (error) {
      if (mounted) {
        _showMessage(
          'Freed about ${_formatBytes(freedBytes)} so far. PictoIQ could not finish cleanup; scan the folder again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanningFolder = false;
          _scanningBestShots = false;
        });
      }
    }
  }

  Future<void> _deleteAllScanRemovables({required bool bestShots}) async {
    final scan = bestShots ? _bestShotsScan : _folderScan;
    if (scan == null || _scanningFolder) return;
    final remove = _scanRemovals(scan, bestShots: bestShots);
    if (remove.isEmpty) return;
    final bytes = remove.fold<int>(0, (total, photo) => total + photo.size);
    final category = bestShots
        ? 'lower-ranked similar shots'
        : 'exact duplicate copies';
    final keepDescription = bestShots
        ? 'PictoIQ will keep your thumbs-up picks, or the top-ranked photo in each group where the match and the ranking are both clear.'
        : 'PictoIQ will keep your thumbs-up picks, or the oldest copy in each group.';
    final skippedGroups = _groupsNeedingReview(scan, bestShots: bestShots);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete all $category?'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Delete ${remove.length} photos from "${scan.folderName}"? $keepDescription',
                ),
                if (skippedGroups > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '$skippedGroups group${skippedGroups == 1 ? '' : 's'} that need${skippedGroups == 1 ? 's' : ''} your review will be left alone.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF7A5200),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _recoveryEstimate(bytes),
                const SizedBox(height: 12),
                for (final photo in remove.take(10))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      photo.relativePath,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (remove.length > 10)
                  Text(
                    'and ${remove.length - 10} more…',
                    style: const TextStyle(fontSize: 12),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'This deletes source files in the selected folder. Review the list before continuing.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF77796F)),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete ${remove.length} photos'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _scanningFolder = true;
      _scanningBestShots = bestShots;
      _folderImagesScanned = 0;
    });
    var freedBytes = 0;
    var failedDeletes = 0;
    for (final photo in remove) {
      try {
        await _folderScanner.deleteFile(photo.uri);
        freedBytes += photo.size;
      } catch (_) {
        failedDeletes += 1;
      }
    }
    try {
      final refreshed = await _folderScanner.scanUri(
        scan.folderUri,
        folderName: scan.folderName,
        bestShotsScan: bestShots,
        useFaceSignals: _settings.useFaceSignals,
        dateRange: scan.dateRange,
        onProgress: (count) {
          if (mounted) setState(() => _folderImagesScanned = count);
        },
      );
      if (!mounted) return;
      setState(() {
        if (bestShots) {
          _bestShotsScan = refreshed;
        } else {
          _folderScan = refreshed;
        }
      });
      _showMessage(
        failedDeletes == 0
            ? 'Freed about ${_formatBytes(freedBytes)}.'
            : 'Freed ${_formatBytes(freedBytes)}. $failedDeletes photos could not be deleted.',
      );
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Freed ${_formatBytes(freedBytes)}. PictoIQ could not refresh the scan; scan this folder again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanningFolder = false;
          _scanningBestShots = false;
        });
      }
    }
  }

  Future<void> _removePhoto(PhotoAsset photo) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from PictoIQ?'),
        content: Text(
          '“${photo.name}” and PictoIQ’s private copy will be removed. The original photo stays in your gallery.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await LibraryStore.instance.removePhoto(photo);
      if (!mounted) return;
      setState(() => _photos.removeWhere((item) => item.id == photo.id));
      _showMessage('Removed from PictoIQ. Your original photo is unchanged.');
    } catch (error) {
      if (mounted) _showMessage('PictoIQ could not remove that library entry.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Map<String, List<PhotoAsset>> get _duplicateGroups {
    final groups = <String, List<PhotoAsset>>{};
    for (final photo in _photos) {
      groups.putIfAbsent(photo.sha256, () => []).add(photo);
    }
    return Map.fromEntries(
      groups.entries.where((entry) => entry.value.length > 1),
    );
  }

  List<PhotoAsset> _visiblePhotos(Map<String, List<PhotoAsset>> groups) {
    final query = _searchController.text.trim().toLowerCase();
    final photos = _photos.where((photo) {
      final matchesQuery =
          query.isEmpty || photo.name.toLowerCase().contains(query);
      final matchesFilter =
          !_duplicatesOnly || groups.containsKey(photo.sha256);
      return matchesQuery && matchesFilter;
    }).toList();

    switch (_sort) {
      case _PhotoSort.recent:
        photos.sort((left, right) => right.id.compareTo(left.id));
        break;
      case _PhotoSort.name:
        photos.sort(
          (left, right) =>
              left.name.toLowerCase().compareTo(right.name.toLowerCase()),
        );
        break;
      case _PhotoSort.largest:
        photos.sort((left, right) => right.size.compareTo(left.size));
        break;
    }
    return photos;
  }

  @override
  void dispose() {
    _folderScanner.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duplicateGroups = _duplicateGroups;
    final visiblePhotos = _visiblePhotos(duplicateGroups);
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              sliver: SliverToBoxAdapter(child: _header()),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              sliver: SliverToBoxAdapter(child: _privacyBanner()),
            ),
            if (Platform.isAndroid)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                sliver: SliverToBoxAdapter(
                  key: _folderSelectionKey,
                  child: _folderSelection(),
                ),
              ),
            if ((_scanningFolder && !_scanningBestShots) ||
                _folderScan != null ||
                _folderScanError != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                sliver: SliverToBoxAdapter(
                  child: _folderScanSection(bestShots: false),
                ),
              ),
            if (_scanningBestShots ||
                _bestShotsScan != null ||
                _bestShotsError != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                sliver: SliverToBoxAdapter(
                  child: _folderScanSection(bestShots: true),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
              sliver: SliverToBoxAdapter(child: _libraryHeading()),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              sliver: SliverToBoxAdapter(
                child: _summary(duplicateGroups.length),
              ),
            ),
            if (!_loading)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: _libraryControls(duplicateGroups),
                ),
              ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_photos.isEmpty &&
                _searchController.text.isEmpty &&
                !_duplicatesOnly)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                sliver: SliverToBoxAdapter(child: _emptyState()),
              )
            else if (visiblePhotos.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                sliver: SliverToBoxAdapter(child: _noMatches()),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                sliver: SliverGrid.builder(
                  itemCount: visiblePhotos.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: MediaQuery.sizeOf(context).width >= 700
                        ? 4
                        : 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: .74,
                  ),
                  itemBuilder: (context, index) => _photoCard(
                    visiblePhotos[index],
                    duplicateGroups.containsKey(visiblePhotos[index].sha256),
                  ),
                ),
              ),
            if (_error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverToBoxAdapter(child: _footer()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/brand/pictoiq-icon.png',
              width: 38,
              height: 38,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'picto',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -.7,
            ),
          ),
          const Text(
            'iq',
            style: TextStyle(
              color: _green,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -.7,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Similar-shot settings',
            onPressed: _showSettings,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'Privacy details',
            onPressed: _showPrivacy,
            icon: const Icon(Icons.shield_outlined),
          ),
        ],
      ),
      const SizedBox(height: 26),
      const Text(
        'YOUR PERSONAL PHOTO SPACE',
        style: TextStyle(
          color: _green,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        _photos.isEmpty
            ? 'Your memories,\nin focus.'
            : 'A calmer camera roll\nstarts here.',
        style: const TextStyle(
          fontSize: 31,
          height: 1.08,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.1,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Find the photos worth keeping. Your library stays on this device.',
        style: TextStyle(color: _ink.withValues(alpha: .66), height: 1.45),
      ),
      const SizedBox(height: 17),
      Text(
        'Find duplicates and standout shots in a folder, then review your private photo library below.',
        style: TextStyle(color: _ink.withValues(alpha: .66), height: 1.45),
      ),
    ],
  );

  Widget _folderSelection() => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: const Color(0xFFEEF3E8),
      border: Border.all(color: const Color(0xFFDDE7D4)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Folder selection',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          'Choose a folder and scan recent photos or the whole folder.',
          style: TextStyle(fontSize: 12, color: Color(0xFF596252)),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _scanningFolder || _importing ? null : _chooseFolder,
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(_selectedFolder?.name ?? 'Choose a folder'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            foregroundColor: _green,
            alignment: Alignment.centerLeft,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Photo date',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          children: [
            for (final range in FolderDateRange.values)
              ChoiceChip(
                label: Text(range.label),
                selected: _folderDateRange == range,
                onSelected: _scanningFolder
                    ? null
                    : (_) => setState(() {
                        _folderDateRange = range;
                        _folderScan = null;
                        _bestShotsScan = null;
                        _folderScanError = null;
                        _bestShotsError = null;
                      }),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed:
              _selectedFolder == null ||
                  _loading ||
                  _importing ||
                  _scanningFolder
              ? null
              : _scanFolder,
          icon: _scanningFolder && !_scanningBestShots
              ? const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.copy_all_outlined),
          label: Text(
            _scanningFolder && !_scanningBestShots
                ? 'Scanning $_folderImagesScanned photos…'
                : 'Find exact duplicates',
          ),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            backgroundColor: _green,
            foregroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 7),
        OutlinedButton.icon(
          onPressed:
              _selectedFolder == null ||
                  _loading ||
                  _importing ||
                  _scanningFolder
              ? null
              : _scanBestShotsFolder,
          icon: _scanningBestShots
              ? const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_outlined),
          label: Text(
            _scanningBestShots
                ? 'Analyzing $_folderImagesScanned photos…'
                : 'Find the best shots',
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            foregroundColor: _green,
          ),
        ),
      ],
    ),
  );

  Widget _privacyBanner() => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFEEF3E8),
      border: Border.all(color: const Color(0xFFDDE7D4)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.verified_user_outlined, size: 19, color: _green),
        SizedBox(width: 9),
        Expanded(
          child: Text(
            'Private by design. Selected photos are copied into PictoIQ’s private app storage and analyzed on this device. Nothing is uploaded.',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: Color(0xFF4E5D47),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _summary(int duplicateCount) => Row(
    children: [
      Expanded(
        child: _statCard(
          'YOUR LIBRARY',
          '${_photos.length}',
          'photos saved',
          Icons.photo_outlined,
          const Color(0xFFF0EEF7),
          const Color(0xFF777092),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _duplicatesOnly = !_duplicatesOnly),
          child: _statCard(
            'EXACT MATCHES',
            '$duplicateCount',
            'tap to review groups',
            Icons.copy_all_outlined,
            const Color(0xFFFBF0E9),
            const Color(0xFFB37957),
          ),
        ),
      ),
    ],
  );

  Widget _statCard(
    String title,
    String value,
    String caption,
    IconData icon,
    Color background,
    Color foreground,
  ) => Container(
    constraints: const BoxConstraints(minHeight: 110),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE9EAE3)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF888A81),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .6,
                ),
              ),
            ),
            Container(
              width: 27,
              height: 27,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 15, color: foreground),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        Text(
          caption,
          style: const TextStyle(color: Color(0xFF85877F), fontSize: 10),
        ),
      ],
    ),
  );

  Widget _libraryHeading() => Row(
    children: [
      Expanded(
        child: Text(
          _duplicatesOnly ? 'Exact duplicates' : 'Your library',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -.3,
          ),
        ),
      ),
      if (!_duplicatesOnly) ...[
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _loading || _importing || _scanningFolder
              ? null
              : _choosePhotos,
          icon: _importing
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_photo_alternate_outlined, size: 17),
          label: Text(_importing ? 'Adding…' : 'Add photos'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _green,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
      ],
    ],
  );

  Widget _libraryControls(
    Map<String, List<PhotoAsset>> duplicateGroups,
  ) => Column(
    children: [
      TextField(
        controller: _searchController,
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search by filename',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close, size: 18),
                ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE6E8E0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE6E8E0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _green),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: false, label: Text('All photos')),
              ButtonSegment(value: true, label: Text('Duplicates')),
            ],
            selected: {_duplicatesOnly},
            onSelectionChanged: (selection) =>
                setState(() => _duplicatesOnly = selection.first),
          ),
          const Spacer(),
          PopupMenuButton<_PhotoSort>(
            tooltip: 'Sort photos',
            initialValue: _sort,
            onSelected: (value) => setState(() => _sort = value),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _PhotoSort.recent,
                child: Text('Recently added'),
              ),
              PopupMenuItem(value: _PhotoSort.name, child: Text('Name')),
              PopupMenuItem(
                value: _PhotoSort.largest,
                child: Text('Largest file'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort, size: 18, color: _green),
                  const SizedBox(width: 3),
                  Text(
                    _sortLabel(_sort),
                    style: const TextStyle(
                      color: _green,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '${_visiblePhotos(duplicateGroups).length} photos · ${duplicateGroups.length} duplicate groups',
            style: const TextStyle(color: Color(0xFF85877F), fontSize: 10),
          ),
        ),
      ),
    ],
  );

  Widget _noMatches() {
    final noDuplicates = _duplicatesOnly && _duplicateGroups.isEmpty;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .65),
        border: Border.all(color: const Color(0xFFE0E4D8)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(
            noDuplicates ? Icons.check_circle_outline : Icons.search_off,
            size: 34,
            color: _green,
          ),
          const SizedBox(height: 10),
          Text(
            noDuplicates
                ? 'No exact duplicates found.'
                : 'No photos match that search.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            noDuplicates
                ? 'New exact matches will appear here after you add photos.'
                : 'Try another filename or clear your filters.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF81847A), fontSize: 12),
          ),
          TextButton(
            onPressed: () {
              _searchController.clear();
              setState(() => _duplicatesOnly = false);
            },
            child: const Text('Show all photos'),
          ),
        ],
      ),
    );
  }

  Widget _folderScanSection({required bool bestShots}) {
    final scan = bestShots ? _bestShotsScan : _folderScan;
    final error = bestShots ? _bestShotsError : _folderScanError;
    final scanningThisMode = _scanningFolder && _scanningBestShots == bestShots;
    final groupLabel = bestShots
        ? 'similar-photo groups'
        : 'exact duplicate groups';
    if (error != null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1ED),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(error, style: const TextStyle(color: Color(0xFF8A4437))),
      );
    }
    if (scanningThisMode && scan == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE6E8E0)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Scanning $_folderImagesScanned image files…'),
            ),
          ],
        ),
      );
    }
    if (scan == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: const Color(0xFFEEF3E8),
            border: Border.all(color: const Color(0xFFDDE7D4)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.folder_open_outlined, color: _green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      scan.folderName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    onPressed: _scanningFolder
                        ? null
                        : bestShots
                        ? _scanBestShotsFolder
                        : _scanFolder,
                    child: const Text('Change'),
                  ),
                ],
              ),
              Text(
                scan.duplicateGroups.isEmpty
                    ? (bestShots
                          ? 'Scanned ${scan.imagesScanned} images from ${scan.dateRange.label.toLowerCase()}. No similar shots found.${_skippedNote(scan.imagesSkipped)}'
                          : 'Scanned ${scan.imagesScanned} images from ${scan.dateRange.label.toLowerCase()}. No exact duplicates found.${_skippedNote(scan.imagesSkipped)}')
                    : 'Scanned ${scan.imagesScanned} images · ${scan.duplicateGroups.length} $groupLabel · ${scan.dateRange.label}${_skippedNote(scan.imagesSkipped)}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF596252)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _spaceRecoverySummary(scan, bestShots: bestShots),
        if (bestShots && scan.duplicateGroups.isNotEmpty)
          _similarReviewNote(scan),
        if (_scanRemovals(scan, bestShots: bestShots).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.tonalIcon(
              onPressed: _scanningFolder
                  ? null
                  : () => _deleteAllScanRemovables(bestShots: bestShots),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text(
                bestShots
                    ? 'Delete lower-ranked photos in ${_bulkGroups(scan, bestShots: true).length} confident group${_bulkGroups(scan, bestShots: true).length == 1 ? '' : 's'}'
                    : 'Delete all duplicates',
              ),
              style: FilledButton.styleFrom(foregroundColor: _ink),
            ),
          ),
        if (scan.duplicateGroups.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFE6E8E0)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                bestShots
                    ? 'No similar photo groups found. PictoIQ groups visually alike shots and ranks face quality when faces are detected.'
                    : 'No exact duplicate photos found. Exact duplicates have identical file contents.',
                style: TextStyle(color: Color(0xFF77796F)),
              ),
            ),
          )
        else
          ...scan.duplicateGroups.map(
            bestShots ? _folderDuplicateCard : _exactDuplicateCard,
          ),
      ],
    );
  }

  Widget _spaceRecoverySummary(
    FolderScanResult scan, {
    required bool bestShots,
  }) {
    final removable = _scanRemovals(scan, bestShots: bestShots);
    final photos = removable.length;
    final recoverableBytes = removable.fold<int>(
      0,
      (total, photo) => total + photo.size,
    );
    final needReview = _groupsNeedingReview(scan, bestShots: bestShots);
    final description = photos == 0
        ? (scan.duplicateGroups.isEmpty
              ? 'No removable copies found in this folder.'
              : 'Nothing is ready for automatic cleanup; review each group below.')
        : bestShots
        ? 'Ready now: $photos similar photos in confident groups. ${needReview == 0 ? 'Review groups before deleting.' : '$needReview group${needReview == 1 ? '' : 's'} need${needReview == 1 ? 's' : ''} your review.'}'
        : 'Potential from $photos exact copies; review groups before deleting.';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F3E8),
        border: Border.all(color: const Color(0xFFD2E5D1)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.storage_rounded, color: _green, size: 23),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Potential space to recover',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF596252),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatBytes(recoverableBytes),
            style: const TextStyle(
              color: _green,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _recoveryEstimate(int bytes) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFE8F3E8),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      'Estimated space to recover: up to ${_formatBytes(bytes)}',
      style: const TextStyle(fontWeight: FontWeight.w700, color: _green),
    ),
  );

  Widget _exactDuplicateCard(FolderDuplicateGroup group) {
    final keepIds = {
      for (final kept in _groupKeepers(group, bestShots: false)) kept.uri,
    };
    final recoverableBytes = _groupRecoveryBytes(group, bestShots: false);
    return Card(
      margin: const EdgeInsets.only(top: 8),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFFE6E8E0)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${group.photos.length} identical photos',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            const Text(
              'Tap a thumbnail to inspect it before deleting copies.',
              style: TextStyle(fontSize: 11, color: Color(0xFF77796F)),
            ),
            const SizedBox(height: 6),
            for (final photo in group.oldestFirst)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(
                      keepIds.contains(photo.uri)
                          ? Icons.check_circle_outline
                          : Icons.copy_outlined,
                      size: 18,
                      color: keepIds.contains(photo.uri)
                          ? _green
                          : const Color(0xFFB37957),
                    ),
                    const SizedBox(width: 8),
                    _exactDuplicateThumbnail(photo),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            photo.relativePath,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${keepIds.contains(photo.uri) ? 'Keep this copy' : 'Duplicate copy'} · ${_formatDate(photo.modifiedDate)} · ${_formatBytes(photo.size)}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF85877F),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _photoRatingButtons(photo.uri),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _scanningFolder
                    ? null
                    : () => _deleteNewerCopies(group),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(
                  'Keep selected · recover up to ${_formatBytes(recoverableBytes)}',
                ),
                style: FilledButton.styleFrom(foregroundColor: _ink),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _exactDuplicateThumbnail(FolderScanPhoto photo) {
    final preview = photo.previewBytes;
    return Tooltip(
      message: preview == null ? 'Preview unavailable' : 'Tap to enlarge',
      child: InkWell(
        onTap: preview == null ? null : () => _showExactPhotoPreview(photo),
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 68,
            height: 68,
            child: preview == null
                ? const ColoredBox(
                    color: Color(0xFFF0F1EC),
                    child: Icon(Icons.image_not_supported_outlined),
                  )
                : Image.memory(
                    preview,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Color(0xFFF0F1EC),
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _showExactPhotoPreview(FolderScanPhoto photo) async {
    final preview = photo.previewBytes;
    if (preview == null) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                photo.relativePath,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(dialogContext).height * .65,
                ),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Image.memory(preview, fit: BoxFit.contain),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _confidenceChip(SimilarityEvidence evidence) {
    final (color, background) = switch (evidence.confidence) {
      SimilarityConfidence.high => (_green, const Color(0xFFE8F3E8)),
      SimilarityConfidence.medium => (
        const Color(0xFF7A5200),
        const Color(0xFFFFF4E0),
      ),
      SimilarityConfidence.low => (
        const Color(0xFF9A3F2F),
        const Color(0xFFFBE9E5),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${evidence.confidence.label} match',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  /// Tells the user how many similar-photo groups were left for them.
  Widget _similarReviewNote(FolderScanResult scan) {
    final review = _groupsNeedingReview(scan, bestShots: true);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        review == 0
            ? 'Similar photos are grouped by appearance and timing. They are not guaranteed duplicates, so check each group before deleting.'
            : '$review of ${scan.duplicateGroups.length} groups are not matched confidently enough to clean up in bulk. Open them to choose what to keep.',
        style: const TextStyle(fontSize: 11, color: Color(0xFF77796F)),
      ),
    );
  }

  Widget _folderDuplicateCard(FolderDuplicateGroup group) {
    final decision = _decisionFor(group, bestShots: true);
    final evidence = group.evidence;
    final recoverableBytes = _groupRecoveryBytes(group, bestShots: true);
    final removeIds = {
      for (final photo in _groupRemovals(group, bestShots: true)) photo.uri,
    };
    final keepIds = decision.keepIds;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFFE6E8E0)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${group.photos.length} similar photos',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (evidence != null) _confidenceChip(evidence),
              ],
            ),
            if (evidence != null) ...[
              const SizedBox(height: 4),
              Text(
                evidence.notes.join(' · '),
                style: const TextStyle(fontSize: 10, color: Color(0xFF85877F)),
              ),
            ],
            if (group.ranking != null) ...[
              const SizedBox(height: 6),
              Text(
                group.ranking!.headline,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
            if (decision.needsReview) ...[
              const SizedBox(height: 6),
              Text(
                _reviewReason(group),
                style: const TextStyle(fontSize: 11, color: Color(0xFF7A5200)),
              ),
            ],
            const SizedBox(height: 6),
            for (final photo in group.bestFirst)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (photo.previewBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.memory(
                          photo.previewBytes!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            width: 56,
                            height: 56,
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      )
                    else
                      const SizedBox(
                        width: 56,
                        height: 56,
                        child: Icon(Icons.image_not_supported_outlined),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            photo.relativePath,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${_stateLabel(photo.uri, keepIds, removeIds, decision)} · ${_shotSummary(group, photo)}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF85877F),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _photoRatingButtons(photo.uri),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => _showCompareShots(group),
                  icon: const Icon(Icons.compare_outlined, size: 18),
                  label: const Text('Compare'),
                ),
                if (group.photos.any((p) => _photoRating(p.uri) != 0))
                  TextButton(
                    onPressed: () => _clearGroupMarks(group),
                    child: const Text('Reset my choices'),
                  ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: decision.hasDecision
                  ? FilledButton.tonalIcon(
                      onPressed: _scanningFolder
                          ? null
                          : () => _deleteSimilarShots(group),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(
                        'Keep ${_keptSummary(_groupKeepers(group, bestShots: true))} · recover up to ${_formatBytes(recoverableBytes)}',
                      ),
                      style: FilledButton.styleFrom(foregroundColor: _ink),
                    )
                  : const Text(
                      'Give a thumbs-up to the photo you want to keep.',
                      style: TextStyle(fontSize: 11, color: Color(0xFF77796F)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Marks [uri] as the only photo to keep in [group]: a thumbs-up for it and
  /// no marks on the others, so every other photo becomes a removal candidate
  /// only after the user confirms the delete dialog.
  void _chooseKeeper(FolderDuplicateGroup group, String uri) {
    setState(() {
      for (final photo in group.photos) {
        _photoRatings[photo.uri] = photo.uri == uri ? 1 : 0;
      }
    });
  }

  /// Removes the user's thumbs-up and thumbs-down marks from [group], which
  /// returns it to PictoIQ's suggestion (or to nothing in manual mode).
  void _clearGroupMarks(FolderDuplicateGroup group) {
    setState(() {
      for (final photo in group.photos) {
        _photoRatings.remove(photo.uri);
      }
    });
  }

  String _percent(double value) => '${(value * 100).round()}%';

  /// Side-by-side view of every photo in a similar-photo group, with the
  /// measurements and reasons behind the ranking and a way to override it.
  Future<void> _showCompareShots(FolderDuplicateGroup group) {
    final ranking = group.ranking;
    final bestSharpness = ranking == null || ranking.shots.isEmpty
        ? 0.0
        : ranking.shots
              .map((shot) => shot.features.signals.sharpness)
              .reduce((a, b) => a > b ? a : b);
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Compare ${group.photos.length} similar photos',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ranking == null
                      ? 'No ranking is available for this group.'
                      : '${ranking.headline}. Scores compare these photos with each other only; they are not a rating of the photo itself.',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF77796F)),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final photo in group.bestFirst)
                          _compareColumn(
                            group,
                            photo,
                            bestSharpness,
                            dialogContext,
                            setDialogState,
                          ),
                      ],
                    ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _compareColumn(
    FolderDuplicateGroup group,
    FolderScanPhoto photo,
    double bestSharpness,
    BuildContext dialogContext,
    StateSetter setDialogState,
  ) {
    final shot = group.ranking?.shotFor(photo.uri);
    final features = shot?.features ?? photo.features;
    final signals = features?.signals;
    final faces = features?.faces;
    final chosen = _photoRating(photo.uri) > 0;
    Widget line(IconData icon, Color color, String text) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 11))),
        ],
      ),
    );
    return Container(
      width: 210,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: chosen ? _green : const Color(0xFFE6E8E0),
          width: chosen ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (photo.previewBytes != null)
            InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Image.memory(
                photo.previewBytes!,
                height: 170,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 170,
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            )
          else
            const SizedBox(
              height: 170,
              child: Center(child: Icon(Icons.image_not_supported_outlined)),
            ),
          const SizedBox(height: 6),
          Text(
            shot == null
                ? photo.relativePath
                : '#${shot.rank} · ${shot.score}/100',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            photo.relativePath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Color(0xFF85877F)),
          ),
          if (shot != null) ...[
            for (final reason in shot.strengths)
              line(Icons.check_circle_outline, _green, reason),
            for (final reason in shot.concerns)
              line(
                Icons.error_outline,
                const Color(0xFFB37957),
                reason,
              ),
          ],
          const Divider(height: 14),
          if (signals != null && bestSharpness > 0)
            Text(
              'Sharpness ${_percent(signals.sharpness / bestSharpness)} of best',
              style: const TextStyle(fontSize: 10, color: Color(0xFF85877F)),
            ),
          if (features != null && features.megapixels > 0)
            Text(
              '${features.megapixels.toStringAsFixed(1)} MP · ${_formatBytes(photo.size)}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF85877F)),
            ),
          if (signals != null)
            Text(
              'Brightness ${_percent(signals.meanLuma / 255)}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF85877F)),
            ),
          if (faces != null)
            Text(
              faces.count == 0
                  ? 'No faces found'
                  : '${faces.count} face${faces.count == 1 ? '' : 's'}'
                        '${faces.eyesOpenMin == null ? '' : ' · eyes open ${_percent(faces.eyesOpenMin!)}'}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF85877F)),
            ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: chosen
                ? OutlinedButton.icon(
                    onPressed: () {
                      _setPhotoRating(photo.uri, 1);
                      setDialogState(() {});
                    },
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Your pick · tap to undo'),
                  )
                : FilledButton.tonal(
                    onPressed: () {
                      _chooseKeeper(group, photo.uri);
                      setDialogState(() {});
                    },
                    child: const Text('Keep this one'),
                  ),
          ),
        ],
      ),
    );
  }

  String _stateLabel(
    String uri,
    Set<String> keepIds,
    Set<String> removeIds,
    KeepDecision decision,
  ) {
    if (keepIds.contains(uri)) {
      return decision.isUserChoice ? 'Kept: your pick' : 'Suggested to keep';
    }
    if (removeIds.contains(uri)) return 'Would be deleted';
    return 'Not selected';
  }

  String _keptSummary(List<FolderScanPhoto> keepers) {
    if (keepers.isEmpty) return 'nothing';
    if (keepers.length == 1) return '"${keepers.first.relativePath}"';
    return '${keepers.length} photos';
  }

  String _shotSummary(FolderDuplicateGroup group, FolderScanPhoto photo) {
    final shot = group.ranking?.shotFor(photo.uri);
    if (shot == null) return 'Quality ${photo.qualityScore}/100';
    return '#${shot.rank} · ${shot.summary}';
  }

  /// Why [group] is not safe to clean up without a person looking at it.
  String _reviewReason(FolderDuplicateGroup group) {
    final evidence = group.evidence;
    if (_settings.manualSelectionOnly) {
      return 'You chose to pick photos yourself, so nothing is selected automatically.';
    }
    if (evidence != null && evidence.confidence != SimilarityConfidence.high) {
      return '${evidence.confidence.label} confidence: these may be different shots of the same place. Look at them before deleting.';
    }
    return 'No photo is clearly better than the others. Look at them before deleting.';
  }

  Widget _emptyState() => Container(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 26),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .65),
      border: Border.all(color: const Color(0xFFE0E4D8)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            color: const Color(0xFFEEF2E8),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Icon(
            Icons.photo_library_outlined,
            size: 38,
            color: _green,
          ),
        ),
        const SizedBox(height: 15),
        const Text(
          'Your next favorite is waiting.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 7),
        const Text(
          'Choose a few photos to start your private library. PictoIQ will find exact matches right on this device.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF81847A), fontSize: 12, height: 1.5),
        ),
      ],
    ),
  );

  Widget _photoCard(PhotoAsset photo, bool isDuplicate) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE6E8E0)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(photo.path),
                fit: BoxFit.cover,
                cacheWidth: 600,
                errorBuilder: (context, error, stack) => const ColoredBox(
                  color: Color(0xFFE9ECDF),
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    color: _green,
                    size: 32,
                  ),
                ),
              ),
              if (isDuplicate)
                Positioned(
                  left: 7,
                  top: 7,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .92),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Exact match',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF75523E),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 3,
                top: 3,
                child: IconButton.filledTonal(
                  onPressed: () => _removePhoto(photo),
                  tooltip: 'Remove from library',
                  icon: const Icon(Icons.close, size: 17),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: .9),
                    minimumSize: const Size(34, 34),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                photo.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_formatDate(photo.modifiedAt)} · ${_formatBytes(photo.size)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF92948A), fontSize: 9),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: _photoRatingButtons('library:${photo.id}'),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _footer() => Row(
    children: [
      const Icon(Icons.lock_outline, color: _green, size: 15),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          'No account. No uploads. Your choice.',
          style: TextStyle(color: _ink.withValues(alpha: .55), fontSize: 10),
        ),
      ),
      TextButton(
        onPressed: _showPrivacy,
        child: const Text('Privacy details', style: TextStyle(fontSize: 11)),
      ),
    ],
  );

  Future<void> _showSettings() => showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        icon: const Icon(Icons.tune, color: _green),
        title: const Text('Similar-shot settings'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('I choose which photos to keep'),
                  subtitle: const Text(
                    'PictoIQ never picks a photo to keep in similar-shot groups. Nothing is selected for deletion until you give a photo a thumbs-up.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _settings.manualSelectionOnly,
                  onChanged: (value) {
                    _updateSettings(
                      _settings.copyWith(manualSelectionOnly: value),
                    );
                    setDialogState(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use faces and eyes when ranking'),
                  subtitle: const Text(
                    'Detects faces on this device to prefer open eyes and smiles. Turn off for faster scans that rank on sharpness, lighting and resolution only. Applies to the next scan.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _settings.useFaceSignals,
                  onChanged: (value) {
                    _updateSettings(_settings.copyWith(useFaceSignals: value));
                    setDialogState(() {});
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );

  Future<void> _showPrivacy() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.shield_outlined, color: _green),
      title: const Text('Your photos stay on this device.'),
      content: const Text(
        'PictoIQ uses the system photo picker. It copies only the photos you choose into private app storage, then calculates fingerprints on your device. There are no accounts or uploads. Removing a photo from PictoIQ deletes its private copy, not the original in your gallery.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}

String _skippedNote(int skipped) => skipped == 0
    ? ''
    : ' $skipped skipped (unreadable or unsupported format; never deleted).';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
}

String _sortLabel(_PhotoSort sort) => switch (sort) {
  _PhotoSort.recent => 'Recent',
  _PhotoSort.name => 'Name',
  _PhotoSort.largest => 'Largest',
};

String _formatDate(DateTime? date) {
  if (date == null) return 'Date unknown';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
