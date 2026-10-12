Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Start-Fido2Provisioning {
    param([Parameter(Mandatory)]$User,[Parameter(Mandatory)][string]$AppRoot)
    # TODO: Hier Ihr bestehendes FIDO2-Skript aufrufen.
    # Beispiel: & (Join-Path $AppRoot 'Scripts\Fido2.ps1') -UserUPN $User.UserPrincipalName -UserId $User.Id
    return "FIDO2-Platzhalter erfolgreich aufgerufen für $($User.UserPrincipalName)."
}

function Start-FixedSecretTotpProvisioning {
    param([Parameter(Mandatory)]$User,[Parameter(Mandatory)][string]$AppRoot)
    # TODO: Hier Ihr bestehendes Skript für die TOTP-Karte mit festem Secret aufrufen.
    return "TOTP-Karte mit festem Secret: Platzhalter erfolgreich aufgerufen für $($User.UserPrincipalName)."
}

function Start-ProgrammableTotpProvisioning {
    param([Parameter(Mandatory)]$User,[Parameter(Mandatory)][string]$AppRoot)
    # TODO: Hier Ihr bestehendes Skript für die programmierbare TOTP-Karte aufrufen.
    return "Programmierbare TOTP-Karte: Platzhalter erfolgreich aufgerufen für $($User.UserPrincipalName)."
}

function Invoke-MfaProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('FIDO2 Security Key','TOTP-Karte mit festem Secret','Programmierbare TOTP-Karte')][string]$Method,
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$AppRoot
    )
    switch ($Method) {
        'FIDO2 Security Key' { Start-Fido2Provisioning -User $User -AppRoot $AppRoot }
        'TOTP-Karte mit festem Secret' { Start-FixedSecretTotpProvisioning -User $User -AppRoot $AppRoot }
        'Programmierbare TOTP-Karte' { Start-ProgrammableTotpProvisioning -User $User -AppRoot $AppRoot }
    }
}

Export-ModuleMember -Function Invoke-MfaProvisioning
