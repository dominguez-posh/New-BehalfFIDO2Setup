#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
# Wird von DSInternals.Passkeys (FIDO2) benötigt
Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Force -AllowClobber
# FIDO2: DSInternals.Passkeys ist auf 1.0.6 gepinnt (neuere Versionen haben eine geänderte API)
Install-Module DSInternals.Passkeys -RequiredVersion 1.0.6 -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
# QR-Code für programmierbare TOTP-Karten
Install-Module QRCodeGenerator -Scope CurrentUser -Force -AllowClobber
Write-Host 'Voraussetzungen wurden installiert.' -ForegroundColor Green
