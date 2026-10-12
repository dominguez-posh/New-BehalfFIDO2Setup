<#
.SYNOPSIS
    Sets up MFA methods on behalf of a user.

.DESCRIPTION
    FIDO2 (DSInternals.Passkeys), hardware OATH/TOTP (fixed and programmable cards, fake MFA)
    and Temporary Access Pass. Requires the Graph functions from Graph.psm1
    (Invoke-M365GraphRequest, ConvertTo-LocalDate), which must be loaded globally.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Methods are addressed by language-independent IDs (see Invoke-MfaProvisioning);
# the display names come from the language files (Languages/*.json).

$script:TapLifetimeMinutes  = 120
$script:OathManufacturer    = 'unique projects'
$script:OathIssuer          = 'Microsoft 365'
$script:Base32Alphabet      = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
$script:Fido2ModuleVersion  = '1.0.6'   # Newer DSInternals.Passkeys versions have a changed API
$script:AuthMethodPolicyUrl = 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/AuthenticationMethodsMenuBlade/~/AdminAuthMethods'

#region General helpers

function New-ProvisioningResult {
    # AddedMethodIds/RemovedMethodIds: IDs of the created or removed methods.
    # After provisioning, the GUI uses them to wait until Graph returns the new state.
    param(
        [Parameter(Mandatory)][string]$Message,
        $TemporaryAccessPass = $null,
        $TotpSetup = $null,
        [string[]]$AddedMethodIds = @(),
        [string[]]$RemovedMethodIds = @()
    )
    [pscustomobject]@{
        Message             = $Message
        TemporaryAccessPass = $TemporaryAccessPass
        TotpSetup           = $TotpSetup
        AddedMethodIds      = $AddedMethodIds
        RemovedMethodIds    = $RemovedMethodIds
    }
}

function Get-RequiredOption {
    param([hashtable]$Options, [string]$Name, [string]$Label)
    $value = if ($Options -and $Options.ContainsKey($Name)) { [string]$Options[$Name] } else { '' }
    if ([string]::IsNullOrWhiteSpace($value)) { throw (T 'Prov.MissingInput' (T $Label)) }
    return $value.Trim()
}

function Import-RequiredModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RequiredVersion,
        [switch]$SkipPublisherCheck
    )
    $loaded = Get-Module -Name $Name
    if ($loaded -and (-not $RequiredVersion -or $loaded.Version -eq [version]$RequiredVersion)) { return }

    $available = @(Get-Module -ListAvailable -Name $Name |
        Where-Object { -not $RequiredVersion -or $_.Version -eq [version]$RequiredVersion })
    if (-not $available.Count) {
        $params = @{ Name = $Name; Scope = 'CurrentUser'; Repository = 'PSGallery'; Force = $true; AllowClobber = $true; ErrorAction = 'Stop' }
        if ($RequiredVersion) { $params.RequiredVersion = $RequiredVersion }
        if ($SkipPublisherCheck) { $params.SkipPublisherCheck = $true }
        try { Install-Module @params }
        catch { throw (T 'Module.InstallFailed' $Name $_.Exception.Message) }
    }

    if ($loaded) { Remove-Module -Name $Name -Force -ErrorAction SilentlyContinue }
    $importParams = @{ Name = $Name; ErrorAction = 'Stop' }
    if ($RequiredVersion) { $importParams.RequiredVersion = $RequiredVersion }
    try { Import-Module @importParams }
    catch { throw (T 'Module.LoadFailed' $Name $_.Exception.Message) }
}

#endregion

#region TOTP / Base32

function New-RandomBase32 {
    param([int]$Length)
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $script:Base32Alphabet[$_ % 32] })
}

function ConvertTo-Base32 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $output = New-Object System.Text.StringBuilder
    $buffer = 0
    $bitCount = 0
    foreach ($b in $Bytes) {
        $buffer = (($buffer -shl 8) -bor $b) -band 0xFFFF
        $bitCount += 8
        while ($bitCount -ge 5) {
            [void]$output.Append($script:Base32Alphabet[($buffer -shr ($bitCount - 5)) -band 0x1F])
            $bitCount -= 5
        }
    }
    if ($bitCount -gt 0) {
        [void]$output.Append($script:Base32Alphabet[($buffer -shl (5 - $bitCount)) -band 0x1F])
    }
    $output.ToString()
}

function ConvertFrom-Base32 {
    param([Parameter(Mandatory)][string]$Secret)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $buffer = 0
    $bitCount = 0
    foreach ($char in $Secret.ToCharArray()) {
        $value = $script:Base32Alphabet.IndexOf($char)
        if ($value -lt 0) { throw (T 'Totp.InvalidChar' $char) }
        $buffer = (($buffer -shl 5) -bor $value) -band 0xFFFF
        $bitCount += 5
        if ($bitCount -ge 8) {
            $bytes.Add([byte](($buffer -shr ($bitCount - 8)) -band 0xFF))
            $bitCount -= 8
        }
    }
    $bytes.ToArray()
}

function ConvertTo-NormalizedTotpSecret {
    param([Parameter(Mandatory)][string]$Secret)
    $normalized = ($Secret -replace '[\s\-=]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[A-Z2-7]+$') { throw (T 'Totp.InvalidSecret') }
    if ($normalized.Length -lt 16) { throw (T 'Totp.SecretTooShort') }
    $normalized
}

function New-TotpSecret {
    param([int]$ByteLength = 20) # 160 bits of entropy is the standard
    $bytes = New-Object byte[] $ByteLength
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ConvertTo-Base32 -Bytes $bytes
}

function Get-TotpCode {
    param(
        [Parameter(Mandatory)][string]$Secret,
        [int]$TimeStepSeconds = 30,
        [DateTimeOffset]$Timestamp = [DateTimeOffset]::UtcNow
    )
    $key = ConvertFrom-Base32 -Secret $Secret
    $counter = [int64][Math]::Floor($Timestamp.ToUnixTimeSeconds() / $TimeStepSeconds)
    $counterBytes = [BitConverter]::GetBytes($counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counterBytes) }

    $hmac = New-Object System.Security.Cryptography.HMACSHA1 -ArgumentList (, $key)
    $hash = $hmac.ComputeHash($counterBytes)
    $hmac.Dispose()

    $offset = $hash[$hash.Length - 1] -band 0xF
    $binary = (($hash[$offset] -band 0x7F) -shl 24) -bor
              (($hash[$offset + 1] -band 0xFF) -shl 16) -bor
              (($hash[$offset + 2] -band 0xFF) -shl 8) -bor
              ($hash[$offset + 3] -band 0xFF)
    ($binary % 1000000).ToString().PadLeft(6, '0')
}

function New-TotpQrCodePng {
    param([Parameter(Mandatory)][string]$Text)
    # QRCodeGenerator ships QRCoder; the QR code is generated in memory only (no file containing the secret on disk).
    Import-RequiredModule -Name 'QRCodeGenerator'
    $generator = New-Object -TypeName QRCoder.QRCodeGenerator
    $data = $generator.CreateQrCode($Text, 'Q')
    $code = New-Object -TypeName QRCoder.PngByteQRCode -ArgumentList ($data)
    [byte[]]$code.GetGraphic(8)
}

function Find-HardwareOathDevice {
    param([Parameter(Mandatory)][string]$SerialNumber)
    $uri = 'beta/directory/authenticationMethodDevices/hardwareOathDevices'
    while ($uri) {
        $response = Invoke-M365GraphRequest -Uri $uri
        foreach ($device in @($response['value'])) {
            if ($null -ne $device -and [string]$device['serialNumber'] -eq $SerialNumber) { return $device }
        }
        $uri = $response['@odata.nextLink']
    }
    return $null
}

function New-HardwareOathTotp {
    <#
        Creates a hardware OATH device (or reuses an existing, unassigned one),
        assigns it to the user and activates it with a code calculated from the secret.
        Returns MethodId and DeviceId. Rolls back on errors.
    #>
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$SerialNumber,
        [Parameter(Mandatory)][string]$SecretKey,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Model,
        [switch]$ReuseExistingDevice
    )

    $userPart = [uri]::EscapeDataString($User.Id)
    $devicesUri = 'beta/directory/authenticationMethodDevices/hardwareOathDevices'
    $deviceId = $null
    $createdDevice = $false
    $assignedMethodId = $null

    try {
        $existing = Find-HardwareOathDevice -SerialNumber $SerialNumber
        if ($null -ne $existing) {
            $assignedTo = $existing['assignedTo']
            if ($assignedTo -is [System.Collections.IDictionary] -and $assignedTo['id']) {
                throw (T 'Totp.AlreadyAssigned' $SerialNumber $assignedTo['displayName'])
            }
            if ($ReuseExistingDevice) {
                $deviceId = [string]$existing['id']
            }
            else {
                # New secret -> replace the existing, unassigned entry.
                Invoke-M365GraphRequest -Method DELETE -Uri "$devicesUri/$([uri]::EscapeDataString([string]$existing['id']))" | Out-Null
            }
        }

        if (-not $deviceId) {
            $device = Invoke-M365GraphRequest -Method POST -Uri $devicesUri -Body @{
                displayName           = $DisplayName
                serialNumber          = $SerialNumber
                manufacturer          = $script:OathManufacturer
                model                 = $Model
                secretKey             = $SecretKey
                timeIntervalInSeconds = 30
            }
            $deviceId = [string]$device['id']
            $createdDevice = $true
        }

        $method = Invoke-M365GraphRequest -Method POST -Uri "beta/users/$userPart/authentication/hardwareOathMethods" -Body @{
            device = @{ id = $deviceId }
        }
        $assignedMethodId = [string]$method['id']
        if (-not $assignedMethodId) { $assignedMethodId = $deviceId }

        Invoke-M365GraphRequest -Method POST -Uri "beta/users/$userPart/authentication/hardwareOathMethods/$([uri]::EscapeDataString($assignedMethodId))/activate" -Body @{
            verificationCode = Get-TotpCode -Secret $SecretKey
            displayName      = $DisplayName
        } | Out-Null

        return [pscustomobject]@{ MethodId = $assignedMethodId; DeviceId = $deviceId }
    }
    catch {
        $message = $_.Exception.Message
        # Roll back so that no half-configured tokens remain.
        if ($assignedMethodId) {
            try { Invoke-M365GraphRequest -Method DELETE -Uri "beta/users/$userPart/authentication/hardwareOathMethods/$([uri]::EscapeDataString($assignedMethodId))" | Out-Null } catch { }
        }
        if ($createdDevice -and $deviceId) {
            try { Invoke-M365GraphRequest -Method DELETE -Uri "$devicesUri/$([uri]::EscapeDataString($deviceId))" | Out-Null } catch { }
        }
        throw (T 'Totp.SetupFailed' $message)
    }
}

#endregion

#region Provisioning methods

function Start-Fido2Provisioning {
    param([Parameter(Mandatory)]$User, [hashtable]$Options = @{})

    $serial = Get-RequiredOption -Options $Options -Name 'SerialNumber' -Label 'Config.Serial.Fido2'
    $upn = [string]$User.UserPrincipalName
    if ($upn.Length -gt 64) {
        throw (T 'Fido2.UpnTooLong' $upn.Length)
    }

    Import-RequiredModule -Name 'DSInternals.Passkeys' -RequiredVersion $script:Fido2ModuleVersion -SkipPublisherCheck

    $displayName = "FIDO2-$serial"
    $fido2Uri = "beta/users/$([uri]::EscapeDataString($User.Id))/authentication/fido2Methods"
    $before = @((Invoke-M365GraphRequest -Uri $fido2Uri)['value'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_['id'] })

    try {
        # Object ID instead of UPN: after a UPN change (e.g. break-glass account) the ID resolves reliably right away.
        $registrationOptions = Get-PasskeyRegistrationOptions -UserId $User.Id -ErrorAction Stop
        # Opens the Windows Security dialog (PIN / touch of the key).
        $passkey = New-Passkey -Options $registrationOptions -DisplayName $displayName -ErrorAction Stop
        $registered = Register-Passkey -Passkey $passkey -UserId $User.Id -ErrorAction Stop
    }
    catch {
        $details = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '' }
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $text = "$details $($_.Exception.Message) $($inner.Message)"
        if ($text -like '*Fido credential policy*') {
            throw (T 'Fido2.PolicyDisabled' $script:AuthMethodPolicyUrl)
        }
        throw (T 'Fido2.Failed' $(if ($details) { $details } else { $inner.Message }))
    }

    $addedId = $null
    if ($null -ne $registered -and $registered.PSObject.Properties['Id'] -and $registered.Id) {
        $addedId = [string]$registered.Id
    }
    else {
        $after = @((Invoke-M365GraphRequest -Uri $fido2Uri)['value'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_['id'] })
        $addedId = $after | Where-Object { $before -notcontains $_ } | Select-Object -First 1
    }

    $model = if ($null -ne $registered -and $registered.PSObject.Properties['Model']) { $registered.Model } else { $null }
    $message = if ($model) { T 'Fido2.RegisteredWithModel' $displayName $upn $model } else { T 'Fido2.Registered' $displayName $upn }
    New-ProvisioningResult -Message $message -AddedMethodIds @($addedId)
}

function Start-FixedSecretTotpProvisioning {
    param([Parameter(Mandatory)]$User, [hashtable]$Options = @{})

    $serial = Get-RequiredOption -Options $Options -Name 'SerialNumber' -Label 'Config.Serial.Card'
    $secret = ConvertTo-NormalizedTotpSecret -Secret (Get-RequiredOption -Options $Options -Name 'Secret' -Label 'Config.Secret')

    $token = New-HardwareOathTotp -User $User -SerialNumber $serial -SecretKey $secret `
        -DisplayName "TOTP card $serial" -Model 'TOTP card (fixed secret)' -ReuseExistingDevice
    $secret = $null

    New-ProvisioningResult -Message (T 'Prov.FixedTotp.Done' $serial $User.UserPrincipalName) -AddedMethodIds @($token.MethodId)
}

function Start-ProgrammableTotpProvisioning {
    param([Parameter(Mandatory)]$User, [hashtable]$Options = @{})

    $serial = Get-RequiredOption -Options $Options -Name 'SerialNumber' -Label 'Config.Serial.Card'
    $secret = New-TotpSecret

    $token = New-HardwareOathTotp -User $User -SerialNumber $serial -SecretKey $secret `
        -DisplayName "TOTP card $serial" -Model 'TOTP Generic'

    $account = [string]$User.UserPrincipalName
    $issuer = [uri]::EscapeDataString($script:OathIssuer)
    $otpUri = 'otpauth://totp/{0}:{1}?secret={2}&issuer={0}&algorithm=SHA1&digits=6&period=30' -f $issuer, [uri]::EscapeDataString($account), $secret

    $qrPng = $null
    $qrWarning = ''
    try { $qrPng = New-TotpQrCodePng -Text $otpUri }
    catch { $qrWarning = ' ' + (T 'Prov.QrFailed' $_.Exception.Message) }

    $setup = [pscustomobject]@{
        UserPrincipalName = $account
        SerialNumber      = $serial
        Secret            = $secret
        OtpAuthUri        = $otpUri
        QrCodePng         = $qrPng
    }

    New-ProvisioningResult -Message ((T 'Prov.ProgTotp.Done' $serial $account) + $qrWarning) `
        -TotpSetup $setup -AddedMethodIds @($token.MethodId)
}

function New-FakeMfaToken {
    # TOTP with a random secret that is discarded after activation:
    # at sign-in, an MFA method is requested that nobody can satisfy.
    param([Parameter(Mandatory)]$User)
    $serial = 'FAKE-' + (New-RandomBase32 -Length 16)
    $token = New-HardwareOathTotp -User $User -SerialNumber $serial -SecretKey (New-TotpSecret) `
        -DisplayName 'Fake-MFA' -Model 'Fake-MFA'
    $token | Add-Member -NotePropertyName SerialNumber -NotePropertyValue $serial -PassThru
}

function Remove-HardwareOathToken {
    # Removes a token from the user and from the device inventory.
    param([Parameter(Mandatory)]$User, [Parameter(Mandatory)]$Token)
    $userPart = [uri]::EscapeDataString($User.Id)
    Invoke-M365GraphRequest -Method DELETE -Uri "beta/users/$userPart/authentication/hardwareOathMethods/$([uri]::EscapeDataString($Token.MethodId))" | Out-Null
    Invoke-M365GraphRequest -Method DELETE -Uri "beta/directory/authenticationMethodDevices/hardwareOathDevices/$([uri]::EscapeDataString($Token.DeviceId))" | Out-Null
}

function Start-FakeMfaProvisioning {
    param([Parameter(Mandatory)]$User, [hashtable]$Options = @{})

    $token = New-FakeMfaToken -User $User
    New-ProvisioningResult -Message (T 'Prov.Fake.Done' $token.SerialNumber $User.UserPrincipalName) `
        -AddedMethodIds @($token.MethodId)
}

function Start-TemporaryAccessPassProvisioning {
    param([Parameter(Mandatory)]$User, [hashtable]$Options = @{})

    $userPart = [uri]::EscapeDataString($User.Id)
    $baseUri = "v1.0/users/$userPart/authentication/temporaryAccessPassMethods"

    # A user can only have one TAP -> remove existing ones first (the GUI asks for confirmation).
    $existing = @((Invoke-M365GraphRequest -Uri $baseUri)['value'] | Where-Object { $null -ne $_ })
    $removedIds = @()
    foreach ($tap in $existing) {
        Invoke-M365GraphRequest -Method DELETE -Uri "$baseUri/$([uri]::EscapeDataString([string]$tap['id']))" | Out-Null
        $removedIds += [string]$tap['id']
    }

    # Without startDateTime, the TAP is valid immediately.
    $response = Invoke-M365GraphRequest -Method POST -Uri $baseUri -Body @{
        lifetimeInMinutes = $script:TapLifetimeMinutes
        isUsableOnce      = $false
    }

    $start = ConvertTo-LocalDate $response['startDateTime']
    if ($null -eq $start) { $start = Get-Date }
    $lifetime = [int]$response['lifetimeInMinutes']

    $tapInfo = [pscustomobject]@{
        UserPrincipalName = $User.UserPrincipalName
        Pass              = [string]$response['temporaryAccessPass']
        ValidFrom         = $start
        ValidUntil        = $start.AddMinutes($lifetime)
        LifetimeInMinutes = $lifetime
        IsUsableOnce      = [bool]$response['isUsableOnce']
    }

    $message = T 'Prov.Tap.Done' $User.UserPrincipalName $tapInfo.ValidFrom.ToString((T 'Format.DateTime')) $tapInfo.ValidUntil.ToString((T 'Format.DateTime'))
    if ($existing.Count) { $message += ' ' + (T 'Prov.Tap.Replaced') }
    New-ProvisioningResult -Message $message -TemporaryAccessPass $tapInfo `
        -AddedMethodIds @([string]$response['id']) -RemovedMethodIds $removedIds
}

#endregion

#region Break-glass account

$script:GlobalAdminRoleId = '62e90394-69f5-4237-9190-012177145e10'

function New-SecureRandomPassword {
    # Cryptographically random password; never displayed, logged or stored.
    param([int]$Length = 255)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}?'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 4
    do {
        $password = -join (1..$Length | ForEach-Object {
            $rng.GetBytes($buffer)
            $chars[[BitConverter]::ToUInt32($buffer, 0) % $chars.Length]
        })
    } until ($password -cmatch '[a-z]' -and $password -cmatch '[A-Z]' -and $password -match '\d' -and $password -match '[^a-zA-Z\d]')
    $password
}

function Invoke-WithRetry {
    # Newly created objects are only available everywhere in Graph after a few seconds.
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$OnProgress,
        [scriptblock]$Wait,
        [int]$Attempts = 8,
        [int]$DelayMilliseconds = 5000
    )
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Action
        }
        catch {
            if ($attempt -ge $Attempts) { throw }
            & $OnProgress (T 'BG.Retry' (T $Description) ($attempt + 1) $Attempts)
            & $Wait $DelayMilliseconds
        }
    }
}

function New-M365BreakGlassAccount {
    <#
    .SYNOPSIS
        Creates a break-glass account and secures it with fake MFA or FIDO2.
    .DESCRIPTION
        1. Create the user with a random, unknown password (255 characters)
        2. Change UPN, mail nickname and display name to the object ID (UPN max. 64 characters for FIDO2)
        3. Optionally assign Global Administrator
        4. Register fake MFA so the account is protected immediately
        5. Optionally register a FIDO2 key and then remove the fake MFA again
    .PARAMETER OnProgress
        Called with status messages (e.g. for the GUI log).
    .PARAMETER Wait
        Called with milliseconds to wait for Graph replication (GUI: without freezing).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [switch]$AssignGlobalAdmin,
        [string]$Fido2SerialNumber,
        [scriptblock]$OnProgress = { param($Message) Write-Verbose $Message },
        [scriptblock]$Wait = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    )

    $retry = @{ OnProgress = $OnProgress; Wait = $Wait }
    $maxLocalPart = 64 - 1 - $Domain.Length
    if ($maxLocalPart -lt 8) { throw (T 'BG.DomainTooLong' $Domain) }

    # 1. Create user
    $tempName = [guid]::NewGuid().ToString('N').Substring(0, [Math]::Min(32, $maxLocalPart))
    & $OnProgress (T 'BG.Creating' $Domain)
    $created = Invoke-M365GraphRequest -Method POST -Uri 'v1.0/users' -Body @{
        accountEnabled    = $true
        displayName       = "Break Glass Account $tempName"
        mailNickname      = $tempName
        userPrincipalName = "$tempName@$Domain"
        passwordProfile   = @{ password = (New-SecureRandomPassword); forceChangePasswordNextSignIn = $false }
    }
    $userId = [string]$created['id']

    # 2. Rename to object ID
    $localPart = $userId.Substring(0, [Math]::Min($userId.Length, $maxLocalPart))
    $user = [pscustomobject]@{
        Id                = $userId
        DisplayName       = "Break Glass Account-$localPart"
        UserPrincipalName = "$localPart@$Domain"
        Mail              = $null
        AccountEnabled    = $true
    }
    Invoke-WithRetry @retry -Description 'BG.Step.Rename' -Action {
        Invoke-M365GraphRequest -Method PATCH -Uri "v1.0/users/$userId" -Body @{
            userPrincipalName = $user.UserPrincipalName
            mailNickname      = $localPart
            displayName       = $user.DisplayName
        } | Out-Null
    }
    & $OnProgress (T 'BG.Created' $user.UserPrincipalName)

    $result = [pscustomobject]@{
        User                = $user
        GlobalAdminAssigned = $false
        Fido2Registered     = $false
        FakeMfaActive       = $false
        Warnings            = New-Object System.Collections.Generic.List[string]
    }

    # 3. Global Administrator
    if ($AssignGlobalAdmin) {
        & $OnProgress (T 'BG.AssigningGlobalAdmin')
        try {
            Invoke-WithRetry @retry -Description 'BG.Step.RoleAssignment' -Action {
                Invoke-M365GraphRequest -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{
                    principalId      = $userId
                    roleDefinitionId = $script:GlobalAdminRoleId
                    directoryScopeId = '/'
                } | Out-Null
            }
            $result.GlobalAdminAssigned = $true
            & $OnProgress (T 'BG.GlobalAdminAssigned')
        }
        catch {
            $result.Warnings.Add((T 'BG.GlobalAdminFailed' $_.Exception.Message))
        }
    }

    # 4. Fake MFA as protection until FIDO2 is registered
    & $OnProgress (T 'BG.RegisteringFake')
    $fakeToken = $null
    try {
        $fakeToken = Invoke-WithRetry @retry -Description 'BG.Step.FakeMfa' -Action { New-FakeMfaToken -User $user }
        $result.FakeMfaActive = $true
        & $OnProgress (T 'BG.FakeRegistered' $fakeToken.SerialNumber)
    }
    catch {
        $result.Warnings.Add((T 'BG.FakeFailed' $_.Exception.Message))
    }

    # 5. Register FIDO2 key, then remove fake MFA
    if (-not [string]::IsNullOrWhiteSpace($Fido2SerialNumber)) {
        try {
            # Wait until the authentication methods of the new user can be retrieved.
            Invoke-WithRetry @retry -Description 'BG.Step.Fido2Prep' -Action {
                Invoke-M365GraphRequest -Uri "beta/users/$userId/authentication/fido2Methods" | Out-Null
            }
            & $OnProgress (T 'Fido2.Prompt')
            $fido = Start-Fido2Provisioning -User $user -Options @{ SerialNumber = $Fido2SerialNumber }
            $result.Fido2Registered = $true
            & $OnProgress $fido.Message

            if ($fakeToken) {
                & $OnProgress (T 'BG.RemovingFake')
                try {
                    Remove-HardwareOathToken -User $user -Token $fakeToken
                    $result.FakeMfaActive = $false
                }
                catch {
                    $result.Warnings.Add((T 'BG.FakeRemoveFailed' $_.Exception.Message))
                }
            }
        }
        catch {
            $result.Warnings.Add((T 'BG.Fido2Failed' $_.Exception.Message))
        }
    }

    $result
}

#endregion

function Invoke-MfaProvisioning {
    <#
    .SYNOPSIS
        Sets up the selected MFA method for a user.
    .PARAMETER Options
        Additional input from the GUI: SerialNumber, Secret.
    .OUTPUTS
        Result object from New-ProvisioningResult.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Fido2', 'FixedTotp', 'ProgrammableTotp', 'Tap', 'FakeMfa')][string]$Method,
        [Parameter(Mandatory)]$User,
        [hashtable]$Options = @{}
    )
    $params = @{ User = $User; Options = $Options }
    switch ($Method) {
        'Fido2'            { Start-Fido2Provisioning @params }
        'FixedTotp'        { Start-FixedSecretTotpProvisioning @params }
        'ProgrammableTotp' { Start-ProgrammableTotpProvisioning @params }
        'Tap'              { Start-TemporaryAccessPassProvisioning @params }
        'FakeMfa'          { Start-FakeMfaProvisioning @params }
    }
}

Export-ModuleMember -Function Invoke-MfaProvisioning, New-M365BreakGlassAccount
