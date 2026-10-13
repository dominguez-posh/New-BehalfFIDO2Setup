<#
.SYNOPSIS
    Tenant-wide MFA status report of the M365 MFA Administration Tool.

.DESCRIPTION
    Loads all users (or the members of a group incl. nested groups), their administrative roles
    and authentication methods, rates every user as a traffic light and exports the result as a
    colored Excel workbook (.xlsx, written directly - neither Excel nor an extra module required).
    Authentication methods are read via Graph JSON batching (20 users per request).
#>

Set-StrictMode -Version Latest

$script:ReportScopes = @(
    'GroupMember.Read.All'   # Group selection and administrative roles assigned via groups
)

$script:BatchSize = 20
$script:UserSelect = 'id,displayName,userPrincipalName,mail,accountEnabled,userType,jobTitle,department,assignedLicenses'
$script:LevelOrder = @{ Red = 0; Yellow = 1; Green = 2; Unknown = 3 }

#region Graph data

function Get-GraphPages {
    # Returns all items of a paged Graph collection.
    param([Parameter(Mandatory)][string]$Uri, [hashtable]$Headers = @{})
    while ($Uri) {
        $response = Invoke-M365GraphRequest -Uri $Uri -Headers $Headers
        foreach ($item in @($response['value'])) { if ($null -ne $item) { $item } }
        $Uri = $response['@odata.nextLink']
    }
}

function Get-M365ReportScopes {
    $script:ReportScopes
}

function Get-M365OrganizationName {
    # Display name of the tenant; $null if it cannot be read.
    try {
        $organization = @((Invoke-M365GraphRequest -Uri 'v1.0/organization?$select=displayName')['value']) | Select-Object -First 1
        if ($organization) { return [string]$organization['displayName'] }
    }
    catch { }
    $null
}

function Find-M365Group {
    <#
    .SYNOPSIS
        Finds groups by object ID or display name prefix.
    #>
    param(
        [Parameter(Mandatory)][string]$SearchTerm,
        [int]$Top = 50
    )

    $term = $SearchTerm.Trim()
    $select = 'id,displayName,description'
    if ($term -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $groups = @(Invoke-M365GraphRequest -Uri "v1.0/groups/$term`?`$select=$select")
    }
    else {
        $filter = [uri]::EscapeDataString("startswith(displayName,'$($term.Replace("'", "''"))')")
        $groups = @((Invoke-M365GraphRequest -Uri "v1.0/groups?`$filter=$filter&`$select=$select&`$top=$Top")['value'])
    }

    $groups |
        Where-Object { $null -ne $_ } |
        ForEach-Object {
            [pscustomobject]@{
                Id          = [string]$_['id']
                DisplayName = [string]$_['displayName']
                Description = [string]$_['description']
            }
        } |
        Sort-Object DisplayName
}

function Get-M365ReportUsers {
    <#
    .SYNOPSIS
        Returns all users of the tenant or the (transitive) user members of a group.
    #>
    param([string]$GroupId)

    if ($GroupId) {
        $uri = "v1.0/groups/$([uri]::EscapeDataString($GroupId))/transitiveMembers/microsoft.graph.user?`$select=$script:UserSelect&`$top=999&`$count=true"
        $headers = @{ ConsistencyLevel = 'eventual' }
    }
    else {
        $uri = "v1.0/users?`$select=$script:UserSelect&`$top=999"
        $headers = @{}
    }

    Get-GraphPages -Uri $uri -Headers $headers | ForEach-Object {
        [pscustomobject]@{
            Id                = [string]$_['id']
            DisplayName       = [string]$_['displayName']
            UserPrincipalName = [string]$_['userPrincipalName']
            Mail              = [string]$_['mail']
            AccountEnabled    = [bool]$_['accountEnabled']
            UserType          = [string]$_['userType']
            JobTitle          = [string]$_['jobTitle']
            Department        = [string]$_['department']
            IsLicensed        = @($_['assignedLicenses'] | Where-Object { $null -ne $_ }).Count -gt 0
        }
    }
}

function Get-M365TenantAdminRoles {
    <#
    .SYNOPSIS
        Returns a table user ID -> role names for all active and PIM-eligible directory roles.
    .DESCRIPTION
        Roles assigned to (role-assignable) groups are resolved to the group's user members.
        PIM-eligible roles are marked with "(PIM)", roles scoped to an administrative unit with "[AU]".
    #>
    param([scriptblock]$OnWarning = { param($Message) })

    $names = Get-M365RoleDefinitionNames
    $roles = @{}
    $groupMembers = @{}

    $sources = @(
        @{ Uri = 'v1.0/roleManagement/directory/roleAssignments'; Suffix = ''; Optional = $false }
        # Requires Entra ID P2; simply skipped without a license
        @{ Uri = 'v1.0/roleManagement/directory/roleEligibilityScheduleInstances'; Suffix = ' (PIM)'; Optional = $true }
    )

    foreach ($source in $sources) {
        try {
            $items = @(Get-GraphPages -Uri "$($source.Uri)?`$expand=principal")
        }
        catch {
            # Without $expand the principal type is unknown: principals are then treated as users.
            try { $items = @(Get-GraphPages -Uri $source.Uri) }
            catch {
                if ($source.Optional) { continue }
                throw
            }
        }

        foreach ($item in $items) {
            $roleId = [string]$item['roleDefinitionId']
            $label = if ($names.ContainsKey($roleId)) { $names[$roleId] } else { $roleId }
            if ([string]$item['directoryScopeId'] -like '/administrativeUnits/*') { $label += ' [AU]' }
            $label += $source.Suffix

            $principalId = [string]$item['principalId']
            $principal = $item['principal']
            $principalType = if ($principal -is [System.Collections.IDictionary]) { [string]$principal['@odata.type'] } else { '' }

            $userIds = switch ($principalType) {
                '#microsoft.graph.servicePrincipal' { @() }
                '#microsoft.graph.group' {
                    if (-not $groupMembers.ContainsKey($principalId)) {
                        try {
                            $groupMembers[$principalId] = @(Get-GraphPages -Uri "v1.0/groups/$principalId/transitiveMembers/microsoft.graph.user?`$select=id" |
                                ForEach-Object { [string]$_['id'] })
                        }
                        catch {
                            $groupMembers[$principalId] = @()
                            & $OnWarning (T 'Report.GroupMembersFailed' ([string]$principal['displayName']) $_.Exception.Message)
                        }
                    }
                    $groupMembers[$principalId]
                }
                default { @($principalId) }
            }

            foreach ($userId in $userIds) {
                if (-not $roles.ContainsKey($userId)) { $roles[$userId] = New-Object System.Collections.Generic.List[string] }
                if (-not $roles[$userId].Contains($label)) { $roles[$userId].Add($label) }
            }
        }
    }
    $roles
}

function Get-M365AuthMethodsBatch {
    <#
    .SYNOPSIS
        Reads the authentication methods of up to 20 users with one Graph batch request.
    .OUTPUTS
        Hashtable user ID -> @{ Items = raw methods; Error = message or $null }
    #>
    param(
        [Parameter(Mandatory)][string[]]$UserIds,
        [scriptblock]$Wait = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    )

    $result = @{}
    $pending = @($UserIds)
    for ($attempt = 1; $pending.Count -and $attempt -le 6; $attempt++) {
        $requests = for ($i = 0; $i -lt $pending.Count; $i++) {
            @{ id = "$i"; method = 'GET'; url = "/users/$($pending[$i])/authentication/methods" }
        }
        $response = Invoke-M365GraphRequest -Method POST -Uri 'beta/$batch' -Body @{ requests = @($requests) }

        $retry = New-Object System.Collections.Generic.List[string]
        $retryAfter = 2
        foreach ($entry in @($response['responses'])) {
            $userId = $pending[[int]$entry['id']]
            $status = [int]$entry['status']
            $body = $entry['body']

            # Throttled or temporarily unavailable: try again after the requested delay
            if ($status -eq 429 -or $status -ge 500) {
                $retry.Add($userId)
                $headers = $entry['headers']
                if ($headers -is [System.Collections.IDictionary] -and $headers['Retry-After']) {
                    $retryAfter = [Math]::Max($retryAfter, [Math]::Min(60, [int]$headers['Retry-After']))
                }
                continue
            }
            if ($status -ge 400) {
                $message = "HTTP $status"
                if ($body -is [System.Collections.IDictionary] -and $body['error'] -is [System.Collections.IDictionary]) {
                    $message = '{0}: {1}' -f $body['error']['code'], $body['error']['message']
                }
                $result[$userId] = @{ Items = @(); Error = $message }
                continue
            }

            $items = @($body['value'] | Where-Object { $null -ne $_ })
            if ($body['@odata.nextLink']) { $items += @(Get-GraphPages -Uri $body['@odata.nextLink']) }
            $result[$userId] = @{ Items = $items; Error = $null }
        }

        $pending = @($retry)
        if ($pending.Count) { & $Wait ($retryAfter * 1000) }
    }
    foreach ($userId in $pending) { $result[$userId] = @{ Items = @(); Error = T 'Report.Throttled' } }
    $result
}

#endregion

#region Rating

function Get-M365TenantMfaRating {
    <#
    .SYNOPSIS
        Rates a user for the tenant report.
    .DESCRIPTION
        Red:    no MFA (password only), or administrative role with insecure MFA
        Yellow: insecure MFA (SMS/call, TAP or fake MFA only), or administrator without phishing-resistant MFA
        Green:  strong MFA (administrators: phishing-resistant)
    #>
    param(
        [object[]]$Methods = @(),
        [bool]$IsAdmin = $false
    )

    $real = @($Methods | Where-Object { -not $_.IsFakeMfa })
    $phishingResistant = @($real | Where-Object Strength -eq 'PhishingResistant')
    $strong = @($real | Where-Object Strength -eq 'Strong')
    $weak = @($real | Where-Object Strength -eq 'Weak')
    $temporary = @($real | Where-Object Strength -eq 'Temporary')
    $fake = @($Methods | Where-Object IsFakeMfa)

    $level, $reason = if ($phishingResistant.Count) { 'Green', 'Report.Reason.PhishingResistant' }
        elseif ($strong.Count) {
            if ($IsAdmin) { 'Yellow', 'Report.Reason.AdminNotPhishingResistant' } else { 'Green', 'Report.Reason.Strong' }
        }
        elseif ($weak.Count -or $temporary.Count -or $fake.Count) {
            if ($IsAdmin) { 'Red', 'Report.Reason.AdminInsecure' }
            elseif ($weak.Count) { 'Yellow', 'Report.Reason.Weak' }
            elseif ($temporary.Count) { 'Yellow', 'Report.Reason.TapOnly' }
            else { 'Yellow', 'Report.Reason.FakeOnly' }
        }
        elseif ($IsAdmin) { 'Red', 'Report.Reason.AdminNoMfa' }
        else { 'Red', 'Report.Reason.NoMfa' }

    [pscustomobject]@{ Level = $level; Reason = T $reason }
}

function New-M365ReportRow {
    param(
        [Parameter(Mandatory)]$User,
        [string[]]$Roles = @(),
        [System.Collections.IDictionary]$MethodResult
    )

    $Roles = @($Roles | Where-Object { $_ } | Sort-Object)
    $isAdmin = $Roles.Count -gt 0
    $methods = @()
    if ($null -eq $MethodResult -or $MethodResult['Error']) {
        $errorText = if ($null -ne $MethodResult) { $MethodResult['Error'] } else { '-' }
        $rating = [pscustomobject]@{ Level = 'Unknown'; Reason = T 'Report.Reason.Unknown' $errorText }
    }
    else {
        $methods = @($MethodResult['Items'] | ForEach-Object { ConvertTo-M365AuthMethod -Raw $_ -SkipDetails })
        $rating = Get-M365TenantMfaRating -Methods $methods -IsAdmin $isAdmin
    }

    $password = @($methods | Where-Object Type -eq '#microsoft.graph.passwordAuthenticationMethod') | Select-Object -First 1
    $mfa = @($methods | Where-Object Type -ne '#microsoft.graph.passwordAuthenticationMethod')

    [pscustomobject]@{
        Level             = $rating.Level
        LevelOrder        = $script:LevelOrder[$rating.Level]
        LevelText         = T "Report.Level.$($rating.Level)"
        Reason            = $rating.Reason
        DisplayName       = $User.DisplayName
        UserPrincipalName = $User.UserPrincipalName
        Mail              = $User.Mail
        IsAdmin           = $isAdmin
        AdminRoles        = $Roles -join ', '
        MethodCount       = $mfa.Count
        Methods           = @($mfa | ForEach-Object { $_.TypeName } | Select-Object -Unique) -join ', '
        AccountEnabled    = $User.AccountEnabled
        IsLicensed        = $User.IsLicensed
        UserType          = $User.UserType
        JobTitle          = $User.JobTitle
        Department        = $User.Department
        PasswordLastSet   = if ($password) { $password.Created } else { $null }
        Id                = $User.Id
    }
}

#endregion

#region Report

function Invoke-M365TenantMfaReport {
    <#
    .SYNOPSIS
        Creates the MFA report and passes the rows in portions to OnRows.
    .PARAMETER OnProgress
        Called with a status text.
    .PARAMETER OnRows
        Called after each batch with the new rows, the number of processed and of all users.
    .PARAMETER ShouldCancel
        Returns $true to stop after the current batch.
    .OUTPUTS
        Number of all and of processed users, and whether the report was cancelled.
    #>
    param(
        [string]$GroupId,
        [switch]$IncludeDisabled,
        [switch]$IncludeGuests,
        [scriptblock]$OnProgress = { param($Message) },
        [scriptblock]$OnWarning = { param($Message) },
        [scriptblock]$OnRows = { param($Rows, $Done, $Total) },
        [scriptblock]$ShouldCancel = { $false },
        [scriptblock]$Wait = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    )

    & $OnProgress (T 'Report.Progress.Users')
    $users = @(Get-M365ReportUsers -GroupId $GroupId |
        Where-Object { ($IncludeDisabled -or $_.AccountEnabled) -and ($IncludeGuests -or $_.UserType -ne 'Guest') } |
        Sort-Object Id -Unique)

    & $OnProgress (T 'Report.Progress.Roles')
    $adminRoles = Get-M365TenantAdminRoles -OnWarning $OnWarning

    $done = 0
    $cancelled = $false
    for ($offset = 0; $offset -lt $users.Count; $offset += $script:BatchSize) {
        if (& $ShouldCancel) { $cancelled = $true; break }
        & $OnProgress (T 'Report.Progress.Methods' $done $users.Count)

        $chunk = @($users[$offset..([Math]::Min($offset + $script:BatchSize, $users.Count) - 1)])
        $methods = Get-M365AuthMethodsBatch -UserIds @($chunk | ForEach-Object { $_.Id }) -Wait $Wait
        $rows = foreach ($user in $chunk) {
            $roles = if ($adminRoles.ContainsKey($user.Id)) { @($adminRoles[$user.Id]) } else { @() }
            New-M365ReportRow -User $user -Roles $roles -MethodResult $methods[$user.Id]
        }
        $done += $chunk.Count
        & $OnRows @($rows) $done $users.Count
    }

    [pscustomobject]@{ Total = $users.Count; Done = $done; Cancelled = $cancelled }
}

#endregion

#region Excel export

# Cell styles (index into cellXfs): text style, date style
$script:XlsxStyles = @{
    Default = 0, 10
    Header  = 1, 1
    Red     = 2, 3
    Yellow  = 4, 5
    Green   = 6, 7
    Unknown = 8, 9
    Bold    = 11, 11
}

function ConvertTo-XlsxColumnName {
    param([int]$Index)   # 1-based
    $name = ''
    while ($Index -gt 0) {
        $name = [char](65 + (($Index - 1) % 26)) + $name
        $Index = [int][Math]::Floor(($Index - 1) / 26)
    }
    $name
}

function ConvertTo-XmlText {
    param([string]$Text)
    # Control characters are not allowed in XML
    [System.Security.SecurityElement]::Escape(($Text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''))
}

function New-XlsxSheetXml {
    <#
    .SYNOPSIS
        Builds a worksheet. Rows are @{ Values = object[]; Style = key of XlsxStyles }.
    #>
    param(
        [double[]]$Widths = @(),
        [object[]]$Rows = @(),
        [switch]$HeaderRow
    )

    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $xml = New-Object System.Text.StringBuilder
    [void]$xml.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$xml.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
    if ($HeaderRow) {
        [void]$xml.Append('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>')
    }
    if ($Widths.Count) {
        [void]$xml.Append('<cols>')
        for ($i = 0; $i -lt $Widths.Count; $i++) {
            [void]$xml.AppendFormat($invariant, '<col min="{0}" max="{0}" width="{1}" customWidth="1"/>', ($i + 1), $Widths[$i])
        }
        [void]$xml.Append('</cols>')
    }

    [void]$xml.Append('<sheetData>')
    $maxColumns = 1
    $letters = @{}
    for ($r = 0; $r -lt $Rows.Count; $r++) {
        $rowNumber = $r + 1
        $styleKey = if ($Rows[$r]['Style']) { $Rows[$r]['Style'] } else { 'Default' }
        $textStyle, $dateStyle = $script:XlsxStyles[$styleKey]
        $values = @($Rows[$r].Values)
        $maxColumns = [Math]::Max($maxColumns, $values.Count)

        [void]$xml.Append("<row r=`"$rowNumber`">")
        for ($c = 0; $c -lt $values.Count; $c++) {
            if (-not $letters.ContainsKey($c)) { $letters[$c] = ConvertTo-XlsxColumnName ($c + 1) }
            $ref = $letters[$c] + $rowNumber
            $value = $values[$c]
            if ($null -eq $value -or "$value" -eq '') {
                [void]$xml.Append("<c r=`"$ref`" s=`"$textStyle`"/>")
            }
            elseif ($value -is [datetime]) {
                [void]$xml.Append("<c r=`"$ref`" s=`"$dateStyle`"><v>$($value.ToOADate().ToString($invariant))</v></c>")
            }
            elseif ($value -is [int] -or $value -is [long] -or $value -is [double]) {
                [void]$xml.Append("<c r=`"$ref`" s=`"$textStyle`"><v>$(([double]$value).ToString($invariant))</v></c>")
            }
            else {
                [void]$xml.Append("<c r=`"$ref`" s=`"$textStyle`" t=`"inlineStr`"><is><t xml:space=`"preserve`">$(ConvertTo-XmlText "$value")</t></is></c>")
            }
        }
        [void]$xml.Append('</row>')
    }
    [void]$xml.Append('</sheetData>')

    if ($HeaderRow -and $Rows.Count) {
        [void]$xml.Append("<autoFilter ref=`"A1:$(ConvertTo-XlsxColumnName $maxColumns)$($Rows.Count)`"/>")
    }
    [void]$xml.Append('</worksheet>')
    $xml.ToString()
}

function Get-XlsxStylesXml {
    $font = '<font>{0}<sz val="11"/>{1}<name val="Calibri"/><family val="2"/></font>'
    $fonts = @(
        ($font -f '', '')
        ($font -f '<b/>', '<color rgb="FFFFFFFF"/>')     # 1 header
        ($font -f '', '<color rgb="FF9C0006"/>')         # 2 red
        ($font -f '', '<color rgb="FF9C5700"/>')         # 3 yellow
        ($font -f '', '<color rgb="FF006100"/>')         # 4 green
        ($font -f '', '<color rgb="FF595959"/>')         # 5 unknown
        ($font -f '<b/>', '')                            # 6 bold
    )
    $solid = '<fill><patternFill patternType="solid"><fgColor rgb="{0}"/><bgColor indexed="64"/></patternFill></fill>'
    $fills = @(
        '<fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill>'
        ($solid -f 'FF0F172A')   # 2 header
        ($solid -f 'FFFFC7CE')   # 3 red
        ($solid -f 'FFFFEB9C')   # 4 yellow
        ($solid -f 'FFC6EFCE')   # 5 green
        ($solid -f 'FFEDEDED')   # 6 unknown
    )
    $side = '<{0} style="thin"><color rgb="FFD9D9D9"/></{0}>'
    $borders = @(
        '<border><left/><right/><top/><bottom/><diagonal/></border>'
        '<border>' + (($('left', 'right', 'top', 'bottom') | ForEach-Object { $side -f $_ }) -join '') + '<diagonal/></border>'
    )
    # numFmtId 22 = date and time in the regional format of Excel
    $xf = '<xf numFmtId="{0}" fontId="{1}" fillId="{2}" borderId="{3}" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>'
    $cellXfs = @(
        ($xf -f 0, 0, 0, 0)    # 0 default
        ($xf -f 0, 1, 2, 1)    # 1 header
        ($xf -f 0, 2, 3, 1)    # 2 red
        ($xf -f 22, 2, 3, 1)   # 3 red date
        ($xf -f 0, 3, 4, 1)    # 4 yellow
        ($xf -f 22, 3, 4, 1)   # 5 yellow date
        ($xf -f 0, 4, 5, 1)    # 6 green
        ($xf -f 22, 4, 5, 1)   # 7 green date
        ($xf -f 0, 5, 6, 1)    # 8 unknown
        ($xf -f 22, 5, 6, 1)   # 9 unknown date
        ($xf -f 22, 0, 0, 0)   # 10 default date
        ($xf -f 0, 6, 0, 0)    # 11 bold
    )

    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
    "<fonts count=`"$($fonts.Count)`">$($fonts -join '')</fonts>" +
    "<fills count=`"$($fills.Count)`">$($fills -join '')</fills>" +
    "<borders count=`"$($borders.Count)`">$($borders -join '')</borders>" +
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
    "<cellXfs count=`"$($cellXfs.Count)`">$($cellXfs -join '')</cellXfs>" +
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
    '</styleSheet>'
}

function Save-XlsxWorkbook {
    <#
    .SYNOPSIS
        Writes an .xlsx file. Sheets are @{ Name; Xml; FilterRef (optional, e.g. A1:P20) }.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Sheets
    )

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    $sheetEntries = ''
    $relations = ''
    $overrides = ''
    $definedNames = ''
    for ($i = 0; $i -lt $Sheets.Count; $i++) {
        $number = $i + 1
        # Sheet names: max. 31 characters, without : \ / ? * [ ]
        $name = ($Sheets[$i].Name -replace '[:\\/\?\*\[\]]', '-')
        if ($name.Length -gt 31) { $name = $name.Substring(0, 31) }
        $sheetEntries += "<sheet name=`"$(ConvertTo-XmlText $name)`" sheetId=`"$number`" r:id=`"rId$number`"/>"
        $relations += "<Relationship Id=`"rId$number`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$number.xml`"/>"
        $overrides += "<Override PartName=`"/xl/worksheets/sheet$number.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>"
        if ($Sheets[$i]['FilterRef']) {
            $absolute = $Sheets[$i]['FilterRef'] -replace '([A-Z]+)(\d+)', '$$$1$$$2'
            $definedNames += "<definedName name=`"_xlnm._FilterDatabase`" localSheetId=`"$i`" hidden=`"1`">'$(ConvertTo-XmlText ($name.Replace("'", "''")))'!$absolute</definedName>"
        }
    }
    $stylesId = $Sheets.Count + 1

    $parts = [ordered]@{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
            '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
            $overrides + '</Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
            '</Relationships>'
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
            "<sheets>$sheetEntries</sheets>" +
            $(if ($definedNames) { "<definedNames>$definedNames</definedNames>" } else { '' }) +
            '</workbook>'
        'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + $relations +
            "<Relationship Id=`"rId$stylesId`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/>" +
            '</Relationships>'
        'xl/styles.xml' = Get-XlsxStylesXml
    }
    for ($i = 0; $i -lt $Sheets.Count; $i++) { $parts["xl/worksheets/sheet$($i + 1).xml"] = $Sheets[$i].Xml }

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($part in $parts.GetEnumerator()) {
            $entry = $zip.CreateEntry($part.Key, [System.IO.Compression.CompressionLevel]::Optimal)
            $writer = New-Object System.IO.StreamWriter ($entry.Open(), (New-Object System.Text.UTF8Encoding $false))
            try { $writer.Write($part.Value) } finally { $writer.Dispose() }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Export-M365MfaReportXlsx {
    <#
    .SYNOPSIS
        Exports report rows as an Excel workbook in traffic light colors (list + summary).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Rows,
        [string]$Tenant,
        [string]$ScopeText,
        [string]$FilterText
    )

    $yesNo = { param($Value) if ($Value) { T 'Common.Yes' } else { T 'Common.No' } }
    $columns = @(
        @{ Key = 'Report.Col.Status';          Width = 12; Property = 'LevelText' }
        @{ Key = 'Report.Col.Reason';          Width = 55; Property = 'Reason' }
        @{ Key = 'Report.Col.Name';            Width = 28; Property = 'DisplayName' }
        @{ Key = 'Report.Col.Upn';             Width = 38; Property = 'UserPrincipalName' }
        @{ Key = 'Report.Col.Mail';            Width = 34; Property = 'Mail' }
        @{ Key = 'Report.Col.Admin';           Width = 9;  Property = 'IsAdmin' }
        @{ Key = 'Report.Col.Roles';           Width = 45; Property = 'AdminRoles' }
        @{ Key = 'Report.Col.MethodCount';     Width = 10; Property = 'MethodCount' }
        @{ Key = 'Report.Col.Methods';         Width = 60; Property = 'Methods' }
        @{ Key = 'Report.Col.Enabled';         Width = 9;  Property = 'AccountEnabled' }
        @{ Key = 'Report.Col.Licensed';        Width = 10; Property = 'IsLicensed' }
        @{ Key = 'Report.Col.UserType';        Width = 11; Property = 'UserType' }
        @{ Key = 'Report.Col.JobTitle';        Width = 24; Property = 'JobTitle' }
        @{ Key = 'Report.Col.Department';      Width = 22; Property = 'Department' }
        @{ Key = 'Report.Col.PasswordLastSet'; Width = 18; Property = 'PasswordLastSet' }
        @{ Key = 'Report.Col.Id';              Width = 38; Property = 'Id' }
    )

    # Sheet 1: list, one colored row per user
    $listRows = New-Object System.Collections.Generic.List[object]
    $listRows.Add(@{ Style = 'Header'; Values = @($columns | ForEach-Object { T $_.Key }) })
    foreach ($row in ($Rows | Sort-Object LevelOrder, DisplayName)) {
        $values = foreach ($column in $columns) {
            $value = $row.($column.Property)
            if ($value -is [bool]) { & $yesNo $value } else { $value }
        }
        $listRows.Add(@{ Style = $row.Level; Values = @($values) })
    }
    $filterRef = 'A1:{0}{1}' -f (ConvertTo-XlsxColumnName $columns.Count), $listRows.Count

    # Sheet 2: summary
    $total = $Rows.Count
    $summaryRows = New-Object System.Collections.Generic.List[object]
    $summaryRows.Add(@{ Style = 'Bold'; Values = @(T 'Report.Title') })
    $summaryRows.Add(@{ Values = @((T 'Report.Summary.Tenant'), $Tenant) })
    $summaryRows.Add(@{ Values = @((T 'Report.Summary.Created'), (Get-Date)) })
    $summaryRows.Add(@{ Values = @((T 'Report.Summary.Scope'), $ScopeText) })
    $summaryRows.Add(@{ Values = @((T 'Report.Summary.Filter'), $(if ($FilterText) { $FilterText } else { T 'Report.Summary.NoFilter' })) })
    $summaryRows.Add(@{ Values = @() })
    $summaryRows.Add(@{ Style = 'Header'; Values = @((T 'Report.Col.Status'), (T 'Report.Summary.Count'), (T 'Report.Summary.Share')) })
    foreach ($level in 'Red', 'Yellow', 'Green', 'Unknown') {
        $count = @($Rows | Where-Object Level -eq $level).Count
        if ($level -eq 'Unknown' -and -not $count) { continue }
        $share = if ($total) { '{0:N1} %' -f (100 * $count / $total) } else { '-' }
        $summaryRows.Add(@{ Style = $level; Values = @((T "Report.Level.$level"), $count, $share) })
    }
    $summaryRows.Add(@{ Style = 'Bold'; Values = @((T 'Report.Summary.Total'), $total) })
    $summaryRows.Add(@{ Values = @() })
    $admins = @($Rows | Where-Object IsAdmin)
    $summaryRows.Add(@{ Values = @((T 'Report.Summary.Admins'), $admins.Count) })
    $summaryRows.Add(@{ Style = 'Red'; Values = @((T 'Report.Summary.AdminsRed'), @($admins | Where-Object Level -eq 'Red').Count) })

    Save-XlsxWorkbook -Path $Path -Sheets @(
        @{ Name = T 'Report.Sheet.List'; FilterRef = $filterRef
           Xml = New-XlsxSheetXml -Widths @($columns | ForEach-Object { $_.Width }) -Rows $listRows.ToArray() -HeaderRow }
        @{ Name = T 'Report.Sheet.Summary'
           Xml = New-XlsxSheetXml -Widths 34, 50, 12 -Rows $summaryRows.ToArray() }
    )
}

#endregion

Export-ModuleMember -Function @(
    'Get-M365ReportScopes'
    'Get-M365OrganizationName'
    'Find-M365Group'
    'Invoke-M365TenantMfaReport'
    'Get-M365TenantMfaRating'
    'Export-M365MfaReportXlsx'
)
