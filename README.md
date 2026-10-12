# M365 MFA Administration Tool

Grafisches PowerShell-Tool, mit dem Administratoren MFA-Methoden **im Namen anderer Benutzer** in Microsoft Entra ID anzeigen, einrichten und löschen können.

## Funktionen

- **Benutzersuche** nach Anzeigename, Vor-/Nachname, UPN, E-Mail-Adresse oder Objekt-ID
- **MFA-Übersicht** eines Benutzers: alle registrierten Methoden mit Erstellungsdatum, Details und sämtlichen Eigenschaften, bevorzugte MFA-Methode und Status der systembevorzugten MFA
- **Methoden löschen** (mit Bestätigung)
- **Methoden einrichten:**

| Methode | Beschreibung |
|---|---|
| FIDO2 Security Key | Registriert einen FIDO2-Stick/Passkey für den Benutzer (Windows fragt nach PIN und Berührung). |
| TOTP-Karte mit festem Secret | Legt eine Hardware-OATH-Karte mit dem Hersteller-Secret an, weist sie zu und aktiviert sie. |
| Programmierbare TOTP-Karte | Erzeugt ein neues Secret, aktiviert die Karte und zeigt QR-Code und Secret zum Programmieren an. |
| Temporary Access Pass | Erstellt einen TAP, ab sofort 2 Stunden gültig und mehrfach nutzbar. |
| Fake-MFA | Registriert ein TOTP mit zufälligem, sofort verworfenem Secret, sodass bei der Anmeldung immer MFA abgefragt wird. |

TAP, Secrets und QR-Codes werden nur in der Oberfläche angezeigt, nicht protokolliert und nicht auf der Festplatte abgelegt (außer der QR-Code wird ausdrücklich gespeichert).

## Start

**`Start.cmd` doppelklicken.** Alternativ:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Start-M365MfaTool.ps1
```

Der komplette Ordner muss zusammenbleiben. Für eine Desktop-Verknüpfung einfach eine Verknüpfung auf `Start.cmd` anlegen.

## Voraussetzungen

- Windows mit **Windows PowerShell 5.1** (nicht PowerShell 7, da WPF-Oberfläche)
- PowerShell-Module (werden bei Bedarf automatisch für den aktuellen Benutzer installiert, alternativ vorab per `Install-Prerequisites.ps1`):
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Identity.SignIns` und `DSInternals.Passkeys` **1.0.6** (FIDO2)
  - `QRCodeGenerator` (QR-Code für programmierbare TOTP-Karten)
- Für FIDO2 muss der Stick am lokalen Rechner angeschlossen sein.

## Berechtigungen

Delegierte Graph-Berechtigungen (Zustimmung bei der ersten Anmeldung):

- `User.Read.All`
- `UserAuthenticationMethod.Read.All`
- `UserAuthenticationMethod.ReadWrite.All`
- `Policy.ReadWrite.AuthenticationMethod` (Hardware-OATH-Token anlegen/löschen)

Entra-Rollen des angemeldeten Kontos:

- **Authentication Administrator** bzw. **Privileged Authentication Administrator** (für Administratorkonten)
- **Authentication Policy Administrator** für TOTP-Karten und Fake-MFA

In der Authentifizierungsmethoden-Richtlinie des Tenants müssen die verwendeten Methoden (FIDO2, Hardware-OATH-Token, Temporary Access Pass) aktiviert sein.

## Struktur

| Datei | Inhalt |
|---|---|
| `Start.cmd` | Starter per Doppelklick |
| `Start-M365MfaTool.ps1` | Oberfläche, Zustandsverwaltung und Ereignisse |
| `UI/MainWindow.xaml` | WPF-Layout |
| `Modules/Graph.psm1` | Modulverwaltung, Anmeldung, Graph-Anfragen, Benutzersuche, Lesen/Löschen von Methoden |
| `Modules/Provisioning.psm1` | Einrichtung von FIDO2, TOTP-Karten, Fake-MFA und TAP |
| `Install-Prerequisites.ps1` | Optionale Vorabinstallation aller Module |

## Hinweise

- Einige Funktionen nutzen die **Beta-API** von Microsoft Graph (u. a. Hardware-OATH), die sich ändern kann.
- Graph übernimmt Änderungen mit kurzer Verzögerung; das Tool wartet nach dem Anlegen oder Löschen automatisch, bis der neue Stand sichtbar ist.
- Administrative Aktionen nur gemäß Freigabe- und Sicherheitsprozess durchführen.
