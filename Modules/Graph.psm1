function Assert-GraphModules {
    $requiredModules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Users'
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
            Import-Module -Name $moduleName -ErrorAction Stop
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
    'UserAuthenticationMethod.ReadWrite.All'
)

function Test-M365GraphConnection {
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

    $term = $SearchTerm.Trim().Replace('"', '')
    $search = '"displayName:{0}" OR "userPrincipalName:{0}" OR "mail:{0}"' -f $term

    Get-MgUser `
        -Search $search `
        -ConsistencyLevel eventual `
        -Top $Top `
        -Property 'id,displayName,userPrincipalName,mail,accountEnabled' `
        -ErrorAction Stop |
        Sort-Object DisplayName |
        ForEach-Object {
            [pscustomobject]@{
                Id                = $_.Id
                DisplayName       = $_.DisplayName
                UserPrincipalName = $_.UserPrincipalName
                Mail              = $_.Mail
                AccountEnabled    = [bool]$_.AccountEnabled
            }
        }
}

Export-ModuleMember -Function Assert-GraphModules, Test-M365GraphConnection, Connect-M365Graph, Disconnect-M365Graph, Find-M365User
