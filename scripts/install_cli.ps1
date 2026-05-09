#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Help {
    @'
Usage: scripts/install_cli.ps1 [-Prefix <dir>] [-Optimize <mode>] [-GlobalCacheDir <dir>]
                              [-Completions <shell>[,<shell>...]] [-Help]

Builds zsass via "zig build" and installs it with "zig build install" so Windows
shell users get a one-liner similar to scripts/install_cli.sh.

Parameters fall back to environment variables when omitted:
  -Prefix           Defaults to $env:ZSASS_INSTALL_PREFIX or %LOCALAPPDATA%\zsass
  -Optimize         Defaults to $env:ZSASS_INSTALL_OPTIMIZE or ReleaseFast
  -GlobalCacheDir   Defaults to $env:ZSASS_GLOBAL_CACHE_DIR or <repo>/.zig-global-cache
  -Completions      One or more of bash, zsh, fish. Generated completion
                    scripts are written to <Prefix>\completions\zsass.<shell>;
                    move them to your shell's completion directory by hand.
'@ | Write-Host
}

[CmdletBinding()]
param(
    [string]$Prefix,
    [string]$Optimize,
    [string]$GlobalCacheDir,
    [string[]]$Completions = @(),
    [switch]$Help
)

if ($Help) {
    Show-Help
    exit 0
}

$ScriptDir = Split-Path -Parent -LiteralPath $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path
Set-Location -LiteralPath $RepoRoot

if (-not $Prefix) {
    if ($env:ZSASS_INSTALL_PREFIX) {
        $Prefix = $env:ZSASS_INSTALL_PREFIX
    } else {
        $localApp = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        $Prefix = Join-Path $localApp 'zsass'
    }
}

if (-not $Optimize) {
    $Optimize = if ($env:ZSASS_INSTALL_OPTIMIZE) { $env:ZSASS_INSTALL_OPTIMIZE } else { 'ReleaseFast' }
}

if (-not $GlobalCacheDir) {
    if ($env:ZSASS_GLOBAL_CACHE_DIR) {
        $GlobalCacheDir = $env:ZSASS_GLOBAL_CACHE_DIR
    } else {
        $GlobalCacheDir = Join-Path $RepoRoot '.zig-global-cache'
    }
}

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Error 'zig not found in PATH'
    exit 127
}

New-Item -ItemType Directory -Path $GlobalCacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $Prefix -Force | Out-Null

Write-Host "[zsass-install] building optimize=$Optimize"
& zig build ("-Doptimize={0}" -f $Optimize) --global-cache-dir $GlobalCacheDir

Write-Host "[zsass-install] installing to $Prefix"
& zig build ("-Doptimize={0}" -f $Optimize) install --prefix $Prefix --global-cache-dir $GlobalCacheDir

$binDir = Join-Path $Prefix 'bin'
$candidates = @(
    Join-Path $binDir 'zsass.exe',
    Join-Path $binDir 'zsass'
)
$installed = $null
foreach ($path in $candidates) {
    if (Test-Path -LiteralPath $path) {
        $installed = $path
        break
    }
}

if ($installed) {
    Write-Host "[zsass-install] done -> $installed"
} else {
    Write-Warning "[zsass-install] install completed but binary not found under $binDir"
}

if ($installed -and $Completions.Count -gt 0) {
    $completionsDir = Join-Path $Prefix 'completions'
    New-Item -ItemType Directory -Force -Path $completionsDir | Out-Null
    foreach ($shell in $Completions) {
        $shellLower = $shell.ToLowerInvariant()
        if ($shellLower -notin @('bash', 'zsh', 'fish')) {
            Write-Warning "[zsass-install] unsupported completion shell: $shell"
            continue
        }
        $outFile = Join-Path $completionsDir "zsass.$shellLower"
        Write-Host "[zsass-install] generating $shellLower completion -> $outFile"
        try {
            $script = & $installed --completions $shellLower
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[zsass-install] zsass --completions $shellLower exited with $LASTEXITCODE"
                continue
            }
            $script | Set-Content -Path $outFile -Encoding UTF8 -NoNewline
        } catch {
            Write-Warning "[zsass-install] failed to write $shellLower completion: $($_.Exception.Message)"
        }
    }
}
