<#
.SYNOPSIS
    Tenant-wide MFA status report of the M365 MFA Administration Tool.

.DESCRIPTION
    Loads all users (or the members of a group incl. nested groups), their administrative roles
    and authentication methods, rates every user as a traffic light and exports the result as a
    colored Excel workbook (via Xlsx.psm1 - neither Excel nor an extra module required).
    Authentication methods are read via Graph JSON batching (20 users per request).
#>

Set-StrictMode -Version Latest

# Generic .xlsx writer, only needed by this module
Import-Module (Join-Path $PSScriptRoot 'Xlsx.psm1') -Force

$script:ReportScopes = @(
    'GroupMember.Read.All'   # Group selection and administrative roles assigned via groups
    'AuditLog.Read.All'      # Last sign-in (signInActivity, requires Entra ID P1/P2)
)

$script:BatchSize = 20
$script:InactiveDays = 90   # No sign-in for longer than this (or never) = inactive
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

function Get-M365ReportInactiveDays {
    $script:InactiveDays
}

function ConvertTo-LastSignIn {
    <#
    .SYNOPSIS
        Returns the last sign-in (local time) from a Graph signInActivity object, $null if never.
    .DESCRIPTION
        Prefers the last successful sign-in (interactive or non-interactive). Graph only records it
        since December 2023, so older accounts fall back to the latest sign-in attempt.
    #>
    param($Activity)
    if ($Activity -isnot [System.Collections.IDictionary]) { return $null }
    $successful = ConvertTo-LocalDate $Activity['lastSuccessfulSignInDateTime']
    if ($successful) { return $successful }
    @(
        ConvertTo-LocalDate $Activity['lastSignInDateTime']
        ConvertTo-LocalDate $Activity['lastNonInteractiveSignInDateTime']
    ) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
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
    .DESCRIPTION
        With IncludeSignIn, all users are loaded including their last sign-in. If that is not possible
        (no Entra ID P1/P2 license or missing permission), OnWarning is called and the users are
        loaded without it. Group members never include it (Graph only returns it on /users),
        it is read per user in Invoke-M365TenantMfaReport instead.
    #>
    param(
        [string]$GroupId,
        [switch]$IncludeSignIn,
        [scriptblock]$OnWarning = { param($Message) }
    )

    $signInKnown = $false
    if ($GroupId) {
        $uri = "v1.0/groups/$([uri]::EscapeDataString($GroupId))/transitiveMembers/microsoft.graph.user?`$select=$script:UserSelect&`$top=999&`$count=true"
        $items = @(Get-GraphPages -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' })
    }
    else {
        $items = $null
        if ($IncludeSignIn) {
            try {
                $items = @(Get-GraphPages -Uri "v1.0/users?`$select=$script:UserSelect,signInActivity&`$top=999")
                $signInKnown = $true
            }
            catch {
                & $OnWarning (T 'Report.SignInUnavailable' $_.Exception.Message)
            }
        }
        if ($null -eq $items) { $items = @(Get-GraphPages -Uri "v1.0/users?`$select=$script:UserSelect&`$top=999") }
    }

    $items | ForEach-Object {
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
            SignInKnown       = $signInKnown
            LastSignIn        = if ($signInKnown) { ConvertTo-LastSignIn $_['signInActivity'] } else { $null }
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

function Invoke-M365UserBatch {
    <#
    .SYNOPSIS
        Runs one GET per user (up to 20) as a Graph batch request, with retries when throttled.
    .PARAMETER Path
        Request path with {0} as placeholder for the user ID, e.g. '/users/{0}/authentication/methods'.
    .OUTPUTS
        Hashtable user ID -> @{ Body = response body; Error = message or $null }
    #>
    param(
        [Parameter(Mandatory)][string[]]$UserIds,
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$Wait = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    )

    $result = @{}
    $pending = @($UserIds)
    for ($attempt = 1; $pending.Count -and $attempt -le 6; $attempt++) {
        $requests = for ($i = 0; $i -lt $pending.Count; $i++) {
            @{ id = "$i"; method = 'GET'; url = $Path -f $pending[$i] }
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
                $result[$userId] = @{ Body = $null; Error = $message }
                continue
            }
            $result[$userId] = @{ Body = $body; Error = $null }
        }

        $pending = @($retry)
        if ($pending.Count) { & $Wait ($retryAfter * 1000) }
    }
    foreach ($userId in $pending) { $result[$userId] = @{ Body = $null; Error = T 'Report.Throttled' } }
    $result
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
    $responses = Invoke-M365UserBatch -UserIds $UserIds -Path '/users/{0}/authentication/methods' -Wait $Wait
    foreach ($userId in $responses.Keys) {
        $response = $responses[$userId]
        if ($response.Error) { $result[$userId] = @{ Items = @(); Error = $response.Error }; continue }
        $body = $response.Body
        $items = @($body['value'] | Where-Object { $null -ne $_ })
        if ($body['@odata.nextLink']) { $items += @(Get-GraphPages -Uri $body['@odata.nextLink']) }
        $result[$userId] = @{ Items = $items; Error = $null }
    }
    $result
}

function Get-M365SignInBatch {
    <#
    .SYNOPSIS
        Reads the last sign-in of up to 20 users with one Graph batch request.
    .OUTPUTS
        Hashtable user ID -> @{ LastSignIn = date or $null (never); Error = message or $null }
    #>
    param(
        [Parameter(Mandatory)][string[]]$UserIds,
        [scriptblock]$Wait = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    )

    $result = @{}
    $responses = Invoke-M365UserBatch -UserIds $UserIds -Path '/users/{0}?$select=id,signInActivity' -Wait $Wait
    foreach ($userId in $responses.Keys) {
        $response = $responses[$userId]
        $result[$userId] = if ($response.Error) { @{ LastSignIn = $null; Error = $response.Error } }
                           else { @{ LastSignIn = ConvertTo-LastSignIn $response.Body['signInActivity']; Error = $null } }
    }
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

    # Last sign-in: SignInKnown = $false means not available (license/permission), LastSignIn = $null means never
    $signInKnown = [bool]($User.PSObject.Properties['SignInKnown'] -and $User.SignInKnown)
    $lastSignIn = if ($signInKnown) { $User.LastSignIn } else { $null }
    $days = if ($lastSignIn) { [int][Math]::Floor(((Get-Date) - $lastSignIn).TotalDays) } else { $null }

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
        SignInKnown       = $signInKnown
        LastSignIn        = $lastSignIn
        LastSignInText    = if ($lastSignIn) { $lastSignIn.ToString((T 'Format.DateTime')) } elseif ($signInKnown) { T 'Report.Never' } else { '' }
        LastSignInExport  = if ($lastSignIn) { $lastSignIn } elseif ($signInKnown) { T 'Report.Never' } else { $null }
        DaysSinceSignIn   = $days
        DaysText          = if ($null -ne $days) { "$days" } elseif ($signInKnown) { T 'Report.Never' } else { '' }
        DaysSort          = if ($null -ne $days) { $days } elseif ($signInKnown) { [int]::MaxValue } else { -1 }
        IsInactive        = $signInKnown -and ($null -eq $days -or $days -gt $script:InactiveDays)
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
    .PARAMETER IncludeSignIn
        Also read the last sign-in (requires AuditLog.Read.All and Entra ID P1/P2).
    .OUTPUTS
        Number of all and of processed users, whether the report was cancelled and whether
        the last sign-in is available.
    #>
    param(
        [string]$GroupId,
        [switch]$IncludeDisabled,
        [switch]$IncludeGuests,
        [switch]$IncludeSignIn,
        [scriptblock]$OnProgress = { param($Message) },
        [scriptblock]$OnWarning = { param($Message) },
        [scriptblock]$OnRows = { param($Rows, $Done, $Total) },
        [scriptblock]$ShouldCancel = { $false },
        [scriptblock]$Wait = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    )

    & $OnProgress (T 'Report.Progress.Users')
    $users = @(Get-M365ReportUsers -GroupId $GroupId -IncludeSignIn:$IncludeSignIn -OnWarning $OnWarning |
        Where-Object { ($IncludeDisabled -or $_.AccountEnabled) -and ($IncludeGuests -or $_.UserType -ne 'Guest') } |
        Sort-Object Id -Unique)
    # Group members come without sign-in data: read it per batch below.
    $readSignIn = $IncludeSignIn -and [bool]$GroupId
    $signInAvailable = @($users | Where-Object SignInKnown).Count -gt 0

    & $OnProgress (T 'Report.Progress.Roles')
    $adminRoles = Get-M365TenantAdminRoles -OnWarning $OnWarning

    $done = 0
    $cancelled = $false
    for ($offset = 0; $offset -lt $users.Count; $offset += $script:BatchSize) {
        if (& $ShouldCancel) { $cancelled = $true; break }
        & $OnProgress (T 'Report.Progress.Methods' $done $users.Count)

        $chunk = @($users[$offset..([Math]::Min($offset + $script:BatchSize, $users.Count) - 1)])
        $userIds = @($chunk | ForEach-Object { $_.Id })
        if ($readSignIn) {
            $signIns = Get-M365SignInBatch -UserIds $userIds -Wait $Wait
            $failed = @($userIds | Where-Object { $signIns[$_].Error })
            if ($failed.Count -eq $userIds.Count) {
                # Fails for all users (no license or permission): do not try again for every batch.
                $readSignIn = $false
                & $OnWarning (T 'Report.SignInUnavailable' $signIns[$failed[0]].Error)
            }
            else {
                foreach ($user in $chunk) {
                    if ($signIns[$user.Id].Error) { continue }
                    $user.SignInKnown = $true
                    $user.LastSignIn = $signIns[$user.Id].LastSignIn
                    $signInAvailable = $true
                }
            }
        }
        $methods = Get-M365AuthMethodsBatch -UserIds $userIds -Wait $Wait
        $rows = foreach ($user in $chunk) {
            $roles = if ($adminRoles.ContainsKey($user.Id)) { @($adminRoles[$user.Id]) } else { @() }
            New-M365ReportRow -User $user -Roles $roles -MethodResult $methods[$user.Id]
        }
        $done += $chunk.Count
        & $OnRows @($rows) $done $users.Count
    }

    [pscustomobject]@{ Total = $users.Count; Done = $done; Cancelled = $cancelled; SignInAvailable = $signInAvailable }
}

#endregion

#region Excel export

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
        @{ Key = 'Report.Col.LastSignIn';      Width = 18; Property = 'LastSignInExport' }
        @{ Key = 'Report.Col.DaysSinceSignIn'; Width = 12; Property = 'DaysSinceSignIn' }
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
    if (@($Rows | Where-Object SignInKnown).Count) {
        $inactive = @($Rows | Where-Object IsInactive)
        $summaryRows.Add(@{ Values = @() })
        $summaryRows.Add(@{ Values = @((T 'Report.Summary.Inactive' $script:InactiveDays), $inactive.Count) })
        $summaryRows.Add(@{ Style = 'Red'; Values = @((T 'Report.Summary.InactiveAdmins'), @($inactive | Where-Object IsAdmin).Count) })
    }
    else {
        $summaryRows.Add(@{ Values = @() })
        $summaryRows.Add(@{ Values = @((T 'Report.Col.LastSignIn'), (T 'Report.Summary.SignInNotAvailable')) })
    }

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
    'Get-M365ReportInactiveDays'
    'Get-M365OrganizationName'
    'Find-M365Group'
    'Invoke-M365TenantMfaReport'
    'Export-M365MfaReportXlsx'
)
