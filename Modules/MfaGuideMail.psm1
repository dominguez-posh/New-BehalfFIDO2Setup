<#
.SYNOPSIS
    MFA setup guide by email of the M365 MFA Administration Tool.

.DESCRIPTION
    Builds an HTML email with a step-by-step guide for the Microsoft Authenticator app in the
    language of the recipient, sends it via Microsoft Graph and stores the sending date in the
    user object.

    The screenshots from Mail\Images are sent as inline attachments (Base64 in the mail, referenced
    via cid:). Outlook and many other mail clients block images embedded as data: URIs.

    The sending date is stored in an open extension of the user (com.m365mfatool.mfaGuide).
    Open extensions exist only in Entra ID: they are not part of Entra Connect / Cloud Sync, so
    they are writable for hybrid (synchronized) users too and are never overwritten by the sync -
    unlike extensionAttribute1-15, which belong to the on-premises AD for synchronized users.
#>

Set-StrictMode -Version Latest

$script:ExtensionName = 'com.m365mfatool.mfaGuide'
$script:ImageFolder = Join-Path (Split-Path -Parent $PSScriptRoot) 'Mail\Images'
$script:SetupUrl = 'https://aka.ms/mfasetup'
$script:AppStoreUrl = 'https://apps.apple.com/app/microsoft-authenticator/id983156458'
$script:GooglePlayUrl = 'https://play.google.com/store/apps/details?id=com.azure.authenticator'

#region Sending date in the user object

function Get-M365MfaGuideExtensionName {
    $script:ExtensionName
}

function ConvertTo-M365MfaGuideInfo {
    <#
    .SYNOPSIS
        Converts the open extension (Graph response) into SentAt (local time), SentBy, Language and Count.
    #>
    param($Extension)
    if ($Extension -isnot [System.Collections.IDictionary]) { return $null }
    [pscustomobject]@{
        SentAt   = ConvertTo-LocalDate $Extension['sentDateTime']
        SentBy   = [string]$Extension['sentBy']
        Language = [string]$Extension['language']
        Count    = [int]$Extension['sentCount']
    }
}

function Get-M365MfaGuideInfo {
    <#
    .SYNOPSIS
        Returns when the MFA guide was last sent to the user, $null if never.
    #>
    param([Parameter(Mandatory)][string]$UserId)
    try {
        $extension = Invoke-M365GraphRequest -Uri "v1.0/users/$([uri]::EscapeDataString($UserId))/extensions/$script:ExtensionName"
    }
    catch {
        # 404: the user has no extension yet, i.e. the guide was never sent
        if ("$($_.Exception.Message)" -match 'ResourceNotFound|NotFound|404|Request_ResourceNotFound') { return $null }
        throw
    }
    ConvertTo-M365MfaGuideInfo $extension
}

function Set-M365MfaGuideInfo {
    <#
    .SYNOPSIS
        Stores the sending date (UTC), the sender and the language in the open extension of the user.
    #>
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$SentBy,
        [Parameter(Mandatory)][string]$Language
    )

    $previous = Get-M365MfaGuideInfo -UserId $UserId
    $body = @{
        sentDateTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        sentBy       = $SentBy
        language     = $Language
        sentCount    = if ($previous) { $previous.Count + 1 } else { 1 }
    }
    $userPart = [uri]::EscapeDataString($UserId)
    if ($previous) {
        Invoke-M365GraphRequest -Method PATCH -Uri "v1.0/users/$userPart/extensions/$script:ExtensionName" -Body $body | Out-Null
    }
    else {
        $body['@odata.type'] = '#microsoft.graph.openTypeExtension'
        $body['extensionName'] = $script:ExtensionName
        Invoke-M365GraphRequest -Method POST -Uri "v1.0/users/$userPart/extensions" -Body $body | Out-Null
    }
}

#endregion

#region Recipient and language

function Resolve-M365MailLanguage {
    <#
    .SYNOPSIS
        Maps a language tag (e.g. de-DE, pt-BR) to an available tool language, otherwise $null.
    #>
    param([string]$LanguageTag)
    if ([string]::IsNullOrWhiteSpace($LanguageTag)) { return $null }
    $code = ($LanguageTag -split '[-_]')[0].ToLowerInvariant()
    if (@(Get-UiLanguages | ForEach-Object Code) -contains $code) { return $code }
    $null
}

function Get-M365MfaGuideRecipient {
    <#
    .SYNOPSIS
        Reads name, email address and preferred language of the user.
    .DESCRIPTION
        Language: preferred language of the user, otherwise of the organization, otherwise English.
    #>
    param([Parameter(Mandatory)][string]$UserId)

    $user = Invoke-M365GraphRequest -Uri "v1.0/users/$([uri]::EscapeDataString($UserId))?`$select=id,displayName,givenName,mail,userPrincipalName,preferredLanguage"
    $language = Resolve-M365MailLanguage ([string]$user['preferredLanguage'])
    $source = 'User'
    $organizationName = $null
    try {
        $organization = @((Invoke-M365GraphRequest -Uri 'v1.0/organization?$select=displayName,preferredLanguage')['value']) | Select-Object -First 1
        if ($organization) {
            $organizationName = [string]$organization['displayName']
            if (-not $language) { $language = Resolve-M365MailLanguage ([string]$organization['preferredLanguage']); $source = 'Organization' }
        }
    }
    catch { }
    if (-not $language) { $language = 'en'; $source = 'Default' }

    [pscustomobject]@{
        Id                = [string]$user['id']
        DisplayName       = [string]$user['displayName']
        GivenName         = [string]$user['givenName']
        Mail              = [string]$user['mail']
        UserPrincipalName = [string]$user['userPrincipalName']
        PreferredLanguage = [string]$user['preferredLanguage']
        Language          = $language
        LanguageSource    = $source
        OrganizationName  = $organizationName
    }
}

#endregion

#region Email

function ConvertTo-HtmlText {
    param([string]$Text)
    [System.Net.WebUtility]::HtmlEncode($Text)
}

function New-M365MfaGuideMail {
    <#
    .SYNOPSIS
        Builds subject, HTML body and inline images of the MFA guide in the given language.
    .OUTPUTS
        Subject, Html (images referenced as cid:<name>) and Images (Name, ContentId, Path).
    #>
    param(
        [Parameter(Mandatory)]$Recipient,
        [Parameter(Mandatory)][string]$Language
    )

    $t = { param([string]$Key, [object[]]$Arguments) ConvertTo-HtmlText (Get-LanguageText -Language $Language -Key $Key -Arguments $Arguments) }
    $link = { param([string]$Url, [string]$Text) '<a href="{0}" style="color:#0067B8;font-weight:600;text-decoration:underline;">{1}</a>' -f $Url, (ConvertTo-HtmlText $Text) }
    $image = { param([string]$Name, [int]$Width, [string]$Alt)
        '<img src="cid:{0}" width="{1}" alt="{2}" style="display:block;width:{1}px;max-width:100%;height:auto;border:1px solid #E1E5EA;border-radius:6px;">' -f $Name, $Width, $Alt }

    $name = if ($Recipient.GivenName) { $Recipient.GivenName } else { $Recipient.DisplayName }
    $organization = if ($Recipient.OrganizationName) { $Recipient.OrganizationName } else { '' }
    $account = if ($Recipient.UserPrincipalName) { $Recipient.UserPrincipalName } else { $Recipient.Mail }

    # Placeholders are inserted after HTML encoding, so links and bold texts stay intact.
    $step2 = (& $t 'Mail.Step2.Text') -f (& $link $script:SetupUrl 'aka.ms/mfasetup'), "<b>$(ConvertTo-HtmlText $account)</b>"
    $step1 = (& $t 'Mail.Step1.Text') -f (& $link $script:AppStoreUrl 'App Store'), (& $link $script:GooglePlayUrl 'Google Play')

    $stepBlock = {
        param([int]$Number, [string]$Title, [string]$TextHtml, [string]$ImagesHtml)
        @"
<tr><td style="padding:18px 28px 6px 28px;">
  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"><tr>
    <td width="40" valign="top"><div style="width:30px;height:30px;line-height:30px;border-radius:15px;background:#0067B8;color:#FFFFFF;font-weight:700;text-align:center;font-size:15px;">$Number</div></td>
    <td valign="top" style="padding-left:6px;">
      <div style="font-size:16px;font-weight:700;color:#0F172A;margin:4px 0 6px 0;">$Title</div>
      <div style="font-size:14px;line-height:21px;color:#334155;">$TextHtml</div>
    </td>
  </tr></table>
</td></tr>
$(if ($ImagesHtml) { "<tr><td style=`"padding:8px 28px 6px 74px;`">$ImagesHtml</td></tr>" })
"@
    }
    $row = { param([string[]]$Cells) '<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>' + (($Cells | ForEach-Object { "<td valign=`"top`" style=`"padding-right:10px;`">$_</td>" }) -join '') + '</tr></table>' }

    $steps = @(
        & $stepBlock 1 (& $t 'Mail.Step1.Title') $step1 ''
        & $stepBlock 2 (& $t 'Mail.Step2.Title') $step2 (& $image 'web-1-security-info.png' 500 (& $t 'Mail.Step2.Title'))
        & $stepBlock 3 (& $t 'Mail.Step3.Title') (& $t 'Mail.Step3.Text') (& $image 'web-2-add-method.png' 330 (& $t 'Mail.Step3.Title'))
        & $stepBlock 4 (& $t 'Mail.Step4.Title') (& $t 'Mail.Step4.Text') (& $row @((& $image 'web-3-install-app.png' 240 (& $t 'Mail.Step4.Title')), (& $image 'web-4-setup-account.png' 240 (& $t 'Mail.Step4.Title'))))
        & $stepBlock 5 (& $t 'Mail.Step5.Title') (& $t 'Mail.Step5.Text') (& $row @((& $image 'phone-1-add-account.png' 150 '+'), (& $image 'phone-2-work-account.png' 150 (& $t 'Mail.Step5.Title')), (& $image 'phone-3-scan-qr.png' 150 (& $t 'Mail.Step5.Title'))))
        & $stepBlock 6 (& $t 'Mail.Step6.Title') (& $t 'Mail.Step6.Text') (& $image 'web-5-scan-qr.png' 260 (& $t 'Mail.Step6.Title'))
    ) -join "`n"

    $html = @"
<!DOCTYPE html>
<html lang="$Language"><head><meta charset="utf-8"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>$(& $t 'Mail.Subject')</title></head>
<body style="margin:0;padding:0;background:#F5F7FA;font-family:'Segoe UI',Arial,sans-serif;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F7FA;"><tr><td align="center" style="padding:24px 12px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="640" style="width:640px;max-width:100%;background:#FFFFFF;border:1px solid #E1E5EA;border-radius:8px;">
  <tr><td style="background:#0F172A;padding:22px 28px;border-radius:8px 8px 0 0;">
    <div style="font-size:20px;font-weight:700;color:#FFFFFF;">$(& $t 'Mail.Header')</div>
    <div style="font-size:13px;color:#CBD5E1;margin-top:4px;">$(ConvertTo-HtmlText $organization)</div>
  </td></tr>
  <tr><td style="padding:24px 28px 4px 28px;font-size:14px;line-height:21px;color:#242424;">
    <p style="margin:0 0 12px 0;">$(& $t 'Mail.Greeting' $name)</p>
    <p style="margin:0 0 12px 0;">$(& $t 'Mail.Intro')</p>
    <p style="margin:0;padding:10px 14px;background:#EFF6FF;border-left:4px solid #0067B8;color:#0F172A;">$(& $t 'Mail.Need')</p>
  </td></tr>
$steps
  <tr><td style="padding:18px 28px 6px 28px;">
    <div style="padding:12px 14px;background:#DCFCE7;border-left:4px solid #16A34A;font-size:14px;line-height:21px;color:#166534;font-weight:600;">$(& $t 'Mail.Done')</div>
  </td></tr>
  <tr><td style="padding:12px 28px 6px 28px;">
    <div style="padding:12px 14px;background:#FEF3C7;border-left:4px solid #D97706;font-size:14px;line-height:21px;color:#92400E;">
      <b>$(& $t 'Mail.Fallback.Title')</b><br>$(& $t 'Mail.Fallback.Text')
    </div>
  </td></tr>
  <tr><td style="padding:18px 28px 24px 28px;font-size:14px;line-height:21px;color:#242424;">
    <p style="margin:0 0 4px 0;">$(& $t 'Mail.Closing')</p>
    <p style="margin:0;font-weight:600;">$(& $t 'Mail.Signature')$(if ($organization) { "<br><span style=`"font-weight:400;color:#64748B;`">$(ConvertTo-HtmlText $organization)</span>" })</p>
  </td></tr>
  <tr><td style="padding:14px 28px;border-top:1px solid #E1E5EA;font-size:12px;line-height:18px;color:#64748B;">
    $(& $t 'Mail.Security')<br>$(& $t 'Mail.Note')
  </td></tr>
</table>
</td></tr></table>
</body></html>
"@

    $images = foreach ($file in Get-ChildItem -LiteralPath $script:ImageFolder -Filter '*.png' | Sort-Object Name) {
        if ($html.Contains("cid:$($file.Name)")) {
            [pscustomobject]@{ Name = $file.Name; ContentId = $file.Name; Path = $file.FullName }
        }
    }

    [pscustomobject]@{
        Subject  = Get-LanguageText -Language $Language -Key 'Mail.Subject'
        Html     = $html
        Images   = @($images)
        Language = $Language
    }
}

function Get-M365MfaGuidePreviewHtml {
    <#
    .SYNOPSIS
        HTML for the preview in the tool: images as data: URIs instead of cid: references.
    #>
    param([Parameter(Mandatory)]$Mail)
    $html = $Mail.Html
    foreach ($image in $Mail.Images) {
        $data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($image.Path))
        $html = $html.Replace("cid:$($image.ContentId)", "data:image/png;base64,$data")
    }
    $html
}

function Get-M365MfaGuideScopes {
    <#
    .SYNOPSIS
        Permissions for sending (own mailbox or shared mailbox) and storing the sending date.
    #>
    param([bool]$SharedMailbox)
    @(
        'Mail.Send'
        if ($SharedMailbox) { 'Mail.Send.Shared' }
        'User.ReadWrite.All'   # Open extension on the user object
    )
}

function Send-M365MfaGuideMail {
    <#
    .SYNOPSIS
        Sends the guide via Graph from the given mailbox (own or shared mailbox with Send As permission).
    #>
    param(
        [Parameter(Mandatory)][string]$Sender,
        [Parameter(Mandatory)]$Recipient,
        [Parameter(Mandatory)]$Mail
    )

    $attachments = foreach ($image in $Mail.Images) {
        @{
            '@odata.type' = '#microsoft.graph.fileAttachment'
            name          = $image.Name
            contentType   = 'image/png'
            contentId     = $image.ContentId
            isInline      = $true
            contentBytes  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($image.Path))
        }
    }
    $body = @{
        message = @{
            subject      = $Mail.Subject
            body         = @{ contentType = 'HTML'; content = $Mail.Html }
            toRecipients = @(@{ emailAddress = @{ address = $Recipient.Mail; name = $Recipient.DisplayName } })
            attachments  = @($attachments)
        }
        saveToSentItems = $true
    }
    Invoke-M365GraphRequest -Method POST -Uri "v1.0/users/$([uri]::EscapeDataString($Sender))/sendMail" -Body $body | Out-Null
}

#endregion

Export-ModuleMember -Function @(
    'Get-M365MfaGuideExtensionName'
    'ConvertTo-M365MfaGuideInfo'
    'Get-M365MfaGuideInfo'
    'Set-M365MfaGuideInfo'
    'Get-M365MfaGuideRecipient'
    'New-M365MfaGuideMail'
    'Get-M365MfaGuidePreviewHtml'
    'Get-M365MfaGuideScopes'
    'Send-M365MfaGuideMail'
)
