# New-BehalfFIDO2Setup

## Beschreibung
`New-BehalfFIDO2Setup` ist ein PowerShell-Skript, das die Einrichtung eines FIDO2-Sticks im Namen eines Benutzers ermöglicht. Es kann auch verwendet werden, um ein Break-Glass-Konto zu erstellen.
Die Ausführung ist ohne Admin-Rechte möglich.
Soll für einen User FIDO eingerichtet werden, das Erstellen eines BG-Accounts einfach mit "N" verneinen.

## Voraussetzungen
- PowerShell
- Module:
  - `DSInternals.Passkeys`
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Users`

## Installation der benötigten Module
Das Skript überprüft, ob die erforderlichen Module installiert sind und installiert sie bei Bedarf:
```powershell
if (-not (Get-Module DSInternals.Passkeys)) {
    Write-Verbose "Installing Module..."
    Install-Module -Name DSInternals.Passkeys -Scope CurrentUser
}
if (-not (Get-Module Microsoft.Graph.Authentication)) {
    Write-Verbose "Installing Module..."
    Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser
}
if (-not (Get-Module Microsoft.Graph.Users)) {
    Write-Verbose "Installing Module..."
    Install-Module -Name Microsoft.Graph.Users -Scope CurrentUser
}
