enum VideoResolution {
  sd(480, 'SD'),
  hd720(720, '720p'),
  fullHd1080(1080, '1080p'),
  ultraHd2160(2160, '4K');

  const VideoResolution(this.height, this.label);

  final int height;
  final String label;
}

enum VideoCodec {
  av1('AV1'),
  hevc('HEVC'),
  h264('H.264'),
  unknown('Unknown');

  const VideoCodec(this.label);

  final String label;
}

enum HdrFormat {
  dolbyVision('Dolby Vision'),
  hdr10Plus('HDR10+'),
  hdr10('HDR10'),
  sdr('SDR'),
  unknown('Unknown');

  const HdrFormat(this.label);

  final String label;
}

enum CacheStatus {
  cached('Instant'),
  uncached('Needs caching'),
  unknown('Unknown');

  const CacheStatus(this.label);

  final String label;
}

class StreamCandidate {
  const StreamCandidate({
    required this.id,
    required this.addonName,
    required this.displayName,
    required this.description,
    required this.resolution,
    required this.codec,
    required this.hdr,
    required this.cacheStatus,
    required this.audioLanguages,
    required this.subtitleLanguages,
    required this.sizeBytes,
    required this.releaseTags,
    this.streamUrl,
    this.infoHash,
    this.fileIndex,
  });

  final String id;
  final String addonName;
  final String displayName;
  final String description;
  final VideoResolution? resolution;
  final VideoCodec codec;
  final HdrFormat hdr;
  final CacheStatus cacheStatus;
  final Set<String> audioLanguages;
  final Set<String> subtitleLanguages;
  final int? sizeBytes;
  final Set<String> releaseTags;
  final Uri? streamUrl;
  final String? infoHash;
  final int? fileIndex;

  StreamCandidate copyWith({CacheStatus? cacheStatus}) {
    return StreamCandidate(
      id: id,
      addonName: addonName,
      displayName: displayName,
      description: description,
      resolution: resolution,
      codec: codec,
      hdr: hdr,
      cacheStatus: cacheStatus ?? this.cacheStatus,
      audioLanguages: audioLanguages,
      subtitleLanguages: subtitleLanguages,
      sizeBytes: sizeBytes,
      releaseTags: releaseTags,
      streamUrl: streamUrl,
      infoHash: infoHash,
      fileIndex: fileIndex,
    );
  }

  String get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null) return 'Size unknown';
    final gb = bytes / 1000000000;
    if (gb >= 1) return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} GB';
    return '${(bytes / 1000000).round()} MB';
  }
}

class DownloadPreferences {
  const DownloadPreferences({
    this.audioLanguageOrder = const ['English'],
    this.subtitleLanguageOrder = const ['English'],
    this.preferredResolution = VideoResolution.fullHd1080,
    this.minimumResolution = VideoResolution.hd720,
    this.maximumResolution = VideoResolution.ultraHd2160,
    this.codecOrder = const [
      VideoCodec.hevc,
      VideoCodec.av1,
      VideoCodec.h264,
      VideoCodec.unknown,
    ],
    this.preferHdr = false,
    this.cachedOnly = true,
    this.requirePreferredAudio = false,
    this.allowUnknownAudio = true,
    this.maximumSizeBytes = 20000000000,
    this.blockedReleaseTags = const {'cam', 'telesync', 'screener'},
  });

  final List<String> audioLanguageOrder;
  final List<String> subtitleLanguageOrder;
  final VideoResolution preferredResolution;
  final VideoResolution minimumResolution;
  final VideoResolution maximumResolution;
  final List<VideoCodec> codecOrder;
  final bool preferHdr;
  final bool cachedOnly;
  final bool requirePreferredAudio;
  final bool allowUnknownAudio;
  final int maximumSizeBytes;
  final Set<String> blockedReleaseTags;

  DownloadPreferences copyWith({
    List<String>? audioLanguageOrder,
    List<String>? subtitleLanguageOrder,
    VideoResolution? preferredResolution,
    VideoResolution? minimumResolution,
    VideoResolution? maximumResolution,
    List<VideoCodec>? codecOrder,
    bool? preferHdr,
    bool? cachedOnly,
    bool? requirePreferredAudio,
    bool? allowUnknownAudio,
    int? maximumSizeBytes,
    Set<String>? blockedReleaseTags,
  }) {
    return DownloadPreferences(
      audioLanguageOrder: audioLanguageOrder ?? this.audioLanguageOrder,
      subtitleLanguageOrder:
          subtitleLanguageOrder ?? this.subtitleLanguageOrder,
      preferredResolution: preferredResolution ?? this.preferredResolution,
      minimumResolution: minimumResolution ?? this.minimumResolution,
      maximumResolution: maximumResolution ?? this.maximumResolution,
      codecOrder: codecOrder ?? this.codecOrder,
      preferHdr: preferHdr ?? this.preferHdr,
      cachedOnly: cachedOnly ?? this.cachedOnly,
      requirePreferredAudio:
          requirePreferredAudio ?? this.requirePreferredAudio,
      allowUnknownAudio: allowUnknownAudio ?? this.allowUnknownAudio,
      maximumSizeBytes: maximumSizeBytes ?? this.maximumSizeBytes,
      blockedReleaseTags: blockedReleaseTags ?? this.blockedReleaseTags,
    );
  }
}

class RankedCandidate {
  const RankedCandidate({
    required this.candidate,
    required this.score,
    required this.reasons,
    required this.rejections,
  });

  final StreamCandidate candidate;
  final int score;
  final List<String> reasons;
  final List<String> rejections;

  bool get isEligible => rejections.isEmpty;
}

class RecommendationResult {
  const RecommendationResult(this.ranked);

  final List<RankedCandidate> ranked;

  RankedCandidate? get best {
    for (final item in ranked) {
      if (item.isEligible) return item;
    }
    return null;
  }

  List<RankedCandidate> get alternatives =>
      ranked.where((item) => item.isEligible).skip(1).toList(growable: false);

  List<RankedCandidate> get rejected =>
      ranked.where((item) => !item.isEligible).toList(growable: false);
}
