param(
  [string]$Version = "",
  [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $root

if ($Version -eq "") {
  $mix = Get-Content -LiteralPath (Join-Path $root "mix.exs") -Raw
  if ($mix -match 'version:\s*"([^"]+)"') {
    $Version = $Matches[1]
  } else {
    throw "Could not determine project version from mix.exs"
  }
}

if (-not $SkipTests) {
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
}

mix escript.build

$dist = Join-Path $root "dist"
$pkgRoot = Join-Path $dist "pkg"
$pkgName = "elixir-luv-v-$Version"
$pkgDir = Join-Path $pkgRoot $pkgName

Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $pkgDir "bin") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $pkgDir "libexec") | Out-Null

Copy-Item -LiteralPath (Join-Path $root "elv") -Destination (Join-Path $pkgDir "libexec/elv")
Copy-Item -LiteralPath (Join-Path $root "bin/elv") -Destination (Join-Path $pkgDir "bin/elv")
Copy-Item -LiteralPath (Join-Path $root "bin/elv.cmd") -Destination (Join-Path $pkgDir "bin/elv.cmd")
Copy-Item -LiteralPath (Join-Path $root "README.md") -Destination $pkgDir
Copy-Item -LiteralPath (Join-Path $root "ARCHITECTURE.md") -Destination $pkgDir
Copy-Item -LiteralPath (Join-Path $root "LICENSE") -Destination $pkgDir
Copy-Item -LiteralPath (Join-Path $root "CHANGELOG.md") -Destination $pkgDir

Copy-Item -LiteralPath (Join-Path $root "elv") -Destination (Join-Path $dist "elv-$Version.escript")

$zipPath = Join-Path $dist "$pkgName-universal.zip"
Compress-Archive -Path (Join-Path $pkgDir "*") -DestinationPath $zipPath -Force

if ($IsLinux -or $IsMacOS) {
  chmod +x (Join-Path $pkgDir "bin/elv")
  chmod +x (Join-Path $pkgDir "libexec/elv")
  tar -czf (Join-Path $dist "$pkgName-universal.tar.gz") -C $pkgRoot $pkgName
}

Write-Host "Release assets:"
Get-ChildItem -LiteralPath $dist -File | ForEach-Object {
  Write-Host "  $($_.FullName)"
}
