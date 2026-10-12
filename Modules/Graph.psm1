<#
.SYNOPSIS
    Microsoft Graph integration of the M365 MFA Administration Tool.

.DESCRIPTION
    Module management, sign-in, user search, and reading and deleting
    authentication methods. All Graph calls go through Invoke-M365GraphRequest
    (Invoke-MgGraphRequest), so only Microsoft.Graph.Authentication is required.
#>

Set-StrictMode -Version Latest

$script:GraphScopes = @(
    'User.Read.All'
    'UserAuthenticationMethod.Read.All'
    'UserAuthenticationMethod.ReadWrite.All'
    'Policy.ReadWrite.AuthenticationMethod'   # Create/delete hardware OATH tokens in the directory
    'RoleManagement.Read.Directory'           # Show the user's administrative roles
)

$script:RoleDefinitionNames = $null   # Cache: role ID -> display name

#region Module management

# All PowerShell modules the tool needs (installed for the current user from the PowerShell Gallery)
$script:RequiredModules = @(
    @{ Name = 'Microsoft.Graph.Authentication' }
    @{ Name = 'Microsoft.Graph.Identity.SignIns' }                                         # required by DSInternals.Passkeys
    @{ Name = 'DSInternals.Passkeys'; RequiredVersion = '1.0.6'; SkipPublisherCheck = $true } # FIDO2, newer versions have a changed API
    @{ Name = 'QRCodeGenerator' }                                                          # QR code for programmable TOTP cards
)

function Get-MissingModules {
    <#
    .SYNOPSIS
        Returns the required modules that are not installed yet.
    #>
    Add-UserModulePath
    foreach ($module in $script:RequiredModules) {
        $installed = @(Get-Module -ListAvailable -Name $module.Name |
            Where-Object { -not $module['RequiredVersion'] -or $_.Version -eq [version]$module['RequiredVersion'] })
        if (-not $installed.Count) {
            [pscustomobject]@{
                Name               = $module.Name
                RequiredVersion    = $module['RequiredVersion']
                SkipPublisherCheck = [bool]$module['SkipPublisherCheck']
            }
        }
    }
}

function Install-RequiredModule {
    <#
    .SYNOPSIS
        Installs a module for the current user without any console prompts.
    .DESCRIPTION
        Runs in a background job so that the GUI stays responsive and no interactive prompt
        (NuGet provider, untrusted repository) can block it. The NuGet provider is installed
        silently if needed.
    .PARAMETER Wait
        Called with milliseconds while waiting for the job (GUI: wait without freezing).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RequiredVersion,
        [switch]$SkipPublisherCheck,
        [scriptblock]$Wait = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    )

    $job = Start-Job -ArgumentList $Name, $RequiredVersion, ([bool]$SkipPublisherCheck) -ScriptBlock {
        param($Name, $RequiredVersion, $SkipPublisherCheck)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        # The PowerShell Gallery requires TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }

        $params = @{ Name = $Name; Repository = 'PSGallery'; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true; Confirm = $false }
        if ($RequiredVersion) { $params.RequiredVersion = $RequiredVersion }
        if ($SkipPublisherCheck) { $params.SkipPublisherCheck = $true }
        Install-Module @params
    }

    try {
        while ($job.State -in 'NotStarted', 'Running') { & $Wait 300 }
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
        if ($job.State -ne 'Completed') { throw $job.ChildJobs[0].JobStateInfo.Reason }
    }
    catch {
        throw (T 'Module.InstallFailed' $Name $_.Exception.Message)
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    Add-UserModulePath
    $installed = @(Get-Module -ListAvailable -Name $Name |
        Where-Object { -not $RequiredVersion -or $_.Version -eq [version]$RequiredVersion })
    if (-not $installed.Count) { throw (T 'Module.NotFoundAfterInstall' $Name) }
}

function Add-UserModulePath {
    # Install-Module -Scope CurrentUser installs to <Documents>\WindowsPowerShell\Modules.
    # When powershell.exe is started e.g. from VS Code or pwsh 7, this path is sometimes missing from PSModulePath.
    $userModulePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
    $paths = @($env:PSModulePath -split ';' | Where-Object { $_ })
    if ($paths -notcontains $userModulePath) {
        $env:PSModulePath = (@($userModulePath) + $paths) -join ';'
    }
}

function Get-CompatibleAuthenticationVersion {
    # DSInternals.Passkeys (FIDO2) loads Microsoft.Graph.Identity.SignIns, which requires an exact version of
    # Microsoft.Graph.Authentication. If a different version is already loaded, the import fails.
    # Therefore pick the Authentication version that matches the newest installed SignIns version.
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
        Ensures that Microsoft.Graph.Authentication is installed and loaded.
    #>
    $moduleName = 'Microsoft.Graph.Authentication'
    Add-UserModulePath
    if (Get-Module -Name $moduleName) { return }

    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Host (T 'Module.Installing' $moduleName) -ForegroundColor Cyan
        Install-RequiredModule -Name $moduleName
    }

    $importParams = @{ Name = $moduleName; ErrorAction = 'Stop' }
    $compatibleVersion = Get-CompatibleAuthenticationVersion
    if ($compatibleVersion) { $importParams.RequiredVersion = $compatibleVersion }

    try {
        Import-Module @importParams
        Write-Host (T 'Module.Loaded' $moduleName) -ForegroundColor Green
    }
    catch {
        throw (T 'Module.LoadFailed' $moduleName $_.Exception.Message)
    }
}

#endregion

#region Connection

function Test-M365GraphConnection {
    <#
    .SYNOPSIS
        Returns $true if a signed-in Graph session exists.
    #>
    # Before the first sign-in, the Graph module may not be loaded yet.
    if (-not (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)) { return $false }
    $context = Get-MgContext -ErrorAction SilentlyContinue
    return ($null -ne $context -and -not [string]::IsNullOrWhiteSpace($context.Account))
}

function Connect-M365Graph {
    <#
    .SYNOPSIS
        Signs in to Microsoft Graph interactively and returns the account and tenant.
    #>
    Assert-GraphModules

    try {
        Connect-MgGraph -Scopes $script:GraphScopes -NoWelcome -ErrorAction Stop | Out-Null
    }
    catch {
        throw (T 'Graph.ConnectFailed' $_.Exception.Message)
    }

    $context = Get-MgContext
    if ($null -eq $context) {
        throw (T 'Graph.ConnectFailed' (T 'Graph.NoContext'))
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
        Requests additional permissions (signs in again only if some are missing).
    .OUTPUTS
        Account and tenant of the (possibly new) session.
    #>
    param([Parameter(Mandatory)][string[]]$Scopes)

    $context = Get-MgContext
    $missing = @($Scopes | Where-Object { @($context.Scopes) -notcontains $_ })
    if ($missing.Count) {
        try {
            Connect-MgGraph -Scopes (@($script:GraphScopes) + $Scopes | Select-Object -Unique) -NoWelcome -ErrorAction Stop | Out-Null
        }
        catch {
            throw (T 'Graph.ScopesDenied' ($missing -join ', ') $_.Exception.Message)
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
        Disconnects the Graph session, if one exists.
    #>
    if (Test-M365GraphConnection) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    $script:RoleDefinitionNames = $null
}

#endregion

#region Graph requests

function Get-GraphErrorMessage {
    param([Parameter(Mandatory)]$ErrorRecord)

    # The Graph SDK often wraps errors in AggregateExceptions ("One or more errors occurred").
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
        Wrapper around Invoke-MgGraphRequest with a JSON body and readable error messages.
    .NOTES
        Intentionally not named "Invoke-GraphRequest": the Graph SDK defines an alias with that
        name for Invoke-MgGraphRequest, and aliases take precedence over functions.
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
        throw (T 'Graph.RequestFailed' $Method ($Uri -replace '\?.*$', '') (Get-GraphErrorMessage $_))
    }
}

function ConvertTo-LocalDate {
    <#
    .SYNOPSIS
        Converts a Graph timestamp (string or DateTime) to local time.
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

#region Users and domains

function Find-M365User {
    <#
    .SYNOPSIS
        Finds users by object ID or name prefix (display name, given name, surname, UPN, email).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SearchTerm,
        [int]$Top = 50
    )

    if (-not (Test-M365GraphConnection)) {
        throw (T 'Graph.NotConnected')
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
        Returns the verified domains of the tenant, default domain first.
    #>
    $response = Invoke-M365GraphRequest -Uri 'v1.0/domains?$select=id,isVerified,isDefault'
    @($response['value']) |
        Where-Object { $null -ne $_ -and $_['isVerified'] } |
        Sort-Object @{ Expression = { [bool]$_['isDefault'] }; Descending = $true }, @{ Expression = { [string]$_['id'] } } |
        ForEach-Object { [string]$_['id'] }
}

#endregion

#region Authentication methods

# Graph type -> display name key, URL segment for deletion ($null = cannot be deleted) and strength:
#   PhishingResistant / Strong = full MFA, Weak = outdated/insecure,
#   Temporary = interim only (TAP), None = not an MFA factor
$script:AuthMethodTypes = @{
    '#microsoft.graph.fido2AuthenticationMethod'                              = @{ Name = 'MethodType.Fido2';                      Segment = 'fido2Methods';                              Strength = 'PhishingResistant' }
    '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod'            = @{ Name = 'MethodType.WindowsHello';               Segment = 'windowsHelloForBusinessMethods';            Strength = 'PhishingResistant' }
    '#microsoft.graph.platformCredentialAuthenticationMethod'                 = @{ Name = 'MethodType.PlatformCredential';         Segment = 'platformCredentialMethods';                 Strength = 'PhishingResistant' }
    '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'             = @{ Name = 'MethodType.Authenticator';              Segment = 'microsoftAuthenticatorMethods';             Strength = 'Strong' }
    '#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod' = @{ Name = 'MethodType.PasswordlessAuthenticator';  Segment = 'passwordlessMicrosoftAuthenticatorMethods'; Strength = 'Strong' }
    '#microsoft.graph.softwareOathAuthenticationMethod'                       = @{ Name = 'MethodType.SoftwareOath';               Segment = 'softwareOathMethods';                       Strength = 'Strong' }
    '#microsoft.graph.hardwareOathAuthenticationMethod'                       = @{ Name = 'MethodType.HardwareOath';               Segment = 'hardwareOathMethods';                       Strength = 'Strong' }
    '#microsoft.graph.externalAuthenticationMethod'                           = @{ Name = 'MethodType.External';                   Segment = 'externalAuthenticationMethods';             Strength = 'Strong' }
    '#microsoft.graph.phoneAuthenticationMethod'                              = @{ Name = 'MethodType.Phone';                      Segment = 'phoneMethods';                              Strength = 'Weak' }
    '#microsoft.graph.qrCodePinAuthenticationMethod'                          = @{ Name = 'MethodType.QrCodePin';                  Segment = 'qrCodePinMethod';                           Strength = 'Weak' }
    '#microsoft.graph.temporaryAccessPassAuthenticationMethod'                = @{ Name = 'MethodType.Tap';                        Segment = 'temporaryAccessPassMethods';                Strength = 'Temporary' }
    '#microsoft.graph.emailAuthenticationMethod'                              = @{ Name = 'MethodType.Email';                      Segment = 'emailMethods';                              Strength = 'None' }
    '#microsoft.graph.passwordAuthenticationMethod'                           = @{ Name = 'MethodType.Password';                   Segment = $null;                                       Strength = 'None' }
}

# Preferred MFA method according to Graph -> text key
$script:PreferredMethodKeys = @{
    'push'                 = 'Preferred.Push'
    'oath'                 = 'Preferred.Oath'
    'voiceMobile'          = 'Preferred.VoiceMobile'
    'voiceAlternateMobile' = 'Preferred.VoiceAlternateMobile'
    'voiceOffice'          = 'Preferred.VoiceOffice'
    'sms'                  = 'Preferred.Sms'
    'none'                 = 'Preferred.None'
}

function Format-GraphValue {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '-' }
    if ($Value -is [bool]) { return $(if ($Value) { T 'Common.Yes' } else { T 'Common.No' }) }
    if ($Value -is [datetime] -or "$Value" -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}') {
        $date = ConvertTo-LocalDate $Value
        if ($date) { return $date.ToString((T 'Format.DateTimeSeconds')) }
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
            "$(T 'Summary.Model'): $(Format-GraphValue $Raw['model'])"
            "$(T 'Summary.Attestation'): $(Format-GraphValue $Raw['attestationLevel'])"
            "$(T 'Summary.Aaguid'): $(Format-GraphValue $Raw['aaGuid'])"
        }
        '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod' {
            "$(T 'Summary.Device'): $(Format-GraphValue $Raw['deviceTag'])"
            "$(T 'Summary.AppVersion'): $(Format-GraphValue $Raw['phoneAppVersion'])"
        }
        '#microsoft.graph.phoneAuthenticationMethod' {
            "$(T 'Summary.PhoneType'): $(Format-GraphValue $Raw['phoneType'])"
            "$(T 'Summary.SmsSignIn'): $(Format-GraphValue $Raw['smsSignInState'])"
        }
        '#microsoft.graph.hardwareOathAuthenticationMethod' {
            $device = $Raw['device']
            if ($device -is [System.Collections.IDictionary]) {
                "$(T 'Summary.Serial'): $(Format-GraphValue $device['serialNumber'])"
                "$(T 'Summary.Manufacturer'): $(Format-GraphValue $device['manufacturer'])"
                "$(T 'Summary.Model'): $(Format-GraphValue $device['model'])"
            }
        }
        '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' {
            "$(T 'Summary.KeyStrength'): $(Format-GraphValue $Raw['keyStrength'])"
        }
        '#microsoft.graph.platformCredentialAuthenticationMethod' {
            "$(T 'Summary.Platform'): $(Format-GraphValue $Raw['platform'])"
            "$(T 'Summary.KeyStrength'): $(Format-GraphValue $Raw['keyStrength'])"
        }
        '#microsoft.graph.temporaryAccessPassAuthenticationMethod' {
            "$(T 'Summary.ValidFrom'): $(Format-GraphValue $Raw['startDateTime'])"
            "$(T 'Summary.Duration'): $(Format-GraphValue $Raw['lifetimeInMinutes']) min"
            "$(T 'Summary.UsableOnce'): $(Format-GraphValue $Raw['isUsableOnce'])"
            "$(T 'Summary.Usable'): $(Format-GraphValue $Raw['isUsable']) ($(Format-GraphValue $Raw['methodUsabilityReason']))"
        }
        '#microsoft.graph.passwordAuthenticationMethod' {
            T 'Summary.PasswordCreated'
        }
    }
    return (@($parts) -join ' | ')
}

function Test-FakeMfaMethod {
    # Fake MFA tokens created by this tool: serial number "FAKE-..." or model "Fake-MFA"
    param([string]$Type, [System.Collections.IDictionary]$Raw)
    if ($Type -ne '#microsoft.graph.hardwareOathAuthenticationMethod') { return $false }
    $device = $Raw['device']
    if ($device -isnot [System.Collections.IDictionary]) { return [string]$Raw['displayName'] -eq 'Fake-MFA' }
    return ([string]$device['serialNumber'] -like 'FAKE-*') -or ([string]$device['model'] -eq 'Fake-MFA')
}

function Get-M365UserAuthMethods {
    <#
    .SYNOPSIS
        Reads all authentication methods of a user and prepares them for display.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    # Beta returns more method types (e.g. hardware OATH, QR code) and properties than v1.0.
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
            TypeName     = if ($info) { T $info.Name } else { $type -replace '^#microsoft\.graph\.', '' }
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
        Reads the preferred MFA method and the status of system-preferred MFA.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    $uri = "beta/users/$([uri]::EscapeDataString($UserId))/authentication/signInPreferences"
    $response = Invoke-M365GraphRequest -Uri $uri
    $preferred = [string]$response['userPreferredMethodForSecondaryAuthentication']

    $preferredName = if ([string]::IsNullOrWhiteSpace($preferred)) { T 'Preferred.NotSet' }
                     elseif ($script:PreferredMethodKeys.ContainsKey($preferred)) { T $script:PreferredMethodKeys[$preferred] }
                     else { $preferred }

    [pscustomobject]@{
        PreferredMethod       = $preferredName
        SystemPreferredActive = Format-GraphValue $response['isSystemPreferredAuthenticationMethodEnabled']
    }
}

function Get-M365MfaAssessment {
    <#
    .SYNOPSIS
        Rates a user's MFA methods as a traffic light (Red/Yellow/Green) with recommendations.
    .PARAMETER Methods
        Objects from Get-M365UserAuthMethods.
    .PARAMETER HasAdminRoles
        Phishing-resistant methods are recommended for administrators.
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
        $title = if ($phishingResistant.Count) { T 'Mfa.Title.PhishingResistant' } else { T 'Mfa.Title.Strong' }
        if ($HasAdminRoles -and -not $phishingResistant.Count) {
            $hints.Add((T 'Mfa.Hint.AdminNoPhishingResistant'))
        }
        if ($weak.Count) { $hints.Add((T 'Mfa.Hint.RemoveWeak')) }
        if ($fake.Count) { $hints.Add((T 'Mfa.Hint.RemoveFake')) }
    }
    elseif ($weak.Count) {
        $level = 'Yellow'
        $title = T 'Mfa.Title.Weak'
        $hints.Add((T 'Mfa.Hint.UpgradeWeak'))
    }
    elseif ($fake.Count) {
        $level = 'Yellow'
        $title = T 'Mfa.Title.FakeOnly'
        $hints.Add((T 'Mfa.Hint.FakeOnly'))
    }
    elseif ($temporary.Count) {
        $level = 'Yellow'
        $title = T 'Mfa.Title.TapOnly'
        $hints.Add((T 'Mfa.Hint.TapOnly'))
    }
    else {
        $level = 'Red'
        $title = T 'Mfa.Title.None'
        $hints.Add((T 'Mfa.Hint.None'))
    }

    if ($temporary.Count -and $level -eq 'Green') { $hints.Add((T 'Mfa.Hint.RemoveTap')) }

    [pscustomobject]@{
        Level = $level
        Title = $title
        Hints = @($hints)
    }
}

function Get-M365RoleDefinitionNames {
    # Role ID -> display name, loaded once per session
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
        Returns the directory roles of a user: active (direct or via groups) and PIM-eligible.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    $names = Get-M365RoleDefinitionNames
    $filter = [uri]::EscapeDataString("principalId eq '$UserId'")

    # Transitive assignments also include roles via role-assignable groups (beta); otherwise direct ones only.
    try {
        $assignments = @((Invoke-M365GraphRequest -Uri "beta/roleManagement/directory/transitiveRoleAssignments?`$filter=$filter&`$count=true" `
            -Headers @{ ConsistencyLevel = 'eventual' })['value'])
    }
    catch {
        $assignments = @((Invoke-M365GraphRequest -Uri "v1.0/roleManagement/directory/roleAssignments?`$filter=$filter")['value'])
    }

    # PIM-eligible roles (requires Entra ID P2; simply skipped without a license)
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
            Kind     = if ($Kind -eq 'Active' -and [string]$Item['principalId'] -ne $UserId) { T 'Role.Kind.ActiveViaGroup' } else { T "Role.Kind.$Kind" }
            Scope    = if ($scope -eq '/') { T 'Role.Scope.Tenant' } elseif ($scope -like '/administrativeUnits/*') { T 'Role.Scope.AdminUnit' } else { $scope }
        }
    }

    @(
        $assignments | Where-Object { $null -ne $_ } | ForEach-Object { & $format $_ 'Active' }
        $eligible | Where-Object { $null -ne $_ } | ForEach-Object { & $format $_ 'Eligible' }
    ) | Sort-Object RoleName, Kind -Unique
}

function Remove-M365UserAuthMethod {
    <#
    .SYNOPSIS
        Deletes an authentication method (object from Get-M365UserAuthMethods) of a user.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)]$Method
    )

    if (-not $Method.CanDelete) {
        throw (T 'Methods.CannotDelete' $Method.TypeName)
    }

    $userPart = [uri]::EscapeDataString($UserId)
    # QR code + PIN is a singleton without a method ID in the URL.
    $uri = if ($Method.Segment -eq 'qrCodePinMethod') {
        "beta/users/$userPart/authentication/qrCodePinMethod"
    }
    else {
        "beta/users/$userPart/authentication/$($Method.Segment)/$([uri]::EscapeDataString($Method.Id))"
    }

    if ($PSCmdlet.ShouldProcess("$($Method.TypeName) ($($Method.Id))", 'Delete')) {
        Invoke-M365GraphRequest -Method DELETE -Uri $uri | Out-Null
    }
}

#endregion

Export-ModuleMember -Function @(
    'Assert-GraphModules'
    'Get-MissingModules'
    'Install-RequiredModule'
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
