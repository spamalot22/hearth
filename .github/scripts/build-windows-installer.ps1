# SPDX-License-Identifier: AGPL-3.0-or-later
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
  [Parameter(Mandatory = $true)][string]$BuildDir,
  [Parameter(Mandatory = $true)][string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$buildPath = (Resolve-Path -LiteralPath $BuildDir).Path
$outputPath = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if ($null -eq $iscc) {
  $fallback = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
  if (-not (Test-Path -LiteralPath $fallback -PathType Leaf)) {
    throw 'Inno Setup 6 is not installed on this runner.'
  }
  $isccPath = $fallback
} else {
  $isccPath = $iscc.Source
}

& $isccPath "/DMyAppVersion=$Version" "/DBuildDir=$buildPath" "/DOutputDir=$outputPath" 'app/windows/installer/hearth.iss'
if ($LASTEXITCODE -ne 0) {
  throw "ISCC failed with exit code $LASTEXITCODE."
}

$installer = Join-Path $outputPath 'hearth-windows-setup.exe'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
  throw "Installer was not created at $installer."
}
