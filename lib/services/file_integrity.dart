import 'dart:convert';
import 'dart:io';

class FileInspection {
  const FileInspection(this.state, this.detail, {this.bytes = 0});
  final String state;
  final String detail;
  final int bytes;
  bool get invalid => state == 'invalid' || state == 'missing';
}

/// A bounded structural check. It never claims full decoding or a trusted hash.
FileInspection inspectMediaHeader(
  List<int> header,
  int size, {
  int? expectedBytes,
}) {
  FileInspection result(String state, String detail) =>
      FileInspection(state, detail, bytes: size);
  if (size < 12) {
    return result(
      'invalid',
      'File is empty or too short to contain a supported video. Bytes were preserved.',
    );
  }
  if (expectedBytes != null && expectedBytes > 0 && size != expectedBytes) {
    return result(
      'invalid',
      'File size differs from the recorded transfer size ($size / $expectedBytes bytes). Bytes were preserved.',
    );
  }
  final text = utf8
      .decode(header.take(512).toList(), allowMalformed: true)
      .trimLeft()
      .toLowerCase();
  if (text.startsWith('<!doctype html') ||
      text.startsWith('<html') ||
      text.startsWith('<?xml') ||
      text.startsWith('{') ||
      text.startsWith('[')) {
    return result(
      'invalid',
      'The downloaded file looks like an error page or text response, not a video. Bytes were preserved.',
    );
  }
  bool at(int offset, List<int> magic) =>
      header.length >= offset + magic.length &&
      List.generate(
        magic.length,
        (i) => header[offset + i] == magic[i],
      ).every((v) => v);
  final recognized =
      at(4, 'ftyp'.codeUnits) ||
      at(0, [0x1a, 0x45, 0xdf, 0xa3]) ||
      (at(0, 'RIFF'.codeUnits) && at(8, 'AVI '.codeUnits)) ||
      (at(0, [0x47]) && at(188, [0x47]) && at(376, [0x47]));
  return result(
    recognized ? 'structural' : 'unverified',
    recognized
        ? 'Media header recognized${expectedBytes == null ? '; no independent size baseline' : '; recorded byte count matches'}. Full video integrity is not verified.'
        : 'Container is unrecognized or unsupported by the quick check. Full video integrity is not verified.',
  );
}

Future<FileInspection> inspectMediaFile(
  String path, {
  int? expectedBytes,
}) async {
  try {
    final uri = Uri.tryParse(path);
    if (uri?.scheme == 'content') {
      return const FileInspection(
        'unverified',
        'Content URI requires a native file check.',
      );
    }
    final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(path);
    final before = await file.stat();
    final input = await file.open();
    try {
      final header = await input.read(4096);
      final after = await file.stat();
      if (before.size != after.size || before.modified != after.modified) {
        return FileInspection(
          'unverified',
          'File changed during the check. Run Diagnostics again.',
          bytes: after.size,
        );
      }
      return inspectMediaHeader(
        header,
        after.size,
        expectedBytes: expectedBytes,
      );
    } finally {
      await input.close();
    }
  } on FileSystemException {
    return const FileInspection(
      'missing',
      'File is missing or cannot be read. The saved record was preserved.',
    );
  }
}

class DownloadIntegrityException implements Exception {
  const DownloadIntegrityException(this.path, this.inspection);
  final String path;
  final FileInspection inspection;
  @override
  String toString() => inspection.detail;
}

class StorageAuditReference {
  const StorageAuditReference({
    required this.id,
    required this.status,
    this.path,
    this.platformId,
    this.expectedBytes,
  });
  final String id, status;
  final String? path, platformId;
  final int? expectedBytes;
}

class StorageAuditResult {
  final counts = <String, int>{};
  final bytes = <String, int>{};
  final examples = <String, List<String>>{};
  bool partial = false;
  void add(String category, int size, [String? id]) {
    counts.update(category, (n) => n + 1, ifAbsent: () => 1);
    bytes.update(category, (n) => n + size, ifAbsent: () => size);
    if (id != null && (examples[category]?.length ?? 0) < 8) {
      (examples[category] ??= []).add(id);
    }
  }
}

Future<StorageAuditResult> auditManagedStorage({
  required List<String> roots,
  required List<StorageAuditReference> references,
  List<Map<String, dynamic>> native = const [],
  List<Map<String, dynamic>> journal = const [],
  int maxEntries = 10000,
  Duration budget = const Duration(seconds: 20),
}) async {
  final report = StorageAuditResult();
  final watch = Stopwatch()..start();
  String key(String path) {
    final uri = Uri.tryParse(path);
    final normalized = uri?.scheme == 'file'
        ? File.fromUri(uri!).absolute.path
        : File(path).absolute.path;
    return Platform.isWindows
        ? normalized.replaceAll('/', r'\').toLowerCase()
        : normalized;
  }

  final owners = <String, Set<String>>{};
  final active = <String>{};
  final expected = <String, int>{};
  void associate(String? path, String id, bool running, int? size) {
    if (path == null || path.isEmpty || path.startsWith('content:')) return;
    final k = key(path);
    (owners[k] ??= {}).add(id);
    if (running) active.add(k);
    if (size != null && size > 0) expected[k] = size;
  }

  bool pending(String status) =>
      !['complete', 'unavailable', 'failed'].contains(status);
  for (final ref in references) {
    associate(ref.path, ref.id, pending(ref.status), ref.expectedBytes);
  }
  final byPlatform = {
    for (final r in references)
      if (r.platformId != null) r.platformId!: r,
  };
  final byId = {for (final r in references) r.id: r};
  final failedPartials = <String>{};
  for (final row in native) {
    final id = '${row['id']}';
    final ref = byPlatform[id] ?? byId[row['jobId']];
    final owner = ref?.id ?? 'native:$id';
    final running = ['queued', 'paused', 'downloading'].contains(row['state']);
    final size = (row['expected'] as num?)?.toInt();
    associate(row['path'] as String?, owner, running, size);
    associate(row['retained'] as String?, owner, running, size);
    if (row['state'] == 'failed' &&
        row['retained'] == null &&
        row['path'] is String) {
      failedPartials.add(key(row['path'] as String));
    }
    if (ref == null) report.add('Untracked native records', 0, id);
  }
  final staleTargets = <String>{};
  for (final row in journal) {
    if (watch.elapsed > budget) {
      report.partial = true;
      break;
    }
    final target = row['target'] as String?;
    final source = row['source'] as String?;
    if (target == null) continue;
    final refOwners = source == null
        ? <String>{}
        : (owners[key(source)] ?? <String>{});
    for (final owner in refOwners) {
      associate(target, owner, false, null);
    }
    if (staleTargets.add(key(target)) && !await File(target).exists()) {
      report.add('Stale retention mappings', 0);
    }
  }
  final seen = <String>{};
  var entries = 0;
  Future<void> inspect(String path, int size) async {
    final k = key(path);
    if (!seen.add(k)) return;
    final refs = owners[k];
    if (refs != null && refs.length > 1) {
      report.add('Duplicate file references', size, refs.join(', '));
    }
    if (active.contains(k)) {
      report.add('Protected active or waiting partials', size);
      return;
    }
    if (failedPartials.contains(k)) {
      report.add('Failed transfer partials (preserved)', size);
      return;
    }
    if (refs == null) {
      report.add(
        'Untracked files (not deleted)',
        size,
        File(path).uri.pathSegments.last,
      );
      final untracked = await inspectMediaFile(path);
      if (untracked.invalid) {
        report.add('Suspicious untracked files (preserved)', size);
      }
      return;
    }
    final check = await inspectMediaFile(path, expectedBytes: expected[k]);
    report.add(
      check.invalid
          ? 'Suspicious or unreadable files'
          : check.state == 'structural'
          ? 'Structurally checked files'
          : 'Integrity unverified',
      size,
      refs.join(', '),
    );
  }

  for (final root in roots.toSet()) {
    final directory = Directory(root);
    if (!await directory.exists()) continue;
    try {
      final canonicalRoot = await directory.resolveSymbolicLinks();
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (++entries > maxEntries || watch.elapsed > budget) {
          report.partial = true;
          break;
        }
        if (entry is Link) {
          report.add('Skipped symbolic links', 0);
          continue;
        }
        final canonical = await entry.resolveSymbolicLinks();
        if (!key(canonical)
            .startsWith('${key(canonicalRoot)}${Platform.pathSeparator}')) {
          report.partial = true;
          continue;
        }
        if (entry is File) {
          await inspect(entry.path, (await entry.stat()).size);
        }
        if (entry is Directory &&
            await entry.list(followLinks: false).isEmpty) {
          report.add('Empty attempt directories', 0);
        }
      }
    } on FileSystemException {
      report.partial = true;
    }
    if (report.partial && (entries > maxEntries || watch.elapsed > budget)) {
      break;
    }
  }
  for (final ref in references) {
    if (watch.elapsed > budget) {
      report.partial = true;
      break;
    }
    final path = ref.path;
    if (path == null || path.isEmpty) continue;
    if (path.startsWith('content:')) {
      report.add('Content URI integrity unverified', 0, ref.id);
      continue;
    }
    if (!seen.contains(key(path))) {
      final file = File(key(path));
      if (await FileSystemEntity.isLink(file.path)) {
        report.add('Skipped symbolic links', 0);
        continue;
      }
      if (await file.exists()) {
        await inspect(file.path, (await file.stat()).size);
      } else {
        final represented = owners.entries.any(
          (e) => seen.contains(e.key) && e.value.contains(ref.id),
        );
        if (!represented) report.add('Missing recorded files', 0, ref.id);
      }
    }
  }
  return report;
}
