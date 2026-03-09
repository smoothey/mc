# Reads setblock command files and sends them to a Minecraft window automatically.
#
# Usage:
#   .\place.ps1 -FilePath commands.txt
#   .\place.ps1 -FilePath commands_batch01.txt -Delay 300
#   .\place.ps1 -FilePath "commands_batch*.txt" -Delay 250 -WindowTitle "Minecraft"
#   .\place.ps1 -FilePath commands.txt -StartDelay 5

param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    # Milliseconds to wait between each command (increase if blocks are missing)
    [int]$Delay = 200,

    # Seconds to count down before starting (gives you time to switch to Minecraft)
    [int]$StartDelay = 3,

    # Partial window title to search for (case-insensitive)
    [string]$WindowTitle = "Minecraft"
)

#region --- Win32 API ---

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

#endregion

#region --- Find files ---

$resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
$files    = @(Get-Item $resolved -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    # Try as wildcard
    $files = @(Get-ChildItem (Split-Path $resolved -Parent) -Filter (Split-Path $resolved -Leaf) | Sort-Object Name)
}
if ($files.Count -eq 0) {
    Write-Error "No files found matching: $FilePath"
    exit 1
}

$allCommands = [System.Collections.Generic.List[string]]::new()
foreach ($f in $files) {
    $lines = Get-Content $f.FullName | Where-Object { $_ -match '\S' }
    $allCommands.AddRange($lines)
    Write-Host "Loaded $($lines.Count) commands from $($f.Name)" -ForegroundColor DarkCyan
}
Write-Host ""
Write-Host "Total commands to send : $($allCommands.Count)" -ForegroundColor Cyan

#endregion

#region --- Find Minecraft window ---

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

#endregion

#region --- Countdown ---

Write-Host "Switch to Minecraft now! Starting in..." -ForegroundColor Yellow
for ($i = $StartDelay; $i -gt 0; $i--) {
    Write-Host "  $i..." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
}
Write-Host "  GO!" -ForegroundColor Green
Write-Host ""

#endregion

#region --- Send commands ---

$sent   = 0
$errors = 0
$total  = $allCommands.Count

foreach ($cmd in $allCommands) {
    $line = $cmd.Trim()
    if (-not $line) { continue }

    # Ensure it starts with /
    if (-not $line.StartsWith('/')) { $line = '/' + $line }

    # Restore Minecraft window and bring to foreground
    if ([Win32]::IsIconic($hwnd)) { [Win32]::ShowWindow($hwnd, 9) }  # SW_RESTORE = 9
    [Win32]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 30

    # Open chat with / then type the rest of the command, then Enter
    [Win32]::SendKey([Win32]::VK_SLASH)        # opens chat + types "/"
    Start-Sleep -Milliseconds 80
    [Win32]::TypeString($line.Substring(1))    # rest of command (without leading /)
    Start-Sleep -Milliseconds 50
    [Win32]::SendKey([Win32]::VK_RETURN)       # submit

    $sent++
    $pct = [int](($sent / $total) * 100)
    Write-Progress -Activity "Sending commands to Minecraft" `
                   -Status "$sent / $total  ($pct%)" `
                   -PercentComplete $pct `
                   -CurrentOperation $line

    Start-Sleep -Milliseconds $Delay
}

Write-Progress -Activity "Sending commands to Minecraft" -Completed

#endregion

Write-Host ""
Write-Host "Done. Sent $sent commands ($errors errors)." -ForegroundColor Green
