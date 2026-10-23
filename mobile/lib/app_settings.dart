import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Preferences that outlive one run of the app.
class AppSettings {
  const AppSettings({
    this.manualSelectionOnly = false,
    this.useFaceSignals = true,
  });

  /// When true, PictoIQ never picks a similar photo to keep: the user marks
  /// the ones to keep, and nothing is selected for deletion until they do.
  final bool manualSelectionOnly;

  /// Whether face and eye detection feed the best-shot ranking. Turning it off
  /// makes scans faster and ranks on sharpness, lighting and resolution only.
  final bool useFaceSignals;

  AppSettings copyWith({bool? manualSelectionOnly, bool? useFaceSignals}) =>
      AppSettings(
        manualSelectionOnly: manualSelectionOnly ?? this.manualSelectionOnly,
        useFaceSignals: useFaceSignals ?? this.useFaceSignals,
      );

  Map<String, Object?> toJson() => {
    'manualSelectionOnly': manualSelectionOnly,
    'useFaceSignals': useFaceSignals,
  };

  /// Unknown or wrongly typed fields fall back to their defaults.
  factory AppSettings.fromJson(Map<String, Object?> json) {
    const defaults = AppSettings();
    final manual = json['manualSelectionOnly'];
    final faces = json['useFaceSignals'];
    return AppSettings(
      manualSelectionOnly: manual is bool
          ? manual
          : defaults.manualSelectionOnly,
      useFaceSignals: faces is bool ? faces : defaults.useFaceSignals,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.manualSelectionOnly == manualSelectionOnly &&
      other.useFaceSignals == useFaceSignals;

  @override
  int get hashCode => Object.hash(manualSelectionOnly, useFaceSignals);
}

/// Keeps [AppSettings] in a small JSON file in the app's private storage.
class SettingsStore {
  SettingsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, 'pictoiq_settings.json'));

  /// Returns the defaults when nothing was saved or the file is unreadable.
  Future<AppSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const AppSettings();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return const AppSettings();
      return AppSettings.fromJson(decoded);
    } catch (error) {
      debugPrint('Settings unavailable: ${error.runtimeType}');
      return const AppSettings();
    }
  }

  /// Writes to a temporary file first so a crash cannot leave half a file.
  Future<void> save(AppSettings settings) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
