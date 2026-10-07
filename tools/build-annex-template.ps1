# Gumagawa ng malinis na templates/annex-a.xlsx mula sa blankong Annex A ng user.
# Tinatanggal: external link, lahat ng formula (+ cached #REF!/#VALUE!), pangalan ng signatory sa A47, mga pangalan sa docProps.
# Hindi ginagalaw: styles, merges, column widths, logos, page setup.
param([string]$Src, [string]$Out)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$enc = New-Object Text.UTF8Encoding $false

$fs = [IO.File]::Open($Src, 'Open', 'Read', 'ReadWrite')
$zin = New-Object IO.Compression.ZipArchive($fs, 'Read')
$parts = [ordered]@{}
foreach ($e in $zin.Entries) {
  if ($e.FullName -like 'xl/externalLinks/*' -or $e.FullName.EndsWith('/')) { continue }
  $s = $e.Open(); $ms = New-Object IO.MemoryStream; $s.CopyTo($ms); $s.Dispose()
  $parts[$e.FullName] = $ms.ToArray()
}
$zin.Dispose(); $fs.Dispose()
function T($n){ $enc.GetString($parts[$n]) }
function SetT($n, $v){ $parts[$n] = $enc.GetBytes($v) }

# workbook: walang external reference; pangalan ng sheet → "ANNEX A"
$wb = T 'xl/workbook.xml'
$wb = $wb -replace '<externalReferences>.*?</externalReferences>', ''
$wb = $wb.Replace('name="ANNEX A (2)"', 'name="ANNEX A"').Replace("'ANNEX A (2)'!", "'ANNEX A'!")
SetT 'xl/workbook.xml' $wb
SetT 'xl/_rels/workbook.xml.rels' ((T 'xl/_rels/workbook.xml.rels') -replace '<Relationship [^>]*relationships/externalLink"[^>]*/>', '')
SetT '[Content_Types].xml' ((T '[Content_Types].xml') -replace '<Override PartName="/xl/externalLinks/[^"]*"[^>]*/>', '')

# sheet: alisin ang lahat ng formula at cached value nito; A47 (pangalan ng signatory) → blangko
$sh = T 'xl/worksheets/sheet1.xml'
$a47 = [regex]::Match($sh, '<c r="A47"[^>]*t="s"[^>]*><v>(\d+)</v></c>')
$sh = [regex]::Replace($sh, '<c r="([A-Z]+\d+)"( s="\d+")?[^>/]*>(?:(?!</c>).)*?<f[ >/](?:(?!</c>).)*</c>', '<c r="$1"$2/>')
$sh = [regex]::Replace($sh, '<c r="A47"( s="\d+")?[^>/]*>.*?</c>', '<c r="A47"$1/>')
$sh = $sh -replace '<selection [^>]*/>', '<selection activeCell="A1" sqref="A1"/>'
SetT 'xl/worksheets/sheet1.xml' $sh

# sharedStrings: burahin ang text ng dating A47
if ($a47.Success) {
  $ss = T 'xl/sharedStrings.xml'; $idx = [int]$a47.Groups[1].Value; $i = -1
  $ss = [regex]::Replace($ss, '<si>.*?</si>', { param($m) $script:i++; if ($script:i -eq $idx) { '<si><t></t></si>' } else { $m.Value } })
  SetT 'xl/sharedStrings.xml' $ss
}

# docProps: walang pangalan ng tao
$core = T 'docProps/core.xml'
$core = $core -replace '<dc:creator>.*?</dc:creator>', '<dc:creator>ReconciliationPro</dc:creator>'
$core = $core -replace '<cp:lastModifiedBy>.*?</cp:lastModifiedBy>', '<cp:lastModifiedBy>ReconciliationPro</cp:lastModifiedBy>'
SetT 'docProps/core.xml' $core

if (Test-Path $Out) { Remove-Item $Out -Force -Confirm:$false }
$zo = [IO.Compression.ZipFile]::Open($Out, 'Create')
$order = @('[Content_Types].xml') + ($parts.Keys | Where-Object { $_ -ne '[Content_Types].xml' })
foreach ($n in $order) {
  $e = $zo.CreateEntry($n, 'Optimal'); $s = $e.Open(); $s.Write($parts[$n], 0, $parts[$n].Length); $s.Dispose()
}
$zo.Dispose()

# Pagsusuri
$chk = (T 'xl/worksheets/sheet1.xml')
"formulas left: " + ([regex]::Matches($chk, '<f[ >/]')).Count
"A47: " + [regex]::Match($chk, '<c r="A47"[^>]*/?>').Value
"external refs in workbook: " + ((T 'xl/workbook.xml') -match 'externalReference')
"parts: " + ($parts.Keys -join ', ')
