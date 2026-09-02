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
$TargetUSBSerialNumber = "1038CA6E"                              # SERIAL pendrive'a
$FailsafeMinutes = 30                                            # Timeout przed wyłączeniem gry
$LogFile = "$env:TEMP\game-usb-watcher.log"
# ==================================================

$global:GameProcess = $null
$global:GamePID = $null
$global:IsSuspended = $false
$global:FailsafeTimer = $null
$global:LastUSBState = $false

# P/Invoke
$Win32Source = @"
using System;
using System.Runtime.InteropServices;

public class GameUSB {
    [DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(IntPtr processHandle);

    [DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(IntPtr processHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(int access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

Add-Type -TypeDefinition $Win32Source -ErrorAction SilentlyContinue

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
        # Szuka urządzenia USB po Serial Number
        $usbDevices = Get-WmiObject Win32_USBControllerDevice -ErrorAction SilentlyContinue
        
        if ($usbDevices) {
            foreach ($device in $usbDevices) {
                $deviceID = $device.Dependent
                
                # Wyciągnij Device ID z kwalifikatora
                if ($deviceID -match 'DeviceID="(.+)"') {
                    $devID = $matches[1]
                    
                    # Szukaj w Device Manager za pomocą PnP entity
                    $pnpEntity = Get-WmiObject Win32_PnPEntity -Filter "DeviceID='$devID'" -ErrorAction SilentlyContinue
                    
                    if ($pnpEntity) {
                        # Sprawdzenie serial number w nazwie urządzenia lub Description
                        if ($pnpEntity.Name -like "*$TargetUSBSerialNumber*" -or 
                            $pnpEntity.Description -like "*$TargetUSBSerialNumber*") {
                            return $true
                        }
                    }
                }
            }
        }
        
        # Alternatywna metoda - szukaj w logicznych dysków
        $volumes = Get-WmiObject Win32_Volume -ErrorAction SilentlyContinue | 
            Where-Object { $_.DriveType -eq 2 }  # 2 = Removable Media
        
        foreach ($vol in $volumes) {
            if ($vol.Name -like "*$TargetUSBSerialNumber*") {
                return $true
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
            $global:GameProcess = Start-Process -FilePath $GameExecutablePath -WorkingDirectory $dir -PassThru -ErrorAction Stop
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
        [GameUSB]::ShowWindowAsync($proc.MainWindowHandle, $SW_HIDE) | Out-Null
        Start-Sleep -Milliseconds 100
    }

    # Zamróź proces
    $handle = [GameUSB]::OpenProcess($PROCESS_SUSPEND_RESUME, $false, $global:GamePID)
    if ($handle -ne [IntPtr]::Zero) {
        [GameUSB]::NtSuspendProcess($handle) | Out-Null
        [GameUSB]::CloseHandle($handle) | Out-Null
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
    $handle = [GameUSB]::OpenProcess($PROCESS_SUSPEND_RESUME, $false, $global:GamePID)
    if ($handle -ne [IntPtr]::Zero) {
        [GameUSB]::NtResumeProcess($handle) | Out-Null
        [GameUSB]::CloseHandle($handle) | Out-Null
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
            [GameUSB]::ShowWindowAsync($procCheck.MainWindowHandle, $SW_RESTORE) | Out-Null
            [GameUSB]::SetForegroundWindow($procCheck.MainWindowHandle) | Out-Null
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
Write-Log "USB Serial: $TargetUSBSerialNumber"
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
} -ErrorAction SilentlyContinue

# Główna pętla
while ($true) {
    try {
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
    } catch {
        Write-Log "✗ Błąd w main loop: $_"
    }

    Start-Sleep -Milliseconds 500
}
