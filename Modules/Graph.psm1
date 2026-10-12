<#
.SYNOPSIS
    Microsoft-Graph-Anbindung des M365 MFA Administration Tools.

.DESCRIPTION
    Modulverwaltung, Anmeldung, Benutzersuche sowie Lesen und Löschen von
    Authentifizierungsmethoden. Alle Graph-Aufrufe laufen über Invoke-M365GraphRequest
    (Invoke-MgGraphRequest), daher wird nur Microsoft.Graph.Authentication benötigt.
#>

Set-StrictMode -Version Latest

$script:GraphScopes = @(
    'User.Read.All'
    'UserAuthenticationMethod.Read.All'
    'UserAuthenticationMethod.ReadWrite.All'
    'Policy.ReadWrite.AuthenticationMethod'   # Hardware-OATH-Token im Verzeichnis anlegen/löschen
    'RoleManagement.Read.Directory'           # Administrative Rollen des Benutzers anzeigen
)

$script:RoleDefinitionNames = $null   # Cache: Rollen-ID -> Anzeigename

#region Modulverwaltung

function Add-UserModulePath {
    # Install-Module -Scope CurrentUser installiert nach <Dokumente>\WindowsPowerShell\Modules.
    # Wird powershell.exe z. B. aus VS Code oder pwsh 7 gestartet, fehlt dieser Pfad teils in PSModulePath.
    $userModulePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
    $paths = @($env:PSModulePath -split ';' | Where-Object { $_ })
    if ($paths -notcontains $userModulePath) {
        $env:PSModulePath = (@($userModulePath) + $paths) -join ';'
    }
}

function Get-CompatibleAuthenticationVersion {
    # DSInternals.Passkeys (FIDO2) lädt Microsoft.Graph.Identity.SignIns, das eine exakte Version von
    # Microsoft.Graph.Authentication voraussetzt. Ist bereits eine andere Version geladen, schlägt der Import fehl.
    # Daher die Authentication-Version wählen, die zur neuesten installierten SignIns-Version passt.
    $signIns = Get-Module -ListAvailable -Name 'Microsoft.Graph.Identity.SignIns' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $signIns) { return $null }

    $required = $signIns.RequiredModules |
        Where-Object Name -eq 'Microsoft.Graph.Authentication' |
        Select-Object -First 1
    if (-not $required -or -not $required.Version) { return $null }

    $installed = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' |
        Where-Object Version -eq $required.Version
    if ($installed) { return $required.Version }
    return $null
}

function Assert-GraphModules {
    <#
    .SYNOPSIS
        Stellt sicher, dass Microsoft.Graph.Authentication installiert und geladen ist.
    #>
    $moduleName = 'Microsoft.Graph.Authentication'
    Add-UserModulePath
    if (Get-Module -Name $moduleName) { return }

    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Host "Das Modul '$moduleName' fehlt und wird für den aktuellen Benutzer installiert ..." -ForegroundColor Cyan
        try {
            Install-Module -Name $moduleName -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            throw "Installation von '$moduleName' fehlgeschlagen: $($_.Exception.Message)"
        }
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "Das Modul '$moduleName' wurde installiert, ist in dieser PowerShell-Sitzung aber nicht auffindbar."
        }
    }

    $importParams = @{ Name = $moduleName; ErrorAction = 'Stop' }
    $compatibleVersion = Get-CompatibleAuthenticationVersion
    if ($compatibleVersion) { $importParams.RequiredVersion = $compatibleVersion }

    try {
        Import-Module @importParams
        Write-Host "'$moduleName' ist geladen." -ForegroundColor Green
    }
    catch {
        throw "Das Modul '$moduleName' konnte nicht geladen werden: $($_.Exception.Message)"
    }
}

#endregion

#region Verbindung

function Test-M365GraphConnection {
    <#
    .SYNOPSIS
        Gibt $true zurück, wenn eine angemeldete Graph-Sitzung besteht.
    #>
    # Vor der ersten Anmeldung ist das Graph-Modul ggf. noch nicht geladen.
    if (-not (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)) { return $false }
    $context = Get-MgContext -ErrorAction SilentlyContinue
    return ($null -ne $context -and -not [string]::IsNullOrWhiteSpace($context.Account))
}

function Connect-M365Graph {
    <#
    .SYNOPSIS
        Meldet interaktiv an Microsoft Graph an und gibt Konto und Tenant zurück.
    #>
    Assert-GraphModules

    try {
        Connect-MgGraph -Scopes $script:GraphScopes -NoWelcome -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Anmeldung an Microsoft Graph fehlgeschlagen: $($_.Exception.Message)"
    }

    $context = Get-MgContext
    if ($null -eq $context) {
        throw 'Anmeldung an Microsoft Graph fehlgeschlagen: Kein Kontext vorhanden.'
    }

    [pscustomobject]@{
        Account  = $context.Account
        TenantId = $context.TenantId
        Scopes   = $context.Scopes
    }
}

function Request-M365GraphScopes {
    <#
    .SYNOPSIS
        Fordert zusätzliche Berechtigungen an (erneute Anmeldung nur, wenn welche fehlen).
    .OUTPUTS
        Konto und Tenant der (ggf. neuen) Sitzung.
    #>
    param([Parameter(Mandatory)][string[]]$Scopes)

    $context = Get-MgContext
    $missing = @($Scopes | Where-Object { @($context.Scopes) -notcontains $_ })
    if ($missing.Count) {
        try {
            Connect-MgGraph -Scopes (@($script:GraphScopes) + $Scopes | Select-Object -Unique) -NoWelcome -ErrorAction Stop | Out-Null
        }
        catch {
            throw "Zusätzliche Berechtigungen ($($missing -join ', ')) wurden nicht erteilt: $($_.Exception.Message)"
        }
        $context = Get-MgContext
    }

    [pscustomobject]@{
        Account  = $context.Account
        TenantId = $context.TenantId
        Scopes   = $context.Scopes
    }
}

function Disconnect-M365Graph {
    <#
    .SYNOPSIS
        Trennt die Graph-Sitzung, falls eine besteht.
    #>
    if (Test-M365GraphConnection) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    $script:RoleDefinitionNames = $null
}

#endregion

#region Graph-Anfragen

function Get-GraphErrorMessage {
    param([Parameter(Mandatory)]$ErrorRecord)

    # Das Graph-SDK verpackt Fehler gern in AggregateExceptions ("Mindestens ein Fehler ist aufgetreten").
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    $message = $exception.Message

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try {
            $graphError = ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json).error
            if ($graphError.message) { $message = "$($graphError.code): $($graphError.message)" }
        }
        catch {
            $message = $ErrorRecord.ErrorDetails.Message
        }
    }
    return $message
}

function Invoke-M365GraphRequest {
    <#
    .SYNOPSIS
        Wrapper um Invoke-MgGraphRequest mit JSON-Body und lesbaren Fehlermeldungen.
    .NOTES
        Bewusst nicht "Invoke-GraphRequest" genannt: Unter diesem Namen definiert das Graph-SDK
        einen Alias auf Invoke-MgGraphRequest, und Aliase haben Vorrang vor Funktionen.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        $Body
    )

    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $params.ContentType = 'application/json'
    }

    try {
        Invoke-MgGraphRequest @params
    }
    catch {
        throw "Graph-Anfrage fehlgeschlagen ($Method $($Uri -replace '\?.*$', '')): $(Get-GraphErrorMessage $_)"
    }
}

function ConvertTo-LocalDate {
    <#
    .SYNOPSIS
        Wandelt einen Graph-Zeitstempel (String oder DateTime) in lokale Zeit um.
    #>
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToLocalTime() }
    try {
        [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    }
    catch {
        $null
    }
}

#endregion

#region Benutzer und Domains

function Find-M365User {
    <#
    .SYNOPSIS
        Sucht Benutzer nach Objekt-ID oder Namensanfang (Anzeigename, Vorname, Nachname, UPN, E-Mail).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SearchTerm,
        [int]$Top = 50
    )

    if (-not (Test-M365GraphConnection)) {
        throw 'Keine Verbindung zu Microsoft Graph. Bitte zuerst anmelden.'
    }

    $term = $SearchTerm.Trim()
    $select = 'id,displayName,userPrincipalName,mail,accountEnabled'

    if ($term -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $users = @(Invoke-M365GraphRequest -Uri "v1.0/users/$term`?`$select=$select")
    }
    else {
        $value = $term.Replace("'", "''")
        $filter = @('displayName', 'givenName', 'surname', 'userPrincipalName', 'mail' |
            ForEach-Object { "startswith($_,'$value')" }) -join ' or '
        $uri = "v1.0/users?`$filter=$([uri]::EscapeDataString($filter))&`$select=$select&`$top=$Top&`$count=true"
        $users = @((Invoke-M365GraphRequest -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' })['value'])
    }

    $users |
        Where-Object { $null -ne $_ } |
        ForEach-Object {
            [pscustomobject]@{
                Id                = [string]$_['id']
                DisplayName       = [string]$_['displayName']
                UserPrincipalName = [string]$_['userPrincipalName']
                Mail              = [string]$_['mail']
                AccountEnabled    = [bool]$_['accountEnabled']
            }
        } |
        Sort-Object DisplayName
}

function Get-M365VerifiedDomains {
    <#
    .SYNOPSIS
        Liefert die verifizierten Domains des Tenants, Standarddomain zuerst.
    #>
    $response = Invoke-M365GraphRequest -Uri 'v1.0/domains?$select=id,isVerified,isDefault'
    @($response['value']) |
        Where-Object { $null -ne $_ -and $_['isVerified'] } |
        Sort-Object @{ Expression = { [bool]$_['isDefault'] }; Descending = $true }, @{ Expression = { [string]$_['id'] } } |
        ForEach-Object { [string]$_['id'] }
}

#endregion

#region Authentifizierungsmethoden

# Graph-Typ -> Anzeigename, URL-Segment zum Löschen ($null = nicht löschbar) und Sicherheitsstufe:
#   PhishingResistant / Strong = vollwertiges MFA, Weak = veraltet/unsicher,
#   Temporary = nur übergangsweise (TAP), None = kein MFA-Faktor
$script:AuthMethodTypes = @{
    '#microsoft.graph.fido2AuthenticationMethod'                              = @{ Name = 'FIDO2 Security Key / Passkey';          Segment = 'fido2Methods';                              Strength = 'PhishingResistant' }
    '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod'            = @{ Name = 'Windows Hello for Business';            Segment = 'windowsHelloForBusinessMethods';            Strength = 'PhishingResistant' }
    '#microsoft.graph.platformCredentialAuthenticationMethod'                 = @{ Name = 'Platform Credential (macOS)';           Segment = 'platformCredentialMethods';                 Strength = 'PhishingResistant' }
    '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'             = @{ Name = 'Microsoft Authenticator';               Segment = 'microsoftAuthenticatorMethods';             Strength = 'Strong' }
    '#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod' = @{ Name = 'Authenticator (kennwortlos, veraltet)'; Segment = 'passwordlessMicrosoftAuthenticatorMethods'; Strength = 'Strong' }
    '#microsoft.graph.softwareOathAuthenticationMethod'                       = @{ Name = 'Software-OATH (TOTP)';                  Segment = 'softwareOathMethods';                       Strength = 'Strong' }
    '#microsoft.graph.hardwareOathAuthenticationMethod'                       = @{ Name = 'Hardware-OATH (TOTP-Token/-Karte)';     Segment = 'hardwareOathMethods';                       Strength = 'Strong' }
    '#microsoft.graph.externalAuthenticationMethod'                           = @{ Name = 'Externe Authentifizierungsmethode';     Segment = 'externalAuthenticationMethods';             Strength = 'Strong' }
    '#microsoft.graph.phoneAuthenticationMethod'                              = @{ Name = 'Telefon (SMS/Anruf)';                   Segment = 'phoneMethods';                              Strength = 'Weak' }
    '#microsoft.graph.qrCodePinAuthenticationMethod'                          = @{ Name = 'QR-Code + PIN';                         Segment = 'qrCodePinMethod';                           Strength = 'Weak' }
    '#microsoft.graph.temporaryAccessPassAuthenticationMethod'                = @{ Name = 'Befristeter Zugriffspass (TAP)';        Segment = 'temporaryAccessPassMethods';                Strength = 'Temporary' }
    '#microsoft.graph.emailAuthenticationMethod'                              = @{ Name = 'E-Mail (SSPR)';                         Segment = 'emailMethods';                              Strength = 'None' }
    '#microsoft.graph.passwordAuthenticationMethod'                           = @{ Name = 'Kennwort';                              Segment = $null;                                       Strength = 'None' }
}

$script:PreferredMethodNames = @{
    'push'                 = 'Microsoft Authenticator (Push)'
    'oath'                 = 'OATH-Code (Software/Hardware)'
    'voiceMobile'          = 'Anruf (Mobiltelefon)'
    'voiceAlternateMobile' = 'Anruf (alternatives Mobiltelefon)'
    'voiceOffice'          = 'Anruf (Bürotelefon)'
    'sms'                  = 'SMS'
    'none'                 = 'Keine'
}

function Format-GraphValue {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '-' }
    if ($Value -is [bool]) { return $(if ($Value) { 'Ja' } else { 'Nein' }) }
    if ($Value -is [datetime] -or "$Value" -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}') {
        $date = ConvertTo-LocalDate $Value
        if ($date) { return $date.ToString('dd.MM.yyyy HH:mm:ss') }
    }
    return "$Value"
}

function ConvertTo-PropertyLines {
    param([System.Collections.IDictionary]$Object, [string]$Prefix = '')
    foreach ($key in ($Object.Keys | Sort-Object)) {
        $value = $Object[$key]
        if ($value -is [System.Collections.IDictionary]) {
            ConvertTo-PropertyLines -Object $value -Prefix "$Prefix$key."
        }
        elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $items = @($value | ForEach-Object { Format-GraphValue $_ })
            '{0}{1}: {2}' -f $Prefix, $key, $(if ($items.Count) { $items -join ', ' } else { '-' })
        }
        else {
            '{0}{1}: {2}' -f $Prefix, $key, (Format-GraphValue $value)
        }
    }
}

function Get-MethodSummary {
    param([string]$Type, [System.Collections.IDictionary]$Raw)

    $parts = switch ($Type) {
        '#microsoft.graph.fido2AuthenticationMethod' {
            "Modell: $(Format-GraphValue $Raw['model'])"
            "Attestierung: $(Format-GraphValue $Raw['attestationLevel'])"
            "AAGUID: $(Format-GraphValue $Raw['aaGuid'])"
        }
        '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod' {
            "Gerät: $(Format-GraphValue $Raw['deviceTag'])"
            "App-Version: $(Format-GraphValue $Raw['phoneAppVersion'])"
        }
        '#microsoft.graph.phoneAuthenticationMethod' {
            "Typ: $(Format-GraphValue $Raw['phoneType'])"
            "SMS-Anmeldung: $(Format-GraphValue $Raw['smsSignInState'])"
        }
        '#microsoft.graph.hardwareOathAuthenticationMethod' {
            $device = $Raw['device']
            if ($device -is [System.Collections.IDictionary]) {
                "Seriennummer: $(Format-GraphValue $device['serialNumber'])"
                "Hersteller: $(Format-GraphValue $device['manufacturer'])"
                "Modell: $(Format-GraphValue $device['model'])"
            }
        }
        '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' {
            "Schlüsselstärke: $(Format-GraphValue $Raw['keyStrength'])"
        }
        '#microsoft.graph.platformCredentialAuthenticationMethod' {
            "Plattform: $(Format-GraphValue $Raw['platform'])"
            "Schlüsselstärke: $(Format-GraphValue $Raw['keyStrength'])"
        }
        '#microsoft.graph.temporaryAccessPassAuthenticationMethod' {
            "Gültig ab: $(Format-GraphValue $Raw['startDateTime'])"
            "Dauer: $(Format-GraphValue $Raw['lifetimeInMinutes']) min"
            "Einmalig: $(Format-GraphValue $Raw['isUsableOnce'])"
            "Nutzbar: $(Format-GraphValue $Raw['isUsable']) ($(Format-GraphValue $Raw['methodUsabilityReason']))"
        }
        '#microsoft.graph.passwordAuthenticationMethod' {
            'Erstellt = letzte Kennwortänderung'
        }
    }
    return (@($parts) -join ' | ')
}

function Test-FakeMfaMethod {
    # Vom Tool angelegte Fake-MFA-Token: Seriennummer "FAKE-..." bzw. Modell "Fake-MFA"
    param([string]$Type, [System.Collections.IDictionary]$Raw)
    if ($Type -ne '#microsoft.graph.hardwareOathAuthenticationMethod') { return $false }
    $device = $Raw['device']
    if ($device -isnot [System.Collections.IDictionary]) { return [string]$Raw['displayName'] -eq 'Fake-MFA' }
    return ([string]$device['serialNumber'] -like 'FAKE-*') -or ([string]$device['model'] -eq 'Fake-MFA')
}

function Get-M365UserAuthMethods {
    <#
    .SYNOPSIS
        Liest alle Authentifizierungsmethoden eines Benutzers und bereitet sie für die Anzeige auf.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    # Beta liefert mehr Methodentypen (z. B. Hardware-OATH, QR-Code) und Eigenschaften als v1.0.
    $uri = "beta/users/$([uri]::EscapeDataString($UserId))/authentication/methods"
    $items = New-Object System.Collections.Generic.List[object]
    while ($uri) {
        $response = Invoke-M365GraphRequest -Uri $uri
        foreach ($item in @($response['value'])) { $items.Add($item) }
        $uri = $response['@odata.nextLink']
    }

    foreach ($raw in $items) {
        $type = [string]$raw['@odata.type']
        $info = $script:AuthMethodTypes[$type]

        $displayName = @($raw['displayName'], $raw['phoneNumber'], $raw['emailAddress']) |
            Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } |
            Select-Object -First 1

        [pscustomobject]@{
            Id           = [string]$raw['id']
            Type         = $type
            TypeName     = if ($info) { $info.Name } else { $type -replace '^#microsoft\.graph\.', '' }
            DisplayName  = if ($displayName) { "$displayName" } else { '-' }
            Summary      = Get-MethodSummary -Type $type -Raw $raw
            Created      = ConvertTo-LocalDate $raw['createdDateTime']
            CanDelete    = [bool]($info -and $info.Segment)
            Segment      = if ($info) { $info.Segment } else { $null }
            Strength     = if ($info) { $info.Strength } else { 'Strong' }
            IsFakeMfa    = Test-FakeMfaMethod -Type $type -Raw $raw
            PropertyText = @(ConvertTo-PropertyLines -Object $raw) -join [Environment]::NewLine
        }
    }
}

function Get-M365UserSignInPreferences {
    <#
    .SYNOPSIS
        Liest die bevorzugte MFA-Methode und den Status der systembevorzugten MFA.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    $uri = "beta/users/$([uri]::EscapeDataString($UserId))/authentication/signInPreferences"
    $response = Invoke-M365GraphRequest -Uri $uri
    $preferred = [string]$response['userPreferredMethodForSecondaryAuthentication']

    $preferredName = if ([string]::IsNullOrWhiteSpace($preferred)) { 'Nicht festgelegt' }
                     elseif ($script:PreferredMethodNames.ContainsKey($preferred)) { $script:PreferredMethodNames[$preferred] }
                     else { $preferred }

    [pscustomobject]@{
        PreferredMethod       = $preferredName
        SystemPreferredActive = Format-GraphValue $response['isSystemPreferredAuthenticationMethodEnabled']
    }
}

function Get-M365MfaAssessment {
    <#
    .SYNOPSIS
        Bewertet die MFA-Methoden eines Benutzers als Ampel (Red/Yellow/Green) mit Empfehlungen.
    .PARAMETER Methods
        Objekte aus Get-M365UserAuthMethods.
    .PARAMETER HasAdminRoles
        Für Administratoren werden phishing-resistente Methoden empfohlen.
    #>
    param(
        [object[]]$Methods = @(),
        [bool]$HasAdminRoles = $false
    )

    $real = @($Methods | Where-Object { -not $_.IsFakeMfa })
    $phishingResistant = @($real | Where-Object Strength -eq 'PhishingResistant')
    $strong = @($real | Where-Object { $_.Strength -in 'PhishingResistant', 'Strong' })
    $weak = @($real | Where-Object Strength -eq 'Weak')
    $temporary = @($real | Where-Object Strength -eq 'Temporary')
    $fake = @($Methods | Where-Object IsFakeMfa)
    $hints = New-Object System.Collections.Generic.List[string]

    if ($strong.Count) {
        $level = 'Green'
        $title = if ($phishingResistant.Count) { 'Starkes MFA (phishing-resistent)' } else { 'Starkes MFA' }
        if ($HasAdminRoles -and -not $phishingResistant.Count) {
            $hints.Add('Administrator ohne phishing-resistente Methode: FIDO2-Stick, Passkey oder Windows Hello ergänzen.')
        }
        if ($weak.Count) { $hints.Add('SMS/Anruf ist zusätzlich registriert und kann entfernt werden.') }
        if ($fake.Count) { $hints.Add('Fake-MFA ist noch registriert und kann entfernt werden.') }
    }
    elseif ($weak.Count) {
        $level = 'Yellow'
        $title = 'Nur schwaches MFA (SMS/Anruf)'
        $hints.Add('Authenticator-App, TOTP oder FIDO2 einrichten und SMS/Anruf anschließend entfernen.')
    }
    elseif ($fake.Count) {
        $level = 'Yellow'
        $title = 'Nur Fake-MFA (Anmeldung blockiert)'
        $hints.Add('Der Benutzer kann sich nicht anmelden, bis eine echte Methode eingerichtet ist (z. B. per TAP).')
    }
    elseif ($temporary.Count) {
        $level = 'Yellow'
        $title = 'Nur Temporary Access Pass'
        $hints.Add('Benutzer sollte mit dem TAP jetzt eine dauerhafte Methode (Authenticator, FIDO2) registrieren.')
    }
    else {
        $level = 'Red'
        $title = 'Kein MFA - nur Kennwort'
        $hints.Add('MFA einrichten: FIDO2-Stick, TOTP-Karte oder TAP ausstellen, damit der Benutzer den Authenticator registriert.')
    }

    if ($temporary.Count -and $level -eq 'Green') { $hints.Add('Aktiver TAP vorhanden - nach der Einrichtung löschen.') }

    [pscustomobject]@{
        Level = $level
        Title = $title
        Hints = @($hints)
    }
}

function Get-M365RoleDefinitionNames {
    # Rollen-ID -> Anzeigename, einmal pro Sitzung geladen
    if (-not $script:RoleDefinitionNames) {
        $names = @{}
        $uri = 'v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName'
        while ($uri) {
            $response = Invoke-M365GraphRequest -Uri $uri
            foreach ($definition in @($response['value'])) { $names[[string]$definition['id']] = [string]$definition['displayName'] }
            $uri = $response['@odata.nextLink']
        }
        $script:RoleDefinitionNames = $names
    }
    $script:RoleDefinitionNames
}

function Get-M365UserAdminRoles {
    <#
    .SYNOPSIS
        Liefert die Verzeichnisrollen eines Benutzers: aktiv (direkt oder über Gruppen) und PIM-berechtigt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    $names = Get-M365RoleDefinitionNames
    $filter = [uri]::EscapeDataString("principalId eq '$UserId'")

    # Transitive Zuweisungen enthalten auch Rollen über rollenzuweisbare Gruppen (Beta); sonst nur direkte.
    try {
        $assignments = @((Invoke-M365GraphRequest -Uri "beta/roleManagement/directory/transitiveRoleAssignments?`$filter=$filter&`$count=true" `
            -Headers @{ ConsistencyLevel = 'eventual' })['value'])
    }
    catch {
        $assignments = @((Invoke-M365GraphRequest -Uri "v1.0/roleManagement/directory/roleAssignments?`$filter=$filter")['value'])
    }

    # PIM-berechtigte Rollen (benötigt Entra ID P2; ohne Lizenz einfach überspringen)
    $eligible = @()
    try {
        $eligible = @((Invoke-M365GraphRequest -Uri "v1.0/roleManagement/directory/roleEligibilityScheduleInstances?`$filter=$filter")['value'])
    }
    catch { }

    $format = {
        param($Item, [string]$Kind)
        $roleId = [string]$Item['roleDefinitionId']
        $scope = [string]$Item['directoryScopeId']
        [pscustomobject]@{
            RoleName = if ($names.ContainsKey($roleId)) { $names[$roleId] } else { $roleId }
            Kind     = if ($Kind -eq 'Aktiv' -and [string]$Item['principalId'] -ne $UserId) { 'Aktiv (über Gruppe)' } else { $Kind }
            Scope    = if ($scope -eq '/') { 'Mandant' } elseif ($scope -like '/administrativeUnits/*') { 'Verwaltungseinheit' } else { $scope }
        }
    }

    @(
        $assignments | Where-Object { $null -ne $_ } | ForEach-Object { & $format $_ 'Aktiv' }
        $eligible | Where-Object { $null -ne $_ } | ForEach-Object { & $format $_ 'Berechtigt (PIM)' }
    ) | Sort-Object RoleName, Kind -Unique
}

function Remove-M365UserAuthMethod {
    <#
    .SYNOPSIS
        Löscht eine Authentifizierungsmethode (Objekt aus Get-M365UserAuthMethods) eines Benutzers.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)]$Method
    )

    if (-not $Method.CanDelete) {
        throw "Die Methode '$($Method.TypeName)' kann nicht gelöscht werden."
    }

    $userPart = [uri]::EscapeDataString($UserId)
    # QR-Code + PIN ist ein Singleton ohne Methoden-ID in der URL.
    $uri = if ($Method.Segment -eq 'qrCodePinMethod') {
        "beta/users/$userPart/authentication/qrCodePinMethod"
    }
    else {
        "beta/users/$userPart/authentication/$($Method.Segment)/$([uri]::EscapeDataString($Method.Id))"
    }

    if ($PSCmdlet.ShouldProcess("$($Method.TypeName) ($($Method.Id))", 'Löschen')) {
        Invoke-M365GraphRequest -Method DELETE -Uri $uri | Out-Null
    }
}

#endregion

Export-ModuleMember -Function @(
    'Assert-GraphModules'
    'Test-M365GraphConnection'
    'Connect-M365Graph'
    'Disconnect-M365Graph'
    'Request-M365GraphScopes'
    'Invoke-M365GraphRequest'
    'Get-M365VerifiedDomains'
    'ConvertTo-LocalDate'
    'Find-M365User'
    'Get-M365UserAuthMethods'
    'Get-M365UserSignInPreferences'
    'Get-M365MfaAssessment'
    'Get-M365UserAdminRoles'
    'Remove-M365UserAuthMethod'
)
