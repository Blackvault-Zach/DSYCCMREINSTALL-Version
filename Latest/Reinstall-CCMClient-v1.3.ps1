<#
.SYNOPSIS
    SCCM Client full reinstall with requirements check, health check, and resume support.
.PARAMETER Resume
    Switch to resume from saved state after reboot.
.NOTES
    Version: 1.2.0
#>
param([switch]$Resume, [switch]$SkipChecks)

#Requires -RunAsAdministrator

$ScriptVersion = "1.2.0"

# ── Prevent sleep, disable Quick Edit Mode, disable close button, block Ctrl+C ─
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class PowerMgmt {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
}
public class ConsoleHelper {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
    [DllImport("user32.dll")] public static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);
}
"@ -ErrorAction SilentlyContinue

# Prevent sleep (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
try { [PowerMgmt]::SetThreadExecutionState(0x80000003) | Out-Null } catch {}

# Disable Quick Edit Mode so console doesn't pause on click
try {
    $handle = [ConsoleHelper]::GetStdHandle(-10) # STD_INPUT_HANDLE
    $mode = 0
    [ConsoleHelper]::GetConsoleMode($handle, [ref]$mode) | Out-Null
    $mode = $mode -band (-bnot 0x0040) # Remove ENABLE_QUICK_EDIT_MODE
    [ConsoleHelper]::SetConsoleMode($handle, $mode) | Out-Null
} catch {}

# Disable the window close button (X) and Alt+F4
try {
    $hwnd = [ConsoleHelper]::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        $sysMenu = [ConsoleHelper]::GetSystemMenu($hwnd, $false)
        if ($sysMenu -ne [IntPtr]::Zero) {
            [ConsoleHelper]::DeleteMenu($sysMenu, 0xF060, 0x00000000) | Out-Null # SC_CLOSE
        }
    }
} catch {}

# Block Ctrl+C / Ctrl+Break so the script cannot be interrupted mid-run
try { [Console]::TreatControlCAsInput = $true } catch {}

# ── Single instance lock ──────────────────────────────────────────────────────
$script:InstanceMutex = $null
try {
    $script:InstanceMutex = New-Object System.Threading.Mutex($false, "Global\CCMReinstallToolMutex")
    if (-not $script:InstanceMutex.WaitOne(0)) {
        Write-Host ""
        Write-Host "  This tool is already running in another window." -ForegroundColor Red
        Write-Host "  Please close that window first, or wait for it to finish." -ForegroundColor Red
        Write-Host ""
        Read-Host "  Press Enter to close"
        exit 1
    }
} catch {}

# ── Verify running from the expected location ─────────────────────────────────
$expectedDir = "C:\Temp\SoftwareCenter\CurrentVersion"
$actualDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($actualDir.TrimEnd('\') -ne $expectedDir.TrimEnd('\')) {
    Write-Host ""
    Write-Host "  This script must be run from: $expectedDir" -ForegroundColor Red
    Write-Host "  It is currently running from: $actualDir" -ForegroundColor Red
    Write-Host "  Extract the full SoftwareCenter folder to C:\Temp\ and run it from there." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

# ── Config ────────────────────────────────────────────────────────────────────
$InstallPath        = "C:\Temp\SoftwareCenter\ccmsetup.exe"
$UninstallPath      = "C:\Temp\SoftwareCenter\ccmsetup.exe"   # always launch uninstall from source copy
$LocalCcmsetupExe   = "C:\Windows\ccmsetup\ccmsetup.exe"       # informational only - not used for decisions
$CMClientInstall    = "C:\Temp\SoftwareCenter\CMClientInstall.exe"
$CCMCab             = "C:\Temp\SoftwareCenter\ccmsetup.cab"
$CMClientInstallWse = "C:\Temp\SoftwareCenter\CMClientInstall.wse"
$I386Dir            = "C:\Temp\SoftwareCenter\i386"
$X64Dir             = "C:\Temp\SoftwareCenter\x64"
$ConfigDir          = "C:\Temp\SoftwareCenter\Config"
$CmdLineConfigPath  = "$ConfigDir\CmdLine.txt"
$UpdateSourcePath   = "$ConfigDir\UpdateSource.txt"
$CCMLog             = "C:\Windows\ccmsetup\Logs\ccmsetup.log"
$LogsDir            = "C:\Temp\SoftwareCenter\Logs"
$ScriptLog          = "$LogsDir\CCMReinstall.log"
$LogArchiveDir      = "$LogsDir\CCMReinstall-Logs"
$SummaryFile        = "$LogsDir\CCMReinstall-Summary.txt"
$StateFile          = "C:\Windows\Temp\CCMReinstall.json"
$ScriptPath         = $MyInvocation.MyCommand.Path
$TaskName           = "CCMClientReinstall"
$PSExe              = if (Get-Command "pwsh.exe" -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }

# Ensure the local Logs folder exists before anything tries to write to it
try { New-Item -Path $LogsDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null } catch {}

function Invoke-LogRotation {
    param([int]$KeepCount = 15)
    try {
        if (Test-Path $LogArchiveDir) {
            $old = Get-ChildItem -Path $LogArchiveDir -Filter "ccmsetup_*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip $KeepCount
            foreach ($f in $old) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}
Invoke-LogRotation -KeepCount 15
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    try {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $ScriptLog -Value "[$ts] [$Level] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

function Initialize-Summary {
    param([string]$Mode)
    try {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $header = "================================================================`r`nCCM Reinstall Tool - Run Summary`r`nVersion: $ScriptVersion`r`nSession: $Mode`r`nStarted: $ts`r`n================================================================"
        Add-Content -Path $SummaryFile -Value $header -ErrorAction SilentlyContinue
    } catch {}
}

function Add-Summary {
    param([string]$Message)
    try {
        $ts = Get-Date -Format "HH:mm:ss"
        Add-Content -Path $SummaryFile -Value "[$ts] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

function Set-Status {
    param([string]$Message, [string]$Color = "White")
    $padded = "  $Message".PadRight([Console]::WindowWidth - 1)
    if ($padded.Length -ge [Console]::WindowWidth) { $padded = $padded.Substring(0, [Console]::WindowWidth - 1) }
    Write-Host "`r$padded" -NoNewline -ForegroundColor $Color
}

function Write-StatusLine {
    param([string]$Message, [string]$Color = "White")
    Write-Host "`r$(" " * ([Console]::WindowWidth - 1))" -NoNewline
    Write-Host "`r  $Message" -ForegroundColor $Color
}

function Write-Banner {
    param([string]$Title, [string]$Color = "Cyan")
    $width = 52
    $line  = "=" * $width
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host "  $Title" -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
}

function Write-PhaseHeader {
    param([int]$Phase, [int]$Total, [string]$Title)
    Write-Host ""
    Write-Host "------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  PHASE $Phase / $Total  -  $Title" -ForegroundColor Cyan
    Write-Host "------------------------------------------------" -ForegroundColor DarkCyan
}

function Get-CcmExecStatus {
    try {
        $svc = Get-Service -Name "CcmExec" -ErrorAction SilentlyContinue
        if ($null -eq $svc) { return "NotFound" }
        return $svc.Status.ToString()
    } catch {
        return "NotFound"
    }
}

function Clear-CCMLog {
    param([string]$Label = "Unknown")

    try {
        if (Test-Path $CCMLog) {

            # Archive the existing log before wiping it, and verify the copy completed
            try {
                New-Item -Path $LogArchiveDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                $ts = Get-Date -Format "yyyyMMdd-HHmmss"
                $archivePath = Join-Path $LogArchiveDir "ccmsetup_${Label}_${ts}.log"

                Set-Status "Archiving previous log ($Label)..." Cyan
                Copy-Item -Path $CCMLog -Destination $archivePath -Force -ErrorAction Stop

                $verifyTries = 0
                $sourceLen = (Get-Item $CCMLog -ErrorAction SilentlyContinue).Length
                while ($verifyTries -lt 10) {
                    $destLen = (Get-Item $archivePath -ErrorAction SilentlyContinue).Length
                    if ($destLen -eq $sourceLen -and $destLen -ne $null) { break }
                    Start-Sleep -Milliseconds 200
                    $verifyTries++
                }

                if ((Get-Item $archivePath -ErrorAction SilentlyContinue).Length -eq $sourceLen) {
                    Write-Log "Archived previous log to: $archivePath"
                } else {
                    Write-Log "WARNING: Log archive size mismatch for: $archivePath" "WARN"
                }
            } catch {
                Write-Log "Could not archive previous log: $_" "WARN"
            }

            Set-Status "Clearing ccmsetup log..." Cyan
            Clear-Content -Path $CCMLog -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            $content = Get-Content $CCMLog -ErrorAction SilentlyContinue
            if ($content -and $content.Count -gt 0) {
                Write-StatusLine "ERROR: Could not clear ccmsetup log. Is another ccmsetup process running?" Red
                Write-Log "Failed to clear ccmsetup log." "ERROR"
                Read-Host "`n  Press Enter to close"
                exit 1
            }
            Write-StatusLine "Log cleared and verified empty." Green
            Write-Log "ccmsetup log cleared and verified."
        } else {
            Write-StatusLine "No existing ccmsetup log found - starting fresh." Cyan
            Write-Log "No existing ccmsetup log found."
        }
    } catch {
        Write-StatusLine "ERROR: Could not clear ccmsetup log: $_" Red
        Write-Log "Exception clearing log: $_" "ERROR"
        Read-Host "`n  Press Enter to close"
        exit 1
    }
}

function Get-LogMessage {
    param([string]$Line)
    if ($Line -match '<!\[LOG\[(.*?)\]LOG\]') { return $matches[1].Trim() }
    return $Line.Trim()
}

function Get-InstallArgsFromConfig {
    if (-not (Test-Path $CmdLineConfigPath)) {
        Write-StatusLine "ERROR: Config\CmdLine.txt not found. Cannot determine install arguments." Red
        Write-Log "Missing $CmdLineConfigPath" "ERROR"
        Read-Host "`n  Press Enter to close"
        exit 1
    }
    try {
        $rawLine = Get-Content $CmdLineConfigPath -ErrorAction Stop | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
        if (-not $rawLine) {
            Write-StatusLine "ERROR: Config\CmdLine.txt is empty." Red
            Write-Log "Config\CmdLine.txt is empty." "ERROR"
            Read-Host "`n  Press Enter to close"
            exit 1
        }

        try {
            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rawLine.Trim()))
        } catch {
            Write-StatusLine "ERROR: Config\CmdLine.txt could not be decoded." Red
            Write-Log "Base64 decode failed for CmdLine.txt: $_" "ERROR"
            Read-Host "`n  Press Enter to close"
            exit 1
        }

        $trimmed = $decoded.Trim()
        $argsOnly = ($trimmed -replace '(?i)^ccmsetup\.exe\s*', '').Trim()
        if ($argsOnly -eq "") {
            Write-StatusLine "ERROR: Could not parse install arguments from Config\CmdLine.txt." Red
            Write-Log "Could not parse decoded CmdLine.txt content: '$trimmed'" "ERROR"
            Read-Host "`n  Press Enter to close"
            exit 1
        }
        Write-Log "Install args loaded from Config\CmdLine.txt."
        return $argsOnly
    } catch {
        Write-StatusLine "ERROR: Could not read Config\CmdLine.txt: $_" Red
        Write-Log "Exception reading CmdLine.txt: $_" "ERROR"
        Read-Host "`n  Press Enter to close"
        exit 1
    }
}

function Get-UpdateUrls {
    if (-not (Test-Path $UpdateSourcePath)) {
        Write-Log "Config\UpdateSource.txt not found - update check will be skipped." "WARN"
        return $null
    }
    try {
        $lines = Get-Content $UpdateSourcePath -ErrorAction Stop | Where-Object { $_.Trim() -ne "" }
        if ($lines.Count -eq 0) {
            Write-Log "Config\UpdateSource.txt is empty - update check will be skipped." "WARN"
            return $null
        }

        $values = @{}
        foreach ($line in $lines) {
            $parts = $line.Trim() -split ':', 2
            if ($parts.Count -ne 2) {
                Write-Log "Skipping malformed line in UpdateSource.txt (no label found): $line" "WARN"
                continue
            }
            $label = $parts[0].Trim().ToUpper()
            $encoded = $parts[1].Trim()
            try {
                $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
                $values[$label] = $decoded
            } catch {
                Write-Log "Could not decode UpdateSource.txt value for label '$label'." "WARN"
            }
        }

        if (-not $values.ContainsKey("VERSION") -or -not $values.ContainsKey("CHANGELOG")) {
            Write-Log "UpdateSource.txt missing required VERSION or CHANGELOG entry - update check will be skipped." "WARN"
            return $null
        }

        return [PSCustomObject]@{
            VersionUrl    = $values["VERSION"]
            ChangelogUrl  = $values["CHANGELOG"]
            UpdateListUrl = $(if ($values.ContainsKey("UPDATELIST")) { $values["UPDATELIST"] } else { $null })
            LatestBaseUrl = $(if ($values.ContainsKey("LATESTBASE")) { $values["LATESTBASE"] } else { $null })
        }
    } catch {
        Write-Log "Could not read UpdateSource.txt: $_ - update check will be skipped." "WARN"
        return $null
    }
}

# ── Wait-ForCompletion: used by UNINSTALL only ────────────────────────────────
function Wait-ForCompletion {
    param(
        [string]$Label,
        [string]$DesiredState,
        [switch]$AllowDefer
    )

    Write-Log "Waiting for '$Label' - desired state: $DesiredState"
    $timeout   = 3600
    $elapsed   = 0
    $reader    = $null
    $rc0Time   = $null
    $deferSecs = 120

    try {
        $logWait = 0
        while (-not (Test-Path $CCMLog) -and $logWait -lt 30) {
            Set-Status "[$Label] Waiting for log file..." Cyan
            Start-Sleep -Seconds 1
            $logWait++
        }

        if (Test-Path $CCMLog) {
            $fileStream = [System.IO.FileStream]::new($CCMLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = [System.IO.StreamReader]::new($fileStream)
        } else {
            Write-StatusLine "WARNING: [$Label] Log file never appeared. Continuing without log." Yellow
            Write-Log "[$Label] Log file never appeared." "WARN"
        }

        while ($elapsed -lt $timeout) {

            if ($reader -ne $null) {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    $msg  = Get-LogMessage -Line $line
                    if ($msg -ne "") {
                        Set-Status "[$Label] $msg" Cyan

                        if ($msg -match "CcmSetup is exiting with return code (\d+)" -and $matches[1] -ne "0") {
                            Write-StatusLine "ERROR: [$Label] Exited with return code $($matches[1])" Red
                            Write-Log "[$Label] Non-zero exit: $($matches[1])" "ERROR"
                            Read-Host "`n  Press Enter to close"
                            exit 1
                        }

                        if ($msg -match "CcmSetup is exiting with return code 0") {
                            Write-Log "[$Label] Return code 0 detected. Checking desired state: $DesiredState"
                            $ccmStatus = Get-CcmExecStatus

                            if ($DesiredState -eq "Gone") {
                                if ($rc0Time -eq $null) { $rc0Time = Get-Date }

                                if ($ccmStatus -eq "NotFound") {
                                    Write-StatusLine "[$Label] Return code 0 + CcmExec gone. Verifying in 5s..." Green
                                    Write-Log "[$Label] RC0 + gone. Verifying..."
                                    Start-Sleep -Seconds 5
                                    if ((Get-CcmExecStatus) -eq "NotFound") {
                                        Write-StatusLine "[$Label] Confirmed complete." Green
                                        Write-Log "[$Label] Verified gone. Complete."
                                        return $true
                                    } else {
                                        Write-StatusLine "[$Label] CcmExec reappeared - continuing..." Yellow
                                        Write-Log "[$Label] CcmExec reappeared after RC0 - resetting." "WARN"
                                    }
                                } else {
                                    Write-StatusLine "[$Label] RC0 but CcmExec still present ($ccmStatus). Continuing..." Yellow
                                    Write-Log "[$Label] RC0 ignored - CcmExec still present." "WARN"
                                }
                            }
                        }
                    }
                }
            }

            # Fallback: if RC0 was seen but CcmExec removal appears deferred to reboot,
            # don't wait forever - proceed after a reasonable grace period.
            # Only allowed on the first attempt (AllowDefer) - never on a retry.
            if ($AllowDefer -and $DesiredState -eq "Gone" -and $rc0Time -ne $null) {
                $sinceRC0 = ((Get-Date) - $rc0Time).TotalSeconds
                if ($sinceRC0 -ge $deferSecs -and (Get-CcmExecStatus) -ne "NotFound") {
                    Write-StatusLine "[$Label] CcmExec still present ${deferSecs}s after RC0 - removal appears deferred to reboot. Proceeding." Yellow
                    Write-Log "[$Label] CcmExec removal deferred to reboot - proceeding anyway." "WARN"
                    Add-Summary "NOTE: [$Label] CcmExec still present ${deferSecs}s after return code 0 - proceeded anyway (deferred-to-reboot fallback)."
                    return $true
                }
            }

            Start-Sleep -Milliseconds 500
            $elapsed += 0.5
        }

        Write-StatusLine "ERROR: [$Label] Timed out after $timeout seconds." Red
        Write-Log "[$Label] Timed out." "ERROR"
        Read-Host "`n  Press Enter to close"
        exit 1

    } finally {
        if ($reader -ne $null) { $reader.Close() }
    }
}

# ── Invoke-UninstallOnce: single uninstall attempt, returns final CcmExec status ─
function Invoke-UninstallOnce {
    param([string]$Label, [switch]$AllowDefer)

    if (Test-Path $LocalCcmsetupExe) {
        Write-Log "[$Label] Local ccmsetup.exe present at $LocalCcmsetupExe (informational)."
    } else {
        Write-Log "[$Label] Local ccmsetup.exe NOT present at $LocalCcmsetupExe (informational)."
    }

    Clear-CCMLog -Label $Label
    Write-Log "[$Label] Launching uninstall from $UninstallPath..."
    Start-Process -FilePath $UninstallPath -ArgumentList "/uninstall" -NoNewWindow
    Wait-ForCompletion -Label $Label -DesiredState "Gone" -AllowDefer:$AllowDefer | Out-Null

    return (Get-CcmExecStatus)
}

# ── Invoke-UninstallWithRetry: self-healing uninstall - CcmExec is the only truth ─
function Invoke-ScDeleteRecovery {
    param([string]$Label)
    Write-Log "[$Label] Attempting sc.exe delete recovery..."
    try {
        Stop-Process -Name "CcmExec" -Force -ErrorAction SilentlyContinue
    } catch {}
    Start-Sleep -Seconds 2

    try {
        $scResult = & sc.exe delete CcmExec 2>&1
        Write-Log "[$Label] sc.exe delete CcmExec result: $scResult"
    } catch {
        Write-Log "[$Label] sc.exe delete CcmExec threw an error: $_" "WARN"
    }
    Start-Sleep -Seconds 5

    return (Get-CcmExecStatus)
}

function Invoke-UninstallWithRetry {
    $status = Invoke-UninstallOnce -Label "Uninstall" -AllowDefer

    if ($status -eq "NotFound") {
        Write-StatusLine "Uninstall confirmed - CcmExec is gone." Green
        Write-Log "Uninstall confirmed on first attempt."
        return
    }

    # ── Escalation Step 1: uninstall reported success but CcmExec is a stale/
    # orphaned service registration. This is a documented ccmsetup quirk -
    # sc.exe delete removes the leftover service entry directly.
    Write-StatusLine "CcmExec still present after uninstall (Status: $status) - removing leftover service entry..." Yellow
    Write-Log "CcmExec still present after first uninstall attempt (Status: $status). Attempting sc.exe delete." "WARN"

    $status = Invoke-ScDeleteRecovery -Label "Uninstall"
    if ($status -eq "NotFound") {
        Write-StatusLine "Leftover CcmExec service entry removed successfully." Green
        Write-Log "CcmExec removed via sc.exe delete."
        Add-Summary "RECOVERY: CcmExec was orphaned after uninstall - resolved via sc.exe delete (step 1)."
        return
    }

    # ── Escalation Step 2: still present - run a full uninstall retry ─────────
    Write-StatusLine "CcmExec still present (Status: $status) - retrying full uninstall..." Yellow
    Write-Log "CcmExec still present after sc.exe delete. Retrying full uninstall." "WARN"
    Add-Summary "RECOVERY: sc.exe delete (step 1) did not resolve it - retrying full uninstall (step 2)."

    $status = Invoke-UninstallOnce -Label "Uninstall Retry"

    if ($status -eq "NotFound") {
        Write-StatusLine "Uninstall confirmed on retry - CcmExec is gone." Green
        Write-Log "Uninstall confirmed on retry."
        Add-Summary "RECOVERY: resolved via full uninstall retry (step 2)."
        return
    }

    # ── Escalation Step 3: one final sc.exe delete attempt after the retry ────
    Write-StatusLine "CcmExec still present after retry (Status: $status) - final removal attempt..." Yellow
    Write-Log "CcmExec still present after retry uninstall. Final sc.exe delete attempt." "WARN"
    Add-Summary "RECOVERY: retry (step 2) did not resolve it - final sc.exe delete attempt (step 3)."

    $status = Invoke-ScDeleteRecovery -Label "Uninstall Final"
    if ($status -eq "NotFound") {
        Write-StatusLine "Leftover CcmExec service entry removed on final attempt." Green
        Write-Log "CcmExec removed via final sc.exe delete."
        Add-Summary "RECOVERY: resolved via final sc.exe delete (step 3)."
        return
    }

    Write-StatusLine "ERROR: CcmExec still present (Status: $status) after all recovery attempts. Cannot proceed." Red
    Write-Log "CcmExec still present after all recovery attempts - aborting." "ERROR"
    Add-Summary "RESULT: FAILED - CcmExec still present (Status: $status) after all recovery attempts (retry + sc.exe delete x2)."
    Read-Host "`n  Press Enter to close"
    exit 1
}

# ── Wait-ForIdleRC0: used by REINSTALL and CMCLIENTINSTALL ───────────────────
function Wait-ForIdleRC0 {
    param(
        [string]$Label,
        [switch]$CheckCcmExec,
        [System.Diagnostics.Process]$Process = $null
    )

    Write-Log "[$Label] Watching for idle log + RC0..."
    $timeout   = 3600
    $elapsed   = 0
    $foundRC0  = $false
    $lastLine  = ""
    $reader    = $null
    $idleSecs  = 15

    try {
        $logWait = 0
        while (-not (Test-Path $CCMLog) -and $logWait -lt 30) {
            Set-Status "[$Label] Waiting for log file..." Cyan
            Start-Sleep -Seconds 1
            $logWait++
        }

        if (Test-Path $CCMLog) {
            $fileStream = [System.IO.FileStream]::new($CCMLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = [System.IO.StreamReader]::new($fileStream)
        } else {
            Write-StatusLine "WARNING: [$Label] Log file never appeared." Yellow
            Write-Log "[$Label] Log file never appeared." "WARN"
        }

        while ($elapsed -lt $timeout) {

            if ($reader -ne $null) {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    $msg  = Get-LogMessage -Line $line
                    if ($msg -ne "") {
                        $lastLine = $msg
                        Set-Status "[$Label] $msg" Cyan

                        if ($msg -match "CcmSetup is exiting with return code (\d+)" -and $matches[1] -ne "0") {
                            Write-StatusLine "ERROR: [$Label] Exited with return code $($matches[1])" Red
                            Write-Log "[$Label] Non-zero exit: $($matches[1])" "ERROR"
                            Read-Host "`n  Press Enter to close"
                            exit 1
                        }

                        if ($msg -match "CcmSetup is exiting with return code 0") {
                            $foundRC0 = $true
                            Write-Log "[$Label] RC0 detected. Waiting for log to go idle..."
                        }
                    }
                }
            }

            # Once RC0 found, check if log has gone idle
            if ($foundRC0) {
                $lwtBefore = (Get-Item $CCMLog -ErrorAction SilentlyContinue).LastWriteTime
                Start-Sleep -Seconds $idleSecs
                $lwtAfter = (Get-Item $CCMLog -ErrorAction SilentlyContinue).LastWriteTime

                if ($lwtBefore -eq $lwtAfter) {
                    # Log is idle - confirm last line is still RC0
                    if ($lastLine -match "CcmSetup is exiting with return code 0") {
                        Write-Log "[$Label] Log idle and last line is RC0. Checking secondary condition..."

                        # Secondary check
                        if ($CheckCcmExec) {
                            $ccmStatus = Get-CcmExecStatus
                            if ($ccmStatus -eq "Running") {
                                Write-StatusLine "[$Label] Confirmed - log idle, RC0, CcmExec running." Green
                                Write-Log "[$Label] Complete."
                                return $true
                            } else {
                                Write-StatusLine "[$Label] RC0 ignored - log idle but CcmExec not yet running ($ccmStatus). Watching..." Yellow
                                Write-Log "[$Label] CcmExec not running after idle - resetting RC0." "WARN"
                                $foundRC0 = $false
                            }
                        } elseif ($Process -ne $null) {
                            if ($Process.HasExited) {
                                Write-StatusLine "[$Label] Confirmed - log idle, RC0, process exited." Green
                                Write-Log "[$Label] Complete."
                                return $true
                            } else {
                                Write-StatusLine "[$Label] RC0 ignored - log idle but process still running. Watching..." Yellow
                                Write-Log "[$Label] Process still running after idle - continuing." "WARN"
                                $foundRC0 = $false
                            }
                        } else {
                            Write-StatusLine "[$Label] Confirmed - log idle and RC0." Green
                            Write-Log "[$Label] Complete."
                            return $true
                        }
                    } else {
                        # Log went idle but last line is not RC0 - still running, just paused
                        Write-StatusLine "[$Label] RC0 ignored - log paused but last line is not RC0. Still in progress..." Yellow
                        Write-Log "[$Label] Log idle but last line is not RC0 - still in progress, waiting..."
                        $foundRC0 = $false
                    }
                } else {
                    # Log still being written - keep watching
                    Write-StatusLine "[$Label] RC0 ignored - log still being written. Continuing to watch..." Yellow
                    Write-Log "[$Label] Log still active after RC0 - continuing to watch."
                    $foundRC0 = $false
                }
                $elapsed += $idleSecs
            } else {
                Start-Sleep -Milliseconds 500
                $elapsed += 0.5
            }
        }

        Write-StatusLine "ERROR: [$Label] Timed out after $timeout seconds." Red
        Write-Log "[$Label] Timed out." "ERROR"
        Read-Host "`n  Press Enter to close"
        exit 1

    } finally {
        if ($reader -ne $null) { $reader.Close() }
    }
}

# ── Confirm-ClientHealth: informational post-completion check ─────────────────
function Get-ClientHealthResults {
    # Runs all checks once and returns an array of result lines (no printing here)
    $results = @()

    $ccmStatus = Get-CcmExecStatus
    if ($ccmStatus -eq "Running") {
        $results += [PSCustomObject]@{ Text = "[OK] CcmExec is running."; Color = "Green"; OK = $true }
    } else {
        $results += [PSCustomObject]@{ Text = "[ !] CcmExec is not running (Status: $ccmStatus)"; Color = "Yellow"; OK = $false }
    }

    try {
        $auth = Get-WmiObject -Namespace "root\ccm" -Query "SELECT * FROM SMS_Authority" -ErrorAction SilentlyContinue
        if ($auth -and $auth.Name -and $auth.CurrentManagementPoint) {
            $results += [PSCustomObject]@{ Text = "[OK] Site authority: $($auth.Name)"; Color = "Green"; OK = $true }
            $results += [PSCustomObject]@{ Text = "[OK] Management point: $($auth.CurrentManagementPoint)"; Color = "Green"; OK = $true }
        } else {
            $results += [PSCustomObject]@{ Text = "[ !] Site authority not yet populated."; Color = "Yellow"; OK = $false }
            $results += [PSCustomObject]@{ Text = "[ !] Management point not yet assigned."; Color = "Yellow"; OK = $false }
        }
    } catch {
        $results += [PSCustomObject]@{ Text = "[ !] Could not query SMS_Authority."; Color = "Yellow"; OK = $false }
        $results += [PSCustomObject]@{ Text = "[ !] (management point check skipped)"; Color = "Yellow"; OK = $false }
    }

    try {
        $ccmReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM" -ErrorAction SilentlyContinue
        if ($ccmReg -and $ccmReg.LookupMPList) {
            $results += [PSCustomObject]@{ Text = "[OK] LookupMPList: $($ccmReg.LookupMPList)"; Color = "Green"; OK = $true }
        } else {
            $results += [PSCustomObject]@{ Text = "[ !] LookupMPList not yet populated."; Color = "Yellow"; OK = $false }
        }
    } catch {
        $results += [PSCustomObject]@{ Text = "[ !] Could not check LookupMPList."; Color = "Yellow"; OK = $false }
    }

    try {
        $ccmReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM" -ErrorAction SilentlyContinue
        if ($ccmReg -and $ccmReg.PKICertReady -eq 1) {
            $results += [PSCustomObject]@{ Text = "[OK] PKI certificate is ready."; Color = "Green"; OK = $true }
        } else {
            $results += [PSCustomObject]@{ Text = "[ !] PKI certificate not yet ready."; Color = "Yellow"; OK = $false }
        }
    } catch {
        $results += [PSCustomObject]@{ Text = "[ !] Could not check PKICertReady."; Color = "Yellow"; OK = $false }
    }

    return $results
}

function Show-HealthBlock {
    param($Results, [string]$FooterLine = $null, [string]$FooterColor = "Cyan")

    if ($script:HealthBlockTop -eq $null) {
        $script:HealthBlockTop = [Console]::CursorTop
    } else {
        [Console]::SetCursorPosition(0, $script:HealthBlockTop)
    }

    $width = [Console]::WindowWidth - 1

    foreach ($r in $Results) {
        $line = "  $($r.Text)"
        if ($line.Length -ge $width) { $line = $line.Substring(0, $width) } else { $line = $line.PadRight($width) }
        Write-Host $line -ForegroundColor $r.Color
    }

    if ($FooterLine -ne $null) {
        $fline = "  $FooterLine"
    } else {
        $fline = ""
    }
    if ($fline.Length -ge $width) { $fline = $fline.Substring(0, $width) } else { $fline = $fline.PadRight($width) }
    Write-Host $fline -ForegroundColor $FooterColor
}

function Confirm-ClientHealth {
    $pollSeconds = 15
    $elapsed     = 0
    $script:HealthBlockTop = $null

    Write-Banner "Verifying Client Configuration"
    Write-Host ""
    Write-Host "  CcmExec is confirmed running. Some items below (site code, PKI cert)" -ForegroundColor Cyan
    Write-Host "  can take a while to populate after a fresh install." -ForegroundColor Cyan
    Write-Host "  You don't need to wait for this, but you won't be able to use" -ForegroundColor Cyan
    Write-Host "  Software Center or receive policy until these finish." -ForegroundColor Cyan
    Write-Host "  Press Enter at any time to stop waiting and finish now." -ForegroundColor Cyan
    Write-Host ""

    $results = Get-ClientHealthResults
    $allGood = -not ($results | Where-Object { -not $_.OK })
    $footer  = if ($allGood) { $null } else { "Waiting... (0s elapsed, press Enter to stop waiting)" }
    Show-HealthBlock -Results $results -FooterLine $footer
    Write-Log ("Initial health check - " + (($results | ForEach-Object { $_.Text }) -join " | "))

    while (-not $allGood) {

        # Poll for Enter key without blocking
        $keyPressed = $false
        $tickEnd = (Get-Date).AddSeconds($pollSeconds)
        while ((Get-Date) -lt $tickEnd) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq "Enter") {
                    $keyPressed = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 250
        }

        if ($keyPressed) {
            Show-HealthBlock -Results $results -FooterLine "Skipping further wait - showing current status." -FooterColor Yellow
            Write-Log "User pressed Enter - ended health wait early at ${elapsed}s."
            break
        }

        $elapsed += $pollSeconds
        $results = Get-ClientHealthResults
        $allGood = -not ($results | Where-Object { -not $_.OK })
        $footer  = if ($allGood) { $null } else { "Waiting... (${elapsed}s elapsed, press Enter to stop waiting)" }
        Show-HealthBlock -Results $results -FooterLine $footer
    }

    Write-Log ("Final health check - all confirmed: $allGood - " + (($results | ForEach-Object { $_.Text }) -join " | "))

    Write-Host ""
    if ($allGood) {
        Write-Banner "Client Reinstall Complete - Fully Verified!" Green
    } else {
        Write-Banner "Client Reinstall Complete" Green
        Write-Host "  Note: Some items above had not finished populating yet." -ForegroundColor Yellow
        Write-Host "  This is normal and they should complete on their own shortly." -ForegroundColor Yellow
    }
    Write-Host "  Log saved to: $ScriptLog" -ForegroundColor Green
    Write-Host ("=" * 52) -ForegroundColor Green
}

function Save-State {
    param([string]$Stage)
    try {
        [PSCustomObject]@{
            Stage   = $Stage
            Started = (Get-Date).ToString("o")
        } | ConvertTo-Json | Set-Content -Path $StateFile -Force
        Write-Log "State saved: $Stage"
    } catch {
        Write-StatusLine "ERROR: Could not save state file: $_" Red
        Write-Log "Failed to save state: $_" "ERROR"
    }
}

function Remove-State {
    try {
        if (Test-Path $StateFile) {
            Remove-Item $StateFile -Force
            Write-Log "State file removed."
        }
    } catch {}
}

function Register-ResumeTask {
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action      = New-ScheduledTaskAction -Execute $PSExe -Argument "-ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume"
        $trigger     = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        $settings    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $principal   = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        Write-Log "Resume task registered for $currentUser using $PSExe."
        Write-StatusLine "Resume task registered." Green
    } catch {
        Write-StatusLine "ERROR: Could not register resume task: $_" Red
        Write-Log "Failed to register task: $_" "ERROR"
        Read-Host "`n  Press Enter to close"
        exit 1
    }
}

function Remove-ResumeTask {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Resume task removed."
    } catch {}
}

function Show-HealthCheck {
    Write-Banner "Detailed Health Check"
    Write-Host ""

    # Pending Reboot
    Write-Host "[ Pending Reboot ]" -ForegroundColor Yellow
    $pendingReboot = $false
    try {
        $cbsKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing" -ErrorAction SilentlyContinue
        $wuKey  = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -ErrorAction SilentlyContinue
        $pvKey  = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction SilentlyContinue
        if ($cbsKey.RebootPending)              { Write-Host "  [!!] CBS reboot pending" -ForegroundColor Red; $pendingReboot = $true }
        if ($wuKey.RebootRequired)              { Write-Host "  [!!] Windows Update reboot required" -ForegroundColor Red; $pendingReboot = $true }
        if ($pvKey.PendingFileRenameOperations) { Write-Host "  [!!] Pending file rename operations" -ForegroundColor Red; $pendingReboot = $true }
        if (-not $pendingReboot)                { Write-Host "  [OK] No pending reboot detected" -ForegroundColor Green }
    } catch {
        Write-Host "  [?] Could not check pending reboot." -ForegroundColor Yellow
    }

    # Windows Update Services
    Write-Host ""
    Write-Host "[ Windows Update Services ]" -ForegroundColor Yellow
    foreach ($svcName in @("wuauserv", "BITS", "CryptSvc", "TrustedInstaller")) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($null -eq $svc)                { Write-Host "  [!!] $svcName - NOT FOUND" -ForegroundColor Red }
            elseif ($svc.Status -eq "Running") { Write-Host "  [OK] $($svc.DisplayName) - Running" -ForegroundColor Green }
            else                               { Write-Host "  [!!] $($svc.DisplayName) - $($svc.Status)" -ForegroundColor Yellow }
        } catch {
            Write-Host "  [?] $svcName - Could not check" -ForegroundColor Yellow
        }
    }

    # SoftwareDistribution
    Write-Host ""
    Write-Host "[ Windows Update Cache ]" -ForegroundColor Yellow
    try {
        $sdPath = "C:\Windows\SoftwareDistribution"
        if (Test-Path $sdPath) {
            $sdSize  = [math]::Round((Get-ChildItem $sdPath -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB, 2)
            $sdColor = if ($sdSize -gt 10) { "Red" } elseif ($sdSize -gt 5) { "Yellow" } else { "Green" }
            Write-Host "  SoftwareDistribution: $sdSize GB" -ForegroundColor $sdColor
            if ($sdSize -gt 10) { Write-Host "  [!!] Cache very large - consider clearing it" -ForegroundColor Red }
        } else {
            Write-Host "  [?] SoftwareDistribution not found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [?] Could not check SoftwareDistribution" -ForegroundColor Yellow
    }

    # Time Sync
    Write-Host ""
    Write-Host "[ Time Sync ]" -ForegroundColor Yellow
    try {
        $w32tm      = w32tm /query /status 2>&1
        $sourceLine = $w32tm | Where-Object { $_ -match "Source:" }
        $offsetLine = $w32tm | Where-Object { $_ -match "Phase Offset:" }
        Write-Host "  $sourceLine"
        Write-Host "  $offsetLine"
    } catch {
        Write-Host "  [?] Could not check time sync" -ForegroundColor Yellow
    }

    # CcmExec
    Write-Host ""
    Write-Host "[ SCCM Client ]" -ForegroundColor Yellow
    $s = Get-CcmExecStatus
    if ($s -eq "Running")      { Write-Host "  [OK] CcmExec is Running" -ForegroundColor Green }
    elseif ($s -eq "NotFound") { Write-Host "  [!!] CcmExec not found" -ForegroundColor Red }
    else                       { Write-Host "  [!!] CcmExec: $s" -ForegroundColor Yellow }

    # Drivers
    Write-Host ""
    Write-Host "[ Drivers - Vendor Only ]" -ForegroundColor Yellow
    $ignoredDates  = @("19680718", "20060621")
    $categoryMatch = @("Intel","Realtek","NVIDIA","AMD","CrowdStrike","HP ","Wireless","Bluetooth","Wi-Fi","WiFi","NVMe","Audio","Graphics","Camera","Fingerprint","VPN","F5","Management Engine","Serial IO","Dynamic Tuning","GNA","iCLS","Active Management","Smart Sound","Sensor")
    $sixMonths     = (Get-Date).AddMonths(-6)
    $twelveMonths  = (Get-Date).AddMonths(-12)
    $flagged       = $false
    try {
        $drivers = Get-WmiObject Win32_PnPSignedDriver | Where-Object { $_.DriverDate -ne $null -and $_.DeviceName -ne $null }
        foreach ($driver in $drivers) {
            $dateStr = $driver.DriverDate.Substring(0, 8)
            if ($ignoredDates -contains $dateStr) { continue }
            $isRelevant = $false
            foreach ($cat in $categoryMatch) {
                if ($driver.DeviceName -match [regex]::Escape($cat)) { $isRelevant = $true; break }
            }
            if (-not $isRelevant) { continue }
            try {
                $driverDate = [datetime]::ParseExact($dateStr, "yyyyMMdd", $null)
                if ($driverDate -lt $twelveMonths) {
                    Write-Host "  [!!] $($driver.DeviceName) - $($driverDate.ToString('yyyy-MM-dd')) v$($driver.DriverVersion)" -ForegroundColor Red
                    $flagged = $true
                } elseif ($driverDate -lt $sixMonths) {
                    Write-Host "  [ !] $($driver.DeviceName) - $($driverDate.ToString('yyyy-MM-dd')) v$($driver.DriverVersion)" -ForegroundColor Yellow
                    $flagged = $true
                }
            } catch {}
        }
        if (-not $flagged) { Write-Host "  [OK] No drivers flagged" -ForegroundColor Green }
    } catch {
        Write-Host "  [?] Could not check drivers" -ForegroundColor Yellow
    }

    Write-Banner "Health Check Complete" Green
    Write-Host ""
}

function Invoke-UpdateCheck {
    $urls = Get-UpdateUrls
    if (-not $urls) {
        # No update source configured - skip entirely, silent
        return
    }

    try {
        $raw   = Invoke-WebRequest -Uri $urls.VersionUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $lines = $raw.Content -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    } catch {
        Write-Log "Could not reach update server: $_" "WARN"
        Write-Host ""
        Write-Host "  Couldn't reach the update server - you're probably not connected" -ForegroundColor Yellow
        Write-Host "  to the internet." -ForegroundColor Yellow
        Write-Host ""
        $cont = Read-Host "  Continue anyway on the current version? (Y/N)"
        if ($cont.ToUpper() -ne "Y") {
            Write-Log "User chose not to continue after failed update check."
            Read-Host "  Press Enter to close"
            exit 0
        }
        Write-Host ""
        return
    }

    if ($lines.Count -lt 3) {
        Write-Log "version.txt malformed - expected 3 lines, got $($lines.Count). Skipping update check." "WARN"
        return
    }

    $remoteVersionStr = $lines[0].Trim()
    $severity         = $lines[1].Trim().ToUpper()
    $status           = $lines[2].Trim().ToUpper()

    if ($status -eq "OFF") {
        Write-Log "Update status is OFF - skipping update check."
        return
    }

    try {
        $remoteVersion = [version]$remoteVersionStr
        $localVersion  = [version]$ScriptVersion
    } catch {
        Write-Log "Could not parse version numbers (remote='$remoteVersionStr', local='$ScriptVersion') - skipping update check." "WARN"
        return
    }

    if ($remoteVersion -le $localVersion) {
        Write-StatusLine "Running v$ScriptVersion - up to date." Green
        Write-Log "Up to date (local=$ScriptVersion, remote=$remoteVersionStr)."
        return
    }

    # ── An update is available ────────────────────────────────────────────────
    Write-Log "Update available: local=$ScriptVersion remote=$remoteVersionStr severity=$severity"

    $changelogText = $null
    try {
        $clRaw = Invoke-WebRequest -Uri $urls.ChangelogUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $changelogText = $clRaw.Content
    } catch {
        Write-Log "Could not fetch changelog: $_" "WARN"
    }

    Write-Banner "Update Available - v$remoteVersionStr"
    Write-Host ""
    if ($changelogText) {
        Write-Host $changelogText
    } else {
        Write-Host "  (Could not load changelog.)" -ForegroundColor Yellow
    }
    Write-Host ""

    $updaterPath = "C:\Temp\SoftwareCenter\CurrentVersion\Update-ReinstallTool.ps1"

    if ($severity -eq "CRITICAL") {
        Write-Host "  This update is marked CRITICAL." -ForegroundColor Red
        Write-Host ""

        if (Test-Path $updaterPath) {
            Write-StatusLine "Launching updater..." Cyan
            Write-Log "Launching updater for CRITICAL update."
            Start-Process -FilePath $PSExe -ArgumentList "-ExecutionPolicy Bypass -File `"$updaterPath`" -AutoRun"
            exit 0
        } else {
            Write-Host "  Update marked CRITICAL, but the updater tool was not found in this folder." -ForegroundColor Red
            Write-Host "  Continuing on the current version in 30 seconds." -ForegroundColor Yellow
            Write-Log "Updater not found for CRITICAL update - forced 30s wait then continuing." "WARN"
            Write-Host ""
            for ($i = 30; $i -ge 1; $i--) {
                Set-Status "Continuing in $i second(s)..." Yellow
                Start-Sleep -Seconds 1
            }
            Write-Host ""
        }
    } else {
        Write-Host "  U  Update now"
        Write-Host "  C  Continue on the current version"
        Write-Host ""
        $choice = Read-Host "  Choice"

        if ($choice.ToUpper() -eq "U") {
            if (Test-Path $updaterPath) {
                Write-StatusLine "Launching updater..." Cyan
                Write-Log "Launching updater for NORMAL update (user chose Update now)."
                Start-Process -FilePath $PSExe -ArgumentList "-ExecutionPolicy Bypass -File `"$updaterPath`" -AutoRun"
                exit 0
            } else {
                Write-Host "  Updater tool was not found in this folder. Continuing on current version." -ForegroundColor Yellow
                Write-Log "Updater not found for NORMAL update - continuing on current version." "WARN"
            }
        } else {
            Write-Log "User chose to continue on current version (NORMAL update available)."
        }
    }
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
try {
    Write-Log "================================================"
    Write-Log "  CCM Reinstall Tool v$ScriptVersion started. Resume: $Resume"
    Write-Log "  PSExe: $PSExe"
    Write-Log "================================================"

    Initialize-Summary -Mode $(if ($Resume) { "Resume (post-reboot)" } else { "Fresh start" })
    Add-Summary "Tool started - version $ScriptVersion"

    # ── Verify all required files and folders are present ─────────────────────
    $missing = @()
    foreach ($f in @($InstallPath, $CMClientInstall, $CCMCab, $CMClientInstallWse)) {
        if (-not (Test-Path $f)) { $missing += $f }
    }
    foreach ($d in @($I386Dir, $X64Dir)) {
        if (-not (Test-Path $d -PathType Container)) { $missing += "$d\ (folder)" }
    }
    if ($missing.Count -gt 0) {
        Write-StatusLine "ERROR: Missing required files/folders:" Red
        Write-Log "Missing required files/folders:" "ERROR"
        foreach ($m in $missing) {
            Write-Host "    - $m" -ForegroundColor Red
            Write-Log "  Missing: $m" "ERROR"
        }
        Write-Host ""
        Write-Host "  Make sure the full SoftwareCenter folder was extracted correctly." -ForegroundColor Yellow
        Read-Host "`n  Press Enter to close"
        exit 1
    }

    # ── Load install arguments from Config\CmdLine.txt ─────────────────────────
    $InstallArgs = Get-InstallArgsFromConfig

    # ── Check for updates (skipped on resume) ──────────────────────────────────
    if (-not $Resume) {
        Invoke-UpdateCheck
    }

    # ── Resume path ───────────────────────────────────────────────────────────
    $state = $null
    if ($Resume) {
        Write-Log "Resume flag detected."
        if (-not (Test-Path $StateFile)) {
            Write-StatusLine "WARNING: Resume flag set but no state file found. Starting from Phase 1." Yellow
            Write-Log "No state file found on resume - falling back to Phase 1." "WARN"
            $Resume = $false
        } else {
            $state = Get-Content $StateFile | ConvertFrom-Json
            Write-Log "Resuming from stage: $($state.Stage)"
        }
    } else {
        # Fresh launch (not a resume) - clean up any orphaned state/task left
        # behind by a previous run that crashed before finishing cleanup.
        $orphanFound = $false
        if (Test-Path $StateFile) {
            Write-Log "Orphaned state file found on fresh launch - removing." "WARN"
            Remove-State
            $orphanFound = $true
        }
        try {
            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                Write-Log "Orphaned resume task found on fresh launch - removing." "WARN"
                Remove-ResumeTask
                $orphanFound = $true
            }
        } catch {}
        if ($orphanFound) {
            Write-StatusLine "Cleaned up leftover state from a previous run." Yellow
        }
    }

    # ── Requirements check - skipped on resume or with -SkipChecks ────────────
    if (-not $Resume) {
        Write-Banner "SCCM Client Reinstall Tool  (v$ScriptVersion)"

        if ($SkipChecks) {
            Write-Host "  Requirements check bypassed (-SkipChecks)." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  You are choosing to skip the automated pre-flight checks" -ForegroundColor Yellow
            Write-Host "  (Windows version, BIOS date, disk space, AC power, network)." -ForegroundColor Yellow
            Write-Host "  Proceeding on hardware that doesn't meet these conditions" -ForegroundColor Yellow
            Write-Host "  may result in a failed or incomplete update." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  By continuing, you accept responsibility for this decision." -ForegroundColor Yellow
            Write-Host ""
            $skipConfirm = Read-Host "  Type YES to confirm and continue"
            if ($skipConfirm -ne "YES") {
                Write-Log "User did not confirm -SkipChecks disclaimer. Aborting."
                Read-Host "  Press Enter to close"
                exit 0
            }
            Write-Log "Requirements check bypassed via -SkipChecks. User confirmed disclaimer." "WARN"
            Write-Host ""
        } else {
        Write-Host "  Checking requirements..." -ForegroundColor Cyan
        Write-Host ""

        $reqFailed = $false

        # Windows version - must not be 25H2
        try {
            $winVer  = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
            $dispVer = $winVer.DisplayVersion
            if ($dispVer -match "25H2") {
                Write-Host "  [!!] Windows is already on $dispVer - no update required." -ForegroundColor Red
                Write-Log "Already on $dispVer - aborting." "ERROR"
                $reqFailed = $true
            } else {
                Write-Host "  [OK] Windows version: $dispVer" -ForegroundColor Green
                Write-Log "Windows version: $dispVer"
            }
        } catch {
            Write-Host "  [?] Could not check Windows version." -ForegroundColor Yellow
            Write-Log "Could not check Windows version." "WARN"
        }

        # BIOS - release date must be 2026 or later
        try {
            $bios     = Get-WmiObject Win32_BIOS -ErrorAction Stop
            $biosVer  = $bios.SMBIOSBIOSVersion
            $biosDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($bios.ReleaseDate)
            $biosYear = $biosDate.Year
            if ($biosYear -ge 2026) {
                Write-Host "  [OK] BIOS version: $biosVer (Released: $($biosDate.ToString('yyyy-MM-dd')))" -ForegroundColor Green
                Write-Log "BIOS OK: $biosVer released $($biosDate.ToString('yyyy-MM-dd'))"
            } else {
                Write-Host "  [!!] BIOS release date is $($biosDate.ToString('yyyy-MM-dd')) - a 2026 BIOS is required. Please update BIOS first." -ForegroundColor Red
                Write-Log "BIOS failed: released $($biosDate.ToString('yyyy-MM-dd'))" "ERROR"
                $reqFailed = $true
            }
        } catch {
            Write-Host "  [?] Could not check BIOS." -ForegroundColor Yellow
            Write-Log "Could not check BIOS." "WARN"
        }

        # Disk space - 50GB minimum
        try {
            $disk    = Get-PSDrive C -ErrorAction Stop
            $freeGB  = [math]::Round($disk.Free / 1GB, 2)
            $totalGB = [math]::Round(($disk.Used + $disk.Free) / 1GB, 2)
            $pctUsed = [math]::Round(($disk.Used / ($disk.Used + $disk.Free)) * 100, 1)
            if ($freeGB -ge 50) {
                Write-Host "  [OK] Free disk space: $freeGB GB / $totalGB GB ($pctUsed pct used)" -ForegroundColor Green
                Write-Log "Disk OK: $freeGB GB free"
            } else {
                Write-Host "  [!!] Insufficient disk space: $freeGB GB free (50 GB required)." -ForegroundColor Red
                Write-Log "Disk failed: $freeGB GB free" "ERROR"
                $reqFailed = $true
            }
        } catch {
            Write-Host "  [?] Could not check disk space." -ForegroundColor Yellow
            Write-Log "Could not check disk space." "WARN"
        }

        # AC Adapter
        try {
            $battery = Get-WmiObject Win32_Battery -ErrorAction SilentlyContinue
            if ($battery) {
                if ($battery.BatteryStatus -eq 2) {
                    Write-Host "  [OK] AC adapter connected." -ForegroundColor Green
                    Write-Log "AC adapter connected."
                } else {
                    Write-Host "  [!!] AC adapter not connected. Please plug in before proceeding." -ForegroundColor Red
                    Write-Log "AC adapter not connected." "ERROR"
                    $reqFailed = $true
                }
            } else {
                Write-Host "  [OK] No battery detected - assuming desktop/docked." -ForegroundColor Green
                Write-Log "No battery detected."
            }
        } catch {
            Write-Host "  [?] Could not check power status." -ForegroundColor Yellow
            Write-Log "Could not check power status." "WARN"
        }

        # WiFi warning - soft only
        try {
            $wifi = Get-NetAdapter | Where-Object { $_.PhysicalMediaType -eq "Native 802.11" -and $_.Status -eq "Up" }
            $eth  = Get-NetAdapter | Where-Object { $_.PhysicalMediaType -eq "802.3" -and $_.Status -eq "Up" }
            if ($wifi -and -not $eth) {
                Write-Host "  [ !] WiFi only - Ethernet strongly recommended for feature updates." -ForegroundColor Yellow
                Write-Log "WiFi only detected." "WARN"
            } elseif ($eth) {
                Write-Host "  [OK] Ethernet connected." -ForegroundColor Green
                Write-Log "Ethernet connected."
            }
        } catch {
            Write-Host "  [?] Could not check network adapters." -ForegroundColor Yellow
            Write-Log "Could not check network adapters." "WARN"
        }

        Write-Host ""

        if ($reqFailed) {
            Write-Host "  One or more requirements failed. Fix the issues above and try again." -ForegroundColor Red
            Write-Log "Requirements check failed - aborting."
            Add-Summary "REQUIREMENTS CHECK: FAILED - see script log for details. Aborting."
            Read-Host "  Press Enter to close"
            exit 1
        }

        Write-Host "  All requirements passed." -ForegroundColor Green
        Write-Host ""
        Add-Summary "Requirements check: all passed."
        }

        # ── Menu ─────────────────────────────────────────────────────────────
        $ccmStatus = Get-CcmExecStatus
        Write-Log "CcmExec status: $ccmStatus"

        if ($ccmStatus -ne "NotFound") {
            $proceedUninstall = $false
            while (-not $proceedUninstall) {
                Write-Host "  CcmExec is present (Status: $ccmStatus)" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  C  Continue with uninstall and reinstall"
                Write-Host "  D  Detailed health check first"
                Write-Host "  N  Cancel"
                Write-Host ""
                $choice = Read-Host "  Choice"

                if ($choice.ToUpper() -eq "D") {
                    Show-HealthCheck
                    Write-Host ""
                    Read-Host "  Press Enter to return to menu"
                    Clear-Host
                } elseif ($choice.ToUpper() -eq "C") {
                    $proceedUninstall = $true
                } elseif ($choice.ToUpper() -eq "N") {
                    Write-Log "User cancelled."
                    Read-Host "  Press Enter to close"
                    exit 0
                } else {
                    Write-Host "  Invalid choice. Please enter C, D, or N." -ForegroundColor Red
                    Write-Host ""
                }
            }

            # ── PHASE 1: Uninstall ────────────────────────────────────────────
            Write-PhaseHeader -Phase 1 -Total 3 -Title "Uninstalling CCM Client"
            Write-Log "--- PHASE 1: Uninstalling ---"
            $phase1Start = Get-Date
            Add-Summary "PHASE 1 (Uninstall): started"

            Invoke-UninstallWithRetry
            Write-StatusLine "Uninstall phase complete." Green
            Write-Log "Uninstall phase complete."
            $phase1Dur = [math]::Round(((Get-Date) - $phase1Start).TotalSeconds, 1)
            Add-Summary "PHASE 1 (Uninstall): completed in ${phase1Dur}s"

            Write-StatusLine "Saving state and registering resume task..." Cyan
            Save-State -Stage "Phase2"
            Register-ResumeTask
            Add-Summary "Reboot scheduled - resume task registered."

            Write-Host ""
            for ($i = 15; $i -ge 1; $i--) {
                Set-Status "Rebooting in $i second(s)..." Yellow
                Start-Sleep -Seconds 1
            }
            Write-Host ""
            Write-Log "Rebooting..."
            Add-Summary "Rebooting now."
            Restart-Computer -Force
            exit 0

        } else {
            Write-Host "  CcmExec not found." -ForegroundColor Yellow
            Write-Host ""
            $choice = Read-Host "  Proceed with reinstall? (Y/N)"
            if ($choice.ToUpper() -ne "Y") {
                Write-Log "User cancelled."
                Read-Host "  Press Enter to close"
                exit 0
            }
        }
    }

    # ── Resume prompt ─────────────────────────────────────────────────────────
    if ($Resume -and $state -ne $null -and $state.Stage -eq "Phase2") {
        Write-Banner "SCCM Client Reinstall Tool - Resuming  (v$ScriptVersion)"
        Write-Host ""
        Write-Host "  System has rebooted. Ready to continue with reinstall." -ForegroundColor Cyan
        Write-Host "  Press Y to start now, or N to cancel." -ForegroundColor Cyan
        Write-Host ""

        $countdown  = 10
        $cancelled  = $false
        $startedNow = $false

        while ($countdown -gt 0 -and -not $startedNow) {
            Set-Status "Starting automatically in $countdown... (Y to start now, N to cancel)" Yellow

            $tickEnd = (Get-Date).AddSeconds(1)
            while ((Get-Date) -lt $tickEnd) {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq "Y") {
                        $startedNow = $true
                        break
                    } elseif ($key.Key -eq "N") {
                        $cancelled = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds 100
            }

            if ($cancelled -or $startedNow) { break }
            $countdown--
        }

        Write-Host ""

        if ($cancelled) {
            Write-StatusLine "Cancelled by user." Yellow
            Write-Log "User cancelled on resume."
            Remove-State
            Remove-ResumeTask
            Read-Host "  Press Enter to close"
            exit 0
        }

        if ($startedNow) {
            Write-StatusLine "Starting now." Green
            Write-Log "User pressed Y - starting immediately on resume."
        } else {
            Write-StatusLine "Starting automatically." Green
            Write-Log "Countdown elapsed - starting automatically on resume."
        }
    }

    # ── PHASE 2: Reinstall ────────────────────────────────────────────────────
    Write-PhaseHeader -Phase 2 -Total 3 -Title "Reinstalling CCM Client"
    Write-Log "--- PHASE 2: Reinstalling ---"
    $phase2Start = Get-Date
    Add-Summary "PHASE 2 (Reinstall): started"

    $preStatus = Get-CcmExecStatus
    if ($preStatus -ne "NotFound") {
        Write-StatusLine "WARNING: CcmExec unexpectedly present after reboot (Status: $preStatus)." Yellow
        Write-Log "CcmExec unexpectedly present at Phase 2 start: $preStatus" "WARN"
        Write-StatusLine "Uninstall did not fully take - retrying before reinstall..." Yellow
        Write-Log "Retrying uninstall before proceeding with reinstall."
        Add-Summary "ANOMALY: CcmExec still present after reboot (Status: $preStatus). Retrying uninstall before reinstall."
        Invoke-UninstallWithRetry
        Write-StatusLine "CcmExec confirmed gone - proceeding with reinstall." Green
        Add-Summary "Recovery successful - CcmExec confirmed gone, proceeding with reinstall."
    }

    Clear-CCMLog -Label "Reinstall"
    Write-Log "Launching reinstall..."
    Start-Process -FilePath $InstallPath -ArgumentList $InstallArgs -NoNewWindow
    Wait-ForIdleRC0 -Label "Reinstall" -CheckCcmExec | Out-Null
    Write-StatusLine "Reinstall complete." Green
    Write-Log "Reinstall complete."
    $phase2Dur = [math]::Round(((Get-Date) - $phase2Start).TotalSeconds, 1)
    Add-Summary "PHASE 2 (Reinstall): completed in ${phase2Dur}s"

    # ── PHASE 3: CMClientInstall ──────────────────────────────────────────────
    Write-PhaseHeader -Phase 3 -Total 3 -Title "Running CMClientInstall"
    Write-Log "--- PHASE 3: CMClientInstall ---"
    $phase3Start = Get-Date
    Add-Summary "PHASE 3 (CMClientInstall): started"

    Clear-CCMLog -Label "CMClientInstall"
    Write-Log "Launching CMClientInstall..."
    $cmProc = Start-Process -FilePath $CMClientInstall -NoNewWindow -PassThru
    Wait-ForIdleRC0 -Label "CMClientInstall" -Process $cmProc | Out-Null
    Write-Log "CMClientInstall complete."
    $phase3Dur = [math]::Round(((Get-Date) - $phase3Start).TotalSeconds, 1)
    Add-Summary "PHASE 3 (CMClientInstall): completed in ${phase3Dur}s"

    # ── Cleanup ───────────────────────────────────────────────────────────────
    Remove-State
    Remove-ResumeTask

    # ── Post-completion health check ──────────────────────────────────────────
    Confirm-ClientHealth
    Add-Summary "Post-completion health check finished - see $ScriptLog for full details."
    Add-Summary "RESULT: SUCCESS"

    Write-Host ""
    Read-Host "  Press Enter to close"

} catch {
    Write-StatusLine "FATAL ERROR: $_" Red
    Write-Log "FATAL ERROR: $_" "ERROR"
    Add-Summary "RESULT: FAILED - FATAL ERROR: $_"
    Write-Host ""
    Write-Host "  Error details: $_" -ForegroundColor Red
    Write-Host "  Check log at: $ScriptLog" -ForegroundColor Yellow
    Read-Host "`n  Press Enter to close"
} finally {
    # Reset sleep prevention on exit
    try { [PowerMgmt]::SetThreadExecutionState(0x80000000) | Out-Null } catch {}
    # Release single-instance lock
    try {
        if ($script:InstanceMutex -ne $null) {
            $script:InstanceMutex.ReleaseMutex() | Out-Null
            $script:InstanceMutex.Dispose()
        }
    } catch {}
}
