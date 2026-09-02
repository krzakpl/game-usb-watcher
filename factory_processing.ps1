
# ============================================================
# CONFIGURATION
# ============================================================

$UsbSerial    = "1038CA6E"
$FactorioPath = "G:\factorio\bin\x64\factorio.exe"
$TimeoutMin   = 30

# Check interval in milliseconds
$CheckIntervalMs = 100

# ============================================================
# WINDOWS API
# ============================================================

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Win32
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetVolumeInformation(
        string lpRootPathName,
        StringBuilder lpVolumeNameBuffer,
        int nVolumeNameSize,
        out uint lpVolumeSerialNumber,
        out uint lpMaximumComponentLength,
        out uint lpFileSystemFlags,
        StringBuilder lpFileSystemNameBuffer,
        int nFileSystemNameSize
    );

    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(
        uint dwDesiredAccess,
        bool bInheritHandle,
        uint dwProcessId
    );

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(IntPtr ProcessHandle);

    [DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(IntPtr ProcessHandle);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(
        EnumWindowsProc lpEnumFunc,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint lpdwProcessId
    );

    public delegate bool EnumWindowsProc(
        IntPtr hWnd,
        IntPtr lParam
    );

    public const int SW_HIDE = 0;
    public const int SW_RESTORE = 9;

    public const uint PROCESS_SUSPEND_RESUME = 0x0800;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;

    public static string GetSerial(string root)
    {
        uint serial;
        uint maxLength;
        uint flags;

        StringBuilder volumeName = new StringBuilder(261);
        StringBuilder fileSystem = new StringBuilder(261);

        bool ok = GetVolumeInformation(
            root,
            volumeName,
            volumeName.Capacity,
            out serial,
            out maxLength,
            out flags,
            fileSystem,
            fileSystem.Capacity
        );

        if (!ok)
            return null;

        return serial.ToString("X8");
    }

    public static bool Suspend(uint pid)
    {
        IntPtr h = OpenProcess(
            PROCESS_SUSPEND_RESUME | PROCESS_QUERY_INFORMATION,
            false,
            pid
        );

        if (h == IntPtr.Zero)
            return false;

        int result = NtSuspendProcess(h);

        CloseHandle(h);

        return result == 0;
    }

    public static bool Resume(uint pid)
    {
        IntPtr h = OpenProcess(
            PROCESS_SUSPEND_RESUME | PROCESS_QUERY_INFORMATION,
            false,
            pid
        );

        if (h == IntPtr.Zero)
            return false;

        int result = NtResumeProcess(h);

        CloseHandle(h);

        return result == 0;
    }

    public static void HideWindows(uint pid)
    {
        EnumWindows(
            delegate(IntPtr hwnd, IntPtr lParam)
            {
                uint windowPid;
                GetWindowThreadProcessId(hwnd, out windowPid);

                if (windowPid == pid)
                    ShowWindow(hwnd, SW_HIDE);

                return true;
            },
            IntPtr.Zero
        );
    }

    public static void ShowWindows(uint pid)
    {
        EnumWindows(
            delegate(IntPtr hwnd, IntPtr lParam)
            {
                uint windowPid;
                GetWindowThreadProcessId(hwnd, out windowPid);

                if (windowPid == pid)
                    ShowWindow(hwnd, SW_RESTORE);

                return true;
            },
            IntPtr.Zero
        );
    }
}
"@

# ============================================================
# FIND USB DRIVE BY VOLUME SERIAL
# ============================================================

function Find-USB
{
    $disks = Get-CimInstance Win32_LogicalDisk

    foreach ($disk in $disks)
    {
        if (-not $disk.DeviceID)
        {
            continue
        }

        $root = $disk.DeviceID + "\"

        try
        {
            $serial = [Win32]::GetSerial($root)
        }
        catch
        {
            continue
        }

        if ($serial -and $serial.ToUpper() -eq $UsbSerial.ToUpper())
        {
            return $root
        }
    }

    return $null
}

# ============================================================
# FIND FACTORIO PROCESS
# ============================================================

function Get-FactorioProcess
{
    return Get-Process -Name "factorio" -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

# ============================================================
# START FACTORIO
# ============================================================

function Start-Factorio
{
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path -PathType Leaf))
    {
        Write-Host ""
        Write-Host "ERROR: Factorio was not found:" -ForegroundColor Red
        Write-Host $Path
        Write-Host ""
        return $null
    }

    Write-Host "[FACTORIO] Starting..." -ForegroundColor Green

    $workingDir = Split-Path $Path -Parent

    $process = Start-Process `
        -FilePath $Path `
        -WorkingDirectory $workingDir `
        -PassThru

    return $process
}

# ============================================================
# STARTUP
# ============================================================

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "       FACTORIO USB CONTROLLER" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "USB serial : $UsbSerial"
Write-Host "Factorio   : $FactorioPath"
Write-Host "Timeout    : $TimeoutMin minutes"
Write-Host ""

if (-not (Test-Path $FactorioPath -PathType Leaf))
{
    Write-Host "ERROR: Factorio path does not exist!" -ForegroundColor Red
    Write-Host $FactorioPath
    Write-Host ""

    Read-Host "Press ENTER to exit"
    exit
}

Write-Host "Controller is running..." -ForegroundColor Cyan
Write-Host ""

# ============================================================
# STATE
# ============================================================

$factorioPid = $null
$frozen = $false
$removedAt = $null
$lastUsbPresent = $false

# ============================================================
# MAIN LOOP
# ============================================================

while ($true)
{
    try
    {
        $usb = Find-USB

        $usbPresent = $null -ne $usb

        # ----------------------------------------------------
        # USB CONNECTED
        # ----------------------------------------------------

        if ($usbPresent)
        {
            if (-not $lastUsbPresent)
            {
                Write-Host "[USB] Connected: $usb" -ForegroundColor Green
            }

            # Find existing Factorio
            if (-not $factorioPid)
            {
                $existing = Get-FactorioProcess

                if ($existing)
                {
                    $factorioPid = $existing.Id

                    Write-Host "[FACTORIO] Existing process PID: $factorioPid"
                }
            }

            # Start Factorio
            if (-not $factorioPid)
            {
                $process = Start-Factorio $FactorioPath

                if ($process)
                {
                    $factorioPid = $process.Id

                    Write-Host "[FACTORIO] PID: $factorioPid" -ForegroundColor Green
                }
            }

            # Resume frozen Factorio
            if ($frozen)
            {
                $processExists = Get-Process `
                    -Id $factorioPid `
                    -ErrorAction SilentlyContinue

                if ($processExists)
                {
                    Write-Host "[RESUME] Resuming Factorio..." -ForegroundColor Green

                    [Win32]::Resume([uint32]$factorioPid)

                    Start-Sleep -Milliseconds 100

                    [Win32]::ShowWindows([uint32]$factorioPid)

                    Write-Host "[RESUME] Done." -ForegroundColor Green

                    $frozen = $false
                    $removedAt = $null
                }
                else
                {
                    Write-Host "[RESUME] Factorio process no longer exists." `
                        -ForegroundColor Red

                    $factorioPid = $null
                    $frozen = $false
                    $removedAt = $null
                }
            }
        }

        # ----------------------------------------------------
        # USB DISCONNECTED
        # ----------------------------------------------------

        else
        {
            if ($lastUsbPresent)
            {
                Write-Host "[USB] Disconnected" -ForegroundColor Yellow
            }

            if ($factorioPid)
            {
                $processExists = Get-Process `
                    -Id $factorioPid `
                    -ErrorAction SilentlyContinue

                if ($processExists)
                {
                    # Freeze
                    if (-not $frozen)
                    {
                        Write-Host "[FREEZE] Hiding Factorio..." `
                            -ForegroundColor Yellow

                        [Win32]::HideWindows([uint32]$factorioPid)

                        Write-Host "[FREEZE] Suspending process..." `
                            -ForegroundColor Yellow

                        $success = [Win32]::Suspend([uint32]$factorioPid)

                        if ($success)
                        {
                            Write-Host "[FREEZE] Frozen in RAM." `
                                -ForegroundColor Green

                            $frozen = $true
                            $removedAt = Get-Date
                        }
                        else
                        {
                            Write-Host "[FREEZE] Failed to suspend process!" `
                                -ForegroundColor Red
                        }
                    }

                    # Timeout
                    if ($frozen)
                    {
                        $elapsedMinutes =
                            ((Get-Date) - $removedAt).TotalMinutes

                        if ($elapsedMinutes -ge $TimeoutMin)
                        {
                            Write-Host ""
                            Write-Host "[TIMEOUT] Timeout reached." `
                                -ForegroundColor Red

                            Write-Host "[TIMEOUT] Closing Factorio..." `
                                -ForegroundColor Red

                            [Win32]::Resume([uint32]$factorioPid)

                            Start-Sleep -Milliseconds 100

                            Stop-Process `
                                -Id $factorioPid `
                                -Force `
                                -ErrorAction SilentlyContinue

                            Write-Host "[TIMEOUT] Factorio closed." `
                                -ForegroundColor Green

                            $factorioPid = $null
                            $frozen = $false
                            $removedAt = $null
                        }
                    }
                }
                else
                {
                    Write-Host "[FACTORIO] Process ended." `
                        -ForegroundColor DarkYellow

                    $factorioPid = $null
                    $frozen = $false
                    $removedAt = $null
                }
            }
        }

        $lastUsbPresent = $usbPresent
    }
    catch
    {
        Write-Host ""
        Write-Host "ERROR:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
    }

    Start-Sleep -Milliseconds $CheckIntervalMs
}

