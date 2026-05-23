## Remote FIDO2 Setup
# Needed API Rights: UserAuthenticationMethod.ReadWrite.All


#setting execution policy for this session to allow running the script without changing the system wide policy
Set-ExecutionPolicy RemoteSigned -Scope Process -Force



[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


function Install-ModuleInCurrentUserContext($ModuleName, $ForceVersion = $null) 
{ 

    Write-Verbose "Checking if $ModuleName Already installed" -Verbose

    $InstalledModules = Get-InstalledModule 


    if(-not ($InstalledModules | Where-Object { $_.Name -eq "$ModuleName" })){
        
        Write-Verbose "Installing Module $ModuleName ..." -Verbose
        Install-Module -Name $ModuleName -Scope CurrentUser

        Write-Verbose "Checking if $ModuleName installed after installation" -Verbose
        if((Get-InstalledModule | Where-Object { $_.Name -eq "$ModuleName" })){

            Write-Verbose "Module $ModuleName was successfully installed" -Verbose
            return (Get-InstalledModule | Where-Object { $_.Name -eq "$ModuleName" })
        }
        else{
            Write-Error "Module $ModuleName could not be installed"
            return 1001
        }

    }
    else{
        $Version = ($InstalledModules | Where-Object { $_.Name -eq "$ModuleName" }).Version
        Write-Verbose "Module allready installed in Version $Version no installation required" -Verbose
        return (Get-InstalledModule | Where-Object { $_.Name -eq "$ModuleName" })
    }


}


Write-Verbose "Installing all required Modules..." -Verbose
Install-ModuleInCurrentUserContext DSInternals.Passkeys
Install-ModuleInCurrentUserContext  Microsoft.Graph.Authentication
Install-ModuleInCurrentUserContext Microsoft.Graph.Identity.SignIns
Install-ModuleInCurrentUserContext Microsoft.Graph.Users

#Void = Disconnect-MgGraph
#just for testing perposures


Write-Verbose "Logging in to Graph...." -Verbose
try{
    $Connection =   Connect-MgGraph -Scopes UserAuthenticationMethod.ReadWrite.All, User.ReadWrite.All
    $Account = (Get-MgContext).Account

}
catch{
    Write-Error "NO CONNECTION with Graph POSSIBLE"
    exit 1001 
}


Write-Verbose "Logged in to Graph With Account  $Account" -Verbose




#Selecting User
Write-Verbose "Getting all Users from Graph. Selecting could be in Background!" -Verbose
$MGUser = (Get-MGUser -All)


$MGUser = $MGUser | Out-GridView -OutputMode Single -Title "Select User to Config"


if($MGUser.UserPrincipalName.Length -le 64){

    $Serial = (Read-Host -Prompt "INPUT FIDO STICK SERIAL OR INTERNAL ID")
    $DisplayName = "FIDO2-$Serial"

    $userUPN = $MGUser.UserPrincipalName 



    $Passkeyregistration =  Get-PasskeyRegistrationOptions -UserId $MGUser.UserPrincipalName 
    $Passkeyregistration.Attestation



    $PassKey  = New-Passkey -Options $Passkeyregistration 


    $PasskeyEntraRegister = $Passkey | Register-Passkey -UserId $MGUser.UserPrincipalName -displayName $DisplayName  



}  