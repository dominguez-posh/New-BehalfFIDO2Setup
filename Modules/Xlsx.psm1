<#
.SYNOPSIS
    Minimal .xlsx writer of the M365 MFA Administration Tool.

.DESCRIPTION
    Writes Excel workbooks directly as Office Open XML (ZIP with XML parts), so neither Excel
    nor an additional PowerShell module is required. Supports text, numbers and dates,
    fixed cell styles (header, traffic light colors, bold), column widths, a frozen header
    row and an autofilter.
#>

Set-StrictMode -Version Latest

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

Export-ModuleMember -Function 'ConvertTo-XlsxColumnName', 'New-XlsxSheetXml', 'Save-XlsxWorkbook'
