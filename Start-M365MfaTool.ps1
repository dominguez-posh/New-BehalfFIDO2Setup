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
# -Global, damit auch Provisioning.psm1 die Graph-Funktionen (Invoke-M365GraphRequest usw.) nutzen kann.
Import-Module (Join-Path $script:AppRoot 'Modules\Graph.psm1') -Force -Global
Import-Module (Join-Path $script:AppRoot 'Modules\Provisioning.psm1') -Force

[xml]$xaml = Get-Content -LiteralPath (Join-Path $script:AppRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    'TxtConnectionStatus','BtnLogin','BtnLogout','TxtSearch','BtnSearch','DgUsers',
    'TxtSelectedName','TxtSelectedUpn','TxtSelectedId','CmbMethod','BtnExecute',
    'TxtLog','ProgressBar','TxtTenant',
    'DgMethods','TxtMethodDetails','BtnRefreshMethods','BtnDeleteMethod',
    'TxtMethodCount','TxtPreferredMethod','TxtSystemPreferred',
    'PnlTap','TxtTapUser','TxtTapValue','TxtTapValidity','BtnCopyTap','BtnHideTap',
    'BtnCopyUpn','BtnCopyId',
    'PnlSerial','LblSerial','TxtSerial','PnlSecret','PwdSecret','TxtMethodHint',
    'PnlTotp','TxtTotpUser','ImgTotpQr','TxtTotpSecret','TxtTotpInfo','BtnCopyTotpSecret','BtnSaveTotpQr','BtnHideTotp'
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
        Serial = 'Seriennummer / interne ID des Sticks'; Secret = $false
        Hint   = 'Stick anstecken. Nach dem Start fragt Windows nach PIN und Berührung des Sticks. Name der Methode: FIDO2-<Seriennummer>.'
    }
    'TOTP-Karte mit festem Secret' = @{
        Serial = 'Seriennummer der Karte'; Secret = $true
        Hint   = 'Seriennummer und Secret aus den Herstellerdaten eingeben. Der Aktivierungscode wird aus dem Secret berechnet.'
    }
    'Programmierbare TOTP-Karte' = @{
        Serial = 'Seriennummer der Karte'; Secret = $false
        Hint   = 'Es wird ein neues Secret erzeugt und aktiviert. Danach die Karte per QR-Code oder Secret programmieren.'
    }
    'Temporary Access Pass (2 Stunden)' = @{
        Serial = $null; Secret = $false
        Hint   = 'Ab sofort 2 Stunden gültig, mehrfach nutzbar. Ein vorhandener TAP wird ersetzt.'
    }
    'Fake-MFA (TOTP ohne Hinterlegung)' = @{
        Serial = $null; Secret = $false
        Hint   = 'Registriert ein TOTP mit zufälligem Secret, das sofort verworfen wird. Bei der Anmeldung wird dadurch immer MFA abgefragt.'
    }
}

function Write-UiLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Info','Success','Warning','Error')][string]$Level='Info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    $script:TxtLog.AppendText($line + [Environment]::NewLine)
    $script:TxtLog.ScrollToEnd()
}

function Set-Busy {
    param([bool]$Busy)
    $script:ProgressBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $connected = Test-M365GraphConnection
    $hasUser = $null -ne $script:SelectedUser
    $script:BtnLogin.IsEnabled = (-not $Busy) -and (-not $connected)
    $script:BtnLogout.IsEnabled = (-not $Busy) -and $connected
    $script:BtnSearch.IsEnabled = (-not $Busy) -and $connected
    $script:BtnExecute.IsEnabled = (-not $Busy) -and $hasUser
    $script:BtnCopyUpn.IsEnabled = $hasUser
    $script:BtnCopyId.IsEnabled = $hasUser
    $script:BtnRefreshMethods.IsEnabled = (-not $Busy) -and $connected -and $hasUser
    $script:BtnDeleteMethod.IsEnabled = (-not $Busy) -and $connected -and ($null -ne $script:SelectedMethod) -and $script:SelectedMethod.CanDelete
    [System.Windows.Forms.Application]::DoEvents()
}

function Clear-MfaView {
    $script:SelectedMethod = $null
    $script:DgMethods.ItemsSource = $null
    $script:TxtMethodDetails.Text = ''
    $script:TxtMethodCount.Text = '-'
    $script:TxtPreferredMethod.Text = '-'
    $script:TxtSystemPreferred.Text = '-'
}

function Show-TapResult {
    param([Parameter(Mandatory)]$Tap)
    $script:TxtTapUser.Text = "für $($Tap.UserPrincipalName)"
    $script:TxtTapValue.Text = $Tap.Pass
    $script:TxtTapValidity.Text = 'Gültig von {0:dd.MM.yyyy HH:mm} bis {1:dd.MM.yyyy HH:mm} Uhr ({2} min, {3})' -f
        $Tap.ValidFrom, $Tap.ValidUntil, $Tap.LifetimeInMinutes,
        $(if ($Tap.IsUsableOnce) { 'einmalig nutzbar' } else { 'mehrfach nutzbar' })
    $script:PnlTap.Visibility = 'Visible'
}

function Hide-TapResult {
    $script:TxtTapValue.Text = ''
    $script:TxtTapUser.Text = '-'
    $script:TxtTapValidity.Text = '-'
    $script:PnlTap.Visibility = 'Collapsed'
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
    finally { $stream.Dispose() }
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

function Update-MethodInputs {
    $method = if ($script:CmbMethod.SelectedItem) { [string]$script:CmbMethod.SelectedItem.Content } else { $null }
    $ui = if ($method) { $script:MethodUi[$method] } else { $null }
    if ($null -eq $ui) {
        $script:PnlSerial.Visibility = 'Collapsed'
        $script:PnlSecret.Visibility = 'Collapsed'
        $script:TxtMethodHint.Text = ''
        return
    }
    $script:PnlSerial.Visibility = if ($ui.Serial) { 'Visible' } else { 'Collapsed' }
    if ($ui.Serial) { $script:LblSerial.Text = $ui.Serial }
    $script:PnlSecret.Visibility = if ($ui.Secret) { 'Visible' } else { 'Collapsed' }
    $script:TxtMethodHint.Text = $ui.Hint
}

function Clear-SelectedUser {
    Hide-TapResult
    Hide-TotpResult
    $script:SelectedUser = $null
    $script:TxtSelectedName.Text = '-'
    $script:TxtSelectedUpn.Text = '-'
    $script:TxtSelectedId.Text = '-'
    Clear-MfaView
}

function Wait-Ui {
    param([int]$Milliseconds)
    # Wartet, ohne die Oberfläche einzufrieren.
    $until = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $until) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Update-MfaView {
    param(
        [string[]]$RemovedMethodIds = @(),
        [string[]]$AddedMethodIds = @()
    )
    Clear-MfaView
    if ($null -eq $script:SelectedUser) { return }
    $user = $script:SelectedUser
    $RemovedMethodIds = @($RemovedMethodIds | Where-Object { $_ })
    $AddedMethodIds = @($AddedMethodIds | Where-Object { $_ })
    try {
        Set-Busy $true
        Write-UiLog "Lade MFA-Methoden für $($user.UserPrincipalName) ..."
        $methods = @(Get-M365UserAuthMethods -UserId $user.Id | Sort-Object TypeName, Created)

        # Graph repliziert Änderungen verzögert - warten, bis gelöschte Methoden weg und neue Methoden da sind.
        $isPending = {
            param($list)
            $ids = @($list | ForEach-Object { $_.Id })
            @($RemovedMethodIds | Where-Object { $ids -contains $_ }).Count -gt 0 -or
            @($AddedMethodIds | Where-Object { $ids -notcontains $_ }).Count -gt 0
        }
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
        Write-UiLog "MFA-Methoden konnten nicht geladen werden: $($_.Exception.Message)" 'Error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Fehler beim Laden der MFA-Methoden', 'OK', 'Error') | Out-Null
    }
    finally { Set-Busy $false }
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
        $DgUsers.ItemsSource = $null
        Clear-SelectedUser
        $TxtConnectionStatus.Text = 'Nicht verbunden'
        $TxtConnectionStatus.Foreground = '#A4262C'
        $TxtTenant.Text = 'Tenant: -'
        Write-UiLog 'Microsoft-Graph-Sitzung wurde getrennt.' 'Success'
    }
    catch { Write-UiLog $_.Exception.Message 'Error' }
    finally { Set-Busy $false }
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
    param($src,$keyArgs)
    if ($keyArgs.Key -eq 'Enter' -and $BtnSearch.IsEnabled) { $BtnSearch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) }
})

$DgUsers.Add_SelectionChanged({
    $user = $DgUsers.SelectedItem
    if ($null -eq $user) {
        Clear-SelectedUser
        Set-Busy $false
        return
    }
    if ($null -ne $script:SelectedUser -and $script:SelectedUser.Id -eq $user.Id) { return }

    Hide-TapResult
    Hide-TotpResult
    $script:SelectedUser = $user
    $TxtSelectedName.Text = $user.DisplayName
    $TxtSelectedUpn.Text = $user.UserPrincipalName
    $TxtSelectedId.Text = $user.Id
    Write-UiLog "Benutzer ausgewählt: $($user.UserPrincipalName)"
    Update-MfaView
})

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
    $answer = [System.Windows.MessageBox]::Show(
        ("Folgende MFA-Methode wirklich löschen?`n`nBenutzer: {0}`nMethode: {1}`nBezeichnung: {2}`nErstellt am: {3}`nID: {4}`n`nDieser Vorgang kann nicht rückgängig gemacht werden." -f
            $user.UserPrincipalName, $method.TypeName, $method.DisplayName, $created, $method.Id),
        'Löschen bestätigen', 'YesNo', 'Warning', 'No')
    if ($answer -ne 'Yes') { return }

    $deleted = $false
    try {
        Set-Busy $true
        Write-UiLog "Lösche $($method.TypeName) '$($method.DisplayName)' ($($method.Id)) für $($user.UserPrincipalName)." 'Warning'
        Remove-M365UserAuthMethod -UserId $user.Id -Method $method -Confirm:$false
        $deleted = $true
        Write-UiLog "Methode gelöscht: $($method.TypeName) '$($method.DisplayName)'." 'Success'
    }
    catch {
        Write-UiLog "Löschen fehlgeschlagen: $($_.Exception.Message)" 'Error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Löschen fehlgeschlagen', 'OK', 'Error') | Out-Null
    }
    finally { Set-Busy $false }
    if ($deleted) { Update-MfaView -RemovedMethodIds $method.Id } else { Update-MfaView }
})

$BtnExecute.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    if ($CmbMethod.SelectedIndex -lt 0) {
        [System.Windows.MessageBox]::Show('Bitte eine Methode auswählen.', 'Methode', 'OK', 'Information') | Out-Null
        return
    }
    $method = [string]$CmbMethod.SelectedItem.Content
    $ui = $script:MethodUi[$method]

    # Eingaben prüfen, bevor nachgefragt wird
    $options = @{}
    if ($ui.Serial) {
        if ([string]::IsNullOrWhiteSpace($TxtSerial.Text)) {
            [System.Windows.MessageBox]::Show("Bitte '$($ui.Serial)' eingeben.", 'Eingabe fehlt', 'OK', 'Information') | Out-Null
            $TxtSerial.Focus() | Out-Null
            return
        }
        $options.SerialNumber = $TxtSerial.Text.Trim()
    }
    if ($ui.Secret) {
        if ([string]::IsNullOrWhiteSpace($PwdSecret.Password)) {
            [System.Windows.MessageBox]::Show('Bitte das Secret der Karte eingeben.', 'Eingabe fehlt', 'OK', 'Information') | Out-Null
            $PwdSecret.Focus() | Out-Null
            return
        }
        $options.Secret = $PwdSecret.Password
    }

    $question = "Konfiguration '$method' für $($script:SelectedUser.UserPrincipalName) starten?"
    if ($options.ContainsKey('SerialNumber')) { $question += "`nSeriennummer: $($options.SerialNumber)" }

    if ($method -like 'Temporary Access Pass*') {
        $existingTap = @($DgMethods.ItemsSource | Where-Object { $null -ne $_ -and $_.Type -eq '#microsoft.graph.temporaryAccessPassAuthenticationMethod' })
        if ($existingTap.Count) {
            $question += "`n`nDer Benutzer hat bereits einen Temporary Access Pass. Dieser wird gelöscht und durch einen neuen ersetzt."
        }
    }

    $answer = [System.Windows.MessageBox]::Show($question, 'Konfiguration bestätigen', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    $result = $null
    try {
        Set-Busy $true
        Hide-TapResult
        Hide-TotpResult
        Write-UiLog "Starte $method für $($script:SelectedUser.UserPrincipalName)." 'Warning'
        if ($method -eq 'FIDO2 Security Key') { Write-UiLog 'Bitte PIN eingeben und den Stick berühren, sobald Windows danach fragt.' }
        $result = Invoke-MfaProvisioning -Method $method -User $script:SelectedUser -AppRoot $script:AppRoot -Options $options
        # TAP und TOTP-Secret werden bewusst nicht protokolliert, nur angezeigt.
        Write-UiLog $result.Message 'Success'
        if ($null -ne $result.TemporaryAccessPass) { Show-TapResult -Tap $result.TemporaryAccessPass }
        if ($null -ne $result.TotpSetup) { Show-TotpResult -Setup $result.TotpSetup }
        $TxtSerial.Clear()
        $PwdSecret.Clear()
    }
    catch {
        Write-UiLog $_.Exception.Message 'Error'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Provisionierungsfehler', 'OK', 'Error') | Out-Null
    }
    finally { Set-Busy $false }
    if ($null -ne $result) {
        Update-MfaView -AddedMethodIds $result.AddedMethodIds -RemovedMethodIds $result.RemovedMethodIds
    }
    else { Update-MfaView }
})

$BtnCopyTap.Add_Click({
    if ([string]::IsNullOrEmpty($TxtTapValue.Text)) { return }
    [System.Windows.Clipboard]::SetText($TxtTapValue.Text)
    Write-UiLog 'Temporary Access Pass in die Zwischenablage kopiert.'
})

$BtnHideTap.Add_Click({ Hide-TapResult })

$CmbMethod.Add_SelectionChanged({ Update-MethodInputs })

$BtnHideTotp.Add_Click({ Hide-TotpResult })

$BtnCopyTotpSecret.Add_Click({
    if ([string]::IsNullOrEmpty($TxtTotpSecret.Text)) { return }
    [System.Windows.Clipboard]::SetText($TxtTotpSecret.Text)
    Write-UiLog 'TOTP-Secret in die Zwischenablage kopiert.'
})

$BtnSaveTotpQr.Add_Click({
    $setup = $script:TotpSetup
    if ($null -eq $setup -or -not $setup.QrCodePng) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'QR-Code speichern'
    $dialog.Filter = 'PNG-Bild (*.png)|*.png'
    $fileName = 'totp-{0}-{1}.png' -f $setup.UserPrincipalName, $setup.SerialNumber
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) { $fileName = $fileName.Replace([string]$char, '_') }
    $dialog.FileName = $fileName
    if ($dialog.ShowDialog($window)) {
        [System.IO.File]::WriteAllBytes($dialog.FileName, [byte[]]$setup.QrCodePng)
        Write-UiLog "QR-Code gespeichert: $($dialog.FileName) (enthält das Secret - nach Gebrauch löschen)." 'Warning'
    }
})

$BtnCopyUpn.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    [System.Windows.Clipboard]::SetText([string]$script:SelectedUser.UserPrincipalName)
    Write-UiLog "UPN kopiert: $($script:SelectedUser.UserPrincipalName)"
})

$BtnCopyId.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    [System.Windows.Clipboard]::SetText([string]$script:SelectedUser.Id)
    Write-UiLog "Objekt-ID kopiert: $($script:SelectedUser.Id)"
})

$window.Add_Closing({
    if (Test-M365GraphConnection) { Disconnect-M365Graph }
})

Write-UiLog 'Anwendung gestartet. Bitte zuerst an Microsoft 365 anmelden.'
$window.ShowDialog() | Out-Null
