Install-Module  Microsoft.Graph.Beta.Identity.DirectoryManagement -Scope CurrentUser
Install-Module  Microsoft.Graph.Beta.Identity.SignIns -Scope CurrentUser
Install-Module  Microsoft.Graph.Beta.Users -Scope CurrentUser
Install-Module  QrCodes  -Scope CurrentUser
Install-Module  QRCodeGenerator  -Scope CurrentUser


Import-Module Microsoft.Graph.Beta.Identity.DirectoryManagement
Import-Module Microsoft.Graph.Beta.Identity.SignIns
Import-Module Microsoft.Graph.Beta.Users
Import-Module -Name QrCodes 
Import-Module -Name QRCodeGenerator 



param(
[Parameter(Mandatory=$false)]
[string]$TOTPSerial,
[string]$userId,
[string]$PathForTOTPPNG
)


function New-TotpSecret {
    param (
        [int]$ByteLength = 20 # 160-bit Entropie ist Standard
    )

    # 1. Kryptografisch sichere Zufallsbytes generieren
    $bytes = New-Object Byte[] $ByteLength
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)

    # 2. Base32 Alphabet definieren (RFC 4648)
    $base32Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $output = New-Object System.Text.StringBuilder

    $bitBuffer = 0
    $bitCount = 0

    foreach ($b in $bytes) {
        $bitBuffer = ($bitBuffer -shl 8) -bor $b
        $bitCount += 8
        while ($bitCount -ge 5) {
            $index = ($bitBuffer -shr ($bitCount - 5)) -band 0x1F
            [void]$output.Append($base32Chars[$index])
            $bitCount -= 5
        }
    }

    if ($bitCount -gt 0) {
        $index = ($bitBuffer -shl (5 - $bitCount)) -band 0x1F
        [void]$output.Append($base32Chars[$index])
    }

    return $output.ToString()
}

function Get-TOTP {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Secret
    )

    # 1. Secret von Base32 in Bytes konvertieren
    $rfc4648 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bits = ""
    foreach ($char in $Secret.ToUpper().ToCharArray()) {
        $bits += [Convert]::ToString($rfc4648.IndexOf($char), 2).PadLeft(5, '0')
    }
    $byteList = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -le ($bits.Length - 8); $i += 8) {
        $byteList.Add([Convert]::ToByte($bits.Substring($i, 8), 2))
    }
    $key = $byteList.ToArray()

    # 2. Zeitintervall berechnen (30 Sekunden Schritte seit Unix-Epoch)
    $unixEpoch = [DateTimeOffset]::new(1970, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $now = [DateTimeOffset]::UtcNow
    $counter = [Math]::Floor(($now - $unixEpoch).TotalSeconds / 30)
    $counterBytes = [BitConverter]::GetBytes([int64]$counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counterBytes) }

    # 3. HMAC-SHA1 Hash berechnen
    $hmac = New-Object System.Security.Cryptography.HMACSHA1 -Property @{ Key = $key }
    $hash = $hmac.ComputeHash($counterBytes)

    # 4. Dynamisches Truncation (6-stelligen Code extrahieren)
    $offset = $hash[$hash.Length - 1] -band 0xf
    $binary = (($hash[$offset] -band 0x7f) -shl 24) -bor 
              (($hash[$offset + 1] -band 0xff) -shl 16) -bor 
              (($hash[$offset + 2] -band 0xff) -shl 8) -bor 
              ($hash[$offset + 3] -band 0xff)

    $otp = $binary % 1000000
    return $otp.ToString().PadLeft(6, '0')
}

function New-TOTPToken ($userID, $TOTPSerial) {

    $ClientSecret = New-TotpSecret

    $status = ""

    Write-Host "Creating new Authentication Device in Entra..."

    $params = @{
        displayName = "TOTP Card or Fake TOTP"
        serialNumber = $TOTPSerial
        manufacturer = "unique projects"
        model = "TOTP Generic"
        secretKey = $ClientSecret
        timeIntervalInSeconds = 30
    }
    #flushing totp serial from ram
    $TOTPSerial = $Null

    $HardwareOauthInfos = New-MgBetaDirectoryAuthenticationMethodDeviceHardwareOathDevice -BodyParameter $params


    $TokenID = $HardwareOauthInfos.Id


    $status = $HardwareOauthInfos.Status


    Write-Host "Created new Authentication Device :" $HardwareOauthInfos.Id
    Write-Host "Deployment Status: $status " -ForegroundColor Green


    Write-Host "Start Binding Authentication Device to User:" $userId
    $params = @{
        device = @{
            id = $TokenID
        }
    }

    # A UPN can also be used as -UserId.

    $UserAuthenticationHardwareOathMethod = New-MgBetaUserAuthenticationHardwareOathMethod -UserId $userId -BodyParameter $params

    $status = (Get-MgBetaUserAuthenticationHardwareOathMethod -UserId $userId -HardwareOathAuthenticationMethodId $TokenID).Device.Status


    Write-Host "Binding is Ready."
    Write-Host "Deployment Status: $status" -ForegroundColor Green




    Write-Host "Activating TOTP Secret for User $UseriD ..."
    $params = @{
        verificationCode = (Get-TOTP -Secret $ClientSecret)
        displayName =  $UserID
    }

    # A UPN can also be used as -UserId.
    Initialize-MgBetaUserAuthenticationHardwareOathMethod -UserId $userId -HardwareOathAuthenticationMethodId $UserAuthenticationHardwareOathMethod.Id -BodyParameter $params

    $status = (Get-MgBetaUserAuthenticationHardwareOathMethod -UserId $userId -HardwareOathAuthenticationMethodId $UserAuthenticationHardwareOathMethod.Id).Device.Status

    Write-Host "Initializing Done."

    Write-Host "Status after activating: $status" -ForegroundColor Green



        return [PSCustomObject]@{
            Device     = (Get-MgBetaUserAuthenticationHardwareOathMethod -UserId $userId -HardwareOathAuthenticationMethodId $UserAuthenticationHardwareOathMethod.Id).Device
            ClientSecret = $ClientSecret
            UserID = $UserID
        }
  
}

function new-totpqrcode ($TokenObject) {

    Write-Host "Creating QR Code..."

    # 1. Daten definieren
    $Issuer = "Microsoft 365"               # Name der Anwendung
    $Account = $TokenObject.UserID      # Benutzername oder E-Mail
    $Secret = $TokenObject.ClientSecret        # Das Client Secret (Muss Base32 sein!)

    $OtpUri = "otpauth://totp/$($Issuer):$($Account)?secret=$($Secret)&issuer=$($Issuer)"

    # 3. QR-Code generieren

    $Pfad = Join-Path $Env:temp ("totpsecret-" + $TokenObject.Device.SerialNumber + ".png")

    New-PSOneQRCodeText -Text $OtpUri -OutPath $Pfad -Width 200

    Write-Host "QR-Code wurde erstellt unter: $Pfad" -ForegroundColor Green

    return $Pfad
}

$Connection = Connect-MgGraph -Scopes "UserAuthenticationMethod.ReadWrite.All", "User.ReadWrite.All", "Directory.ReadWrite.All", "UserAuthenticationMethod.ReadWrite" #, "Policy.ReadWrite.AuthenticationMethod."



#if (-not $userid) {
#    
#    $UserInfos = (Get-MGBetaUser -All  | Select-Object DisplayName, UserprincipalName | Out-GridView -OutputMode Single)
#    $userId = $UserInfos.UserprincipalName
#}

#if(-not $TOTPSerial) { $TOTPSerial = -join (1..32 | ForEach-Object { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[(Get-SecureRandom -Maximum 32)] })}





#$TOTPSerial = -join (1..32 | ForEach-Object { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[(Get-SecureRandom -Maximum 32)] })



$UserInfos = Import-CSV "C:\Admin\totp-karten.csv"


foreach ($UserInfo in ($Userinfos | ? totpserial))
{

     $TOTPSerial = $UserInfo.totpserial
     $userId = $UserInfo.UPN
    
     $Token = New-TOTPToken -userID $UserID -TOTPSerial $TOTPSerial
     $QRCode = new-totpqrcode $Token -PathForTOTPPNG "C:\admin\"

}


#$TOTPSerial = Read-Host
#$userId = "christine.schmengler@skmd.de"




#$Token = New-TOTPToken -userID $UserID -TOTPSerial $TOTPSerial

#$QRCode = new-totpqrcode $Token


#Remove-MgBetaUserAuthenticationHardwareOathMethod -HardwareOathAuthenticationMethodId  $TokenID -UserId $userId