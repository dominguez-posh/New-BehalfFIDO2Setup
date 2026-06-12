## Remote FIDO2 Setup
## Needed API Rights:
## - UserAuthenticationMethod.ReadWrite.All
## - User.ReadWrite.All
##
## WICHTIG:
## - Für Windows PowerShell 5.1
## - DSInternals.Passkeys wird auf 1.0.6 gepinnt
## - Out-GridView wird verwendet (wie in deinem Ursprungs-Script)

# setting execution policy for this session to allow running the script without changing the system wide policy
Set-ExecutionPolicy RemoteSigned -Scope Process -Force

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = "Stop"

function Install-ModuleInCurrentUserContext {
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName,

        [string]$RequiredVersion = $null,

        [switch]$SkipPublisherCheck
    )

    Write-Verbose "Checking if $ModuleName is already installed" -Verbose

    $InstalledModules = Get-InstalledModule -ErrorAction SilentlyContinue

    if ($RequiredVersion) {
        $InstalledExact = $InstalledModules | Where-Object {
            $_.Name -eq $ModuleName -and $_.Version -eq [version]$RequiredVersion
        }

        if (-not $InstalledExact) {
            Write-Verbose "Installing module $ModuleName version $RequiredVersion ..." -Verbose

            $params = @{
                Name            = $ModuleName
                RequiredVersion = $RequiredVersion
                Scope           = "CurrentUser"
                Force           = $true
            }

            if ($SkipPublisherCheck) {
                $params.SkipPublisherCheck = $true
            }

            Install-Module @params

            Write-Verbose "Checking if $ModuleName $RequiredVersion was installed successfully" -Verbose
            $CheckInstalled = Get-InstalledModule -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -eq $ModuleName -and $_.Version -eq [version]$RequiredVersion
            }

            if ($CheckInstalled) {
                Write-Verbose "Module $ModuleName version $RequiredVersion was successfully installed" -Verbose
                return $CheckInstalled
            }
            else {
                Write-Error "Module $ModuleName version $RequiredVersion could not be installed"
                return 1001
            }
        }
        else {
            Write-Verbose "Module $ModuleName version $RequiredVersion already installed" -Verbose
            return $InstalledExact
        }
    }
    else {
        if (-not ($InstalledModules | Where-Object { $_.Name -eq $ModuleName })) {
            Write-Verbose "Installing module $ModuleName ..." -Verbose
            Install-Module -Name $ModuleName -Scope CurrentUser -Force

            Write-Verbose "Checking if $ModuleName was installed successfully" -Verbose
            $CheckInstalled = Get-InstalledModule -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $ModuleName }

            if ($CheckInstalled) {
                Write-Verbose "Module $ModuleName was successfully installed" -Verbose
                return $CheckInstalled
            }
            else {
                Write-Error "Module $ModuleName could not be installed"
                return 1001
            }
        }
        else {
            $Version = ($InstalledModules | Where-Object { $_.Name -eq $ModuleName } | Sort-Object Version -Descending | Select-Object -First 1).Version
            Write-Verbose "Module already installed in version $Version - no installation required" -Verbose
            return ($InstalledModules | Where-Object { $_.Name -eq $ModuleName } | Sort-Object Version -Descending | Select-Object -First 1)
        }
    }
}

Write-Verbose "Installing all required Modules..." -Verbose

# WICHTIG: DSInternals.Passkeys fest auf 1.0.6 pinnen
Install-ModuleInCurrentUserContext -ModuleName "DSInternals.Passkeys" -RequiredVersion "1.0.6" -SkipPublisherCheck

Install-ModuleInCurrentUserContext -ModuleName "Microsoft.Graph.Authentication"
Install-ModuleInCurrentUserContext -ModuleName "Microsoft.Graph.Identity.SignIns"
Install-ModuleInCurrentUserContext -ModuleName "Microsoft.Graph.Users"

# Alte geladene Version aus der Session entfernen
Get-Module DSInternals.Passkeys | Remove-Module -Force -ErrorAction SilentlyContinue

# Exakt die funktionierende Version importieren
Import-Module DSInternals.Passkeys -RequiredVersion 1.0.6 -Force

$LoadedPasskeysModule = Get-Module DSInternals.Passkeys
if (-not $LoadedPasskeysModule) {
    Write-Error "DSInternals.Passkeys konnte nicht geladen werden."
    exit 1002
}

if ($LoadedPasskeysModule.Version -ne [version]"1.0.6") {
    Write-Error "Falsche DSInternals.Passkeys Version geladen: $($LoadedPasskeysModule.Version). Erwartet: 1.0.6"
    exit 1003
}

Write-Verbose "Loaded DSInternals.Passkeys version: $($LoadedPasskeysModule.Version)" -Verbose

# just for testing purposes:
# Disconnect-MgGraph

Write-Verbose "Logging in to Graph...." -Verbose
try {
    $Connection = Connect-MgGraph -Scopes UserAuthenticationMethod.ReadWrite.All, User.ReadWrite.All -ErrorAction Stop
    $Account = (Get-MgContext).Account
}
catch {
    Write-Error "NO CONNECTION with Graph POSSIBLE"
    exit 1001
}

Write-Verbose "Logged in to Graph with account $Account" -Verbose
Write-Verbose "Scopes: $(((Get-MgContext).Scopes) -join ', ')" -Verbose

# Selecting User
Write-Verbose "Getting all Users from Graph..." -Verbose
$MGUser = Get-MgUser -All -ErrorAction Stop

# wie in deinem Ursprungs-Script: Auswahl per GridView
$MGUser = $MGUser | Out-GridView -OutputMode Single -Title "Select User to Config"

if (-not $MGUser) {
    Write-Warning "No user selected. Exiting."
    exit 1004
}

if ($MGUser.UserPrincipalName.Length -le 64) {

    $Serial = Read-Host -Prompt "INPUT FIDO STICK SERIAL OR INTERNAL ID"
    $DisplayName = "FIDO2-$Serial"
    $userUPN = $MGUser.UserPrincipalName

    Write-Verbose "Selected user: $userUPN" -Verbose
    Write-Verbose "DisplayName: $DisplayName" -Verbose

    # Vorab-Check
    Write-Host ""
    Write-Host "==== DEBUG: Existing FIDO2 methods before registration ====" -ForegroundColor Cyan
    try {
        $ExistingMethods = Get-MgUserAuthenticationFido2Method -UserId $userUPN -ErrorAction Stop
        if ($ExistingMethods) {
            $ExistingMethods | Format-List *
        }
        else {
            Write-Host "No FIDO2 methods currently registered." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Warning "Could not check existing FIDO2 methods: $($_.Exception.Message)"
    }

    # Registration Options holen
    Write-Host ""
    Write-Host "==== DEBUG: Get-PasskeyRegistrationOptions ====" -ForegroundColor Cyan
    try {
        $Passkeyregistration = Get-PasskeyRegistrationOptions -UserId $MGUser.UserPrincipalName -ErrorAction Stop

        Write-Host "[DEBUG] Registration options type:" -ForegroundColor Yellow
        $Passkeyregistration.GetType().FullName

        Write-Host "[DEBUG] Registration options content:" -ForegroundColor Yellow
        try {
            $Passkeyregistration | Format-List * -Force
        }
        catch {
            Write-Warning "Could not fully format registration options."
        }
    }
    catch {
        Write-Error "Error while getting passkey registration options: $($_.Exception.Message)"
        exit 1005
    }

    # Lokale Erzeugung des Passkeys
    Write-Host ""
    Write-Host "==== DEBUG: New-Passkey ====" -ForegroundColor Cyan
    Write-Host "Please complete PIN / touch interaction on the key..." -ForegroundColor Yellow

    try {
        # WICHTIG für DSInternals.Passkeys 1.0.6:
        # DisplayName gehört an New-Passkey
        $PassKey = New-Passkey -Options $Passkeyregistration -DisplayName $DisplayName -ErrorAction Stop

        Write-Host "[DEBUG] Passkey object type:" -ForegroundColor Yellow
        $PassKey.GetType().FullName

        Write-Host "[DEBUG] Passkey object content:" -ForegroundColor Yellow
        try {
            $PassKey | Format-List * -Force
        }
        catch {
            Write-Warning "Could not fully format passkey object."
        }
    }
    catch {
        Write-Error "Error during New-Passkey: $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Warning "InnerException: $($_.Exception.InnerException.Message)"
        }
        exit 1006
    }

    # Registrierung in Entra
    Write-Host ""
    Write-Host "==== DEBUG: Register-Passkey ====" -ForegroundColor Cyan

    try {
        Write-Host "[DEBUG] Register-Passkey Syntax:" -ForegroundColor Yellow
        Get-Command Register-Passkey -Syntax

        # WICHTIG für DSInternals.Passkeys 1.0.6:
        # KEIN Pipeline-Input
        # KEIN -DisplayName hier
        $PasskeyEntraRegister = Register-Passkey -Passkey $PassKey -UserId $MGUser.UserPrincipalName -Verbose 4>&1

        Write-Host "[DEBUG] Raw Register-Passkey result:" -ForegroundColor Yellow
        try {
            $PasskeyEntraRegister | Format-List * -Force
        }
        catch {
            Write-Warning "Could not fully format Register-Passkey result."
        }
    }
    catch {
        Write-Error "Error during Register-Passkey: $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Warning "InnerException: $($_.Exception.InnerException.Message)"
        }
        exit 1007
    }

    # Finaler Verify-Check
    Write-Host ""
    Write-Host "==== DEBUG: Verify FIDO2 methods after registration ====" -ForegroundColor Cyan
    try {
        $Methods = Get-MgUserAuthenticationFido2Method -UserId $userUPN -ErrorAction Stop

        if ($Methods) {
            Write-Host "✅ FIDO2 method is now present in Entra ID" -ForegroundColor Green
            $Methods | Format-List *

            $LatestMethod = $Methods | Sort-Object CreatedDateTime -Descending | Select-Object -First 1

            Write-Host ""
            Write-Host "============================================" -ForegroundColor Green
            Write-Host "✅ FIDO2 / Passkey successfully registered!" -ForegroundColor Green
            Write-Host "User            : $userUPN" -ForegroundColor Green
            Write-Host "DisplayName     : $($LatestMethod.DisplayName)" -ForegroundColor Green
            Write-Host "Model           : $($LatestMethod.Model)" -ForegroundColor Green
            Write-Host "Attestation     : $($LatestMethod.AttestationLevel)" -ForegroundColor Green
            Write-Host "PasskeyType     : $($LatestMethod.PasskeyType)" -ForegroundColor Green
            Write-Host "CreatedDateTime : $($LatestMethod.CreatedDateTime)" -ForegroundColor Green
            Write-Host "============================================" -ForegroundColor Green
        }
        else {
            Write-Warning "No FIDO2 method found after registration."
        }
    }
    catch {
        Write-Warning "Verification after registration failed: $($_.Exception.Message)"
    }
}
else {
    Write-Error "The selected user's UPN is invalid or too long."
}