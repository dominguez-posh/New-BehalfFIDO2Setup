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
    'TxtConnectionStatus', 'TxtTenant', 'BtnBreakGlass', 'BtnLogin', 'BtnLogout'
    # Benutzersuche (Ergebnisse im Popup)
    'TxtSearch', 'BtnSearch', 'PopUsers', 'TxtUserHits', 'DgUsers'
    # MFA-Methoden
    'GrpMethods', 'TxtNoUser', 'DgMethods', 'TxtMethodDetails', 'BtnRefreshMethods', 'BtnDeleteMethod'
    # Ausgewählter Benutzer
    'TxtSelectedName', 'TxtSelectedUpn', 'TxtSelectedId', 'BtnCopyUpn', 'BtnCopyId'
    'TxtMethodCount', 'TxtPreferredMethod', 'TxtSystemPreferred'
    'BdgMfa', 'DotMfa', 'TxtMfaLevel', 'TxtMfaHints', 'TxtRoleSummary', 'BtnShowRoles', 'LstRoles'
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
    $script:BtnBreakGlass.IsEnabled      = -not $Busy -and $connected
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

# Farben der MFA-Ampel: Hintergrund, Rahmen, Punkt, Text
$script:MfaLevelColors = @{
    Red     = @('#FEE2E2', '#FCA5A5', '#DC2626', '#991B1B')
    Yellow  = @('#FEF3C7', '#FCD34D', '#D97706', '#92400E')
    Green   = @('#DCFCE7', '#86EFAC', '#16A34A', '#166534')
    Neutral = @('#F1F5F9', '#CBD5E1', '#94A3B8', '#242424')
}

function Set-MfaIndicator {
    param($Assessment)
    $level = if ($Assessment) { $Assessment.Level } else { 'Neutral' }
    $colors = $script:MfaLevelColors[$level]
    $script:BdgMfa.Background = $colors[0]
    $script:BdgMfa.BorderBrush = $colors[1]
    $script:DotMfa.Fill = $colors[2]
    $script:TxtMfaLevel.Foreground = $colors[3]
    $script:TxtMfaLevel.Text = if ($Assessment) { $Assessment.Title } else { '-' }

    $hints = @(if ($Assessment) { $Assessment.Hints })
    $script:TxtMfaHints.Text = ($hints | ForEach-Object { "• $_" }) -join [Environment]::NewLine
    $script:TxtMfaHints.Visibility = if ($hints.Count) { 'Visible' } else { 'Collapsed' }
}

function Set-AdminRoles {
    param([object[]]$Roles, [string]$Status)
    $Roles = @($Roles | Where-Object { $null -ne $_ })
    $script:LstRoles.ItemsSource = $Roles
    $script:LstRoles.Visibility = 'Collapsed'
    $script:BtnShowRoles.Content = 'Anzeigen'
    $script:BtnShowRoles.IsEnabled = $Roles.Count -gt 0
    $script:BtnShowRoles.Visibility = if ($Roles.Count) { 'Visible' } else { 'Collapsed' }

    if ($Status) {
        $script:TxtRoleSummary.Text = $Status
        $script:TxtRoleSummary.Foreground = $script:MfaLevelColors.Neutral[3]
        $script:TxtRoleSummary.FontWeight = 'Normal'
    }
    elseif (-not $Roles.Count) {
        $script:TxtRoleSummary.Text = 'Keine'
        $script:TxtRoleSummary.Foreground = $script:MfaLevelColors.Neutral[3]
        $script:TxtRoleSummary.FontWeight = 'Normal'
    }
    else {
        $names = @($Roles | Select-Object -ExpandProperty RoleName -Unique)
        $highlight = if ($names -contains 'Global Administrator') { ' (inkl. Global Administrator)' } else { '' }
        $script:TxtRoleSummary.Text = "$($names.Count) Rolle(n)$highlight"
        $script:TxtRoleSummary.Foreground = $script:MfaLevelColors.Yellow[3]
        $script:TxtRoleSummary.FontWeight = 'SemiBold'
    }
}

function Clear-MfaView {
    $script:SelectedMethod = $null
    $script:DgMethods.ItemsSource = $null
    $script:TxtMethodDetails.Text = ''
    $script:TxtMethodCount.Text = '-'
    $script:TxtPreferredMethod.Text = '-'
    $script:TxtSystemPreferred.Text = '-'
    Set-MfaIndicator $null
    Set-AdminRoles -Roles @() -Status '-'
}

function Clear-SelectedUser {
    Hide-Results
    $script:SelectedUser = $null
    $script:TxtSelectedName.Text = '-'
    $script:TxtSelectedUpn.Text = '-'
    $script:TxtSelectedId.Text = '-'
    $script:GrpMethods.Header = '2. Registrierte MFA-Methoden'
    $script:TxtNoUser.Visibility = 'Visible'
    Clear-MfaView
}

function Select-User {
    param([Parameter(Mandatory)]$User)
    Hide-Results
    $script:SelectedUser = $User
    $script:TxtSelectedName.Text = $User.DisplayName
    $script:TxtSelectedUpn.Text = $User.UserPrincipalName
    $script:TxtSelectedId.Text = $User.Id
    $script:GrpMethods.Header = "2. Registrierte MFA-Methoden - $($User.DisplayName) ($($User.UserPrincipalName))"
    $script:TxtNoUser.Visibility = 'Collapsed'
    Write-UiLog "Benutzer ausgewählt: $($User.UserPrincipalName)"
    Update-MfaView
}

function Set-ConnectionStatus {
    param($Context)
    if ($null -eq $Context) {
        $script:TxtConnectionStatus.Text = 'Nicht verbunden'
        $script:TxtConnectionStatus.Foreground = '#FCA5A5'
        $script:TxtTenant.Text = 'Tenant: -'
    }
    else {
        $script:TxtConnectionStatus.Text = "Verbunden als $($Context.Account)"
        $script:TxtConnectionStatus.Foreground = '#4ADE80'
        $script:TxtTenant.Text = "Tenant: $($Context.TenantId)"
    }
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

        $roles = @()
        try {
            $roles = @(Get-M365UserAdminRoles -UserId $user.Id)
            Set-AdminRoles -Roles $roles
        }
        catch {
            Set-AdminRoles -Roles @() -Status 'Nicht verfügbar'
            Write-UiLog "Administrative Rollen konnten nicht gelesen werden: $($_.Exception.Message)" 'Warning'
        }

        $assessment = Get-M365MfaAssessment -Methods $methods -HasAdminRoles ($roles.Count -gt 0)
        Set-MfaIndicator $assessment
        Write-UiLog "MFA-Status: $($assessment.Title)" $(if ($assessment.Level -eq 'Green') { 'Success' } else { 'Warning' })

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
        Set-ConnectionStatus $context
        Write-UiLog "Anmeldung erfolgreich: $($context.Account)" 'Success'
        $TxtSearch.Focus() | Out-Null
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
        $PopUsers.IsOpen = $false
        $DgUsers.ItemsSource = $null
        Clear-SelectedUser
        Set-ConnectionStatus $null
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
        Write-UiLog "$($users.Count) Benutzer gefunden." 'Success'
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title 'Suchfehler'
        return
    }
    finally {
        Set-Busy $false
    }

    # Ein Treffer wird direkt ausgewählt, mehrere werden im Popup unter dem Suchfeld angezeigt.
    switch ($users.Count) {
        0 { Show-Message -Text "Keine Benutzer zu '$term' gefunden." -Title 'Benutzersuche' }
        1 { $PopUsers.IsOpen = $false; Select-User -User $users[0] }
        default {
            $DgUsers.ItemsSource = $users
            $TxtUserHits.Text = "$($users.Count) Treffer - Benutzer auswählen" + $(if ($users.Count -ge 50) { ' (max. 50, ggf. Suche verfeinern)' } else { '' })
            $PopUsers.IsOpen = $true
        }
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
    if ($null -eq $user) { return }

    $PopUsers.IsOpen = $false
    # Auswahl im Popup zurücksetzen, damit derselbe Eintrag später erneut gewählt werden kann.
    $DgUsers.Dispatcher.BeginInvoke([action]{ $script:DgUsers.UnselectAll() }) | Out-Null

    if ($null -ne $script:SelectedUser -and $script:SelectedUser.Id -eq $user.Id) { return }
    Select-User -User $user
})

# Klick ins Suchfeld öffnet die letzten Treffer wieder.
$TxtSearch.Add_PreviewMouseLeftButtonUp({
    if (-not $PopUsers.IsOpen -and @($DgUsers.ItemsSource).Count -gt 1) { $PopUsers.IsOpen = $true }
})

# Popup selbst schließen: StaysOpen="False" greift nicht zuverlässig, wenn das Popup
# aus einem Button-Klick heraus geöffnet wird. Klicks im Popup selbst erreichen das Fenster nicht.
$window.Add_PreviewMouseDown({
    if ($PopUsers.IsOpen -and -not $TxtSearch.IsMouseOver -and -not $BtnSearch.IsMouseOver) { $PopUsers.IsOpen = $false }
})
$window.Add_PreviewKeyDown({
    param($src, $keyArgs)
    if ($keyArgs.Key -eq 'Escape' -and $PopUsers.IsOpen) { $PopUsers.IsOpen = $false; $keyArgs.Handled = $true }
})
$PopUsers.Add_KeyDown({
    param($src, $keyArgs)
    if ($keyArgs.Key -eq 'Escape') { $PopUsers.IsOpen = $false; $keyArgs.Handled = $true }
})
$window.Add_Deactivated({ $PopUsers.IsOpen = $false })
$window.Add_LocationChanged({ $PopUsers.IsOpen = $false })
$window.Add_SizeChanged({ $PopUsers.IsOpen = $false })

$BtnCopyUpn.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    Copy-ToClipboard -Text $script:SelectedUser.UserPrincipalName -LogMessage "UPN kopiert: $($script:SelectedUser.UserPrincipalName)"
})

$BtnShowRoles.Add_Click({
    $show = $LstRoles.Visibility -ne 'Visible'
    $LstRoles.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    $BtnShowRoles.Content = if ($show) { 'Ausblenden' } else { 'Anzeigen' }
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

#region Breakglass-Account

$script:BreakGlassScopes = @(
    'User.ReadWrite.All'                    # Benutzer anlegen und umbenennen
    'Domain.Read.All'                       # Domains zur Auswahl lesen
    'RoleManagement.ReadWrite.Directory'    # Global Administrator zuweisen
)

function Show-BreakGlassDialog {
    <#
    .SYNOPSIS
        Zeigt den Breakglass-Dialog. Gibt die Eingaben zurück oder $null bei Abbruch.
    #>
    param([Parameter(Mandatory)][string[]]$Domains)

    [xml]$dialogXaml = Get-Content -LiteralPath (Join-Path $script:AppRoot 'UI\BreakGlassDialog.xaml') -Raw -Encoding UTF8
    $dialog = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($dialogXaml))
    $dialog.Owner = $window

    $cmbDomain   = $dialog.FindName('CmbBgDomain')
    $txtUpnHint  = $dialog.FindName('TxtBgUpnHint')
    $chkAdmin    = $dialog.FindName('ChkBgGlobalAdmin')
    $chkFido2    = $dialog.FindName('ChkBgFido2')
    $pnlSerial   = $dialog.FindName('PnlBgSerial')
    $txtSerial   = $dialog.FindName('TxtBgSerial')
    $btnCreate   = $dialog.FindName('BtnBgCreate')

    $cmbDomain.ItemsSource = $Domains
    $cmbDomain.SelectedIndex = 0

    $updateHint = {
        $domain = [string]$cmbDomain.SelectedItem
        $txtUpnHint.Text = if ($domain) { "UPN: <Objekt-ID, gekürzt>@$domain (max. 64 Zeichen für FIDO2)" } else { '' }
    }.GetNewClosure()
    & $updateHint
    $cmbDomain.Add_SelectionChanged($updateHint)
    $chkFido2.Add_Click({ $pnlSerial.IsEnabled = [bool]$chkFido2.IsChecked }.GetNewClosure())

    $btnCreate.Add_Click({
        if ($chkFido2.IsChecked -and [string]::IsNullOrWhiteSpace($txtSerial.Text)) {
            [System.Windows.MessageBox]::Show('Bitte die Seriennummer / interne ID des FIDO2-Sticks eingeben.', 'Eingabe fehlt', 'OK', 'Information') | Out-Null
            $txtSerial.Focus() | Out-Null
            return
        }
        $dialog.DialogResult = $true
    }.GetNewClosure())

    if (-not $dialog.ShowDialog()) { return $null }

    [pscustomobject]@{
        Domain            = [string]$cmbDomain.SelectedItem
        AssignGlobalAdmin = [bool]$chkAdmin.IsChecked
        Fido2SerialNumber = if ($chkFido2.IsChecked) { $txtSerial.Text.Trim() } else { $null }
    }
}

$BtnBreakGlass.Add_Click({
    try {
        Set-Busy $true
        Write-UiLog 'Breakglass: Prüfe zusätzliche Berechtigungen (Benutzer anlegen, Domains lesen, Rollen zuweisen) ...'
        Set-ConnectionStatus (Request-M365GraphScopes -Scopes $script:BreakGlassScopes)
        $domains = @(Get-M365VerifiedDomains)
        if (-not $domains.Count) { throw 'Es wurden keine verifizierten Domains gefunden.' }
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title 'Breakglass-Account'
        return
    }
    finally {
        Set-Busy $false
    }

    $options = Show-BreakGlassDialog -Domains $domains
    if ($null -eq $options) { return }

    $question = "Neuen Breakglass-Account in '$($options.Domain)' erstellen?`n`n" +
        "Global Administrator: $(if ($options.AssignGlobalAdmin) { 'Ja' } else { 'Nein' })`n" +
        "FIDO2-Stick: $(if ($options.Fido2SerialNumber) { $options.Fido2SerialNumber } else { 'später einrichten (Fake-MFA bleibt aktiv)' })"
    if (-not (Confirm-Action -Text $question -Title 'Breakglass-Account erstellen')) { return }

    $result = $null
    try {
        Set-Busy $true
        Hide-Results
        $result = New-M365BreakGlassAccount -Domain $options.Domain -AssignGlobalAdmin:$options.AssignGlobalAdmin `
            -Fido2SerialNumber $options.Fido2SerialNumber `
            -OnProgress { param($Message) Write-UiLog "Breakglass: $Message" } `
            -Wait { param($Milliseconds) Wait-Ui $Milliseconds }
    }
    catch {
        Write-UiError -Message "Breakglass-Account konnte nicht erstellt werden: $($_.Exception.Message)" -Title 'Breakglass-Account'
    }
    finally {
        Set-Busy $false
    }
    if ($null -eq $result) { return }

    foreach ($warning in $result.Warnings) { Write-UiLog "Breakglass: $warning" 'Warning' }
    $summary = @(
        "Breakglass-Account erstellt: $($result.User.UserPrincipalName)"
        ''
        "Global Administrator: $(if ($result.GlobalAdminAssigned) { 'zugewiesen' } elseif ($options.AssignGlobalAdmin) { 'FEHLGESCHLAGEN' } else { 'nein' })"
        "FIDO2-Stick: $(if ($result.Fido2Registered) { 'registriert' } else { 'nicht registriert' })"
        "Fake-MFA: $(if ($result.FakeMfaActive) { 'aktiv' } else { 'nicht aktiv' })"
    )
    if ($result.Warnings.Count) { $summary += @('', 'Hinweise:') + @($result.Warnings | ForEach-Object { "- $_" }) }
    $summary += @('', 'Nicht vergessen: Account von Conditional-Access-Richtlinien ausnehmen und eine Anmeldebenachrichtigung einrichten.')

    Write-UiLog "Breakglass-Account erstellt: $($result.User.UserPrincipalName)" 'Success'
    Show-Message -Text ($summary -join "`n") -Title 'Breakglass-Account' -Icon $(if ($result.Warnings.Count) { 'Warning' } else { 'Information' })

    Select-User -User $result.User
})

#endregion

#region Start

$window.Add_Closing({
    if (Test-M365GraphConnection) { Disconnect-M365Graph }
})

Write-UiLog 'Anwendung gestartet. Bitte zuerst an Microsoft 365 anmelden.'
$window.ShowDialog() | Out-Null

#endregion
