# Run after flutter pub get, from any working directory. This does not change Windows security settings.
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$application = Join-Path $repository 'app'
$dependencies = Get-Content -LiteralPath (Join-Path $application '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
$linksDirectory = Join-Path $application 'windows/flutter/ephemeral/.plugin_symlinks'
New-Item -ItemType Directory -Path $linksDirectory -Force | Out-Null
foreach ($plugin in $dependencies.plugins.windows) {
    if ($plugin.name -notmatch '^[A-Za-z0-9_]+$') { throw 'Unexpected plugin name' }
    $target = [IO.Path]::GetFullPath($plugin.path)
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Missing plugin directory: $($plugin.name)" }
    $link = Join-Path $linksDirectory $plugin.name
    if (Test-Path -LiteralPath $link) {
        $existing = Get-Item -LiteralPath $link
        if (-not $existing.LinkType -or [IO.Path]::GetFullPath(@($existing.Target)[0]).TrimEnd('\', '/') -ne $target.TrimEnd('\', '/')) {
            throw "Existing plugin link differs: $($plugin.name). Inspect it before replacing it."
        }
    } else {
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
}
Write-Output 'Windows plugin junctions are ready.'
