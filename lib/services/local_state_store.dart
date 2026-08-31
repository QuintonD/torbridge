import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/media_models.dart';

class StoredLocalState {
  const StoredLocalState({
    this.preferences = const DownloadPreferences(
      subtitleLanguageOrder: ['Dutch', 'English'],
    ),
    this.watchedTitleIds = const {},
    this.downloadRecords = const [],
  });

  final DownloadPreferences preferences;
  final Set<String> watchedTitleIds;
  final List<Map<String, dynamic>> downloadRecords;
}

abstract class LocalStateStore {
  Future<StoredLocalState> read();

  Future<void> savePreferences(DownloadPreferences preferences);

  Future<void> saveWatched(Set<String> titleIds);

  Future<void> saveDownloadRecords(List<Map<String, dynamic>> records);
}

class SharedPreferencesLocalStateStore implements LocalStateStore {
  static const _preferencesKey = 'download_preferences_v1';
  static const _watchedKey = 'watched_title_ids_v1';
  static const _downloadsKey = 'completed_downloads_v1';

  @override
  Future<StoredLocalState> read() async {
    final storage = await SharedPreferences.getInstance();
    final preferencesJson = storage.getString(_preferencesKey);
    final preferences = preferencesJson == null
        ? const StoredLocalState().preferences
        : _preferencesFromJson(
            Map<String, dynamic>.from(jsonDecode(preferencesJson) as Map),
          );
    final downloadsJson = storage.getString(_downloadsKey);
    final downloadsValue = downloadsJson == null
        ? const <Object?>[]
        : jsonDecode(downloadsJson) as List;
    return StoredLocalState(
      preferences: preferences,
      watchedTitleIds: storage.getStringList(_watchedKey)?.toSet() ?? const {},
      downloadRecords: downloadsValue
          .whereType<Map>()
          .map((record) => Map<String, dynamic>.from(record))
          .toList(growable: false),
    );
  }

  @override
  Future<void> savePreferences(DownloadPreferences preferences) async {
    final storage = await SharedPreferences.getInstance();
    await storage.setString(
      _preferencesKey,
      jsonEncode(_preferencesToJson(preferences)),
    );
  }

  @override
  Future<void> saveWatched(Set<String> titleIds) async {
    final storage = await SharedPreferences.getInstance();
    final sorted = titleIds.toList()..sort();
    await storage.setStringList(_watchedKey, sorted);
  }

  @override
  Future<void> saveDownloadRecords(List<Map<String, dynamic>> records) async {
    final storage = await SharedPreferences.getInstance();
    await storage.setString(_downloadsKey, jsonEncode(records));
  }

  Map<String, dynamic> _preferencesToJson(DownloadPreferences value) => {
    'audioLanguageOrder': value.audioLanguageOrder,
    'subtitleLanguageOrder': value.subtitleLanguageOrder,
    'preferredResolution': value.preferredResolution.name,
    'minimumResolution': value.minimumResolution.name,
    'maximumResolution': value.maximumResolution.name,
    'codecOrder': value.codecOrder.map((codec) => codec.name).toList(),
    'preferHdr': value.preferHdr,
    'cachedOnly': value.cachedOnly,
    'requirePreferredAudio': value.requirePreferredAudio,
    'allowUnknownAudio': value.allowUnknownAudio,
    'maximumSizeBytes': value.maximumSizeBytes,
    'blockedReleaseTags': value.blockedReleaseTags.toList(),
  };

  DownloadPreferences _preferencesFromJson(Map<String, dynamic> json) {
    final defaults = const StoredLocalState().preferences;
    return DownloadPreferences(
      audioLanguageOrder: _strings(
        json['audioLanguageOrder'],
        defaults.audioLanguageOrder,
      ),
      subtitleLanguageOrder: _strings(
        json['subtitleLanguageOrder'],
        defaults.subtitleLanguageOrder,
      ),
      preferredResolution: _enumByName(
        VideoResolution.values,
        json['preferredResolution'],
        defaults.preferredResolution,
      ),
      minimumResolution: _enumByName(
        VideoResolution.values,
        json['minimumResolution'],
        defaults.minimumResolution,
      ),
      maximumResolution: _enumByName(
        VideoResolution.values,
        json['maximumResolution'],
        defaults.maximumResolution,
      ),
      codecOrder: _enumList(
        VideoCodec.values,
        json['codecOrder'],
        defaults.codecOrder,
      ),
      preferHdr: json['preferHdr'] as bool? ?? defaults.preferHdr,
      cachedOnly: json['cachedOnly'] as bool? ?? defaults.cachedOnly,
      requirePreferredAudio:
          json['requirePreferredAudio'] as bool? ??
          defaults.requirePreferredAudio,
      allowUnknownAudio:
          json['allowUnknownAudio'] as bool? ?? defaults.allowUnknownAudio,
      maximumSizeBytes:
          (json['maximumSizeBytes'] as num?)?.toInt() ??
          defaults.maximumSizeBytes,
      blockedReleaseTags: _strings(
        json['blockedReleaseTags'],
        defaults.blockedReleaseTags.toList(),
      ).toSet(),
    );
  }

  List<String> _strings(Object? value, List<String> fallback) {
    if (value is! List) return fallback;
    final result = value.whereType<String>().toList(growable: false);
    return result.isEmpty ? fallback : result;
  }

  T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  List<T> _enumList<T extends Enum>(
    List<T> values,
    Object? names,
    List<T> fallback,
  ) {
    if (names is! List) return fallback;
    final result = <T>[];
    for (final name in names) {
      for (final value in values) {
        if (value.name == name) result.add(value);
      }
    }
    return result.isEmpty ? fallback : result;
  }
}
