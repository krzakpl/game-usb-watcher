<#
.SYNOPSIS
    USB Game Watcher - Automatyczne uruchamianie/zawieszanie gry na wyjęciu/włożeniu pendrive'a

.DESCRIPTION
    Wsadzasz pendrive -> gra się odpala
    Wyjmujesz pendrive -> gra zamraża się w RAM (0% CPU, stan zachowany)
    Wsadzasz z powrotem -> wraca dokładnie tam gdzie była
    30 minut bez pendrive'a -> gra się wyłącza na dobre

.EXAMPLE
    .\game-usb-watcher.ps1
#>

# ================= KONFIGURACJA =================
$GameExecutablePath = "C:\Games\Factorio\bin\x64\factorio.exe"  # ZMIEŃ NA SWOJĄ GRĘ
$TargetUSBDeviceID = "USB\VID_1234&PID_5678"                    # ZMIEŃ NA ID SWOJEGO PENDRIVE'A (zobacz instrukcję poniżej)
$FailsafeMinutes = 30                                            # Timeout przed wyłączeniem gry
$LogFile = "$env:TEMP\game-usb-watcher.log"
# ==================================================
# INSTRUKCJA: Aby znaleźć ID pendrive'a, uruchom w PowerShell (jako admin):
#
# Get-WmiObject Win32_USBControllerDevice | ForEach-Object { 
#     $_.Dependent -match 'DeviceID="(.+)"' | Out-Null; 
#     $matches[1] 
# } | Get-Unique
#
# Lub w Device Manager: Pendrive → Properties → Details → Hardware IDs
# ==================================================

$global:GameProcess = $null
$global:GamePID = $null
$global:IsSuspended = $false
$global:FailsafeTimer = $null
$global:USBPresent = $false
$global:LastUSBState = $false

# P/Invoke do NtSuspendProcess i NtResumeProcess
Add-Type -Name Win32 -Namespace GameUSB -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(System.IntPtr processHandle);

    [System.Runtime.InteropServices.DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(System.IntPtr processHandle);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    public static extern System.IntPtr OpenProcess(int access, bool inherit, int pid);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(System.IntPtr handle);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(System.IntPtr hWnd);
#>

$PROCESS_SUSPEND_RESUME = 0x0800
$SW_RESTORE = 9
$SW_HIDE = 0

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    Write-Host $logLine -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
}

function Test-USBPresent {
    try {
        # Szuka urządzenia USB po Device ID w rejestrze
        $usbDevices = Get-WmiObject Win32_PnPEntity | Where-Object { 
            $_.DeviceID -like "*$TargetUSBDeviceID*" 
        }
        
        if ($usbDevices) {
            # Sprawdzenie czy urządzenie jest dostępne (ConfigManagerErrorCode = 0)
            foreach ($device in $usbDevices) {
                $pnpDevice = Get-WmiObject Win32_PnPDevice -Filter "DeviceID='$($device.DeviceID)'" -ErrorAction SilentlyContinue
                if ($pnpDevice -and $pnpDevice.ConfigManagerErrorCode -eq 0) {
                    return $true
                }
            }
        }
        
        return $false
    } catch {
        Write-Log "✗ Błąd podczas sprawdzania USB: $_"
        return $false
    }
}

function Start-Game {
    if (Test-Path $GameExecutablePath) {
        try {
            $dir = Split-Path $GameExecutablePath -Parent
            $global:GameProcess = Start-Process -FilePath $GameExecutablePath -WorkingDirectory $dir -PassThru
            $global:GamePID = $global:GameProcess.Id
            $global:IsSuspended = $false
            Write-Log "✓ Gra uruchomiona (PID: $($global:GamePID))"
            return $true
        } catch {
            Write-Log "✗ Błąd uruchamiania gry: $_"
            return $false
        }
    } else {
        Write-Log "✗ Nie znaleziono pliku: $GameExecutablePath"
        return $false
    }
}

function Suspend-Game {
    if ($null -eq $global:GamePID -or $global:IsSuspended) {
        return
    }

    $proc = Get-Process -Id $global:GamePID -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        $global:GameProcess = $null
        $global:GamePID = $null
        return
    }

    # Schowaj okno
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        [GameUSB.Win32]::ShowWindowAsync($proc.MainWindowHandle, $SW_HIDE) | Out-Null
        Start-Sleep -Milliseconds 100
    }

    # Zamróź proces
    $handle = [GameUSB.Win32]::OpenProcess($PROCESS_SUSPEND_RESUME, $false, $global:GamePID)
    if ($handle -ne [IntPtr]::Zero) {
        [GameUSB.Win32]::NtSuspendProcess($handle) | Out-Null
        [GameUSB.Win32]::CloseHandle($handle) | Out-Null
        $global:IsSuspended = $true
        Write-Log "❄ Gra zamrożona w RAM (PID: $($global:GamePID))"
    } else {
        Write-Log "✗ Nie udało się otworzyć procesu - uruchom PowerShell jako Administrator"
    }
}

function Resume-Game {
    if ($null -eq $global:GamePID -or -not $global:IsSuspended) {
        return
    }

    $proc = Get-Process -Id $global:GamePID -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        $global:GameProcess = $null
        $global:GamePID = $null
        $global:IsSuspended = $false
        return
    }

    # Wznów proces
    $handle = [GameUSB.Win32]::OpenProcess($PROCESS_SUSPEND_RESUME, $false, $global:GamePID)
    if ($handle -ne [IntPtr]::Zero) {
        [GameUSB.Win32]::NtResumeProcess($handle) | Out-Null
        [GameUSB.Win32]::CloseHandle($handle) | Out-Null
        $global:IsSuspended = $false
        
        # Czekaj na stabilizację procesu
        Start-Sleep -Milliseconds 500
        
        # Sprawdzenie czy proces przetrwał
        $procCheck = Get-Process -Id $global:GamePID -ErrorAction SilentlyContinue
        if ($null -eq $procCheck) {
            Write-Log "✗ Proces padł przy wznawianiu, uruchamiam od nowa..."
            $global:GameProcess = $null
            $global:GamePID = $null
            Start-Game
            return
        }

        # Pokaż okno
        if ($procCheck.MainWindowHandle -ne [IntPtr]::Zero) {
            [GameUSB.Win32]::ShowWindowAsync($procCheck.MainWindowHandle, $SW_RESTORE) | Out-Null
            [GameUSB.Win32]::SetForegroundWindow($procCheck.MainWindowHandle) | Out-Null
        }
        
        Write-Log "▶ Gra wznowiona (PID: $($global:GamePID))"
    } else {
        Write-Log "✗ Nie udało się otworzyć procesu przy wznawianiu"
    }
}

function Stop-Failsafe {
    if ($global:FailsafeTimer) {
        $global:FailsafeTimer.Stop()
        $global:FailsafeTimer.Dispose()
        Unregister-Event -SourceIdentifier GameUSBFailsafe -ErrorAction SilentlyContinue
        $global:FailsafeTimer = $null
        Write-Log "⏱ Failsafe anulowany"
    }
}

function Start-Failsafe {
    Stop-Failsafe
    
    $timer = New-Object System.Timers.Timer
    $timer.Interval = $FailsafeMinutes * 60 * 1000
    $timer.AutoReset = $false
    
    $action = {
        Write-Log "⏱ Failsafe! Pendrive nie wrócił w ciągu $FailsafeMinutes minut - wyłączam grę"
        if ($null -ne $global:GamePID) {
            $proc = Get-Process -Id $global:GamePID -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $global:GamePID -Force -ErrorAction SilentlyContinue
            }
        }
        $global:GameProcess = $null
        $global:GamePID = $null
        $global:IsSuspended = $false
    }
    
    Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier GameUSBFailsafe -Action $action | Out-Null
    $timer.Start()
    $global:FailsafeTimer = $timer
    Write-Log "⏱ Failsafe uzbrojony na $FailsafeMinutes minut"
}

# ================= MAIN LOOP =================

Write-Log "=== USB Game Watcher uruchomiony ==="
Write-Log "Gra: $GameExecutablePath"
Write-Log "USB Device ID: $TargetUSBDeviceID"
Write-Log "Failsafe timeout: $FailsafeMinutes minut"
Write-Log "Log: $LogFile"
Write-Log ""

# Obsługa sygnału zamknięcia
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Log "Watcher się wyłącza..."
    Stop-Failsafe
    if ($global:IsSuspended -and $null -ne $global:GamePID) {
        Resume-Game
    }
}

# Główna pętla
while ($true) {
    $USBNow = Test-USBPresent
    
    if ($USBNow -and -not $global:LastUSBState) {
        # ========== WŁOŻONO PENDRIVE ==========
        Write-Log "🔌 Pendrive włożony!"
        $global:LastUSBState = $true
        Stop-Failsafe
        
        if ($null -eq $global:GamePID) {
            # Gra nie była uruchomiona - start
            Start-Game
        } elseif ($global:IsSuspended) {
            # Gra była zamrożona - resume
            Resume-Game
        }
    }
    elseif (-not $USBNow -and $global:LastUSBState) {
        # ========== WYJĘTO PENDRIVE ==========
        Write-Log "🔌 Pendrive wyjęty!"
        $global:LastUSBState = $false
        
        if ($null -ne $global:GamePID -and -not $global:IsSuspended) {
            Suspend-Game
            Start-Failsafe
        }
    }

    # Sprawdzenie czy gra się nie padła sama
    if ($null -ne $global:GamePID) {
        $proc = Get-Process -Id $global:GamePID -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
            Write-Log "⚠ Gra się wyłączyła samodzielnie"
            $global:GameProcess = $null
            $global:GamePID = $null
            $global:IsSuspended = $false
            Stop-Failsafe
        }
    }

    Start-Sleep -Milliseconds 500
}
