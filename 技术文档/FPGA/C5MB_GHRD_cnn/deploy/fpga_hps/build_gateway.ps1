param(
    [string]$ArmGxx = 'D:\intelFPGA_lite\18.1\embedded\ds_5\sw\gcc\bin\arm-linux-gnueabihf-g++.exe'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Output = Join-Path $Root 'pl_sort_gateway'
if (-not (Test-Path -LiteralPath $ArmGxx)) {
    throw "ARMv7 hard-float compiler not found: $ArmGxx"
}

$Arguments = @(
    '-std=c++11', '-O2', '-Wall', '-Wextra',
    '-march=armv7-a', '-mfloat-abi=hard', '-mfpu=neon',
    ('-I' + (Join-Path $Root 'card_include')),
    (Join-Path $Root 'pl_sort_gateway.cc'),
    '-pthread', '-o', $Output
)
& $ArmGxx @Arguments
if ($LASTEXITCODE -ne 0) {
    throw 'pl_sort_gateway ARM build failed'
}
Write-Host "Built $Output"
