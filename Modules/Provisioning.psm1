Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Anzeigenamen im Dropdown (UI\MainWindow.xaml) -> müssen exakt übereinstimmen.
$script:MethodFido2       = 'FIDO2 Security Key'
$script:MethodFixedTotp   = 'TOTP-Karte mit festem Secret'
$script:MethodProgTotp    = 'Programmierbare TOTP-Karte'
$script:MethodTap         = 'Temporary Access Pass (2 Stunden)'
$script:MethodFakeMfa     = 'Fake-MFA (TOTP ohne Hinterlegung)'

$script:TapLifetimeMinutes   = 120
$script:OathManufacturer     = 'unique projects'
$script:OathIssuer           = 'Microsoft 365'
$script:Base32Alphabet       = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
$script:Fido2ModuleVersion   = '1.0.6'
$script:AuthMethodPolicyUrl  = 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/AuthenticationMethodsMenuBlade/~/AdminAuthMethods'

#region Allgemeine Hilfsfunktionen

function New-ProvisioningResult {
    # AddedMethodIds/RemovedMethodIds: IDs der angelegten bzw. entfernten Methoden.
    # Die GUI wartet damit nach der Provisionierung, bis Graph den neuen Stand liefert.
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
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Bitte '$Label' angeben." }
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
        catch { throw "Modul '$Name' konnte nicht installiert werden: $($_.Exception.Message)" }
    }

    if ($loaded) { Remove-Module -Name $Name -Force -ErrorAction SilentlyContinue }
    $importParams = @{ Name = $Name; ErrorAction = 'Stop' }
    if ($RequiredVersion) { $importParams.RequiredVersion = $RequiredVersion }
    try { Import-Module @importParams }
    catch { throw "Modul '$Name' konnte nicht geladen werden: $($_.Exception.Message)" }
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
        if ($value -lt 0) { throw "Ungültiges Base32-Zeichen im Secret: '$char'" }
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
    if ($normalized -notmatch '^[A-Z2-7]+$') { throw 'Das Secret ist kein gültiger Base32-Wert (erlaubt: A-Z und 2-7).' }
    if ($normalized.Length -lt 16) { throw 'Das Secret ist zu kurz (mindestens 16 Base32-Zeichen).' }
    $normalized
}

function New-TotpSecret {
    param([int]$ByteLength = 20) # 160 Bit Entropie ist Standard
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
    # QRCodeGenerator bringt QRCoder mit; der QR-Code wird nur im Speicher erzeugt (keine Datei mit Secret auf der Platte).
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
        Legt ein Hardware-OATH-Gerät an (bzw. nutzt ein vorhandenes, nicht zugewiesenes),
        weist es dem Benutzer zu und aktiviert es mit einem aus dem Secret berechneten Code.
        Gibt die ID der Benutzer-Methode zurück. Bei Fehlern wird zurückgerollt.
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
                throw "Ein Token mit der Seriennummer '$SerialNumber' ist bereits '$($assignedTo['displayName'])' zugewiesen. Bitte dort zuerst entfernen."
            }
            if ($ReuseExistingDevice) {
                $deviceId = [string]$existing['id']
            }
            else {
                # Neues Secret -> vorhandenen, nicht zugewiesenen Eintrag ersetzen.
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

        return $assignedMethodId
    }
    catch {
        $message = $_.Exception.Message
        # Rollback, damit keine halb eingerichteten Token zurückbleiben.
        if ($assignedMethodId) {
            try { Invoke-M365GraphRequest -Method DELETE -Uri "beta/users/$userPart/authentication/hardwareOathMethods/$([uri]::EscapeDataString($assignedMethodId))" | Out-Null } catch { }
        }
        if ($createdDevice -and $deviceId) {
            try { Invoke-M365GraphRequest -Method DELETE -Uri "$devicesUri/$([uri]::EscapeDataString($deviceId))" | Out-Null } catch { }
        }
        throw "TOTP-Token konnte nicht eingerichtet werden: $message"
    }
}

#endregion

#region Provisionierungsmethoden

function Start-Fido2Provisioning {
    param([Parameter(Mandatory)]$User, [Parameter(Mandatory)][string]$AppRoot, [hashtable]$Options)

    $serial = Get-RequiredOption -Options $Options -Name 'SerialNumber' -Label 'Seriennummer / interne ID'
    $upn = [string]$User.UserPrincipalName
    if ($upn.Length -gt 64) {
        throw "Der UPN ist zu lang ($($upn.Length) Zeichen). Für FIDO2 sind maximal 64 Zeichen erlaubt."
    }

    # DSInternals.Passkeys ist auf 1.0.6 gepinnt (neuere Versionen haben eine geänderte API).
    Import-RequiredModule -Name 'DSInternals.Passkeys' -RequiredVersion $script:Fido2ModuleVersion -SkipPublisherCheck

    $displayName = "FIDO2-$serial"
    $fido2Uri = "beta/users/$([uri]::EscapeDataString($User.Id))/authentication/fido2Methods"
    $before = @((Invoke-M365GraphRequest -Uri $fido2Uri)['value'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_['id'] })

    try {
        $registrationOptions = Get-PasskeyRegistrationOptions -UserId $upn -ErrorAction Stop
        # Öffnet den Windows-Sicherheitsdialog (PIN / Berührung des Sticks).
        $passkey = New-Passkey -Options $registrationOptions -DisplayName $displayName -ErrorAction Stop
        $registered = Register-Passkey -Passkey $passkey -UserId $upn -ErrorAction Stop
    }
    catch {
        $details = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '' }
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $text = "$details $($_.Exception.Message) $($inner.Message)"
        if ($text -like '*Fido credential policy*') {
            throw "FIDO2 ist in der Authentifizierungsmethoden-Richtlinie des Tenants nicht aktiviert. Bitte aktivieren unter: $script:AuthMethodPolicyUrl"
        }
        throw "FIDO2-Registrierung fehlgeschlagen: $(if ($details) { $details } else { $inner.Message })"
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
    $message = "FIDO2-Passkey '$displayName' registriert für $upn" + $(if ($model) { " (Modell: $model)." } else { '.' })
    New-ProvisioningResult -Message $message -AddedMethodIds @($addedId)
}

function Start-FixedSecretTotpProvisioning {
    param([Parameter(Mandatory)]$User, [Parameter(Mandatory)][string]$AppRoot, [hashtable]$Options)

    $serial = Get-RequiredOption -Options $Options -Name 'SerialNumber' -Label 'Seriennummer'
    $secret = ConvertTo-NormalizedTotpSecret -Secret (Get-RequiredOption -Options $Options -Name 'Secret' -Label 'Secret der Karte')

    $methodId = New-HardwareOathTotp -User $User -SerialNumber $serial -SecretKey $secret `
        -DisplayName "TOTP-Karte $serial" -Model 'TOTP-Karte (festes Secret)' -ReuseExistingDevice
    $secret = $null

    New-ProvisioningResult -Message "TOTP-Karte '$serial' (festes Secret) zugewiesen und aktiviert für $($User.UserPrincipalName)." -AddedMethodIds @($methodId)
}

function Start-ProgrammableTotpProvisioning {
    param([Parameter(Mandatory)]$User, [Parameter(Mandatory)][string]$AppRoot, [hashtable]$Options)

    $serial = Get-RequiredOption -Options $Options -Name 'SerialNumber' -Label 'Seriennummer'
    $secret = New-TotpSecret

    $methodId = New-HardwareOathTotp -User $User -SerialNumber $serial -SecretKey $secret `
        -DisplayName "TOTP-Karte $serial" -Model 'TOTP Generic'

    $account = [string]$User.UserPrincipalName
    $issuer = [uri]::EscapeDataString($script:OathIssuer)
    $otpUri = 'otpauth://totp/{0}:{1}?secret={2}&issuer={0}&algorithm=SHA1&digits=6&period=30' -f $issuer, [uri]::EscapeDataString($account), $secret

    $qrPng = $null
    $qrWarning = ''
    try { $qrPng = New-TotpQrCodePng -Text $otpUri }
    catch { $qrWarning = " QR-Code konnte nicht erzeugt werden: $($_.Exception.Message)" }

    $setup = [pscustomobject]@{
        UserPrincipalName = $account
        SerialNumber      = $serial
        Secret            = $secret
        OtpAuthUri        = $otpUri
        QrCodePng         = $qrPng
    }

    New-ProvisioningResult -Message "Programmierbare TOTP-Karte '$serial' zugewiesen und aktiviert für $account. Karte jetzt programmieren.$qrWarning" `
        -TotpSetup $setup -AddedMethodIds @($methodId)
}

function Start-FakeMfaProvisioning {
    param([Parameter(Mandatory)]$User, [Parameter(Mandatory)][string]$AppRoot, [hashtable]$Options)

    # TOTP mit zufälligem Secret, das nach der Aktivierung verworfen wird:
    # Bei der Anmeldung wird eine MFA-Methode abgefragt, die niemand bedienen kann.
    $secret = New-TotpSecret
    $serial = 'FAKE-' + (New-RandomBase32 -Length 16)

    $methodId = New-HardwareOathTotp -User $User -SerialNumber $serial -SecretKey $secret `
        -DisplayName 'Fake-MFA' -Model 'Fake-MFA'
    $secret = $null

    New-ProvisioningResult -Message "Fake-MFA (Seriennummer $serial) registriert für $($User.UserPrincipalName). Das Secret wurde verworfen." -AddedMethodIds @($methodId)
}

function Start-TemporaryAccessPassProvisioning {
    param([Parameter(Mandatory)]$User, [Parameter(Mandatory)][string]$AppRoot, [hashtable]$Options)

    $userPart = [uri]::EscapeDataString($User.Id)
    $baseUri = "v1.0/users/$userPart/authentication/temporaryAccessPassMethods"

    # Ein Benutzer kann nur einen TAP haben -> vorhandene vorher entfernen (Rückfrage erfolgt in der GUI).
    $existing = @((Invoke-M365GraphRequest -Uri $baseUri)['value'] | Where-Object { $null -ne $_ })
    $removedIds = @()
    foreach ($tap in $existing) {
        Invoke-M365GraphRequest -Method DELETE -Uri "$baseUri/$([uri]::EscapeDataString([string]$tap['id']))" | Out-Null
        $removedIds += [string]$tap['id']
    }

    # Ohne startDateTime ist der TAP sofort gültig.
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

    $message = 'Temporary Access Pass erstellt für {0} (gültig {1:dd.MM.yyyy HH:mm} - {2:HH:mm}{3}).' -f
        $User.UserPrincipalName, $tapInfo.ValidFrom, $tapInfo.ValidUntil,
        $(if ($existing.Count) { ', vorheriger TAP ersetzt' } else { '' })
    New-ProvisioningResult -Message $message -TemporaryAccessPass $tapInfo `
        -AddedMethodIds @([string]$response['id']) -RemovedMethodIds $removedIds
}

#endregion

function Invoke-MfaProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet(
            'FIDO2 Security Key',
            'TOTP-Karte mit festem Secret',
            'Programmierbare TOTP-Karte',
            'Temporary Access Pass (2 Stunden)',
            'Fake-MFA (TOTP ohne Hinterlegung)'
        )][string]$Method,
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$AppRoot,
        # Zusätzliche Eingaben aus der GUI, z. B. SerialNumber, Secret
        [hashtable]$Options = @{}
    )
    $params = @{ User = $User; AppRoot = $AppRoot; Options = $Options }
    switch ($Method) {
        $script:MethodFido2     { Start-Fido2Provisioning @params }
        $script:MethodFixedTotp { Start-FixedSecretTotpProvisioning @params }
        $script:MethodProgTotp  { Start-ProgrammableTotpProvisioning @params }
        $script:MethodTap       { Start-TemporaryAccessPassProvisioning @params }
        $script:MethodFakeMfa   { Start-FakeMfaProvisioning @params }
    }
}

Export-ModuleMember -Function Invoke-MfaProvisioning
