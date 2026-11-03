param(
    [string]$QsysPath = (Join-Path $PSScriptRoot '..\soc_system.qsys')
)

$resolvedPath = (Resolve-Path -LiteralPath $QsysPath).Path
$text = [IO.File]::ReadAllText($resolvedPath)

$oldWidth = '<parameter name="F2SDRAM_Width" value="256" />'
$newWidth = '<parameter name="F2SDRAM_Width" value="128" />'
$oldWidthCount = ([regex]::Matches($text, [regex]::Escape($oldWidth))).Count
$newWidthCount = ([regex]::Matches($text, [regex]::Escape($newWidth))).Count
if ($oldWidthCount -eq 1 -and $newWidthCount -eq 0) {
    $text = $text.Replace($oldWidth, $newWidth)
}
elseif ($oldWidthCount -ne 0 -or $newWidthCount -ne 1) {
    throw "Expected exactly one F2SDRAM_Width entry (256 or 128)"
}

$oldClockPattern = 'start="clk_0\.clk"\r?\n   end="hps_0\.f2h_sdram0_clock"'
$newClockPattern = 'start="pll_1_cnn\.outclk0"\r?\n   end="hps_0\.f2h_sdram0_clock"'
$oldClockCount = ([regex]::Matches($text, $oldClockPattern)).Count
$newClockCount = ([regex]::Matches($text, $newClockPattern)).Count
if ($oldClockCount -eq 1 -and $newClockCount -eq 0) {
    $replacement = 'start="pll_1_cnn.outclk0"' + [Environment]::NewLine +
        '   end="hps_0.f2h_sdram0_clock"'
    $text = [regex]::Replace($text, $oldClockPattern, $replacement)
}
elseif ($oldClockCount -ne 0 -or $newClockCount -ne 1) {
    throw "Expected exactly one F2SDRAM0 clock connection (clk_0 or pll_1_cnn)"
}

$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($resolvedPath, $text, $utf8NoBom)
Write-Host "Verified AI DDR width and PLL clock in $resolvedPath"
