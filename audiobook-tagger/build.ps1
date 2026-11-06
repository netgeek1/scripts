<#
.SYNOPSIS
    Builds a single self-contained audiobook-tagger.exe (no Python install
    needed to RUN the result).

.DESCRIPTION
    Creates a throwaway virtual environment, installs mutagen plus the optional
    libraries, and runs PyInstaller to produce one portable .exe. Python IS
    required to BUILD (run this once); it is NOT required to run the resulting
    exe on any other machine.

    Output:  .\dist\audiobook-tagger.exe

.NOTES
    - Run on the SAME OS/arch you want the exe for (Windows exe needs Windows).
    - mutagen is GPL-2.0-or-later. A bundled binary that embeds it is, as a
      whole, covered by the GPL. Distributing the .py script with deps installed
      separately keeps them independent works. Fine for personal use either way.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1
#>

[CmdletBinding()]
param(
    [string]$Script  = "audiobook_tagger.py",   # source to bundle
    [string]$Name    = "audiobook-tagger",      # output exe name (no extension)
    [switch]$Console = $true,                   # keep the console window (CLI tool)
    [switch]$Clean                              # remove build/ dist/ *.spec first
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Find-Python {
    foreach ($c in @(
        @{ exe = "py";     args = @("-3") },
        @{ exe = "python"; args = @() },
        @{ exe = "python3"; args = @() }
    )) {
        $cmd = Get-Command $c.exe -ErrorAction SilentlyContinue
        if ($cmd) {
            try { & $c.exe @($c.args + "--version") *> $null; return $c } catch {}
        }
    }
    throw "No Python found. Install Python 3.9+ from https://python.org and re-run."
}

if (-not (Test-Path $Script)) {
    throw "Source script '$Script' not found next to this build script."
}

if ($Clean) {
    Write-Host "Cleaning build/ dist/ *.spec ..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force build, dist -ErrorAction SilentlyContinue
    Remove-Item -Force *.spec -ErrorAction SilentlyContinue
}

$py = Find-Python
$pyExe = $py.exe
$pyArgs = $py.args
Write-Host "Using Python: $pyExe $($pyArgs -join ' ')" -ForegroundColor Cyan

# --- isolated build venv (keeps your system Python clean) ------------------
$venv = Join-Path $PSScriptRoot ".build-venv"
if (-not (Test-Path $venv)) {
    Write-Host "Creating build venv in $venv ..." -ForegroundColor Cyan
    & $pyExe @($pyArgs + @("-m", "venv", $venv))
}
$venvPy = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
    # non-Windows venv layout (lets this script also build on Linux/macOS)
    $venvPy = Join-Path $venv "bin/python"
}

Write-Host "Installing build dependencies ..." -ForegroundColor Cyan
& $venvPy -m pip install --upgrade pip *> $null
# mutagen is the only hard dep; the rest light up optional features
& $venvPy -m pip install mutagen rapidfuzz Pillow PyYAML certifi pyinstaller

# --- build -----------------------------------------------------------------
$iconArg = @()
if (Test-Path "icon.ico") { $iconArg = @("--icon", "icon.ico") }

$mode = if ($Console) { "--console" } else { "--windowed" }

Write-Host "Running PyInstaller ..." -ForegroundColor Cyan
& $venvPy -m PyInstaller `
    --onefile `
    $mode `
    --name $Name `
    --collect-submodules mutagen `
    --collect-data certifi `
    --noconfirm `
    @iconArg `
    $Script

$out = Join-Path $PSScriptRoot "dist\$Name.exe"
if (-not (Test-Path $out)) { $out = Join-Path $PSScriptRoot "dist/$Name" }  # non-Windows

if (Test-Path $out) {
    $size = "{0:N1} MB" -f ((Get-Item $out).Length / 1MB)
    Write-Host ""
    Write-Host "Built: $out  ($size)" -ForegroundColor Green
    Write-Host "Test it:  & '$out' --version" -ForegroundColor Green
    Write-Host ""
    Write-Host "Copy that single file anywhere - no Python needed to run it." -ForegroundColor Green
} else {
    throw "Build finished but the expected output was not found under dist\."
}
