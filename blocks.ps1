# Parse a Minecraft .mcstructure file (Bedrock Edition little-endian NBT)
# and output each block with its position and state parameters.
#
# Usage:
#   .\blocks.ps1 -FilePath "mystructure.mcstructure"
#   .\blocks.ps1 -FilePath "mystructure.mcstructure" -SkipAir
#   .\blocks.ps1 -FilePath "mystructure.mcstructure" -PaletteOnly
#   .\blocks.ps1 -FilePath "mystructure.mcstructure" -SkipAir -OutputFile commands.txt
#   .\blocks.ps1 -FilePath "mystructure.mcstructure" -SkipAir -OutputFile commands.txt -BatchSize 50 -Prefix

param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    # Skip air / structure_void blocks in the block grid output
    [switch]$SkipAir,

    # Only show the block palette; do not enumerate every position
    [switch]$PaletteOnly,

    # Optional file path to write setblock commands to (e.g. commands.txt)
    [string]$OutputFile,

    # Split output into multiple files of this many commands each (requires -OutputFile)
    [int]$BatchSize = 0,

    # Prepend '/' to every command so it can be pasted directly into the Minecraft console
    [switch]$Prefix
)

#region --- Binary reader helpers (little-endian) ---

$script:data = $null
$script:pos  = 0

function script:ReadByte   { $b = $script:data[$script:pos]; $script:pos++; return [int]$b }
function script:ReadSByte  { $b = $script:data[$script:pos]; $script:pos++; return [sbyte]$b }

function script:ReadInt16 {
    $v = [BitConverter]::ToInt16($script:data, $script:pos); $script:pos += 2; return $v
}
function script:ReadUInt16 {
    $v = [BitConverter]::ToUInt16($script:data, $script:pos); $script:pos += 2; return $v
}
function script:ReadInt32 {
    $v = [BitConverter]::ToInt32($script:data, $script:pos); $script:pos += 4; return $v
}
function script:ReadInt64 {
    $v = [BitConverter]::ToInt64($script:data, $script:pos); $script:pos += 8; return $v
}
function script:ReadFloat {
    $v = [BitConverter]::ToSingle($script:data, $script:pos); $script:pos += 4; return $v
}
function script:ReadDouble {
    $v = [BitConverter]::ToDouble($script:data, $script:pos); $script:pos += 8; return $v
}

function script:ReadNbtString {
    $len = ReadUInt16
    if ($len -eq 0) { return "" }
    $str = [System.Text.Encoding]::UTF8.GetString($script:data, $script:pos, $len)
    $script:pos += $len
    return $str
}

#endregion

#region --- NBT tag parser ---

# NBT tag type constants
Set-Variable -Name TAG_End        -Value  0 -Option Constant
Set-Variable -Name TAG_Byte       -Value  1 -Option Constant
Set-Variable -Name TAG_Short      -Value  2 -Option Constant
Set-Variable -Name TAG_Int        -Value  3 -Option Constant
Set-Variable -Name TAG_Long       -Value  4 -Option Constant
Set-Variable -Name TAG_Float      -Value  5 -Option Constant
Set-Variable -Name TAG_Double     -Value  6 -Option Constant
Set-Variable -Name TAG_ByteArray  -Value  7 -Option Constant
Set-Variable -Name TAG_String     -Value  8 -Option Constant
Set-Variable -Name TAG_List       -Value  9 -Option Constant
Set-Variable -Name TAG_Compound   -Value 10 -Option Constant
Set-Variable -Name TAG_IntArray   -Value 11 -Option Constant
Set-Variable -Name TAG_LongArray  -Value 12 -Option Constant

function script:ReadTagPayload([int]$type) {
    switch ($type) {
        $TAG_Byte      { return ReadSByte }
        $TAG_Short     { return ReadInt16 }
        $TAG_Int       { return ReadInt32 }
        $TAG_Long      { return ReadInt64 }
        $TAG_Float     { return ReadFloat }
        $TAG_Double    { return ReadDouble }

        $TAG_ByteArray {
            $count = ReadInt32
            $arr = [byte[]]::new($count)
            [System.Buffer]::BlockCopy($script:data, $script:pos, $arr, 0, $count)
            $script:pos += $count
            return ,$arr
        }

        $TAG_String    { return ReadNbtString }

        $TAG_List {
            $elemType = ReadByte
            $count    = ReadInt32
            $list     = [System.Collections.Generic.List[object]]::new($count)
            for ($i = 0; $i -lt $count; $i++) {
                $list.Add((ReadTagPayload $elemType))
            }
            return ,$list
        }

        $TAG_Compound {
            $map = [ordered]@{}
            while ($true) {
                $childType = ReadByte
                if ($childType -eq $TAG_End) { break }
                $childName = ReadNbtString
                $map[$childName] = ReadTagPayload $childType
            }
            return $map
        }

        $TAG_IntArray {
            $count = ReadInt32
            $arr   = [int[]]::new($count)
            for ($i = 0; $i -lt $count; $i++) { $arr[$i] = ReadInt32 }
            return ,$arr
        }

        $TAG_LongArray {
            $count = ReadInt32
            $arr   = [long[]]::new($count)
            for ($i = 0; $i -lt $count; $i++) { $arr[$i] = ReadInt64 }
            return ,$arr
        }

        default { throw "Unknown NBT tag type: $type at byte offset $script:pos" }
    }
}

function script:ParseNbtRoot {
    $type = ReadByte
    if ($type -eq $TAG_End) { return $null }
    $name = ReadNbtString          # root tag name (usually empty string)
    $payload = ReadTagPayload $type
    return [pscustomobject]@{ Name = $name; Value = $payload }
}

#endregion

#region --- State formatting helpers ---

function Format-States([object]$states) {
    if (-not $states -or $states.Count -eq 0) { return "" }
    $parts = foreach ($key in $states.Keys) {
        $val = $states[$key]
        # Booleans stored as TAG_Byte 0/1
        if ($val -is [sbyte] -or $val -is [byte]) {
            "${key}=$([bool][int]$val)".ToLower()
        } else {
            "${key}=$val"
        }
    }
    return " [" + ($parts -join ", ") + "]"
}

# Formats block states as a Bedrock /setblock command state argument:
#   ["key"=value, ...]  strings quoted, ints bare, bytes as true/false
function Format-SetblockStates([object]$states) {
    if (-not $states -or $states.Count -eq 0) { return "" }
    $parts = foreach ($key in $states.Keys) {
        $val = $states[$key]
        if ($val -is [sbyte] -or $val -is [byte]) {
            # output byte as 0/1
            '"' + $key + '"=' + ([int]$val)
        } elseif ($val -is [int] -or $val -is [long] -or $val -is [short]) {
            '"' + $key + '"=' + $val
        } else {
            # string
            '"' + $key + '"="' + $val + '"'
        }
    }
    return " [" + ($parts -join ",") + "]"
}

#endregion

#region --- Main ---

# Resolve files to process (single file, directory, or wildcard)
if (Test-Path $FilePath -PathType Container) {
    $filesToProcess = @(Get-ChildItem -Path $FilePath -Filter '*.mcstructure' | Select-Object -ExpandProperty FullName)
} elseif ($FilePath -match '[*?]') {
    $filesToProcess = @(Resolve-Path $FilePath | Select-Object -ExpandProperty Path)
} else {
    if (-not (Test-Path $FilePath)) {
        Write-Error "File not found: $FilePath"
        exit 1
    }
    $filesToProcess = @((Resolve-Path $FilePath).Path)
}

if ($filesToProcess.Count -eq 0) {
    Write-Error "No .mcstructure files found at: $FilePath"
    exit 1
}

$totalCommandsAll = 0

foreach ($currentFilePath in $filesToProcess) {

$script:data = [System.IO.File]::ReadAllBytes($currentFilePath)
$script:pos  = 0

Write-Host ""
Write-Host "File   : $currentFilePath" -ForegroundColor Cyan
Write-Host "Size   : $([Math]::Round($script:data.Length / 1KB, 1)) KB" -ForegroundColor Cyan
Write-Host ""

# Parse the root NBT compound
$root = ParseNbtRoot
if (-not $root) { Write-Error "Failed to parse NBT root."; exit 1 }
$nbt = $root.Value

# --- Structure dimensions ---
$sizeList = $nbt['size']
$sx = [int]$sizeList[0]
$sy = [int]$sizeList[1]
$sz = [int]$sizeList[2]

Write-Host ("Dimensions : {0} x {1} x {2}  ({3} blocks)" -f $sx, $sy, $sz, ($sx * $sy * $sz)) -ForegroundColor Yellow
Write-Host ""

# --- Block palette ---
$palette = $nbt['structure']['palette']['default']['block_palette']

Write-Host "=== Block Palette ($($palette.Count) entries) ===" -ForegroundColor Green
Write-Host ""

$paletteTable = foreach ($i in 0..($palette.Count - 1)) {
    $entry  = $palette[$i]
    $name   = $entry['name']
    $states = $entry['states']
    [pscustomobject]@{
        Index  = $i
        Block  = $name
        States = if ($states -and $states.Count -gt 0) {
                     ($states.Keys | ForEach-Object { "$_=$($states[$_])" }) -join ", "
                 } else { "(none)" }
    }
}
$paletteTable | Format-Table -AutoSize

if ($PaletteOnly) { exit 0 }

# --- Block grid ---
$blockIndices = $nbt['structure']['block_indices']
$primary      = $blockIndices[0]   # layer 0 – solid blocks
$waterlog     = $blockIndices[1]   # layer 1 – waterlogged / liquid layer

Write-Host "=== Setblock Commands ===" -ForegroundColor Green
Write-Host ""

$airNames = @('minecraft:air', 'minecraft:structure_void')

$commands = [System.Collections.Generic.List[string]]::new()

for ($x = 0; $x -lt $sx; $x++) {
    for ($y = 0; $y -lt $sy; $y++) {
        for ($z = 0; $z -lt $sz; $z++) {
            $linearIdx   = ($x * $sz * $sy) + ($y * $sx) + $z
            $paletteIdx  = [int]$primary[$linearIdx]

            if ($paletteIdx -lt 0 -or $paletteIdx -ge $palette.Count) { continue }

            $entry     = $palette[$paletteIdx]
            $blockName = $entry['name']

            if ($SkipAir -and $blockName -in $airNames) { continue }

            $states   = $entry['states']
            $stateStr = Format-SetblockStates $states

            $cmdPrefix = if ($Prefix) { '/' } else { '' }
            $cmd = $cmdPrefix + "setblock ~$x ~$y ~$z $blockName$stateStr replace"
            $commands.Add($cmd)
            #Write-Host $cmd

            # Waterlog layer — emit a second setblock if occupied
            $wlogIdx  = [int]$waterlog[$linearIdx]
            if ($wlogIdx -ge 0 -and $wlogIdx -lt $palette.Count) {
                $wlogName = $palette[$wlogIdx]['name']
                if ($wlogName -notin $airNames) {
                    $wlogStates = $palette[$wlogIdx]['states']
                    $wlogStateStr = Format-SetblockStates $wlogStates
                    $wCmd = $cmdPrefix + "setblock ~$x ~$y ~$z $wlogName$wlogStateStr replace"
                    $commands.Add($wCmd)
                    #Write-Host $wCmd
                }
            }
        }
    }
}


if ($OutputFile) {
    $outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
    $base    = [System.IO.Path]::GetFileNameWithoutExtension($outPath)
    $ext     = [System.IO.Path]::GetExtension($outPath)
    $dir     = [System.IO.Path]::GetDirectoryName($outPath)

    # Prepare four lists for 32x32 x/z areas
    $areaCommands = @{
        '0_0' = [System.Collections.Generic.List[string]]::new()
        '0_1' = [System.Collections.Generic.List[string]]::new()
        '1_0' = [System.Collections.Generic.List[string]]::new()
        '1_1' = [System.Collections.Generic.List[string]]::new()
    }


    foreach ($cmd in $commands) {
        # Extract x, y, z from command string
        if ($cmd -match 'setblock ~([0-9]+) ~([0-9]+) ~([0-9]+) ') {
            $x = [int]$matches[1]
            $y = [int]$matches[2]
            $z = [int]$matches[3]
            $areaX = if ($x -lt 32) { 0 } else { 1 }
            $areaZ = if ($z -lt 32) { 0 } else { 1 }
            $areaKey = "$areaX`_$areaZ"

            # Calculate relative coordinates for each area
            $relX = $x
            $relZ = $z
            if ($areaX -eq 1) { $relX = $x - 32 }
            if ($areaZ -eq 1) { $relZ = $z - 32 }

            # Compose new command with relative coordinates
            $cmdPrefix = if ($Prefix) { '/' } else { '' }
            $cmdParts = $cmd -split ' '
            $blockCmd = $cmdParts[0]
            $blockY = $cmdParts[2]
            $blockRest = $cmdParts[4..($cmdParts.Count-1)] -join ' '
            $newCmd = "$cmdPrefix$blockCmd ~${relX} $blockY ~${relZ} $blockRest"
            #Write-Host $blockRest
            $areaCommands[$areaKey].Add($newCmd)
        }
    }

    foreach ($area in $areaCommands.Keys) {
        # Calculate block offset for filename
        $offsetX = if ($area -eq '0_0' -or $area -eq '0_1') { 0 } else { 32 }
        $offsetZ = if ($area -eq '0_0' -or $area -eq '1_0') { 0 } else { 32 }
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($currentFilePath)
        # For 64x64, offsets are 0 or 32, so add to base coordinates
        if ($baseName -match '^(\d+)_(\d+)_(\d+)_(.+)$') {
            $baseX = [int]$matches[1]
            $baseY = [int]$matches[2]
            $baseZ = [int]$matches[3]
            $namePart = $matches[4]
        } else {
            $baseX = 0; $baseY = 0; $baseZ = 0; $namePart = $baseName
        }
        # Map areaKey to correct offset
        if ($area -eq '0_0') {
            $outX = $baseX; $outY = $baseY; $outZ = $baseZ;
        } elseif ($area -eq '1_0') {
            $outX = $baseX + 32; $outY = $baseY; $outZ = $baseZ;
        } elseif ($area -eq '0_1') {
            $outX = $baseX; $outY = $baseY; $outZ = $baseZ + 32;
        } elseif ($area -eq '1_1') {
            $outX = $baseX + 32; $outY = $baseY; $outZ = $baseZ + 32;
        }
        $fileName    = "${outX}_${outY}_${outZ}_${namePart}${ext}"
        $outFilePath = [System.IO.Path]::Combine($dir, $fileName)
        $areaCommands[$area] | Set-Content -Path $outFilePath -Encoding UTF8
        Write-Host ("Area {0} ({1} commands) -> {2}" -f "$offsetX,0,$offsetZ", $areaCommands[$area].Count, $outFilePath) -ForegroundColor Cyan
    }
}

    $totalCommandsAll += $commands.Count

} # end foreach $currentFilePath

Write-Host ""
Write-Host ("Total commands output : {0}" -f $totalCommandsAll) -ForegroundColor Cyan
Write-Host "Done." -ForegroundColor Cyan

#endregion
