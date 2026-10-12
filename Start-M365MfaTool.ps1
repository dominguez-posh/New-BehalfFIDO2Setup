#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "Dieses WPF-Tool muss mit Windows PowerShell 5.1 gestartet werden: powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:AppRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $script:AppRoot 'Modules\Graph.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Provisioning.psm1') -Force

[xml]$xaml = Get-Content -LiteralPath (Join-Path $script:AppRoot 'UI\MainWindow.xaml') -Raw
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    'TxtConnectionStatus','BtnLogin','BtnLogout','TxtSearch','BtnSearch','DgUsers',
    'TxtSelectedName','TxtSelectedUpn','TxtSelectedId','CmbMethod','BtnExecute',
    'TxtLog','ProgressBar','TxtTenant'
)
foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

$script:SelectedUser = $null

function Write-UiLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Info','Success','Warning','Error')][string]$Level='Info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    $script:TxtLog.AppendText($line + [Environment]::NewLine)
    $script:TxtLog.ScrollToEnd()
}

function Set-Busy {
    param([bool]$Busy)
    $script:ProgressBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $script:BtnLogin.IsEnabled = -not $Busy
    $script:BtnSearch.IsEnabled = (-not $Busy) -and (Test-M365GraphConnection)
    $script:BtnExecute.IsEnabled = (-not $Busy) -and ($null -ne $script:SelectedUser)
    [System.Windows.Forms.Application]::DoEvents()
}

Add-Type -AssemblyName System.Windows.Forms

$BtnLogin.Add_Click({
    try {
        Set-Busy $true
        Write-UiLog 'Interaktive Anmeldung an Microsoft Graph wird gestartet.'
        $context = Connect-M365Graph
        $TxtConnectionStatus.Text = "Verbunden als $($context.Account)"
        $TxtConnectionStatus.Foreground = '#107C10'
        $TxtTenant.Text = "Tenant: $($context.TenantId)"
        $BtnLogout.IsEnabled = $true
        Write-UiLog "Anmeldung erfolgreich: $($context.Account)" 'Success'
    }
    catch {
        Write-UiLog $_.Exception.Message 'Error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Anmeldefehler', 'OK', 'Error') | Out-Null
    }
    finally { Set-Busy $false }
})

$BtnLogout.Add_Click({
    try {
        Disconnect-M365Graph
        $script:SelectedUser = $null
        $DgUsers.ItemsSource = $null
        $TxtConnectionStatus.Text = 'Nicht verbunden'
        $TxtConnectionStatus.Foreground = '#A4262C'
        $TxtTenant.Text = 'Tenant: -'
        $BtnLogout.IsEnabled = $false
        $BtnSearch.IsEnabled = $false
        $BtnExecute.IsEnabled = $false
        Write-UiLog 'Microsoft-Graph-Sitzung wurde getrennt.' 'Success'
    } catch { Write-UiLog $_.Exception.Message 'Error' }
})

$BtnSearch.Add_Click({
    try {
        $term = $TxtSearch.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($term)) {
            [System.Windows.MessageBox]::Show('Bitte Name, UPN oder E-Mail-Adresse eingeben.', 'Benutzersuche', 'OK', 'Information') | Out-Null
            return
        }
        Set-Busy $true
        Write-UiLog "Benutzersuche: $term"
        $users = @(Find-M365User -SearchTerm $term)
        $DgUsers.ItemsSource = $users
        Write-UiLog "$($users.Count) Benutzer gefunden." 'Success'
    }
    catch {
        Write-UiLog $_.Exception.Message 'Error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Suchfehler', 'OK', 'Error') | Out-Null
    }
    finally { Set-Busy $false }
})

$TxtSearch.Add_KeyDown({
    param($sender,$eventArgs)
    if ($eventArgs.Key -eq 'Enter' -and $BtnSearch.IsEnabled) { $BtnSearch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) }
})

$DgUsers.Add_SelectionChanged({
    $script:SelectedUser = $DgUsers.SelectedItem
    if ($null -ne $script:SelectedUser) {
        $TxtSelectedName.Text = $script:SelectedUser.DisplayName
        $TxtSelectedUpn.Text = $script:SelectedUser.UserPrincipalName
        $TxtSelectedId.Text = $script:SelectedUser.Id
        $BtnExecute.IsEnabled = $true
        Write-UiLog "Benutzer ausgewählt: $($script:SelectedUser.UserPrincipalName)"
    }
})

$BtnExecute.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    if ($CmbMethod.SelectedIndex -lt 0) {
        [System.Windows.MessageBox]::Show('Bitte eine Methode auswählen.', 'Methode', 'OK', 'Information') | Out-Null
        return
    }
    $method = [string]$CmbMethod.SelectedItem.Content
    $answer = [System.Windows.MessageBox]::Show(
        "Konfiguration '$method' für $($script:SelectedUser.UserPrincipalName) starten?",
        'Konfiguration bestätigen','YesNo','Warning')
    if ($answer -ne 'Yes') { return }
    try {
        Set-Busy $true
        Write-UiLog "Starte $method für $($script:SelectedUser.UserPrincipalName)." 'Warning'
        $result = Invoke-MfaProvisioning -Method $method -User $script:SelectedUser -AppRoot $script:AppRoot
        Write-UiLog $result 'Success'
    }
    catch {
        Write-UiLog $_.Exception.Message 'Error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Provisionierungsfehler', 'OK', 'Error') | Out-Null
    }
    finally { Set-Busy $false }
})

$window.Add_Closing({
    if (Test-M365GraphConnection) { Disconnect-M365Graph }
})

Write-UiLog 'Anwendung gestartet. Bitte zuerst an Microsoft 365 anmelden.'
$window.ShowDialog() | Out-Null
