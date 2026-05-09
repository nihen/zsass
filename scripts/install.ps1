#!/usr/bin/env pwsh
# zsass binary installer for Windows.
#
# Detects arch, downloads the matching zip from GitHub Releases, verifies its
# SHA256, and installs zsass.exe under <Prefix>\bin.
#
# Usage:
#   iwr -useb https://raw.githubusercontent.com/nihen/zsass/main/scripts/install.ps1 | iex
#   pwsh -File scripts/install.ps1 -Prefix "$env:LOCALAPPDATA\zsass" -Version v0.1.0
#
# Environment overrides:
#   ZSASS_INSTALL_PREFIX   default install prefix (default: %LOCALAPPDATA%\zsass)
#   ZSASS_VERSION          default version tag to install (default: latest)

[CmdletBinding()]
param(
    [string]$Prefix,
    [string]$Version,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    @'
Usage: install.ps1 [-Prefix <dir>] [-Version <tag>]

Parameters:
  -Prefix    Install prefix; binary goes to <Prefix>\bin (default: %LOCALAPPDATA%\zsass)
  -Version   Version tag to install, e.g. v0.1.0 (default: latest)
'@ | Write-Host
    exit 0
}

# Older Windows / PS 5.1 environments default to TLS 1.0/1.1, which GitHub
# refuses. OR in Tls12 without disturbing newer protocols already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # Tls12 unavailable on extremely old .NET; let downstream calls fail with a clearer error.
}

$repo = 'nihen/zsass'
$binName = 'zsass.exe'

if (-not $Prefix) {
    if ($env:ZSASS_INSTALL_PREFIX) {
        $Prefix = $env:ZSASS_INSTALL_PREFIX
    } else {
        $localApp = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        $Prefix = Join-Path $localApp 'zsass'
    }
}

if (-not $Version) {
    $Version = $env:ZSASS_VERSION
}

# Detect OS architecture (not the current process arch). Prefer
# RuntimeInformation.OSArchitecture, which sees through WoW64. It requires
# .NET Framework 4.7.1+ (or any .NET Core), so on older Win 7 / 8.1 hosts
# stuck on .NET 4.5.x we fall back to PROCESSOR_ARCHITEW6432 / -ECTURE.
function Get-ZsassOSArch {
    try {
        return "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    } catch {
        $procArch = $env:PROCESSOR_ARCHITEW6432
        if (-not $procArch) { $procArch = $env:PROCESSOR_ARCHITECTURE }
        switch ($procArch) {
            'AMD64' { return 'X64' }
            'ARM64' { return 'Arm64' }
            default { return $procArch }
        }
    }
}

$osArch = Get-ZsassOSArch
$arch = switch ($osArch) {
    'X64'   { 'x86_64' }
    'Arm64' {
        Write-Warning '[zsass-install] no native windows-aarch64 build yet; falling back to windows-x86_64 (runs via Windows on ARM x64 emulation).'
        'x86_64'
    }
    default { throw "Unsupported architecture: $osArch" }
}
$os = 'windows'

function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [string]$OutFile,
        [int]$Retries = 3
    )
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            if ($OutFile) {
                Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
                return
            } else {
                return Invoke-RestMethod -UseBasicParsing -Uri $Uri
            }
        } catch {
            if ($i -eq $Retries) { throw }
            $sleep = [Math]::Min(5, $i * 2)
            Write-Warning "[zsass-install] attempt $i for $Uri failed: $($_.Exception.Message). Retrying in $sleep s..."
            Start-Sleep -Seconds $sleep
        }
    }
}

# Resolve latest tag if version not pinned.
if (-not $Version) {
    Write-Host '[zsass-install] resolving latest release'
    try {
        $latest = Invoke-DownloadWithRetry -Uri "https://api.github.com/repos/$repo/releases/latest"
    } catch {
        throw "Failed to query GitHub releases API: $($_.Exception.Message). Retry with -Version <tag>."
    }
    $Version = $latest.tag_name
    if (-not $Version) {
        throw 'Could not resolve latest version. Retry with -Version <tag>.'
    }
}
if (-not $Version.StartsWith('v')) {
    $Version = "v$Version"
}

$asset = "zsass-$Version-$os-$arch.zip"
$url = "https://github.com/$repo/releases/download/$Version/$asset"
$shaUrl = "$url.sha256"

$tmp = $null
try {
    $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "zsass-install-$([Guid]::NewGuid().Guid)")

    Write-Host "[zsass-install] downloading $asset"
    Invoke-DownloadWithRetry -Uri $url    -OutFile (Join-Path $tmp $asset)
    Invoke-DownloadWithRetry -Uri $shaUrl -OutFile (Join-Path $tmp "$asset.sha256")

    Write-Host '[zsass-install] verifying sha256'
    $shaLine = Get-Content -LiteralPath (Join-Path $tmp "$asset.sha256") -First 1
    $expected = ($shaLine -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tmp $asset)).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "SHA256 mismatch: expected $expected, got $actual"
    }

    # Sigstore verification: when `cosign` is on PATH, the install is
    # fail-closed. cosign missing -> skip silently (SHA256 + GitHub TLS
    # still apply). Set $env:ZSASS_INSTALL_SKIP_SIGSTORE=1 to bypass even
    # when cosign is present (intended for offline / locked-down installs).
    $cosignCmd = Get-Command cosign -ErrorAction SilentlyContinue
    if ($env:ZSASS_INSTALL_SKIP_SIGSTORE -eq '1') {
        Write-Host '[zsass-install] note: ZSASS_INSTALL_SKIP_SIGSTORE=1 set; skipping signature verification'
    } elseif ($null -ne $cosignCmd) {
        Write-Host '[zsass-install] cosign found; verifying sigstore signature (fail-closed)'
        $sigPath = Join-Path $tmp "$asset.sig"
        $pemPath = Join-Path $tmp "$asset.pem"
        try {
            Invoke-DownloadWithRetry -Uri "$url.sig" -OutFile $sigPath
        } catch {
            throw "Failed to download $($asset).sig from a release that should publish it ($($_.Exception.Message)). Aborting install. Set `$env:ZSASS_INSTALL_SKIP_SIGSTORE='1' to bypass."
        }
        try {
            Invoke-DownloadWithRetry -Uri "$url.pem" -OutFile $pemPath
        } catch {
            throw "Failed to download $($asset).pem from a release that should publish it ($($_.Exception.Message)). Aborting install. Set `$env:ZSASS_INSTALL_SKIP_SIGSTORE='1' to bypass."
        }
        $cosignArgs = @(
            'verify-blob',
            '--certificate',            $pemPath,
            '--signature',              $sigPath,
            '--certificate-identity',   "https://github.com/$repo/.github/workflows/release.yml@refs/tags/$Version",
            '--certificate-oidc-issuer','https://token.actions.githubusercontent.com',
            (Join-Path $tmp $asset)
        )
        & $cosignCmd.Source @cosignArgs
        if ($LASTEXITCODE -ne 0) {
            throw "cosign verify-blob FAILED (exit $LASTEXITCODE) for $asset"
        }
        Write-Host '[zsass-install] sigstore signature OK'
    } else {
        Write-Host '[zsass-install] note: cosign not in PATH; skipping signature verification (run cosign verify-blob manually for hardened install)'
    }

    Write-Host '[zsass-install] extracting'
    Expand-Archive -LiteralPath (Join-Path $tmp $asset) -DestinationPath $tmp -Force
    $extracted = Join-Path $tmp "zsass-$Version-$os-$arch"
    $sourceBin = Join-Path $extracted $binName
    if (-not (Test-Path -LiteralPath $sourceBin)) {
        throw "Binary not found in archive at $sourceBin"
    }

    # Atomic install: stage in <binDir>\.<name>.installtmp.<pid> and
    # Move-Item -Force over the final path. Move-Item across the same
    # directory uses MoveFileEx(REPLACE_EXISTING) on Windows; same-volume
    # rename is generally atomic, though MoveFileEx alone does not give
    # the strict transactional guarantees of ReplaceFile().
    $binDir = Join-Path $Prefix 'bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $finalBin = Join-Path $binDir $binName
    $tmpBin = Join-Path $binDir (".$binName.installtmp." + $PID)
    try {
        Copy-Item -Force -LiteralPath $sourceBin -Destination $tmpBin
        Move-Item -Force -LiteralPath $tmpBin -Destination $finalBin
    } catch {
        # Best-effort cleanup if Copy-Item / Move-Item fails between the
        # stage and rename steps.
        if (Test-Path -LiteralPath $tmpBin) {
            Remove-Item -Force -LiteralPath $tmpBin -ErrorAction SilentlyContinue
        }
        throw
    }

    $installed = Join-Path $binDir $binName
    Write-Host "[zsass-install] installed -> $installed"
    & $installed --version

    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $sessionPath = $env:PATH
    $alreadyOnPath =
        ($sessionPath -split ';') -contains $binDir -or
        (($userPath -ne $null) -and (($userPath -split ';') -contains $binDir))
    if (-not $alreadyOnPath) {
        Write-Host ''
        Write-Host "[zsass-install] note: $binDir is not in your PATH"
        Write-Host '[zsass-install] add it for the current session with:'
        Write-Host "    `$env:PATH = `"$binDir;`$env:PATH`""
        Write-Host '[zsass-install] or persist it for your user with:'
        Write-Host "    [Environment]::SetEnvironmentVariable('PATH', `"$binDir;`" + [Environment]::GetEnvironmentVariable('PATH','User'), 'User')"
    }
}
finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
