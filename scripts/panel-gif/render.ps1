# Regenerate docs/panel.gif from the captured page HTML in frames/.
#
# Run from Windows PowerShell:  & .\scripts\panel-gif\render.ps1
# Needs: Microsoft Edge (headless screenshots) and Node (npm install once
# in this directory to pull gifenc + pngjs).
#
# Screenshots are taken at the gif's native 1120x680 — no downscale pass.
# Downscaling was tried once (1640 -> 820) and rejected: tiny text, and the
# extra quantize pass speckled the flat dark background.
$ErrorActionPreference = 'Stop'
$dir   = $PSScriptRoot
$shots = Join-Path $dir 'shots'
$prof  = Join-Path $dir 'edgeprof'
New-Item -ItemType Directory -Force $shots | Out-Null

foreach ($html in Get-ChildItem (Join-Path $dir 'frames\*.html')) {
    $png = Join-Path $shots ($html.BaseName + '.png')
    # own --user-data-dir or the Edge singleton eats the call; Start-Process
    # (not &) so Edge's stderr doesn't trip NativeCommandError; embedded
    # quotes because -ArgumentList joins without quoting paths with spaces
    Start-Process msedge -ArgumentList @(
        '--headless=new', "--user-data-dir=`"$prof`"", '--hide-scrollbars',
        '--window-size=1120,680', "--screenshot=`"$png`"",
        "`"$($html.FullName)`"") -Wait
    if (-not (Test-Path $png)) { throw "no screenshot for $($html.Name)" }
    Write-Output "$($html.BaseName).png"
}

node (Join-Path $dir 'assemble.js')
