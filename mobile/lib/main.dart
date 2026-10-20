import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'folder_duplicate_scanner.dart';
import 'library_store.dart';
import 'photo_asset.dart';

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
  final _searchController = TextEditingController();
  final _libraryHeadingKey = GlobalKey();
  List<PhotoAsset> _photos = [];
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

  Future<void> _runFolderScan({required bool bestShots}) async {
    if (!Platform.isAndroid || _scanningFolder || _importing) return;
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
      final result =
          await (bestShots
              ? _folderScanner.pickAndScanBestShots
              : _folderScanner.pickAndScan)(
            onProgress: (count) {
              if (mounted) setState(() => _folderImagesScanned = count);
            },
          );
      if (!mounted) return;
      if (result != null) {
        setState(() {
          if (bestShots) {
            _bestShotsScan = result;
          } else {
            _folderScan = result;
          }
        });
        _scrollToLibrary();
        _showMessage(
          result.duplicateGroups.isEmpty
              ? bestShots
                    ? 'Scanned ${result.imagesScanned} photos. No similar shots found.'
                    : 'Scanned ${result.imagesScanned} photos. No exact duplicates found.'
              : bestShots
              ? 'Found ${result.duplicateGroups.length} best-shot groups in ${result.folderName}.'
              : 'Found ${result.duplicateGroups.length} exact duplicate groups in ${result.folderName}.',
        );
      }
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

  void _scrollToLibrary() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _libraryHeadingKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _deleteNewerCopies(FolderDuplicateGroup group) async {
    final scan = _folderScan;
    if (scan == null) return;
    final original = group.original;
    final newerCopies = group.newerCopies;
    final recoverableBytes = _groupReclaimableBytes(group, bestShots: false);
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep the oldest, delete newer copies?'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'This will keep the oldest exact file and delete the newer identical copies listed below. Nothing is deleted until you confirm.',
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
            child: Text('Delete ${newerCopies.length} newer'),
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
        onProgress: (count) {
          if (mounted) setState(() => _folderImagesScanned = count);
        },
      );
      if (!mounted) return;
      setState(() => _folderScan = refreshed);
      _showMessage(
        'Freed about ${_formatBytes(freedBytes)}; kept ${original.name}.',
      );
    } catch (error) {
      if (!mounted) return;
      try {
        final refreshed = await _folderScanner.scanUri(
          scan.folderUri,
          folderName: scan.folderName,
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
    final keeper = group.recommended;
    final remove = group.otherShots;
    final recoverableBytes = _groupReclaimableBytes(group, bestShots: true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep the suggested best shot?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Keep "${keeper.relativePath}" based on the quality signals. The following similar photos will be deleted from "${scan.folderName}":',
              ),
              const SizedBox(height: 10),
              _recoveryEstimate(recoverableBytes),
              const SizedBox(height: 10),
              for (final photo in remove)
                Text(
                  '• ${photo.relativePath} · score ${photo.qualityScore}/100',
                ),
              const SizedBox(height: 10),
              const Text(
                'These are similar shots, not identical duplicates. PictoIQ waits for your confirmation before deleting source files.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete ${remove.length} photos'),
          ),
        ],
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
      );
      if (!mounted) return;
      setState(() => _bestShotsScan = refreshed);
      _showMessage(
        'Freed about ${_formatBytes(freedBytes)}; kept ${keeper.name}.',
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
              sliver: SliverToBoxAdapter(
                child: _header(duplicateGroups.length),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              sliver: SliverToBoxAdapter(child: _privacyBanner()),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              sliver: SliverToBoxAdapter(
                child: _summary(duplicateGroups.length),
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
              sliver: SliverToBoxAdapter(
                key: _libraryHeadingKey,
                child: _libraryHeading(visiblePhotos.length),
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

  Widget _header(int duplicateCount) => Column(
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
        'Scan a folder in place, or add selected photos to your PictoIQ library below.',
        style: TextStyle(color: _ink.withValues(alpha: .66), height: 1.45),
      ),
      if (Platform.isAndroid) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _loading || _importing || _scanningFolder
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
              _scanningFolder
                  ? 'Scanning $_folderImagesScanned photos…'
                  : 'Scan a folder for exact duplicates',
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              foregroundColor: _green,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _loading || _importing || _scanningFolder
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
                  : 'Find the best shots in a folder',
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              foregroundColor: _green,
            ),
          ),
        ),
      ],
    ],
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

  Widget _libraryHeading(int visibleCount) => Row(
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
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFEBEDE6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$visibleCount',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
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
        ? 'best-shot groups'
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
                          ? 'Scanned ${scan.imagesScanned} images. No similar shots found.'
                          : 'Scanned ${scan.imagesScanned} images. No exact duplicates found.')
                    : 'Scanned ${scan.imagesScanned} images · ${scan.duplicateGroups.length} $groupLabel',
                style: const TextStyle(fontSize: 12, color: Color(0xFF596252)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _spaceRecoverySummary(scan, bestShots: bestShots),
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
    final photos = scan.removablePhotos.length;
    final description = photos == 0
        ? 'No removable copies found in this folder.'
        : 'Potential from $photos ${bestShots ? 'similar photos' : 'exact copies'}; review groups before deleting.';

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
            _formatBytes(scan.reclaimableBytes),
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
    final original = group.original;
    final recoverableBytes = _groupReclaimableBytes(group, bestShots: false);
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
                      identical(photo, original)
                          ? Icons.check_circle_outline
                          : Icons.copy_outlined,
                      size: 18,
                      color: identical(photo, original)
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
                            '${identical(photo, original) ? 'Keep original' : 'Newer exact copy'} · ${_formatDate(photo.modifiedDate)} · ${_formatBytes(photo.size)}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF85877F),
                            ),
                          ),
                        ],
                      ),
                    ),
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
                  'Keep oldest · recover up to ${_formatBytes(recoverableBytes)}',
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

  Widget _folderDuplicateCard(FolderDuplicateGroup group) {
    final original = group.recommended;
    final recoverableBytes = _groupReclaimableBytes(group, bestShots: true);
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
              '${group.photos.length} similar photos · suggested best ${original.qualityScore}/100',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
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
                        ),
                      )
                    else
                      Icon(
                        identical(photo, original)
                            ? Icons.check_circle_outline
                            : Icons.copy_outlined,
                        size: 18,
                        color: identical(photo, original)
                            ? _green
                            : const Color(0xFFB37957),
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
                            '${identical(photo, original) ? 'Suggested best · ' : ''}Quality ${photo.qualityScore}/100 · ${photo.qualityNotes.join(' · ')}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF85877F),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _scanningFolder
                    ? null
                    : () => _deleteSimilarShots(group),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(
                  'Keep suggested · recover up to ${_formatBytes(recoverableBytes)}',
                ),
                style: FilledButton.styleFrom(foregroundColor: _ink),
              ),
            ),
          ],
        ),
      ),
    );
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

int _groupReclaimableBytes(
  FolderDuplicateGroup group, {
  required bool bestShots,
}) => (bestShots ? group.otherShots : group.newerCopies).fold(
  0,
  (total, photo) => total + photo.size,
);

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
