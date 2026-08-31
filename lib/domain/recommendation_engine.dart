import 'media_models.dart';

class RecommendationEngine {
  const RecommendationEngine();

  RecommendationResult rank(
    Iterable<StreamCandidate> candidates,
    DownloadPreferences preferences,
  ) {
    final ranked = candidates
        .map((candidate) => _evaluate(candidate, preferences))
        .toList();
    ranked.sort(_compare);
    return RecommendationResult(List.unmodifiable(ranked));
  }

  RankedCandidate _evaluate(
    StreamCandidate candidate,
    DownloadPreferences preferences,
  ) {
    var score = 0;
    final reasons = <String>[];
    final rejections = <String>[];

    final blocked = candidate.releaseTags.intersection(
      preferences.blockedReleaseTags,
    );
    if (blocked.isNotEmpty) {
      rejections.add('Blocked release type: ${blocked.join(', ')}');
    }

    if (preferences.cachedOnly && candidate.cacheStatus != CacheStatus.cached) {
      rejections.add('Not confirmed as instantly cached');
    }
    if (candidate.cacheStatus == CacheStatus.cached) {
      score += 1000;
      reasons.add('Instantly cached on TorBox');
    }

    final size = candidate.sizeBytes;
    if (size != null && size > preferences.maximumSizeBytes) {
      rejections.add(
        'Over size limit (${candidate.sizeLabel}, limit ${_sizeLabel(preferences.maximumSizeBytes)})',
      );
    }

    final resolution = candidate.resolution;
    if (resolution == null) {
      score -= 120;
      reasons.add('Resolution is not labelled');
    } else {
      if (resolution.height < preferences.minimumResolution.height ||
          resolution.height > preferences.maximumResolution.height) {
        rejections.add(
          '${resolution.label} is outside the allowed quality range',
        );
      }
      final distance =
          (resolution.height - preferences.preferredResolution.height).abs();
      if (distance == 0) {
        score += 400;
        reasons.add('Matches preferred ${resolution.label} quality');
      } else {
        score += (250 - (distance / 5).round()).clamp(-100, 250);
        reasons.add('${resolution.label} available');
      }
    }

    final audioRank = _firstLanguageRank(
      candidate.audioLanguages,
      preferences.audioLanguageOrder,
    );
    if (audioRank != null) {
      score += 260 - (audioRank * 45);
      reasons.add(
        '${preferences.audioLanguageOrder[audioRank]} audio detected',
      );
    } else if (candidate.audioLanguages.isEmpty &&
        preferences.allowUnknownAudio) {
      score -= 40;
      reasons.add('Audio language is not labelled');
    } else if (preferences.requirePreferredAudio) {
      rejections.add('Preferred audio language is unavailable');
    } else {
      score -= 160;
    }

    final subtitleRank = _firstLanguageRank(
      candidate.subtitleLanguages,
      preferences.subtitleLanguageOrder,
    );
    if (subtitleRank != null) {
      score += 120 - (subtitleRank * 25);
      reasons.add(
        '${preferences.subtitleLanguageOrder[subtitleRank]} subtitles detected',
      );
    }

    final codecRank = preferences.codecOrder.indexOf(candidate.codec);
    if (codecRank >= 0) {
      score += 140 - (codecRank * 35);
      if (candidate.codec != VideoCodec.unknown) {
        reasons.add('${candidate.codec.label} codec preferred');
      }
    }

    if (preferences.preferHdr) {
      if (candidate.hdr != HdrFormat.sdr &&
          candidate.hdr != HdrFormat.unknown) {
        score += 80;
        reasons.add('${candidate.hdr.label} presentation');
      }
    } else if (candidate.hdr == HdrFormat.sdr) {
      score += 20;
    }

    if (candidate.releaseTags.contains('remux')) {
      score += 50;
      reasons.add('Remux source');
    } else if (candidate.releaseTags.contains('bluray')) {
      score += 40;
    } else if (candidate.releaseTags.contains('webdl')) {
      score += 30;
    }

    if (size != null && preferences.maximumSizeBytes > 0) {
      final ratio = size / preferences.maximumSizeBytes;
      score += (60 * (1 - ratio.clamp(0, 1))).round();
    }

    return RankedCandidate(
      candidate: candidate,
      score: score,
      reasons: List.unmodifiable(reasons),
      rejections: List.unmodifiable(rejections),
    );
  }

  int? _firstLanguageRank(Set<String> available, List<String> preferred) {
    for (var i = 0; i < preferred.length; i++) {
      if (available.contains(preferred[i])) return i;
    }
    return null;
  }

  int _compare(RankedCandidate a, RankedCandidate b) {
    final eligibility = b.isEligible.toString().compareTo(
      a.isEligible.toString(),
    );
    if (eligibility != 0) return eligibility;
    final score = b.score.compareTo(a.score);
    if (score != 0) return score;
    final cache = a.candidate.cacheStatus.index.compareTo(
      b.candidate.cacheStatus.index,
    );
    if (cache != 0) return cache;
    final aSize = a.candidate.sizeBytes ?? 1 << 62;
    final bSize = b.candidate.sizeBytes ?? 1 << 62;
    final size = aSize.compareTo(bSize);
    if (size != 0) return size;
    return a.candidate.id.compareTo(b.candidate.id);
  }

  String _sizeLabel(int bytes) {
    final gb = bytes / 1000000000;
    return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} GB';
  }
}
