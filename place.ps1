# Reads setblock command files and sends them to a Minecraft window automatically.
#
# Usage:
#   .\place.ps1 -FilePath commands.txt
#   .\place.ps1 -FilePath commands_0_0.txt -Delay 300
#   .\place.ps1 -FilePath "commands_*.txt" -Delay 250 -WindowTitle "Minecraft"
#   .\place.ps1 -FilePath commands.txt -StartDelay 5
#   .\place.ps1 -FilePath commands\ -DryRun
#   .\place.ps1 -FilePath commands\ -ClearArea

param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    # Milliseconds to wait between each command (increase if blocks are missing)
    [int]$Delay = 800,

    # Add this value to setblock Y coordinates before sending (default lifts builds by 1)
    [int]$YOffset = 1,

    # Seconds to pause between files; press Q during countdown to abort
    [int]$InterFilePause = 5,

    # Clear a 128 x Y x 128 build volume with air before placing blocks
    [switch]$ClearArea,

    # Height (Y) for clear volume; default 32 clears ~0..~31
    [int]$ClearHeight = 0,

    # Relative minimum Y used by clear volume before YOffset is applied
    [int]$ClearStartY = 0,

    # Milliseconds to wait after each clear-pass /fill command (0 = use Delay)
    [int]$FillDelay = 0,

    # Send each clear-pass /fill command twice for reliability
    [switch]$RepeatFill,

    # Seconds to count down before starting (gives you time to switch to Minecraft)
    [int]$StartDelay = 5,

    # Partial window title to search for (case-insensitive)
    [string]$WindowTitle = "Minecraft",

    # Optional selector used for teleport commands (empty = teleport self)
    [string]$TeleportTarget = "",

    # Print commands without sending key input
    [switch]$DryRun
)

#region --- Win32 API ---

if (-not ("Win32" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class Win32 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    public static List<IntPtr> FindWindowsByTitle(string partialTitle) {
        var matches = new List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new System.Text.StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.ToString().IndexOf(partialTitle, StringComparison.OrdinalIgnoreCase) >= 0)
                matches.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return matches;
    }

    // INPUT struct for SendInput
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx, dy, mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const ushort VK_RETURN = 0x0D;
    public const ushort VK_SLASH  = 0xBF;
    public const ushort VK_T      = 0x54;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static void SendKey(ushort vk) {
        var inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = vk;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = vk;
        inputs[1].u.ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // Type a string of Unicode characters via SendInput
    public static void TypeString(string text) {
        var inputs = new INPUT[text.Length * 2];
        for (int i = 0; i < text.Length; i++) {
            inputs[i*2].type = INPUT_KEYBOARD;
            inputs[i*2].u.ki.wVk = 0;
            inputs[i*2].u.ki.wScan = (ushort)text[i];
            inputs[i*2].u.ki.dwFlags = KEYEVENTF_UNICODE;

            inputs[i*2+1].type = INPUT_KEYBOARD;
            inputs[i*2+1].u.ki.wVk = 0;
            inputs[i*2+1].u.ki.wScan = (ushort)text[i];
            inputs[i*2+1].u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@ -ReferencedAssemblies System.Collections
}

#endregion

#region --- Find files ---


# Support region-split files (e.g., commands_0_0.txt, commands_1_1.txt) and wildcards
$resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
$files    = @(Get-Item $resolved -ErrorAction SilentlyContinue)

if ($files.Count -eq 1 -and $files[0].PSIsContainer) {
    $files = @(Get-ChildItem -Path $files[0].FullName -File | Sort-Object Name)
}

if ($files.Count -eq 0) {
    # Try as wildcard (e.g., commands_*.txt)
    $files = @(Get-ChildItem (Split-Path $resolved -Parent) -Filter (Split-Path $resolved -Leaf) | Sort-Object Name)
}
if ($files.Count -eq 0) {
    Write-Error "No files found matching: $FilePath"
    exit 1
}

$totalCommands = 0
foreach ($f in $files) {
    $lineCount = (Get-Content $f.FullName | Where-Object { $_ -match '\S' } | Measure-Object).Count
    $totalCommands += $lineCount
    Write-Host "Loaded $lineCount commands from $($f.Name)" -ForegroundColor DarkCyan
}

Write-Host ""
Write-Host "Total files to send    : $($files.Count)" -ForegroundColor Cyan
Write-Host "Total commands to send : $totalCommands" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "Mode                  : DRY RUN (no key input)" -ForegroundColor Yellow
}

if ($ClearArea -and $ClearHeight -le 0) {
    $ClearHeight = 32
}

if ($ClearArea) {
    Write-Host ("Clear volume           : 128 x {0} x 128" -f $ClearHeight) -ForegroundColor Cyan
    Write-Host ("Clear Y range          : {0}..{1} (includes YOffset)" -f ($ClearStartY + $YOffset), ($ClearStartY + $YOffset + $ClearHeight - 1)) -ForegroundColor Cyan
}

function Get-FileOffset {
    param([string]$Name)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($baseName -match '^(-?\d+)_(-?\d+)_(-?\d+)(?:_.+)?$') {
        return [pscustomobject]@{
            X = [int]$matches[1]
            Y = [int]$matches[2]
            Z = [int]$matches[3]
        }
    }

    return $null
}

#endregion

#region --- Find Minecraft window ---

$hwnd = [IntPtr]::Zero
if (-not $DryRun) {
    $windows = [Win32]::FindWindowsByTitle($WindowTitle)
    if ($windows.Count -eq 0) {
        Write-Error "No window found with title containing '$WindowTitle'. Make sure Minecraft is running."
        exit 1
    }

    $hwnd = $windows[0]
    $sb   = [System.Text.StringBuilder]::new(256)
    [Win32]::GetWindowText($hwnd, $sb, 256) | Out-Null
    Write-Host "Found window  : '$($sb.ToString())'" -ForegroundColor Cyan
    Write-Host ""
}

#endregion

#region --- Countdown ---

if (-not $DryRun) {
    Write-Host "Switch to Minecraft now! Starting in..." -ForegroundColor Yellow
    for ($i = $StartDelay; $i -gt 0; $i--) {
        Write-Host "  $i..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host "  GO!" -ForegroundColor Green
    Write-Host ""
}

#endregion

#region --- Send commands ---

$sent   = 0
$errors = 0
$total  = $totalCommands
$script:currentOffset = [pscustomobject]@{ X = 0; Y = 0; Z = 0 }
$abortRequested = $false
$effectiveFillDelay = if ($FillDelay -gt 0) { $FillDelay } else { $Delay }

function Send-CommandToMinecraft {
    param([string]$CommandLine)

    $line = $CommandLine.Trim()
    if (-not $line) { return }
    $line = '/' + $line.TrimStart('/')

    if ($DryRun) {
        Write-Host "DRYRUN: $line" -ForegroundColor DarkYellow
        return
    }

    Write-Host "Sending: $line" -ForegroundColor Gray

    if ([Win32]::IsIconic($hwnd)) { [Win32]::ShowWindow($hwnd, 9) }  # SW_RESTORE = 9
    [Win32]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 30

    # Open chat with T so the command text determines exactly one leading '/'.
    [Win32]::SendKey([Win32]::VK_T)
    Start-Sleep -Milliseconds 80
    [Win32]::TypeString($line)

    # /fill lines are longer; give chat input more time before pressing Enter.
    if ($line.StartsWith('/fill ')) {
        Start-Sleep -Milliseconds 220
    } else {
        Start-Sleep -Milliseconds 80
    }

    [Win32]::SendKey([Win32]::VK_RETURN)
}

function Move-ToOffset {
    param(
        [int]$TargetX,
        [int]$TargetY,
        [int]$TargetZ
    )

    $dx = $TargetX - $script:currentOffset.X
    $dy = $TargetY - $script:currentOffset.Y
    $dz = $TargetZ - $script:currentOffset.Z

    Write-Host ("Teleporting by offset: dx={0}, dy={1}, dz={2}" -f $dx, $dy, $dz) -ForegroundColor DarkCyan

    if ($dx -eq 0 -and $dy -eq 0 -and $dz -eq 0) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($TeleportTarget)) {
        $tpLine = "/tp ~$dx ~$dy ~$dz"
    } else {
        $tpLine = "/tp $TeleportTarget ~$dx ~$dy ~$dz"
    }

    Send-CommandToMinecraft -CommandLine $tpLine
    Start-Sleep -Milliseconds ([Math]::Max(250, $Delay))

    $script:currentOffset = [pscustomobject]@{ X = $TargetX; Y = $TargetY; Z = $TargetZ }
}

if ($ClearArea) {
    Write-Host ""
    Write-Host "=== Clear Pass (128xYx128) ===" -ForegroundColor Yellow

    $clearMinY = $ClearStartY + $YOffset
    $clearMaxY = $clearMinY + $ClearHeight - 1

    for ($chunkX = 0; $chunkX -lt 128; $chunkX += 32) {
        for ($chunkZ = 0; $chunkZ -lt 128; $chunkZ += 32) {
            # Keep each fill under Bedrock volume limits by slicing vertically into 32-high bands.
            for ($y1 = $clearMinY; $y1 -le $clearMaxY; $y1 += 32) {
                # Teleport before every clear command so each /fill is anchored after a fresh /tp.
                Move-ToOffset -TargetX $chunkX -TargetY 0 -TargetZ $chunkZ
                Start-Sleep -Milliseconds 180

                $y2 = [Math]::Min($y1 + 31, $clearMaxY)
                $clearCmd = "/fill ~0 ~$y1 ~0 ~31 ~$y2 ~31 air"
                Send-CommandToMinecraft -CommandLine $clearCmd
                if ($RepeatFill) {
                    Start-Sleep -Milliseconds 220
                    Send-CommandToMinecraft -CommandLine $clearCmd
                }
                Start-Sleep -Milliseconds $effectiveFillDelay
            }
        }
    }

    Write-Host ""
    Write-Host "Clear pass complete. Exiting without placing blocks." -ForegroundColor Green
    exit 0
}

for ($fileIndex = 0; $fileIndex -lt $files.Count; $fileIndex++) {
    $f = $files[$fileIndex]
    Write-Host ""
    Write-Host "=== File $($fileIndex + 1)/$($files.Count): $($f.Name) ===" -ForegroundColor Yellow

    $targetOffset = Get-FileOffset -Name $f.Name
    if ($null -eq $targetOffset) {
        Write-Warning "Could not parse XYZ offset from filename '$($f.Name)'. Skipping file."
        continue
    }

    Move-ToOffset -TargetX $targetOffset.X -TargetY $targetOffset.Y -TargetZ $targetOffset.Z

    $fileCommands = @(Get-Content $f.FullName | Where-Object { $_ -match '\S' })
    foreach ($cmd in $fileCommands) {
        $line = $cmd.Trim()
        if (-not $line) { continue }

        # Shift setblock coordinates upward by the configured Y offset.
        if ($line -match '^/?setblock\s+~(-?\d+)\s+~(-?\d+)\s+~(-?\d+)\s+(.+)$') {
            $x = [int]$matches[1]
            $y = [int]$matches[2]
            $z = [int]$matches[3]
            $rest = $matches[4]
            $adjY = $y + $YOffset
            $line = "setblock ~$x ~$adjY ~$z $rest"
        }

        Send-CommandToMinecraft -CommandLine $line

        $sent++
        $pct = if ($total -gt 0) { [int](($sent / $total) * 100) } else { 100 }
        Write-Progress -Activity "Sending commands to Minecraft" `
                       -Status "$sent / $total  ($pct%)" `
                       -PercentComplete $pct `
                       -CurrentOperation $line

        Start-Sleep -Milliseconds $Delay
    }

    if ($fileIndex -lt ($files.Count - 1) -and $InterFilePause -gt 0) {
        Write-Host ""
        Write-Host "Press Q to abort, or wait to continue..." -ForegroundColor Yellow

        for ($remaining = $InterFilePause; $remaining -gt 0; $remaining--) {
            Write-Host -NoNewline "`rNext file in $remaining second(s)   "
            $nextTick = (Get-Date).AddSeconds(1)

            while ((Get-Date) -lt $nextTick) {
                try {
                    if ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true)
                        if ($key.Key -eq 'Q') {
                            $abortRequested = $true
                            break
                        }
                    }
                } catch {
                    # Fallback for non-interactive hosts.
                }

                Start-Sleep -Milliseconds 50
            }

            if ($abortRequested) { break }
        }

        Write-Host ""
        if ($abortRequested) {
            Write-Warning "Aborted by user between files."
            break
        }
    }
}

Write-Progress -Activity "Sending commands to Minecraft" -Completed

#endregion

Write-Host ""
Write-Host "Done. Sent $sent commands ($errors errors)." -ForegroundColor Green
