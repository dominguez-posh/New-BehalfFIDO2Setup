#requires -Version 5.1
<#
.SYNOPSIS
    Installs all modules required by the M365 MFA Administration Tool for the current user.

.DESCRIPTION
    Optional - otherwise, the tool asks at the first sign-in and installs missing modules itself.
    Uses the same module list and installation routine as the tool (Modules\Graph.psm1),
    so no console prompts (NuGet provider, untrusted repository) appear.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$appRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $appRoot 'Modules\Localization.psm1') -Force -Global
Import-Module (Join-Path $appRoot 'Modules\Graph.psm1') -Force -Global
Initialize-Localization -Path (Join-Path $appRoot 'Languages') -Language 'en'

$missing = @(Get-MissingModules)
if (-not $missing.Count) {
    Write-Host 'All required modules are already installed.' -ForegroundColor Green
    return
}

foreach ($module in $missing) {
    Write-Host "Installing $($module.Name) ..." -ForegroundColor Cyan
    Install-RequiredModule -Name $module.Name -RequiredVersion $module.RequiredVersion -SkipPublisherCheck:$module.SkipPublisherCheck
}

Write-Host 'All required modules have been installed.' -ForegroundColor Green
