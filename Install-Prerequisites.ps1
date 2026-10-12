#requires -Version 5.1
<#
.SYNOPSIS
    Installiert alle vom M365 MFA Administration Tool benötigten Module für den aktuellen Benutzer.

.DESCRIPTION
    Optional - fehlende Module werden sonst beim ersten Start bzw. bei der ersten Nutzung
    automatisch installiert.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$modules = @(
    @{ Name = 'Microsoft.Graph.Authentication' }
    @{ Name = 'Microsoft.Graph.Identity.SignIns' }                                        # benötigt von DSInternals.Passkeys
    @{ Name = 'DSInternals.Passkeys'; RequiredVersion = '1.0.6'; SkipPublisherCheck = $true } # FIDO2, neuere Versionen haben eine geänderte API
    @{ Name = 'QRCodeGenerator' }                                                         # QR-Code für programmierbare TOTP-Karten
)

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

foreach ($module in $modules) {
    Write-Host "Installiere $($module.Name) ..." -ForegroundColor Cyan
    Install-Module @module -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}

Write-Host 'Voraussetzungen wurden installiert.' -ForegroundColor Green
