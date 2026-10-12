#requires -Version 5.1
<#
.SYNOPSIS
    M365 MFA Administration Tool - view, set up and delete MFA methods on behalf of other users.

.DESCRIPTION
    WPF user interface for Windows PowerShell 5.1. Start by double-clicking Start.cmd or run:
    powershell.exe -ExecutionPolicy Bypass -File .\Start-M365MfaTool.ps1

    All visible texts come from Languages\<code>.json and are retrieved via T '<key>'.
    In the XAML files, the Uid attribute refers to an element's text key.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "This WPF tool requires Windows PowerShell 5.1: powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

#region Initialization

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot = Split-Path -Parent $PSCommandPath
# -Global so that all modules can use each other's functions (T, Invoke-M365GraphRequest, etc.).
Import-Module (Join-Path $script:AppRoot 'Modules\Localization.psm1') -Force -Global
Import-Module (Join-Path $script:AppRoot 'Modules\Graph.psm1') -Force -Global
Import-Module (Join-Path $script:AppRoot 'Modules\Provisioning.psm1') -Force

# User settings (currently only the language)
$script:SettingsPath = Join-Path $env:APPDATA 'M365MfaTool\settings.json'

# Daily log files (Logs\yyyy-MM-dd.log); fallback if the tool folder is not writable
$script:LogFolder = Join-Path $script:AppRoot 'Logs'
# Path::Combine instead of Join-Path: does not fail at startup if the drive does not exist
$script:FallbackLogFolder = [System.IO.Path]::Combine([string]$env:LOCALAPPDATA, 'M365MfaTool', 'Logs')
$script:LogFileDisabled = $false

function Read-Settings {
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            return (Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    }
    catch { }
    [pscustomobject]@{ Language = 'en' }
}

function Save-Settings {
    try {
        $folder = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        [pscustomobject]@{ Language = Get-UiLanguage } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { }
}

$settings = Read-Settings
Initialize-Localization -Path (Join-Path $script:AppRoot 'Languages') -Language $(if ($settings.PSObject.Properties['Language']) { $settings.Language } else { 'en' })

[xml]$xaml = Get-Content -LiteralPath (Join-Path $script:AppRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))

$controlNames = @(
    # Header and connection
    'TxtConnectionStatus', 'TxtTenant', 'BtnBreakGlass', 'CmbLanguage', 'BtnLogin', 'BtnLogout'
    # User search (results in popup)
    'TxtSearch', 'BtnSearch', 'PopUsers', 'TxtUserHits', 'DgUsers'
    # MFA methods
    'GrpMethods', 'TxtNoUser', 'DgMethods', 'TxtMethodDetails', 'BtnRefreshMethods', 'BtnDeleteMethod'
    # Selected user
    'TxtSelectedName', 'TxtSelectedUpn', 'TxtSelectedId', 'BtnCopyUpn', 'BtnCopyId'
    'TxtMethodCount', 'TxtPreferredMethod', 'TxtSystemPreferred'
    'BdgMfa', 'DotMfa', 'TxtMfaLevel', 'TxtMfaHints', 'TxtRoleSummary', 'BtnShowRoles', 'LstRoles'
    # Configure method
    'CmbMethod', 'PnlSerial', 'LblSerial', 'TxtSerial', 'PnlSecret', 'PwdSecret', 'TxtMethodHint', 'BtnExecute'
    # Result: Temporary Access Pass
    'PnlTap', 'TxtTapUser', 'TxtTapValue', 'TxtTapValidity', 'BtnCopyTap', 'BtnHideTap'
    # Result: programmable TOTP card
    'PnlTotp', 'TxtTotpUser', 'ImgTotpQr', 'TxtTotpSecret', 'TxtTotpInfo', 'BtnCopyTotpSecret', 'BtnSaveTotpQr', 'BtnHideTotp'
    # Log and status
    'TxtLog', 'ProgressBar'
)
foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

$script:Context = $null
$script:SelectedUser = $null
$script:SelectedMethod = $null
$script:TapResult = $null
$script:TotpSetup = $null
$script:ColumnKeys = @{}

# Input fields and hints per method (key = method ID from the Tag in the dropdown)
$script:MethodUi = @{
    Fido2            = @{ Serial = 'Config.Serial.Fido2'; Secret = $false; Hint = 'Config.Hint.Fido2' }
    FixedTotp        = @{ Serial = 'Config.Serial.Card';  Secret = $true;  Hint = 'Config.Hint.FixedTotp' }
    ProgrammableTotp = @{ Serial = 'Config.Serial.Card';  Secret = $false; Hint = 'Config.Hint.ProgrammableTotp' }
    Tap              = @{ Serial = $null;                 Secret = $false; Hint = 'Config.Hint.Tap' }
    FakeMfa          = @{ Serial = $null;                 Secret = $false; Hint = 'Config.Hint.FakeMfa' }
}

#endregion

#region UI translation

function Get-LogicalDescendants {
    param($Element)
    $Element
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Element)) {
        if ($child -is [System.Windows.DependencyObject]) { Get-LogicalDescendants $child }
    }
}

function Update-ElementTexts {
    <#
    .SYNOPSIS
        Sets the texts of all elements with a Uid (Text/Content/Header/Title) and their tooltips (<Uid>.ToolTip).
    #>
    param([Parameter(Mandatory)]$Root)
    foreach ($element in Get-LogicalDescendants $Root) {
        if ($element -isnot [System.Windows.UIElement] -or [string]::IsNullOrEmpty($element.Uid)) { continue }
        $key = $element.Uid
        if (Test-UiText $key) {
            $text = T $key
            if ($element -is [System.Windows.Window]) { $element.Title = $text }
            elseif ($element -is [System.Windows.Controls.TextBlock]) { $element.Text = $text }
            elseif ($element -is [System.Windows.Controls.HeaderedContentControl]) { $element.Header = $text }
            elseif ($element -is [System.Windows.Controls.ContentControl]) { $element.Content = $text }
        }
        if (Test-UiText "$key.ToolTip") { $element.ToolTip = T "$key.ToolTip" }
    }
}

function Update-UiTexts {
    Update-ElementTexts -Root $window

    # Column headers: the XAML contains the text key, which is remembered on the first call.
    foreach ($grid in $script:DgUsers, $script:DgMethods) {
        foreach ($column in $grid.Columns) {
            if (-not $script:ColumnKeys.ContainsKey($column)) { $script:ColumnKeys[$column] = [string]$column.Header }
            $column.Header = T $script:ColumnKeys[$column]
        }
    }
    # Date format of the "Created" column per language
    $createdColumn = $script:DgMethods.Columns | Where-Object { $script:ColumnKeys[$_] -eq 'Methods.Col.Created' }
    $binding = New-Object System.Windows.Data.Binding 'Created'
    $binding.StringFormat = T 'Format.DateTime'
    $createdColumn.Binding = $binding
}

function Update-DynamicTexts {
    # Re-apply state-dependent texts in the new language.
    Set-ConnectionStatus $script:Context
    Update-MethodInputs
    Update-MethodsHeader
    Update-RolesToggle
    if ($null -ne $script:TapResult) { Show-TapResult -Tap $script:TapResult }
    if ($null -ne $script:TotpSetup) { Show-TotpResult -Setup $script:TotpSetup }
    if (@($script:DgUsers.ItemsSource).Count -gt 1) { Set-UserHitsText @($script:DgUsers.ItemsSource).Count }
}

#endregion

#region UI helpers

function Write-LogFile {
    <#
    .SYNOPSIS
        Appends a line to the daily log file (Logs\yyyy-MM-dd.log) immediately.
    .DESCRIPTION
        Each line is written and flushed right away, so the log survives crashes. The file is opened
        with shared read/write access, so it can be viewed in an editor while the tool is running.
        If the tool folder is not writable, %LOCALAPPDATA%\M365MfaTool\Logs is used instead.
    #>
    param([Parameter(Mandatory)][string]$Line)
    if ($script:LogFileDisabled) { return }

    foreach ($attempt in 1, 2) {
        try {
            if (-not (Test-Path -LiteralPath $script:LogFolder)) { New-Item -ItemType Directory -Path $script:LogFolder -Force | Out-Null }
            $file = Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f (Get-Date))
            $stream = [System.IO.File]::Open($file, 'Append', 'Write', 'ReadWrite')
            try {
                $writer = New-Object System.IO.StreamWriter ($stream, [System.Text.UTF8Encoding]::new($false))
                $writer.WriteLine($Line)
                $writer.Flush()
            }
            finally {
                $stream.Dispose()
            }
            return
        }
        catch {
            if ($attempt -eq 1 -and $script:LogFolder -ne $script:FallbackLogFolder) {
                $script:LogFolder = $script:FallbackLogFolder
                continue
            }
            # Logging to file is not possible at all: keep the GUI log working, report it once.
            $script:LogFileDisabled = $true
            $script:TxtLog.AppendText(('{0} [WARNING] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (T 'Log.FileFailed' $_.Exception.Message)) + [Environment]::NewLine)
            return
        }
    }
}

function Write-UiLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    $script:TxtLog.AppendText($line + [Environment]::NewLine)
    $script:TxtLog.ScrollToEnd()
    Write-LogFile -Line $line
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
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('Warning', 'Question')][string]$Icon = 'Warning',
        [switch]$DefaultYes
    )
    $default = if ($DefaultYes) { 'Yes' } else { 'No' }
    [System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', $Icon, $default) -eq 'Yes'
}

function Install-MissingModules {
    <#
    .SYNOPSIS
        Asks once in the GUI and installs all missing modules without console prompts.
        Returns $false if the user declined.
    #>
    $missing = @(Get-MissingModules)
    if (-not $missing.Count) { return $true }

    $list = ($missing | ForEach-Object { '• ' + $_.Name + $(if ($_.RequiredVersion) { " $($_.RequiredVersion)" } else { '' }) }) -join "`n"
    if (-not (Confirm-Action -Text (T 'Modules.ConfirmInstall' $list) -Title (T 'Title.Prerequisites') -Icon Question -DefaultYes)) {
        Write-UiLog (T 'Modules.Declined') 'Warning'
        return $false
    }

    $script:TxtConnectionStatus.Text = T 'Header.Installing'
    $script:TxtConnectionStatus.Foreground = '#FCD34D'
    $index = 0
    foreach ($module in $missing) {
        $index++
        Write-UiLog (T 'Modules.InstallingProgress' $index $missing.Count $module.Name)
        Install-RequiredModule -Name $module.Name -RequiredVersion $module.RequiredVersion -SkipPublisherCheck:$module.SkipPublisherCheck `
            -Wait { param($Milliseconds) Wait-Ui $Milliseconds }
        Write-UiLog (T 'Modules.Installed' $module.Name) 'Success'
    }
    $true
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
    $script:CmbLanguage.IsEnabled        = -not $Busy
    $script:BtnSearch.IsEnabled          = -not $Busy -and $connected
    $script:BtnExecute.IsEnabled         = -not $Busy -and $hasUser
    $script:BtnRefreshMethods.IsEnabled  = -not $Busy -and $connected -and $hasUser
    $script:BtnDeleteMethod.IsEnabled    = -not $Busy -and $connected -and $canDelete
    $script:BtnCopyUpn.IsEnabled         = $hasUser
    $script:BtnCopyId.IsEnabled          = $hasUser
    [System.Windows.Forms.Application]::DoEvents()
}

function Wait-Ui {
    # Waits without freezing the UI.
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

function Format-UiDate {
    param($Date)
    if ($null -eq $Date) { return '-' }
    $Date.ToString((T 'Format.DateTime'))
}

function Get-SelectedMethodId {
    if ($script:CmbMethod.SelectedItem) { [string]$script:CmbMethod.SelectedItem.Tag } else { $null }
}

function Update-MethodInputs {
    $methodId = Get-SelectedMethodId
    $ui = if ($methodId) { $script:MethodUi[$methodId] } else { $null }

    $script:PnlSerial.Visibility = if ($ui -and $ui.Serial) { 'Visible' } else { 'Collapsed' }
    $script:PnlSecret.Visibility = if ($ui -and $ui.Secret) { 'Visible' } else { 'Collapsed' }
    $script:TxtMethodHint.Text = if ($ui) { T $ui.Hint } else { '' }
    if ($ui -and $ui.Serial) { $script:LblSerial.Text = T $ui.Serial }
}

function Set-UserHitsText {
    param([int]$Count)
    $script:TxtUserHits.Text = (T 'Search.Hits' $Count) + $(if ($Count -ge 50) { ' ' + (T 'Search.HitsLimit') } else { '' })
}

#endregion

#region Result cards (TAP / TOTP card)

function Show-TapResult {
    param([Parameter(Mandatory)]$Tap)
    $script:TapResult = $Tap
    $usage = if ($Tap.IsUsableOnce) { T 'Tap.UsableOnce' } else { T 'Tap.UsableMultiple' }
    $script:TxtTapUser.Text = T 'Common.ForUser' $Tap.UserPrincipalName
    $script:TxtTapValue.Text = $Tap.Pass
    $script:TxtTapValidity.Text = T 'Tap.Validity' (Format-UiDate $Tap.ValidFrom) (Format-UiDate $Tap.ValidUntil) $Tap.LifetimeInMinutes $usage
    $script:PnlTap.Visibility = 'Visible'
}

function Hide-TapResult {
    $script:TapResult = $null
    $script:TxtTapValue.Text = ''
    $script:TxtTapUser.Text = '-'
    $script:TxtTapValidity.Text = '-'
    $script:PnlTap.Visibility = 'Collapsed'
}

function Show-TotpResult {
    param([Parameter(Mandatory)]$Setup)
    $script:TotpSetup = $Setup
    $script:TxtTotpUser.Text = T 'Common.ForUser' $Setup.UserPrincipalName
    $script:TxtTotpSecret.Text = $Setup.Secret
    $script:TxtTotpInfo.Text = T 'Totp.Info' $Setup.SerialNumber
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

#region User and MFA view

# MFA traffic light colors: background, border, dot, text
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

function Update-RolesToggle {
    $script:BtnShowRoles.Content = if ($script:LstRoles.Visibility -eq 'Visible') { T 'User.HideRoles' } else { T 'User.ShowRoles' }
}

function Set-AdminRoles {
    param([object[]]$Roles, [string]$Status)
    $Roles = @($Roles | Where-Object { $null -ne $_ })
    $script:LstRoles.ItemsSource = $Roles
    $script:LstRoles.Visibility = 'Collapsed'
    Update-RolesToggle
    $script:BtnShowRoles.IsEnabled = $Roles.Count -gt 0
    $script:BtnShowRoles.Visibility = if ($Roles.Count) { 'Visible' } else { 'Collapsed' }

    if ($Status) {
        $script:TxtRoleSummary.Text = $Status
        $script:TxtRoleSummary.Foreground = $script:MfaLevelColors.Neutral[3]
        $script:TxtRoleSummary.FontWeight = 'Normal'
    }
    elseif (-not $Roles.Count) {
        $script:TxtRoleSummary.Text = T 'User.NoRoles'
        $script:TxtRoleSummary.Foreground = $script:MfaLevelColors.Neutral[3]
        $script:TxtRoleSummary.FontWeight = 'Normal'
    }
    else {
        $names = @($Roles | Select-Object -ExpandProperty RoleName -Unique)
        $script:TxtRoleSummary.Text = if ($names -contains 'Global Administrator') { T 'User.RoleCountWithGa' $names.Count } else { T 'User.RoleCount' $names.Count }
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

function Update-MethodsHeader {
    $user = $script:SelectedUser
    $script:GrpMethods.Header = if ($user) { T 'Methods.GroupForUser' $user.DisplayName $user.UserPrincipalName } else { T 'Methods.Group' }
}

function Clear-SelectedUser {
    Hide-Results
    $script:SelectedUser = $null
    $script:TxtSelectedName.Text = '-'
    $script:TxtSelectedUpn.Text = '-'
    $script:TxtSelectedId.Text = '-'
    Update-MethodsHeader
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
    Update-MethodsHeader
    $script:TxtNoUser.Visibility = 'Collapsed'
    Write-UiLog (T 'Log.UserSelected' $User.UserPrincipalName)
    Update-MfaView
}

function Set-ConnectionStatus {
    param($Context)
    $script:Context = $Context
    if ($null -eq $Context) {
        $script:TxtConnectionStatus.Text = T 'Header.NotConnected'
        $script:TxtConnectionStatus.Foreground = '#FCA5A5'
        $script:TxtTenant.Text = T 'Header.Tenant' '-'
    }
    else {
        $script:TxtConnectionStatus.Text = T 'Header.ConnectedAs' $Context.Account
        $script:TxtConnectionStatus.Foreground = '#4ADE80'
        $script:TxtTenant.Text = T 'Header.Tenant' $Context.TenantId
    }
}

function Update-MfaView {
    <#
    .SYNOPSIS
        Reloads the MFA methods of the selected user.
    .DESCRIPTION
        Graph replicates changes with a delay. If IDs are passed, waits until deleted
        methods have disappeared and new methods are visible (max. approx. 16 seconds).
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
        Write-UiLog (T 'Log.LoadingMethods' $user.UserPrincipalName)
        $methods = @(Get-M365UserAuthMethods -UserId $user.Id | Sort-Object TypeName, Created)

        for ($attempt = 1; $attempt -le 8 -and (& $isPending $methods); $attempt++) {
            if ($attempt -eq 1) { Write-UiLog (T 'Log.WaitingReplication') }
            Wait-Ui 2000
            $methods = @(Get-M365UserAuthMethods -UserId $user.Id | Sort-Object TypeName, Created)
        }
        if (& $isPending $methods) {
            Write-UiLog (T 'Log.ReplicationPending') 'Warning'
            $methods = @($methods | Where-Object { $RemovedMethodIds -notcontains $_.Id })
        }

        $script:DgMethods.ItemsSource = $methods
        $script:TxtMethodCount.Text = "$($methods.Count)"
        Write-UiLog (T 'Log.MethodsFound' $methods.Count $user.UserPrincipalName) 'Success'

        $roles = @()
        try {
            $roles = @(Get-M365UserAdminRoles -UserId $user.Id)
            Set-AdminRoles -Roles $roles
        }
        catch {
            Set-AdminRoles -Roles @() -Status (T 'Common.NotAvailable')
            Write-UiLog (T 'Log.RolesFailed' $_.Exception.Message) 'Warning'
        }

        $assessment = Get-M365MfaAssessment -Methods $methods -HasAdminRoles ($roles.Count -gt 0)
        Set-MfaIndicator $assessment
        Write-UiLog (T 'Log.MfaStatus' $assessment.Title) $(if ($assessment.Level -eq 'Green') { 'Success' } else { 'Warning' })

        try {
            $prefs = Get-M365UserSignInPreferences -UserId $user.Id
            $script:TxtPreferredMethod.Text = $prefs.PreferredMethod
            $script:TxtSystemPreferred.Text = $prefs.SystemPreferredActive
        }
        catch {
            $script:TxtPreferredMethod.Text = T 'Common.NotAvailable'
            $script:TxtSystemPreferred.Text = T 'Common.NotAvailable'
            Write-UiLog (T 'Log.PreferencesFailed' $_.Exception.Message) 'Warning'
        }
    }
    catch {
        Write-UiError -Message (T 'Log.MethodsFailed' $_.Exception.Message) -Title (T 'Title.LoadError')
    }
    finally {
        Set-Busy $false
    }
}

#endregion

#region Events: language, connection and search

$CmbLanguage.Add_SelectionChanged({
    $selected = $CmbLanguage.SelectedItem
    if ($null -eq $selected -or $selected.Code -eq (Get-UiLanguage)) { return }
    $code = $selected.Code
    Set-UiLanguage -Language $code
    Save-Settings
    Update-UiTexts
    Update-DynamicTexts
    # Method names and traffic light texts come from the modules, so reload them.
    if ($null -ne $script:SelectedUser) { Update-MfaView }
})

$BtnLogin.Add_Click({
    try {
        Set-Busy $true
        # Install missing modules first, visibly in the GUI (instead of console prompts in the background)
        if (-not (Install-MissingModules)) { return }
        Write-UiLog (T 'Log.SigningIn')
        $context = Connect-M365Graph
        Set-ConnectionStatus $context
        Write-UiLog (T 'Log.SignedIn' $context.Account) 'Success'
        $TxtSearch.Focus() | Out-Null
    }
    catch {
        Set-ConnectionStatus $script:Context
        Write-UiError -Message $_.Exception.Message -Title (T 'Title.SignInError')
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
        Write-UiLog (T 'Log.SignedOut') 'Success'
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
        Show-Message -Text (T 'Search.Empty') -Title (T 'Title.Search')
        return
    }
    try {
        Set-Busy $true
        Write-UiLog (T 'Log.Searching' $term)
        $users = @(Find-M365User -SearchTerm $term)
        Write-UiLog (T 'Log.UsersFound' $users.Count) 'Success'
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title (T 'Title.SearchError')
        return
    }
    finally {
        Set-Busy $false
    }

    # A single result is selected directly; multiple results are shown in the popup below the search box.
    switch ($users.Count) {
        0 { Show-Message -Text (T 'Search.NoResults' $term) -Title (T 'Title.Search') }
        1 { $PopUsers.IsOpen = $false; Select-User -User $users[0] }
        default {
            $DgUsers.ItemsSource = $users
            Set-UserHitsText $users.Count
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
    # Reset the popup selection so the same entry can be selected again later.
    $DgUsers.Dispatcher.BeginInvoke([action]{ $script:DgUsers.UnselectAll() }) | Out-Null

    if ($null -ne $script:SelectedUser -and $script:SelectedUser.Id -eq $user.Id) { return }
    Select-User -User $user
})

# Clicking into the search box reopens the last results.
$TxtSearch.Add_PreviewMouseLeftButtonUp({
    if (-not $PopUsers.IsOpen -and @($DgUsers.ItemsSource).Count -gt 1) { $PopUsers.IsOpen = $true }
})

# Close the popup ourselves: StaysOpen="False" is unreliable when the popup is opened
# from a button click. Clicks inside the popup itself do not reach the window.
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
    Copy-ToClipboard -Text $script:SelectedUser.UserPrincipalName -LogMessage (T 'Log.UpnCopied' $script:SelectedUser.UserPrincipalName)
})

$BtnShowRoles.Add_Click({
    $LstRoles.Visibility = if ($LstRoles.Visibility -ne 'Visible') { 'Visible' } else { 'Collapsed' }
    Update-RolesToggle
})

$BtnCopyId.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    Copy-ToClipboard -Text $script:SelectedUser.Id -LogMessage (T 'Log.IdCopied' $script:SelectedUser.Id)
})

#endregion

#region Events: view and delete MFA methods

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

    $question = T 'Delete.Confirm' $user.UserPrincipalName $method.TypeName $method.DisplayName (Format-UiDate $method.Created) $method.Id
    if (-not (Confirm-Action -Text $question -Title (T 'Title.ConfirmDelete'))) { return }

    $deleted = $false
    try {
        Set-Busy $true
        Write-UiLog (T 'Log.Deleting' $method.TypeName $method.DisplayName $method.Id $user.UserPrincipalName) 'Warning'
        Remove-M365UserAuthMethod -UserId $user.Id -Method $method -Confirm:$false
        $deleted = $true
        Write-UiLog (T 'Log.Deleted' $method.TypeName $method.DisplayName) 'Success'
    }
    catch {
        Write-UiError -Message (T 'Log.DeleteFailed' $_.Exception.Message) -Title (T 'Title.DeleteFailed')
    }
    finally {
        Set-Busy $false
    }

    if ($deleted) { Update-MfaView -RemovedMethodIds $method.Id } else { Update-MfaView }
})

#endregion

#region Events: configure method

$CmbMethod.Add_SelectionChanged({ Update-MethodInputs })

$BtnExecute.Add_Click({
    if ($null -eq $script:SelectedUser) { return }
    $methodId = Get-SelectedMethodId
    if (-not $methodId) {
        Show-Message -Text (T 'Config.SelectMethod') -Title (T 'Title.Method')
        return
    }

    $user = $script:SelectedUser
    $methodName = [string]$CmbMethod.SelectedItem.Content
    $ui = $script:MethodUi[$methodId]

    # Validate input before asking for confirmation
    $options = @{}
    if ($ui.Serial) {
        if ([string]::IsNullOrWhiteSpace($TxtSerial.Text)) {
            Show-Message -Text (T 'Prov.MissingInput' (T $ui.Serial)) -Title (T 'Title.MissingInput')
            $TxtSerial.Focus() | Out-Null
            return
        }
        $options.SerialNumber = $TxtSerial.Text.Trim()
    }
    if ($ui.Secret) {
        if ([string]::IsNullOrWhiteSpace($PwdSecret.Password)) {
            Show-Message -Text (T 'Prov.MissingInput' (T 'Config.Secret')) -Title (T 'Title.MissingInput')
            $PwdSecret.Focus() | Out-Null
            return
        }
        $options.Secret = $PwdSecret.Password
    }

    $question = T 'Config.Confirm' $methodName $user.UserPrincipalName
    if ($options.ContainsKey('SerialNumber')) { $question += "`n" + (T 'Config.ConfirmSerial' $options.SerialNumber) }
    if ($methodId -eq 'Tap') {
        $existingTap = @($DgMethods.ItemsSource | Where-Object { $null -ne $_ -and $_.Type -eq '#microsoft.graph.temporaryAccessPassAuthenticationMethod' })
        if ($existingTap.Count) { $question += "`n`n" + (T 'Config.ConfirmReplaceTap') }
    }
    if (-not (Confirm-Action -Text $question -Title (T 'Title.ConfirmConfig'))) { return }

    $result = $null
    try {
        Set-Busy $true
        Hide-Results
        Write-UiLog (T 'Log.Provisioning' $methodName $user.UserPrincipalName) 'Warning'
        if ($methodId -eq 'Fido2') { Write-UiLog (T 'Fido2.Prompt') }

        $result = Invoke-MfaProvisioning -Method $methodId -User $user -Options $options

        # The TAP and TOTP secret are intentionally not logged, only displayed.
        Write-UiLog $result.Message 'Success'
        if ($null -ne $result.TemporaryAccessPass) { Show-TapResult -Tap $result.TemporaryAccessPass }
        if ($null -ne $result.TotpSetup) { Show-TotpResult -Setup $result.TotpSetup }
        $TxtSerial.Clear()
        $PwdSecret.Clear()
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title (T 'Title.ProvisioningError')
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

#region Events: result cards

$BtnCopyTap.Add_Click({
    Copy-ToClipboard -Text $TxtTapValue.Text -LogMessage (T 'Log.TapCopied')
})

$BtnHideTap.Add_Click({ Hide-TapResult })

$BtnCopyTotpSecret.Add_Click({
    Copy-ToClipboard -Text $TxtTotpSecret.Text -LogMessage (T 'Log.SecretCopied')
})

$BtnSaveTotpQr.Add_Click({
    $setup = $script:TotpSetup
    if ($null -eq $setup -or -not $setup.QrCodePng) { return }

    $fileName = 'totp-{0}-{1}.png' -f $setup.UserPrincipalName, $setup.SerialNumber
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) { $fileName = $fileName.Replace([string]$char, '_') }

    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = T 'Totp.SaveQr'
    $dialog.Filter = (T 'Totp.PngFilter') + ' (*.png)|*.png'
    $dialog.FileName = $fileName
    if ($dialog.ShowDialog($window)) {
        [System.IO.File]::WriteAllBytes($dialog.FileName, [byte[]]$setup.QrCodePng)
        Write-UiLog (T 'Log.QrSaved' $dialog.FileName) 'Warning'
    }
})

$BtnHideTotp.Add_Click({ Hide-TotpResult })

#endregion

#region Break-glass account

$script:BreakGlassScopes = @(
    'User.ReadWrite.All'                    # Create and rename users
    'Domain.Read.All'                       # Read domains for selection
    'RoleManagement.ReadWrite.Directory'    # Assign Global Administrator
)

function Show-BreakGlassDialog {
    <#
    .SYNOPSIS
        Shows the break-glass dialog. Returns the input or $null if cancelled.
    #>
    param([Parameter(Mandatory)][string[]]$Domains)

    [xml]$dialogXaml = Get-Content -LiteralPath (Join-Path $script:AppRoot 'UI\BreakGlassDialog.xaml') -Raw -Encoding UTF8
    $dialog = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($dialogXaml))
    $dialog.Owner = $window
    Update-ElementTexts -Root $dialog

    $cmbDomain   = $dialog.FindName('CmbBgDomain')
    $txtUpnHint  = $dialog.FindName('TxtBgUpnHint')
    $chkAdmin    = $dialog.FindName('ChkBgGlobalAdmin')
    $chkFido2    = $dialog.FindName('ChkBgFido2')
    $pnlSerial   = $dialog.FindName('PnlBgSerial')
    $txtSerial   = $dialog.FindName('TxtBgSerial')
    $btnCreate   = $dialog.FindName('BtnBgCreate')

    $cmbDomain.ItemsSource = $Domains
    $cmbDomain.SelectedIndex = 0

    $upnHintTemplate = T 'BreakGlass.UpnHint'
    $updateHint = {
        $domain = [string]$cmbDomain.SelectedItem
        $txtUpnHint.Text = if ($domain) { $upnHintTemplate -f $domain } else { '' }
    }.GetNewClosure()
    & $updateHint
    $cmbDomain.Add_SelectionChanged($updateHint)
    $chkFido2.Add_Click({ $pnlSerial.IsEnabled = [bool]$chkFido2.IsChecked }.GetNewClosure())

    $missingSerialText = T 'Prov.MissingInput' (T 'Config.Serial.Fido2')
    $missingTitle = T 'Title.MissingInput'
    $btnCreate.Add_Click({
        if ($chkFido2.IsChecked -and [string]::IsNullOrWhiteSpace($txtSerial.Text)) {
            [System.Windows.MessageBox]::Show($missingSerialText, $missingTitle, 'OK', 'Information') | Out-Null
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
        Write-UiLog (T 'Log.BreakGlassScopes')
        Set-ConnectionStatus (Request-M365GraphScopes -Scopes $script:BreakGlassScopes)
        $domains = @(Get-M365VerifiedDomains)
        if (-not $domains.Count) { throw (T 'BG.NoDomains') }
    }
    catch {
        Write-UiError -Message $_.Exception.Message -Title (T 'BreakGlass.Title')
        return
    }
    finally {
        Set-Busy $false
    }

    $options = Show-BreakGlassDialog -Domains $domains
    if ($null -eq $options) { return }

    $fidoText = if ($options.Fido2SerialNumber) { $options.Fido2SerialNumber } else { T 'BG.Fido2Later' }
    $question = T 'BG.Confirm' $options.Domain $(if ($options.AssignGlobalAdmin) { T 'Common.Yes' } else { T 'Common.No' }) $fidoText
    if (-not (Confirm-Action -Text $question -Title (T 'BreakGlass.Title'))) { return }

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
        Write-UiError -Message (T 'BG.Failed' $_.Exception.Message) -Title (T 'BreakGlass.Title')
    }
    finally {
        Set-Busy $false
    }
    if ($null -eq $result) { return }

    foreach ($warning in $result.Warnings) { Write-UiLog "Breakglass: $warning" 'Warning' }
    $gaStatus = if ($result.GlobalAdminAssigned) { T 'BG.Status.Assigned' } elseif ($options.AssignGlobalAdmin) { T 'BG.Status.Failed' } else { T 'Common.No' }
    $summary = @(
        T 'BG.Summary.Created' $result.User.UserPrincipalName
        ''
        T 'BG.Summary.GlobalAdmin' $gaStatus
        T 'BG.Summary.Fido2' $(if ($result.Fido2Registered) { T 'BG.Status.Registered' } else { T 'BG.Status.NotRegistered' })
        T 'BG.Summary.FakeMfa' $(if ($result.FakeMfaActive) { T 'BG.Status.Active' } else { T 'BG.Status.Inactive' })
    )
    if ($result.Warnings.Count) { $summary += @('', (T 'BG.Summary.Notes')) + @($result.Warnings | ForEach-Object { "- $_" }) }
    $summary += @('', (T 'BG.Summary.Reminder'))

    Write-UiLog (T 'BG.Summary.Created' $result.User.UserPrincipalName) 'Success'
    Show-Message -Text ($summary -join "`n") -Title (T 'BreakGlass.Title') -Icon $(if ($result.Warnings.Count) { 'Warning' } else { 'Information' })

    Select-User -User $result.User
})

#endregion

#region Start

$window.Add_Closing({
    if (Test-M365GraphConnection) { Disconnect-M365Graph }
})

# Fill the language selection and set all texts
$languages = @(Get-UiLanguages)
$CmbLanguage.ItemsSource = $languages
$CmbLanguage.SelectedItem = $languages | Where-Object Code -eq (Get-UiLanguage) | Select-Object -First 1
Update-UiTexts
Set-ConnectionStatus $null
Clear-SelectedUser
Update-MethodInputs
Set-Busy $false

# Separator in the log file so that several sessions per day can be told apart
Write-LogFile -Line ('{0} ===== M365 MFA Administration Tool started by {1}\{2} on {3} =====' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
Write-UiLog (T 'Log.Started')
if (-not $script:LogFileDisabled) { Write-UiLog (T 'Log.FileLocation' $script:LogFolder) }
$window.ShowDialog() | Out-Null

#endregion
