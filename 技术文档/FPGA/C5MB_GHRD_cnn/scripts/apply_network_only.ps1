$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-AsciiCompatibleFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Replace-ExactlyOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$New,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($New.Length -gt 0 -and $Text.Contains($New)) {
        return $Text
    }
    if ($count -eq 1) {
        return $Text.Replace($Old, $New)
    }
    throw "$Description expected one old match or an existing replacement; old matches: $count"
}

$integrationPath = Join-Path $PSScriptRoot "integrate_ai_qsys.tcl"
$integration = [System.IO.File]::ReadAllText($integrationPath)
$integration = Replace-ExactlyOnce $integration `
    "load_system soc_system.qsys" `
    @" 
load_system soc_system.qsys

# The FPGA board exchanges application data with the Raspberry Pi only through
# HPS EMAC1. Disable unused HPS USB/UART pin muxing at the source.
set_instance_parameter_value hps_0 UART0_PinMuxing Unused
set_instance_parameter_value hps_0 UART0_Mode {N/A}
set_instance_parameter_value hps_0 USB1_PinMuxing Unused
set_instance_parameter_value hps_0 USB1_Mode {N/A}
"@.TrimEnd() `
    "HPS pin-mux insertion"
$integration = Replace-ExactlyOnce $integration `
    "# 65 MHz is used until a full compile proves a higher board-specific target." `
    "# A full C5MB compile closes timing at the 70 MHz competition target." `
    "CNN clock comment"
$integrationLineEnding = if ($integration.Contains("and the CNN`r`n# accelerator occupies")) { "`r`n" } else { "`n" }
$integration = Replace-ExactlyOnce $integration `
    "# DVP occupies 0x000-0x01f, SYSID occupies 0x020-0x027, and the CNN${integrationLineEnding}# accelerator occupies 0x400-0x7ff on the lightweight bridge." `
    "# SYSID occupies 0x020-0x027 and the CNN accelerator occupies${integrationLineEnding}# 0x400-0x7ff on the lightweight bridge." `
    "lightweight bridge map comment"
Write-AsciiCompatibleFile $integrationPath $integration

$topPath = Join-Path $projectRoot "C5MB_net_top.v"
$top = [System.IO.File]::ReadAllText($topPath)
$topSignalCount = ([regex]::Matches($top, "HPS_(UART|USB)")).Count
if ($topSignalCount -eq 21) {
    $top = [regex]::Replace($top, "(?m)^.*HPS_(UART|USB).*(?:`r?`n|$)", "")
} elseif ($topSignalCount -ne 0) {
    throw "C5MB_net_top.v expected 21 or 0 USB/UART references, found $topSignalCount"
}
$top = Replace-ExactlyOnce $top `
    "    output             HPS_EMMC_RST_n," `
    "    output             HPS_EMMC_RST_n" `
    "last network-top port comma"
Write-AsciiCompatibleFile $topPath $top

$qsfPath = Join-Path $projectRoot "C5MB_top.qsf"
$qsf = [System.IO.File]::ReadAllText($qsfPath)
$qsfSignalCount = ([regex]::Matches($qsf, "HPS_(UART|USB)")).Count
if ($qsfSignalCount -eq 29) {
    $qsf = [regex]::Replace($qsf, "(?m)^.*HPS_(UART|USB).*(?:`r?`n|$)", "")
} elseif ($qsfSignalCount -ne 0) {
    throw "C5MB_top.qsf expected 29 or 0 USB/UART references, found $qsfSignalCount"
}
Write-AsciiCompatibleFile $qsfPath $qsf

Write-Host "Applied network-only C5MB interface policy."
