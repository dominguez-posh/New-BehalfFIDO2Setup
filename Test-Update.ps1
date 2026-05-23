## Remote FIDO2 Setup
# Needed API Rights: UserAuthenticationMethod.ReadWrite.All
if(-not (Get-Module DSInternals.Passkeys)){
    
    Write-Verbose "Installing Module..."
    Install-Module -Name DSInternals.Passkeys -Scope CurrentUser

}

if(-not (Get-Module Microsoft.Graph.Authentication)){
    
    Write-Verbose "Installing Module..."
    Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser

}

if(-not (Get-Module Microsoft.Graph.Users)){
    
    Write-Verbose "Installing Module..."
    Install-Module -Name Microsoft.Graph.Users -Scope CurrentUser

}

#Void = Disconnect-MgGraph

Write-Verbose "Logging in to Graph...." -Verbose
try{
    $Connection =   Connect-MgGraph -Scopes UserAuthenticationMethod.ReadWrite.All, User.ReadWrite.All 
}
catch{
    Write-Error "NO CONNECTION with Graph POSSIBLE"
    exit 1001 
}


#Selecting User
$MGUser = (Get-MGUser -All | Out-GridView -OutputMode Single -Title "Select User to Config")


if($MGUser.UserPrincipalName.Length -le 64){
    #Welcome
    Write-Host "Selected User: "
    Write-Host $MGUser.UserPrincipalName -ForegroundColor Green
    Write-Host ""



    #######################################################
    ###### PiKl - Quick & Dirty ########################### 
    #######################################################


    #Getting Serial
    $Serial = (Read-Host -Prompt "INPUT FIDO STICK SERIAL OR INTERNAL ID")
    $DisplayName = "FIDO2-$Serial"

    $userUPN = $MGUser.UserPrincipalName 



    $Passkeyregistration =  Get-PasskeyRegistrationOptions -UserId $MGUser.UserPrincipalName
    
    #######################################################
    #CHANGE
    # Variable $PasskeyregistrationOptions war nicht gesetzt 
    #$PassKeyRaw  = New-Passkey -Options $PasskeyregistrationOptions -DisplayName $DisplayNam
    $PassKeyRaw  = New-Passkey -Options $Passkeyregistration -DisplayName $DisplayName


    $body = @{
        displayName = $DisplayName
        publicKeyCredential = @{
            id = ($PassKeyRaw.PublicKeyCred | ConvertFrom-Json).rawId
            response = @{
                #######################################################
                #CHANGE
                #response existiert nicht, jedoch AuthenticatorResponse. Daher blieb beides leer
                #clientDataJSON    = $PassKey.publicKeyCredential.response.clientDataJSON
                #attestationObject = $PassKey.publicKeyCredential.response.attestationObject
                clientDataJSON    = ($PassKeyRaw.PublicKeyCred | ConvertFrom-Json).response.clientDataJSON
                attestationObject = ($PassKeyRaw.PublicKeyCred | ConvertFrom-Json).response.attestationObject
            }
        }
    } 
    #######################################################
    #CHANGE 
    #| ConvertTo-Json #-Depth 10

    Invoke-MgGraphRequest -Method 'POST' `
    -Body $body `
    -OutputType 'Json' `
    -ContentType "application/json" `
    -Uri "https://graph.microsoft.com/beta/users/$userUPN/authentication/fido2Methods"


    $Connection = Disconnect-MgGraph

}  