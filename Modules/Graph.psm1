function Add-UserModulePath {
    # Install-Module -Scope CurrentUser installiert nach <Dokumente>\WindowsPowerShell\Modules.
    # Wird powershell.exe z. B. aus VS Code oder pwsh 7 gestartet, fehlt dieser Pfad teils in PSModulePath.
    $userModulePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
    $paths = $env:PSModulePath -split ';' | Where-Object { $_ }
    if ($paths -notcontains $userModulePath) {
        $env:PSModulePath = (@($userModulePath) + $paths) -join ';'
    }
}

function Get-CompatibleAuthenticationVersion {
    # DSInternals.Passkeys (FIDO2) lädt Microsoft.Graph.Identity.SignIns, das eine exakte Version von
    # Microsoft.Graph.Authentication voraussetzt. Ist bereits eine andere Version geladen, schlägt der Import fehl.
    # Daher die Authentication-Version laden, die zur neuesten installierten SignIns-Version passt.
    $signIns = Get-Module -ListAvailable -Name 'Microsoft.Graph.Identity.SignIns' |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $signIns) { return $null }
    $required = $signIns.RequiredModules | Where-Object Name -eq 'Microsoft.Graph.Authentication' | Select-Object -First 1
    if (-not $required -or -not $required.Version) { return $null }
    $installed = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' | Where-Object Version -eq $required.Version
    if ($installed) { return $required.Version }
    return $null
}

function Assert-GraphModules {
    Add-UserModulePath

    # Alle Graph-Aufrufe laufen über Invoke-MgGraphRequest, daher reicht das Authentication-Modul.
    $requiredModules = @(
        'Microsoft.Graph.Authentication'
    )

    foreach ($moduleName in $requiredModules) {
        $installedModule = Get-Module -ListAvailable -Name $moduleName |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if (-not $installedModule) {
            Write-Host ""
            Write-Host "Das Modul '$moduleName' fehlt." -ForegroundColor Yellow
            Write-Host "Installation aus der PowerShell Gallery für den aktuellen Benutzer ..." -ForegroundColor Cyan

            try {
                Install-Module `
                    -Name $moduleName `
                    -Repository PSGallery `
                    -Scope CurrentUser `
                    -Force `
                    -AllowClobber `
                    -ErrorAction Stop
            }
            catch {
                throw "Installation von '$moduleName' fehlgeschlagen: $($_.Exception.Message)"
            }

            $installedModule = Get-Module -ListAvailable -Name $moduleName |
                Sort-Object Version -Descending |
                Select-Object -First 1

            if (-not $installedModule) {
                throw "Das Modul '$moduleName' wurde installiert, ist in dieser PowerShell-Sitzung aber nicht auffindbar."
            }

            Write-Host "'$moduleName' wurde installiert." -ForegroundColor Green
        }

        try {
            if (Get-Module -Name $moduleName) { continue }
            $importParams = @{ Name = $moduleName; ErrorAction = 'Stop' }
            $authVersion = Get-CompatibleAuthenticationVersion
            if ($moduleName -eq 'Microsoft.Graph.Authentication' -and $authVersion) {
                $importParams.RequiredVersion = $authVersion
            }
            Import-Module @importParams
            Write-Host "'$moduleName' ist geladen." -ForegroundColor Green
        }
        catch {
            throw "Das Modul '$moduleName' konnte nicht geladen werden: $($_.Exception.Message)"
        }
    }
}

$script:GraphScopes = @(
    'User.Read.All',
    'UserAuthenticationMethod.Read.All',
    'UserAuthenticationMethod.ReadWrite.All',
    # Anlegen/Löschen von Hardware-OATH-Token im Verzeichnis (TOTP-Karten, Fake-MFA)
    'Policy.ReadWrite.AuthenticationMethod'
)

function Test-M365GraphConnection {
    # Vor der ersten Anmeldung ist das Graph-Modul ggf. noch nicht geladen.
    if (-not (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)) {
        return $false
    }
    $context = Get-MgContext -ErrorAction SilentlyContinue
    return ($null -ne $context -and -not [string]::IsNullOrWhiteSpace($context.Account))
}

function Connect-M365Graph {
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

    return [pscustomobject]@{
        Account  = $context.Account
        TenantId = $context.TenantId
        Scopes   = $context.Scopes
    }
}

function Disconnect-M365Graph {
    if (Test-M365GraphConnection) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}

function Find-M365User {
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
        # Direkte Suche nach Objekt-ID
        $users = @(Invoke-M365GraphRequest -Uri "v1.0/users/$term`?`$select=$select")
    }
    else {
        $value = $term.Replace("'", "''")
        $filter = "startswith(displayName,'{0}') or startswith(givenName,'{0}') or startswith(surname,'{0}') or startswith(userPrincipalName,'{0}') or startswith(mail,'{0}')" -f $value
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
        catch { $message = $ErrorRecord.ErrorDetails.Message }
    }
    return $message
}

function Invoke-M365GraphRequest {
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

#region Authentifizierungsmethoden

# Graph-Typ -> Anzeigename und URL-Segment zum Löschen ($null = nicht löschbar).
$script:AuthMethodTypes = @{
    '#microsoft.graph.fido2AuthenticationMethod'                           = @{ Name = 'FIDO2 Security Key / Passkey';          Segment = 'fido2Methods' }
    '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'          = @{ Name = 'Microsoft Authenticator';               Segment = 'microsoftAuthenticatorMethods' }
    '#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod' = @{ Name = 'Authenticator (kennwortlos, veraltet)'; Segment = 'passwordlessMicrosoftAuthenticatorMethods' }
    '#microsoft.graph.phoneAuthenticationMethod'                           = @{ Name = 'Telefon (SMS/Anruf)';                   Segment = 'phoneMethods' }
    '#microsoft.graph.emailAuthenticationMethod'                           = @{ Name = 'E-Mail (SSPR)';                         Segment = 'emailMethods' }
    '#microsoft.graph.softwareOathAuthenticationMethod'                    = @{ Name = 'Software-OATH (TOTP)';                  Segment = 'softwareOathMethods' }
    '#microsoft.graph.hardwareOathAuthenticationMethod'                    = @{ Name = 'Hardware-OATH (TOTP-Token/-Karte)';     Segment = 'hardwareOathMethods' }
    '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod'         = @{ Name = 'Windows Hello for Business';            Segment = 'windowsHelloForBusinessMethods' }
    '#microsoft.graph.temporaryAccessPassAuthenticationMethod'             = @{ Name = 'Befristeter Zugriffspass (TAP)';        Segment = 'temporaryAccessPassMethods' }
    '#microsoft.graph.platformCredentialAuthenticationMethod'              = @{ Name = 'Platform Credential (macOS)';           Segment = 'platformCredentialMethods' }
    '#microsoft.graph.qrCodePinAuthenticationMethod'                       = @{ Name = 'QR-Code + PIN';                         Segment = 'qrCodePinMethod' }
    '#microsoft.graph.externalAuthenticationMethod'                        = @{ Name = 'Externe Authentifizierungsmethode';     Segment = 'externalAuthenticationMethods' }
    '#microsoft.graph.passwordAuthenticationMethod'                        = @{ Name = 'Kennwort';                              Segment = $null }
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

function ConvertTo-LocalDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToLocalTime() }
    try {
        return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    }
    catch { return $null }
}

function Format-GraphValue {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '-' }
    if ($Value -is [bool]) { if ($Value) { return 'Ja' } else { return 'Nein' } }
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

function Get-M365UserAuthMethods {
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
        $typeName = if ($info) { $info.Name } else { $type -replace '^#microsoft\.graph\.', '' }

        $displayName = @($raw['displayName'], $raw['phoneNumber'], $raw['emailAddress']) |
            Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } |
            Select-Object -First 1

        [pscustomobject]@{
            Id           = [string]$raw['id']
            Type         = $type
            TypeName     = $typeName
            DisplayName  = if ($displayName) { "$displayName" } else { '-' }
            Summary      = Get-MethodSummary -Type $type -Raw $raw
            Created      = ConvertTo-LocalDate $raw['createdDateTime']
            CanDelete    = [bool]($info -and $info.Segment)
            Segment      = if ($info) { $info.Segment } else { $null }
            PropertyText = (@(ConvertTo-PropertyLines -Object $raw) -join [Environment]::NewLine)
        }
    }
}

function Get-M365UserSignInPreferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    $uri = "beta/users/$([uri]::EscapeDataString($UserId))/authentication/signInPreferences"
    $response = Invoke-M365GraphRequest -Uri $uri

    $preferred = [string]$response['userPreferredMethodForSecondaryAuthentication']
    [pscustomobject]@{
        PreferredMethod       = if ([string]::IsNullOrWhiteSpace($preferred)) { 'Nicht festgelegt' }
                                elseif ($script:PreferredMethodNames.ContainsKey($preferred)) { $script:PreferredMethodNames[$preferred] }
                                else { $preferred }
        SystemPreferredActive = Format-GraphValue $response['isSystemPreferredAuthenticationMethodEnabled']
    }
}

function Remove-M365UserAuthMethod {
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

Export-ModuleMember -Function Assert-GraphModules, Test-M365GraphConnection, Connect-M365Graph, Disconnect-M365Graph, Find-M365User,
    Get-M365UserAuthMethods, Get-M365UserSignInPreferences, Remove-M365UserAuthMethod,
    Invoke-M365GraphRequest, ConvertTo-LocalDate
