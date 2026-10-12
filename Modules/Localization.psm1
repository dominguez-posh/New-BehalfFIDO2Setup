<#
.SYNOPSIS
    Localization of the M365 MFA Administration Tool.

.DESCRIPTION
    Texts are stored as JSON per language in Languages\<code>.json (e.g. en.json, de.json).
    English is the reference: if a text is missing in a language, the English one is used.
    Placeholders {0}, {1}, ... are filled with the passed arguments.
#>

Set-StrictMode -Version Latest

$script:LanguagePath = $null
$script:Language = 'en'
$script:Strings = @{}
$script:Fallback = @{}

# Order in the language selection: English, German, then alphabetical
$script:PreferredOrder = @('en', 'de')

function Import-LanguageFile {
    param([Parameter(Mandatory)][string]$Path)
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $table = @{}
    foreach ($property in $json.PSObject.Properties) { $table[$property.Name] = [string]$property.Value }
    $table
}

function Initialize-Localization {
    <#
    .SYNOPSIS
        Loads the English reference texts and activates the requested language.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Language = 'en'
    )
    $script:LanguagePath = $Path
    $script:Fallback = Import-LanguageFile -Path (Join-Path $Path 'en.json')
    Set-UiLanguage -Language $Language
}

function Set-UiLanguage {
    <#
    .SYNOPSIS
        Activates a language; unknown languages fall back to English.
    #>
    param([Parameter(Mandatory)][string]$Language)
    $file = Join-Path $script:LanguagePath "$Language.json"
    if (-not (Test-Path -LiteralPath $file)) {
        $Language = 'en'
        $file = Join-Path $script:LanguagePath 'en.json'
    }
    $script:Strings = Import-LanguageFile -Path $file
    $script:Language = $Language
}

function Get-UiLanguage {
    $script:Language
}

function Get-UiLanguages {
    <#
    .SYNOPSIS
        Returns all available languages (code and name in the respective language).
    #>
    Get-ChildItem -LiteralPath $script:LanguagePath -Filter '*.json' |
        ForEach-Object {
            $strings = Import-LanguageFile -Path $_.FullName
            [pscustomobject]@{
                Code = $_.BaseName
                Name = if ($strings.ContainsKey('_language')) { $strings['_language'] } else { $_.BaseName }
            }
        } |
        Sort-Object @{ Expression = { $index = $script:PreferredOrder.IndexOf($_.Code); if ($index -ge 0) { $index } else { 99 } } }, Name
}

function Test-UiText {
    param([Parameter(Mandatory)][string]$Key)
    $script:Strings.ContainsKey($Key) -or $script:Fallback.ContainsKey($Key)
}

function T {
    <#
    .SYNOPSIS
        Returns the text for a key in the active language, optionally with placeholders.
    .EXAMPLE
        T 'Log.UsersFound' 3
    #>
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1, ValueFromRemainingArguments)][object[]]$Arguments
    )
    $text = if ($script:Strings.ContainsKey($Key) -and $script:Strings[$Key]) { $script:Strings[$Key] }
            elseif ($script:Fallback.ContainsKey($Key)) { $script:Fallback[$Key] }
            else { $Key }
    if ($Arguments -and $Arguments.Count) { return ($text -f $Arguments) }
    $text
}

Export-ModuleMember -Function Initialize-Localization, Set-UiLanguage, Get-UiLanguage, Get-UiLanguages, Test-UiText, T
