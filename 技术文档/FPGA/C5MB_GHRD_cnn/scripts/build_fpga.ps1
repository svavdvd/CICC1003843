param(
    [string]$QuartusRoot = "D:\intelFPGA_lite\18.1\quartus",
    [switch]$SkipQsys
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$qsysScript = Join-Path $QuartusRoot "sopc_builder\bin\qsys-script.exe"
$qsysGenerate = Join-Path $QuartusRoot "sopc_builder\bin\qsys-generate.exe"
$quartusSh = Join-Path $QuartusRoot "bin64\quartus_sh.exe"
$quartusCpf = Join-Path $QuartusRoot "bin64\quartus_cpf.exe"
$integrationScript = Join-Path $PSScriptRoot "integrate_pure_cnn_qsys.tcl"

$sortIpPath = Join-Path $projectRoot "ip\sort_control"
$aiIpPath = Join-Path $projectRoot "ip"
$ipSearchPath = "$sortIpPath,$aiIpPath,$"

foreach ($tool in @($qsysScript, $qsysGenerate, $quartusSh, $quartusCpf)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Required Quartus 18.1 tool not found: $tool"
    }
}

Push-Location $projectRoot
try {
    if (-not $SkipQsys) {
        Write-Host "Applying C5MB pure-Verilog CNN Platform Designer integration..."
        & $qsysScript "--search-path=$ipSearchPath" "--script=$integrationScript"
        if ($LASTEXITCODE -ne 0) {
            throw "qsys-script failed with exit code $LASTEXITCODE"
        }


        Write-Host "Generating Platform Designer system..."
        $qsysArgs = @(
            "soc_system.qsys",
            "--synthesis=VERILOG",
            "--part=5CSEBA6U23I7",
            "--search-path=$ipSearchPath"
        )
        & $qsysGenerate @qsysArgs
        if ($LASTEXITCODE -ne 0) {
            throw "qsys-generate failed with exit code $LASTEXITCODE"
        }
    }

    Write-Host "Compiling C5MB_top with Quartus 18.1..."
    & $quartusSh "--flow" "compile" "C5MB_top"
    if ($LASTEXITCODE -ne 0) {
        throw "Quartus compile failed with exit code $LASTEXITCODE"
    }

    $sof = Join-Path $projectRoot "output_files\C5MB_top.sof"
    $staSummary = Join-Path $projectRoot "output_files\C5MB_top.sta.summary"
    if (-not (Test-Path -LiteralPath $sof)) {
        throw "Quartus reported success but no SOF was produced: $sof"
    }
    if (-not (Test-Path -LiteralPath $staSummary)) {
        throw "Quartus reported success but no STA summary was produced"
    }
    $negativeSlack = Select-String -LiteralPath $staSummary -Pattern '^Slack\s*:\s*-'
    if ($negativeSlack) {
        $values = ($negativeSlack | ForEach-Object { $_.Line.Trim() }) -join ', '
        throw "Timing is not closed: $values"
    }

    $rbf = Join-Path $projectRoot "output_files\C5MB_top.rbf"
    & $quartusCpf "-c" $sof $rbf
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $rbf)) {
        throw "quartus_cpf failed to create RBF"
    }

    Write-Host "Build and timing checks complete:"
    Write-Host "  $sof"
    Write-Host "  $rbf"
}
finally {
    Pop-Location
}
