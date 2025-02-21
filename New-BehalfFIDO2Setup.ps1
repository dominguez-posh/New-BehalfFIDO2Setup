## Remote FIDO2 Setup
# Needed API Rights: UserAuthenticationMethod.ReadWrite.All

function New-RandomPassword {
    param (
        [int]$length = 255
    )

    $characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()'
    $password = -join ((1..$length) | ForEach-Object { $characters[(Get-Random -Minimum 0 -Maximum $characters.Length)] })
    return $password
}



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
    $Connection =   Connect-MgGraph -Scopes UserAuthenticationMethod.ReadWrite.All, User.ReadWrite.All  -NoWelcome  # -TenantId $TenantID 
}
catch{
    Write-Error "NO CONNECTION with Graph POSSIBLE"
    exit 1001 
}


##New BG User

$INPUT = Read-Host -Prompt "Create NEW BREAKGLASS Account?(Y/N)"

if($INput -eq "Y"){

    $PasswordProfile = @{
      Password = New-RandomPassword
      }
    $GUID = (New-Guid).Guid

    #GetMax UPN Length
    $DomainName= (Get-MgDomain | Out-GridView -OutputMode Single -Title "SELECT DOMAIN SUFFIX").id
    #$DomainName= ((Get-MgDomain).Id | sort { $_.length })[0]
    $UserNameMaxLenth = 63 - $DomainName.Length

    #Shorten GUID to lowest Possible Lenth

    $NewUPN = $GUID + "@" + $DomainName

    $MGUser = New-MgUser -DisplayName ("Break Glass Account " + $GUID) -PasswordProfile $PasswordProfile -AccountEnabled -UserPrincipalName $NewUPN -MailNickname $GUID

    $NewGUID = $MGUser.id

    $NewGUID  = $NewGUID.Substring(0, [Math]::Min($NewGUID.Length, $UserNameMaxLenth))

    Update-MGUser -UserId $MGUser.Id -UserPrincipalName ($NewGUID + "@" + $DomainName) -MailNickname $NewGUID -DisplayName ("Break Glass Account-" + $NewGUID)

    $MGUser = Get-MGUser -UserId $MGUser.Id

}

else{

    #Selecting User
    $MGUser = (Get-MGUser -All | Out-GridView -OutputMode Single -Title "Select User to Config")

}

if($MGUser.UserPrincipalName.Length -le 64){

    
    #Getting Serial
    $Serial = (Read-Host -Prompt "INPUT FIDO STICK SERIAL OR INTERNAL ID")
    $DisplayName = "FIDO2-$Serial"

    #Writing FIDO2
    $Passkeyregistration =  Get-PasskeyRegistrationOptions -UserId $MGUser.UserPrincipalName

    $Passkey = $Passkeyregistration |  New-Passkey -DisplayName $DisplayName

    $ErrMessage = $Null

        try{
    
            $PasskeyEntraRegister = $Passkey | Register-Passkey -UserId $MGUser.UserPrincipalName
        }
    
        catch{
            $ErrMessage = $_.ErrorDetails.Message
    
        }
            
        if($ErrMessage -like "*No Fido credential policy found in tenant, default is disabled. Administrator must set policy.*"){
            
            Write-Error "No Fido credential policy found in tenant, default is disabled. Administrator must set policy."
            Write-Host "Enable Under: https://entra.microsoft.com/#view/Microsoft_AAD_IAM/AuthenticationMethodsMenuBlade/~/AdminAuthMethods/fromNav/Identity?Microsoft_AAD_IAM_legacyAADRedirect=true" -Verbose
            Read-Host "Press Any Key to Retry"
        }
        if($ErrMessage -like "*Fido credential policy disabled in tenant*"){
            
            Write-Error "Fido credential policy disabled in tenant. Administrator must enablepolicy."
            Write-Host "Enable Under: https://entra.microsoft.com/#view/Microsoft_AAD_IAM/AuthenticationMethodsMenuBlade/~/AdminAuthMethods/fromNav/Identity?Microsoft_AAD_IAM_legacyAADRedirect=true" -Verbose
            Read-Host "Press Any Key to Retry"
        }
        else{$ErrMessage = $Null}


    $Void = Disconnect-MgGraph

    if($PasskeyEntraRegister){
        Write-Host "PassKey eingerichtet!"
        Write-Host
        Write-Host $PasskeyEntraRegister.CreatedDateTime
        Write-Host $PasskeyEntraRegister.DisplayName
        Write-Host $PasskeyEntraRegister.Model
        Write-Host
        Write-Host $MGUser.UserPrincipalName
        Write-Host
        Write-Host "If you created a new Breakglass account, add it to Exclusion List in CA rules and give it global Access Rights"
        Write-HOst "Also remember to setup a Login Notification for the Account!"
        Write-Host

    }
        


}
else{
    Write-Error "UPN TOO LONG! ONLY 64 CHARS ARE ALLOWED FOR FIDO2 PLEASE SHORT IT FIRST"
}



Read-Host  "Press Any Key to Continue"
