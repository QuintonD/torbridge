param([string]$Flutter = '')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = Join-Path $env:USERPROFILE 'Tools\flutter\bin\flutter.bat'
}

# Explicit investigation tool. These are desired-behavior assertions for open
# issues, not part of the passing release test suite. Never use real app data.
$probePath = Join-Path $PSScriptRoot 'audit\2026-09-10-probes.dart.txt'
$fixturePath = Join-Path $projectRoot 'test\app_state_test.dart'
$outputDir = Join-Path $projectRoot '.dart_tool'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$generatedPath = Join-Path $outputDir 'app_audit_test.dart'
$logPath = Join-Path $outputDir 'app-audit-results.log'
$imports = @'
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:torbridge/domain/stream_parser.dart';
import 'package:torbridge/integrations/trakt_client.dart';
import 'package:torbridge/features/library/library_screen.dart';
'@
$fixtures = [System.IO.File]::ReadAllText($fixturePath)
if (-not $fixtures.Contains('void main() {')) { throw 'Test fixture entry point changed.' }
$fixtures = $fixtures.Replace('void main() {', "void main() {`n  auditProbes();")
$probes = [System.IO.File]::ReadAllText($probePath)
[System.IO.File]::WriteAllText($generatedPath, $imports + "`n" + $fixtures + "`n" + $probes,
    [System.Text.UTF8Encoding]::new($false))

Push-Location $projectRoot
try {
    # Windows PowerShell must not interpret ordinary native stderr as a
    # terminating script exception. The actual tool exit status is authoritative.
    $ErrorActionPreference = 'Continue'
    & $Flutter test --no-pub .dart_tool/app_audit_test.dart --plain-name AUDIT --reporter expanded *> $logPath
    $auditExit = $LASTEXITCODE
    Get-Content -LiteralPath $logPath
    Write-Output "Audit exit code: $auditExit. On v1.2.10, 11 failed assertions reproduce the documented open issues."
    exit $auditExit
} finally {
    $ErrorActionPreference = 'Stop'
    Pop-Location
}
