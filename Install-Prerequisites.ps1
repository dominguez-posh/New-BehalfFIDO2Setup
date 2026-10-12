#requires -Version 5.1
<#
.SYNOPSIS
    Installs all modules required by the M365 MFA Administration Tool for the current user.

.DESCRIPTION
    Optional - otherwise, missing modules are installed automatically on first start
    or first use.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$modules = @(
    @{ Name = 'Microsoft.Graph.Authentication' }
    @{ Name = 'Microsoft.Graph.Identity.SignIns' }                                        # required by DSInternals.Passkeys
    @{ Name = 'DSInternals.Passkeys'; RequiredVersion = '1.0.6'; SkipPublisherCheck = $true } # FIDO2, newer versions have a changed API
    @{ Name = 'QRCodeGenerator' }                                                         # QR code for programmable TOTP cards
)

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

foreach ($module in $modules) {
    Write-Host "Installiere $($module.Name) ..." -ForegroundColor Cyan
    Install-Module @module -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}

Write-Host 'Voraussetzungen wurden installiert.' -ForegroundColor Green
