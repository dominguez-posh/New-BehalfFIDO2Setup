#requires -Version 5.1
<#
.SYNOPSIS
    M365 MFA Administration Tool - MFA-Methoden für andere Benutzer anzeigen, einrichten und löschen.

.DESCRIPTION
    WPF-Oberfläche für Windows PowerShell 5.1. Start per Doppelklick auf Start.cmd oder:
    powershell.exe -ExecutionPolicy Bypass -File .\Start-M365MfaTool.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "Dieses WPF-Tool muss mit Windows PowerShell 5.1 gestartet werden: powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

#region Initialisierung

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot = Split-Path -Parent $PSCommandPath
# -Global, damit auch Provisioning.psm1 die Graph-Funktionen (Invoke-M365GraphRequest usw.) nutzen kann.
Import-Module (Join-Path $script:AppRoot 'Modules\Graph.psm1') -Force -Global
Import-Module (Join-Path $script:AppRoot 'Modules\Provisioning.psm1') -Force

[xml]$xaml = Get-Content -LiteralPath (Join-Path $script:AppRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))

$controlNames = @(
    # Kopfzeile und Verbindung
    'TxtConnectionStatus', 'TxtTenant', 'BtnLogin', 'BtnLogout'
    # Benutzersuche
    'TxtSearch', 'BtnSearch', 'DgUsers'
    # MFA-Methoden
    'DgMethods', 'TxtMethodDetails', 'BtnRefreshMethods', 'BtnDeleteMethod'
    # Ausgewählter Benutzer
    'TxtSelectedName', 'TxtSelectedUpn', 'TxtSelectedId', 'BtnCopyUpn', 'BtnCopyId'
    'TxtMethodCount', 'TxtPreferredMethod', 'TxtSystemPreferred'
    # Methode konfigurieren
    'CmbMethod', 'PnlSerial', 'LblSerial', 'TxtSerial', 'PnlSecret', 'PwdSecret', 'TxtMethodHint', 'BtnExecute'
    # Ergebnis: Temporary Access Pass
    'PnlTap', 'TxtTapUser', 'TxtTapValue', 'TxtTapValidity', 'BtnCopyTap', 'BtnHideTap'
    # Ergebnis: programmierbare TOTP-Karte
    'PnlTotp', 'TxtTotpUser', 'ImgTotpQr', 'TxtTotpSecret', 'TxtTotpInfo', 'BtnCopyTotpSecret', 'BtnSaveTotpQr', 'BtnHideTotp'
    # Protokoll und Status
    'TxtLog', 'ProgressBar'
)
foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

$script:SelectedUser = $null
$script:SelectedMethod = $null
$script:TotpSetup = $null

# Eingabefelder und Hinweise je Methode (Schlüssel = Dropdown-Text)
$script:MethodUi = @{
    'FIDO2 Security Key' = @{
        Serial = 'Seriennummer / interne ID des Sticks'
        Secret = $false
        Hint   = 'Stick anstecken. Nach dem Start fragt Windows nach PIN und Berührung des Sticks. Name der Methode: FIDO2-<Seriennummer>.'
    }
    'TOTP-Karte mit festem Secret' = @{
        Serial = 'Seriennummer der Karte'
        Secret = $true
        Hint   = 'Seriennummer und Secret aus den Herstellerdaten eingeben. Der Aktivierungscode wird aus dem Secret berechnet.'
    }
    'Programmierbare TOTP-Karte' = @{
        Serial = 'Seriennummer der Karte'
        Secret = $false
        Hint   = 'Es wird ein neues Secret erzeugt und aktiviert. Danach die Karte per QR-Code oder Secret programmieren.'
    }
    'Temporary Access Pass (2 Stunden)' = @{
        Serial = $null
        Secret = $false
        Hint   = 'Ab sofort 2 Stunden gültig, mehrfach nutzbar. Ein vorhandener TAP wird ersetzt.'
    }
    'Fake-MFA (TOTP ohne Hinterlegung)' = @{
        Serial = $null
        Secret = $false
        Hint   = 'Registriert ein TOTP mit zufälligem Secret, das sofort verworfen wird. Bei der Anmeldung wird dadurch immer MFA abgefragt.'
    }
}

#endregion

#region UI-Hilfsfunktionen

function Write-UiLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    $script:TxtLog.AppendText($line + [Environment]::NewLine)
    $script:TxtLog.ScrollToEnd()
}

function Show-Message {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )
    [System.Windows.MessageBox]::Show($Text, $Title, 'OK', $Icon) | Out-Null
}

function Confirm-Action {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Title)
    [System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Warning', 'No') -eq 'Yes'
}

function Write-UiError {
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][string]$Title)
    Write-UiLog $Message 'Error'
    Show-Message -Text $Message -Title $Title -Icon Error
}

function Copy-ToClipboard {
    param([string]$Text, [Parameter(Mandatory)][string]$LogMessage)
    if ([string]::IsNullOrEmpty($Text)) { return }
    [System.Windows.Clipboard]::SetText($Text)
    Write-UiLog $LogMessage
}

function Set-Busy {
    param([bool]$Busy)
    $connected = Test-M365GraphConnection
    $hasUser = $null -ne $script:SelectedUser
    $canDelete = ($null -ne $script:SelectedMethod) -and $script:SelectedMethod.CanDelete

    $script:ProgressBar.Visibility       = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $script:BtnLogin.IsEnabled           = -not $Busy -and -not $connected
    $script:BtnLogout.IsEnabled          = -not $Busy -and $connected
    $script:BtnSearch.IsEnabled          = -not $Busy -and $connected
    $script:BtnExecute.IsEnabled         = -not $Busy -and $hasUser
    $script:BtnRefreshMethods.IsEnabled  = -not $Busy -and $connected -and $hasUser
    $script:BtnDeleteMethod.IsEnabled    = -not $Busy -and $connected -and $canDelete
    $script:BtnCopyUpn.IsEnabled         = $hasUser
    $script:BtnCopyId.IsEnabled          = $hasUser
    [System.Windows.Forms.Application]::DoEvents()
}

function Wait-Ui {
    # Wartet, ohne die Oberfläche einzufrieren.
    param([int]$Milliseconds)
    $until = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $until) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function ConvertTo-BitmapImage {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $stream = New-Object System.IO.MemoryStream (, $Bytes)
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource = $stream
        $bitmap.EndInit()
        $bitmap.Freeze()
        return $bitmap
    }
    finally {
        $stream.Dispose()
    }
}

function Update-MethodInputs {
    $method = if ($script:CmbMethod.SelectedItem) { [string]$script:CmbMethod.SelectedItem.Content } else { $null }
    $ui = if ($method) { $script:MethodUi[$method] } else { $null }

    $script:PnlSerial.Visibility = if ($ui -and $ui.Serial) { 'Visible' } else { 'Collapsed' }
    $script:PnlSecret.Visibility = if ($ui -and $ui.Secret) { 'Visible' } else { 'Collapsed' }
    $script:TxtMethodHint.Text = if ($ui) { $ui.Hint } else { '' }
    if ($ui -and $ui.Serial) { $script:LblSerial.Text = $ui.Serial }
}

#endregion

#region Ergebnisanzeigen (TAP / TOTP-Karte)

function Show-TapResult {
    param([Parameter(Mandatory)]$Tap)
    $usage = if ($Tap.IsUsableOnce) { 'einmalig nutzbar' } else { 'mehrfach nutzbar' }
    $script:TxtTapUser.Text = "für $($Tap.UserPrincipalName)"
    $script:TxtTapValue.Text = $Tap.Pass
    $script:TxtTapValidity.Text = 'Gültig von {0:dd.MM.yyyy HH:mm} bis {1:dd.MM.yyyy HH:mm} Uhr ({2} min, {3})' -f
        $Tap.ValidFrom, $Tap.ValidUntil, $Tap.LifetimeInMinutes, $usage
    $script:PnlTap.Visibility = 'Visible'
}

function Hide-TapResult {
    $script:TxtTapValue.Text = ''
    $script:TxtTapUser.Text = '-'
    $script:TxtTapValidity.Text = '-'
    $script:PnlTap.Visibility = 'Collapsed'
}

function Show-TotpResult {
    param([Parameter(Mandatory)]$Setup)
    $script:TotpSetup = $Setup
    $script:TxtTotpUser.Text = "für $($Setup.UserPrincipalName)"
    $script:TxtTotpSecret.Text = $Setup.Secret
    $script:TxtTotpInfo.Text = "Seriennummer: $($Setup.SerialNumber) · TOTP, SHA1, 6 Stellen, 30 Sekunden"
    $script:ImgTotpQr.Source = if ($Setup.QrCodePng) { ConvertTo-BitmapImage -Bytes $Setup.QrCodePng } else { $null }
    $script:BtnSaveTotpQr.IsEnabled = [bool]$Setup.QrCodePng
    $script:PnlTotp.Visibility = 'Visible'
}

function Hide-TotpResult {
    $script:TotpSetup = $null
    $script:TxtTotpSecret.Text = ''
    $script:TxtTotpUser.Text = '-'
    $script:TxtTotpInfo.Text = '-'
    $script:ImgTotpQr.Source = $null
    $script:PnlTotp.Visibility = 'Collapsed'
}

function Hide-Results {
    Hide-TapResult
    Hide-TotpResult
}

#endregion

#region Benutzer- und MFA-Ansicht

function Clear-MfaView {
    $script:SelectedMethod = $null
    $script:DgMethods.ItemsSource = $null
    $script:TxtMethodDetails.Text = ''
    $script:TxtMethodCount.Text = '-'
    $script:TxtPreferredMethod.Text = '-'
    $script:TxtSystemPreferred.Text = '-'
}

function Clear-SelectedUser {
    Hide-Results
    $script:SelectedUser = $null
    $script:TxtSelectedName.Text = '-'
    $script:TxtSelectedUpn.Text = '-'
    $script:TxtSelectedId.Text = '-'
    Clear-MfaView
}

function Update-MfaView {
    <#
    .SYNOPSIS
        Lädt die MFA-Methoden des ausgewählten Benutzers neu.
    .DESCRIPTION
        Graph repliziert Änderungen verzögert. Werden IDs übergeben, wird gewartet, bis
        gelöschte Methoden verschwunden und neue Methoden sichtbar sind (max. ca. 16 Sekunden).
    #>
    param(
        [string[]]$RemovedMethodIds = @(),
        [string[]]$AddedMethodIds = @()
    )

    Clear-MfaView
    if ($null -eq $script:SelectedUser) { return }

    $user = $script:SelectedUser
    $RemovedMethodIds = @($RemovedMethodIds | Where-Object { $_ })
    $AddedMethodIds = @($AddedMethodIds | Where-Object { $_ })

    $isPending = {
        param($list)
        $ids = @($list | ForEach-Object { $_.Id })
        @($RemovedMethodIds | Where-Object { $ids -contains $_ }).Count -gt 0 -or
        @($AddedMethodIds | Where-Object { $ids -notcontains $_ }).Count -gt 0
    }

    try {
        Set-Busy $true
        Write-UiLog "Lade MFA-Methoden für $($user.UserPrincipalName) ..."
        $methods = @(Get-M365UserAuthMethods -UserId $user.Id | Sort-Object TypeName, Created)

        for ($attempt = 1; $attempt -le 8 -and (& $isPending $methods); $attempt++) {
            if ($attempt -eq 1) { Write-UiLog 'Änderung noch nicht in Graph sichtbar, warte auf Replikation ...' }
            Wait-Ui 2000
            $methods = @(Get-M365UserAuthMethods -UserId $user.Id | Sort-Object TypeName, Created)
        }
        if (& $isPending $methods) {
            Write-UiLog 'Graph liefert noch nicht den aktuellen Stand. Gelöschte Methoden werden ausgeblendet; später ggf. "Aktualisieren" klicken.' 'Warning'
            $methods = @($methods | Where-Object { $RemovedMethodIds -notcontains $_.Id })
        }

        $script:DgMethods.ItemsSource = $methods
        $script:TxtMethodCount.Text = "$($methods.Count)"
        Write-UiLog "$($methods.Count) Methode(n) gefunden für $($user.UserPrincipalName)." 'Success'

        try {
            $prefs = Get-M365UserSignInPreferences -UserId $user.Id
            $script:TxtPreferredMethod.Text = $prefs.PreferredMethod
            $script:TxtSystemPreferred.Text = $prefs.SystemPreferredActive
        }
        catch {
            $script:TxtPreferredMethod.Text = 'Nicht verfügbar'
            $script:TxtSystemPreferred.Text = 'Nicht verfügbar'
            Write-UiLog "Anmeldeeinstellungen konnten nicht gelesen werden: $($_.Exception.Message)" 'Warning'
        }
    }
    catch {
        Write-UiError -Message "MFA-Methoden konnten nicht geladen werden: $($_.Exception.Message)" -Title 'Fehler beim Laden der MFA-Methoden'
    }
    finally {
        Set-Busy $false
    }
}

#endregion

#region Ereignisse: Verbindung und Suche

$BtnLogin.Add_Click({
    try {
        Set-Busy $true
        Write-UiLog 'Interaktive Anmeldung an Microsoft Graph wird gestartet.'
        $context = Connect-M365Graph
        $TxtConnectionStatus.Text = "Verbunden als $($context.Account)"
        $TxtConnectionStatus.Foreground = '#107C10'
        $TxtTenant.Text = "Tenant: $($context.TenantId)"
        Write-UiLog "Anmeldung erfolgreich: $($context.Account)" 'Success'
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title 'Anmeldefehler'
    }
    finally {
        Set-Busy $false
    }
})

$BtnLogout.Add_Click({
    try {
        Disconnect-M365Graph
        $DgUsers.ItemsSource = $null
        Clear-SelectedUser
        $TxtConnectionStatus.Text = 'Nicht verbunden'
        $TxtConnectionStatus.Foreground = '#A4262C'
        $TxtTenant.Text = 'Tenant: -'
        Write-UiLog 'Microsoft-Graph-Sitzung wurde getrennt.' 'Success'
    }
    catch {
        Write-UiLog $_.Exception.Message 'Error'
    }
    finally {
        Set-Busy $false
    }
})

$BtnSearch.Add_Click({
    $term = $TxtSearch.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($term)) {
        Show-Message -Text 'Bitte Name, UPN oder E-Mail-Adresse eingeben.' -Title 'Benutzersuche'
        return
    }
    try {
        Set-Busy $true
        Write-UiLog "Benutzersuche: $term"
        $users = @(Find-M365User -SearchTerm $term)
        $DgUsers.ItemsSource = $users
        Write-UiLog "$($users.Count) Benutzer gefunden." 'Success'
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title 'Suchfehler'
    }
    finally {
        Set-Busy $false
    }
})

$TxtSearch.Add_KeyDown({
    param($src, $keyArgs)
    if ($keyArgs.Key -eq 'Enter' -and $BtnSearch.IsEnabled) {
        $BtnSearch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

$DgUsers.Add_SelectionChanged({
    $user = $DgUsers.SelectedItem
    if ($null -eq $user) {
        Clear-SelectedUser
        Set-Busy $false
        return
    }
    if ($null -ne $script:SelectedUser -and $script:SelectedUser.Id -eq $user.Id) { return }

    Hide-Results
    $script:SelectedUser = $user
    $TxtSelectedName.Text = $user.DisplayName
    $TxtSelectedUpn.Text = $user.UserPrincipalName
    $TxtSelectedId.Text = $user.Id
    Write-UiLog "Benutzer ausgewählt: $($user.UserPrincipalName)"
    Update-MfaView
})

$BtnCopyUpn.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    Copy-ToClipboard -Text $script:SelectedUser.UserPrincipalName -LogMessage "UPN kopiert: $($script:SelectedUser.UserPrincipalName)"
})

$BtnCopyId.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    Copy-ToClipboard -Text $script:SelectedUser.Id -LogMessage "Objekt-ID kopiert: $($script:SelectedUser.Id)"
})

#endregion

#region Ereignisse: MFA-Methoden anzeigen und löschen

$DgMethods.Add_SelectionChanged({
    $script:SelectedMethod = $DgMethods.SelectedItem
    $TxtMethodDetails.Text = if ($null -ne $script:SelectedMethod) { $script:SelectedMethod.PropertyText } else { '' }
    Set-Busy $false
})

$BtnRefreshMethods.Add_Click({ Update-MfaView })

$BtnDeleteMethod.Add_Click({
    $user = $script:SelectedUser
    $method = $script:SelectedMethod
    if ($null -eq $user -or $null -eq $method) { return }

    $created = if ($method.Created) { $method.Created.ToString('dd.MM.yyyy HH:mm') } else { '-' }
    $question = "Folgende MFA-Methode wirklich löschen?`n`nBenutzer: {0}`nMethode: {1}`nBezeichnung: {2}`nErstellt am: {3}`nID: {4}`n`nDieser Vorgang kann nicht rückgängig gemacht werden." -f
        $user.UserPrincipalName, $method.TypeName, $method.DisplayName, $created, $method.Id
    if (-not (Confirm-Action -Text $question -Title 'Löschen bestätigen')) { return }

    $deleted = $false
    try {
        Set-Busy $true
        Write-UiLog "Lösche $($method.TypeName) '$($method.DisplayName)' ($($method.Id)) für $($user.UserPrincipalName)." 'Warning'
        Remove-M365UserAuthMethod -UserId $user.Id -Method $method -Confirm:$false
        $deleted = $true
        Write-UiLog "Methode gelöscht: $($method.TypeName) '$($method.DisplayName)'." 'Success'
    }
    catch {
        Write-UiError -Message "Löschen fehlgeschlagen: $($_.Exception.Message)" -Title 'Löschen fehlgeschlagen'
    }
    finally {
        Set-Busy $false
    }

    if ($deleted) { Update-MfaView -RemovedMethodIds $method.Id } else { Update-MfaView }
})

#endregion

#region Ereignisse: Methode konfigurieren

$CmbMethod.Add_SelectionChanged({ Update-MethodInputs })

$BtnExecute.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    if ($CmbMethod.SelectedIndex -lt 0) {
        Show-Message -Text 'Bitte eine Methode auswählen.' -Title 'Methode'
        return
    }

    $user = $script:SelectedUser
    $method = [string]$CmbMethod.SelectedItem.Content
    $ui = $script:MethodUi[$method]

    # Eingaben prüfen, bevor nachgefragt wird
    $options = @{}
    if ($ui.Serial) {
        if ([string]::IsNullOrWhiteSpace($TxtSerial.Text)) {
            Show-Message -Text "Bitte '$($ui.Serial)' eingeben." -Title 'Eingabe fehlt'
            $TxtSerial.Focus() | Out-Null
            return
        }
        $options.SerialNumber = $TxtSerial.Text.Trim()
    }
    if ($ui.Secret) {
        if ([string]::IsNullOrWhiteSpace($PwdSecret.Password)) {
            Show-Message -Text 'Bitte das Secret der Karte eingeben.' -Title 'Eingabe fehlt'
            $PwdSecret.Focus() | Out-Null
            return
        }
        $options.Secret = $PwdSecret.Password
    }

    $question = "Konfiguration '$method' für $($user.UserPrincipalName) starten?"
    if ($options.ContainsKey('SerialNumber')) { $question += "`nSeriennummer: $($options.SerialNumber)" }
    if ($method -eq 'Temporary Access Pass (2 Stunden)') {
        $existingTap = @($DgMethods.ItemsSource | Where-Object { $null -ne $_ -and $_.Type -eq '#microsoft.graph.temporaryAccessPassAuthenticationMethod' })
        if ($existingTap.Count) {
            $question += "`n`nDer Benutzer hat bereits einen Temporary Access Pass. Dieser wird gelöscht und durch einen neuen ersetzt."
        }
    }
    if (-not (Confirm-Action -Text $question -Title 'Konfiguration bestätigen')) { return }

    $result = $null
    try {
        Set-Busy $true
        Hide-Results
        Write-UiLog "Starte $method für $($user.UserPrincipalName)." 'Warning'
        if ($method -eq 'FIDO2 Security Key') { Write-UiLog 'Bitte PIN eingeben und den Stick berühren, sobald Windows danach fragt.' }

        $result = Invoke-MfaProvisioning -Method $method -User $user -Options $options

        # TAP und TOTP-Secret werden bewusst nicht protokolliert, nur angezeigt.
        Write-UiLog $result.Message 'Success'
        if ($null -ne $result.TemporaryAccessPass) { Show-TapResult -Tap $result.TemporaryAccessPass }
        if ($null -ne $result.TotpSetup) { Show-TotpResult -Setup $result.TotpSetup }
        $TxtSerial.Clear()
        $PwdSecret.Clear()
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title 'Provisionierungsfehler'
    }
    finally {
        Set-Busy $false
    }

    if ($null -ne $result) {
        Update-MfaView -AddedMethodIds $result.AddedMethodIds -RemovedMethodIds $result.RemovedMethodIds
    }
    else {
        Update-MfaView
    }
})

#endregion

#region Ereignisse: Ergebnisanzeigen

$BtnCopyTap.Add_Click({
    Copy-ToClipboard -Text $TxtTapValue.Text -LogMessage 'Temporary Access Pass in die Zwischenablage kopiert.'
})

$BtnHideTap.Add_Click({ Hide-TapResult })

$BtnCopyTotpSecret.Add_Click({
    Copy-ToClipboard -Text $TxtTotpSecret.Text -LogMessage 'TOTP-Secret in die Zwischenablage kopiert.'
})

$BtnSaveTotpQr.Add_Click({
    $setup = $script:TotpSetup
    if ($null -eq $setup -or -not $setup.QrCodePng) { return }

    $fileName = 'totp-{0}-{1}.png' -f $setup.UserPrincipalName, $setup.SerialNumber
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) { $fileName = $fileName.Replace([string]$char, '_') }

    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'QR-Code speichern'
    $dialog.Filter = 'PNG-Bild (*.png)|*.png'
    $dialog.FileName = $fileName
    if ($dialog.ShowDialog($window)) {
        [System.IO.File]::WriteAllBytes($dialog.FileName, [byte[]]$setup.QrCodePng)
        Write-UiLog "QR-Code gespeichert: $($dialog.FileName) (enthält das Secret - nach Gebrauch löschen)." 'Warning'
    }
})

$BtnHideTotp.Add_Click({ Hide-TotpResult })

#endregion

#region Start

$window.Add_Closing({
    if (Test-M365GraphConnection) { Disconnect-M365Graph }
})

Write-UiLog 'Anwendung gestartet. Bitte zuerst an Microsoft 365 anmelden.'
$window.ShowDialog() | Out-Null

#endregion
