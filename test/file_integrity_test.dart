import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/services/file_integrity.dart';

void main() {
  test('read-only inventory distinguishes partials, remnants and damaged completed files', () async {
    final root = await Directory.systemTemp.createTemp('inventory-fixture-');
    addTearDown(() => root.delete(recursive: true));
    final valid = File('${root.path}/valid.mp4');
    final active = File('${root.path}/active.mp4');
    final failed = File('${root.path}/failed.mp4');
    final orphan = File('${root.path}/orphan.mp4');
    final bad = File('${root.path}/bad.mp4');
    await valid.writeAsBytes([
      0,
      0,
      0,
      24,
      ...'ftyp'.codeUnits,
      ...List<int>.filled(56, 0),
    ]);
    for (final f in [active, failed, orphan, bad]) {
      await f.writeAsBytes([1]);
    }
    await Directory('${root.path}/empty').create();
    final before = {
      for (final f in [valid, active, failed, orphan, bad])
        f.path: await f.readAsBytes(),
    };
    final report = await auditManagedStorage(
      roots: [root.path],
      references: [
        StorageAuditReference(
          id: 'valid',
          status: 'complete',
          path: valid.uri.toString(),
          expectedBytes: 64,
        ),
        StorageAuditReference(
          id: 'duplicate',
          status: 'complete',
          path: valid.path,
        ),
        StorageAuditReference(
          id: 'active',
          status: 'downloading',
          path: active.path,
          platformId: '1',
        ),
        StorageAuditReference(
          id: 'failed',
          status: 'failed',
          path: failed.path,
          platformId: '2',
        ),
        StorageAuditReference(id: 'bad', status: 'complete', path: bad.path),
        StorageAuditReference(
          id: 'missing',
          status: 'complete',
          path: '${root.path}/missing.mp4',
        ),
      ],
      native: [
        {'id': 1, 'path': active.path, 'state': 'paused'},
        {'id': 2, 'path': failed.path, 'state': 'failed'},
      ],
      journal: [
        {'target': '${root.path}/gone'},
        {'target': '${root.path}/gone'},
      ],
    );
    for (final category in [
      'Structurally checked files',
      'Duplicate file references',
      'Protected active or waiting partials',
      'Failed transfer partials (preserved)',
      'Suspicious or unreadable files',
      'Untracked files (not deleted)',
      'Missing recorded files',
      'Stale retention mappings',
      'Empty attempt directories',
    ]) {
      expect(report.counts[category], 1, reason: category);
    }
    expect(report.partial, isFalse);
    for (final entry in before.entries) {
      expect(await File(entry.key).readAsBytes(), entry.value);
    }
    expect(
      (await auditManagedStorage(
        roots: [root.path],
        references: [],
        maxEntries: 1,
      )).partial,
      isTrue,
    );
  });
  test(
    'rejects error payloads, tiny files and independent size mismatches',
    () async {
      final root = await Directory.systemTemp.createTemp('integrity-fixture-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/fixture.mp4');
      for (final data in [
        <int>[],
        [1],
        '<html>error</html>'.codeUnits,
        '{"error":"expired"}'.codeUnits,
      ]) {
        await file.writeAsBytes(data);
        expect((await inspectMediaFile(file.path)).invalid, isTrue);
      }
      final bytes = [
        0,
        0,
        0,
        24,
        102,
        116,
        121,
        112,
        ...List<int>.filled(56, 0),
      ];
      await file.writeAsBytes(bytes);
      expect(
        (await inspectMediaFile(file.path, expectedBytes: 128)).invalid,
        isTrue,
      );
      expect(
        (await inspectMediaFile(file.path, expectedBytes: 64)).state,
        'structural',
      );
      expect(
        (await inspectMediaFile(file.path)).detail,
        contains('not verified'),
      );
      expect(await file.readAsBytes(), bytes);
    },
  );

  test(
    'unknown containers and missing baselines do not claim verified integrity',
    () async {
      final root = await Directory.systemTemp.createTemp('integrity-fixture-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/fixture.bin');
      await file.writeAsBytes(List<int>.filled(100, 42));
      expect((await inspectMediaFile(file.path)).state, 'unverified');
    },
  );
}
