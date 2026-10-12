#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force -AllowClobber
Write-Host 'Voraussetzungen wurden installiert.' -ForegroundColor Green
