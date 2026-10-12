# M365 MFA Administration Tool

## Start

1. `Install-Prerequisites.ps1` einmalig in Windows PowerShell 5.1 ausführen.
2. `Start-M365MfaTool.ps1` mit Windows PowerShell 5.1 starten:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Start-M365MfaTool.ps1
```

## Struktur

- `Start-M365MfaTool.ps1`: GUI, Zustandsverwaltung und Eventhandler
- `UI/MainWindow.xaml`: modernes WPF-Layout
- `Modules/Graph.psm1`: Anmeldung und Benutzersuche
- `Modules/Provisioning.psm1`: zentrale Schnittstelle zu den vorhandenen Provisionierungsskripten

## Eigene Skripte einbinden

Die drei Platzhalterfunktionen in `Modules/Provisioning.psm1` durch die vorhandenen Skriptaufrufe ersetzen. Übergaben stehen als `$User.UserPrincipalName` und `$User.Id` zur Verfügung.

## Berechtigungen

Die Anmeldung fordert delegiert `User.Read.All`, `UserAuthenticationMethod.Read.All` und `UserAuthenticationMethod.ReadWrite.All` an. Welche Aktion tatsächlich ausgeführt werden darf, hängt zusätzlich von der Entra-Rolle des angemeldeten Kontos und der jeweiligen API ab.

## Sicherheit

Secrets nicht protokollieren oder dauerhaft im Klartext ablegen. Administrative Aktionen sollten nachvollziehbar protokolliert und nur über freigegebene Rollen ausgeführt werden.
