#requires -version 5.1
# School Account Lockdown (S.A.L.)
# Console edition for authorized school-owned Windows 11 PCs.

$ErrorActionPreference = 'Stop'
$RawScriptUrl = 'https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    if (Test-IsAdministrator) { return }

    Write-Host 'Administrator permission is required. Opening UAC...' -ForegroundColor Yellow

    # Works both when launched from a local .ps1 and via: irm <raw-url> | iex
    if ($PSCommandPath) {
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    else {
        $remote = "irm '$RawScriptUrl' | iex"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
        $args = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args | Out-Null
    }
    catch {
        Write-Host "Could not request Administrator permission: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
    }
    exit
}

Ensure-Administrator

function Get-AdminGroupName {
    try {
        $group = Get-CimInstance Win32_Group -Filter "LocalAccount=True AND SID='S-1-5-32-544'"
        if ($group -and $group.Name) { return $group.Name }
    }
    catch {}
    return 'Administrators'
}

$AdminGroup = Get-AdminGroupName

function Get-LocalUserSafe {
    param([Parameter(Mandatory=$true)][string]$Name)
    try { return Get-LocalUser -Name $Name -ErrorAction Stop }
    catch { return $null }
}

function Test-LocalAdministrator {
    param([Parameter(Mandatory=$true)][string]$Name)
    try {
        $members = Get-LocalGroupMember -Group $AdminGroup -ErrorAction Stop
        foreach ($member in $members) {
            if (($member.Name -split '\\')[-1] -ieq $Name) { return $true }
        }
    }
    catch {}
    return $false
}

function Get-DeviceState {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $studentObject = Get-LocalUserSafe -Name $Student
    $adminObject = Get-LocalUserSafe -Name $Admin

    [pscustomobject]@{
        AdminExists           = [bool]$adminObject
        AdminIsAdministrator  = if ($adminObject) { Test-LocalAdministrator -Name $Admin } else { $false }
        StudentExists         = [bool]$studentObject
        StudentIsStandard     = if ($studentObject) { -not (Test-LocalAdministrator -Name $Student) } else { $false }
        PasswordChangeBlocked = if ($studentObject) { $studentObject.UserMayChangePassword -eq $false } else { $false }
    }
}

function Test-FullyConfigured {
    param($State)
    return (
        $State.AdminExists -and
        $State.AdminIsAdministrator -and
        $State.StudentExists -and
        $State.StudentIsStandard -and
        $State.PasswordChangeBlocked
    )
}

function Show-State {
    param($State)

    function Mark([bool]$Value) {
        if ($Value) { return '[OK]' }
        return '[--]'
    }

    Write-Host ''
    Write-Host "$(Mark $State.AdminExists) Dedicated admin account exists"
    Write-Host "$(Mark $State.AdminIsAdministrator) Dedicated admin has Administrator rights"
    Write-Host "$(Mark $State.StudentExists) Student account exists"
    Write-Host "$(Mark $State.StudentIsStandard) Student account is Standard User"
    Write-Host "$(Mark $State.PasswordChangeBlocked) Student password creation/change is blocked"
    Write-Host ''
}

Clear-Host
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '       SCHOOL ACCOUNT LOCKDOWN (S.A.L.)' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host 'For authorized school-owned PCs only.'
Write-Host ''

Write-Host 'Local users:' -ForegroundColor Yellow
Get-LocalUser |
    Where-Object { $_.Name -notin @('DefaultAccount','WDAGUtilityAccount') } |
    Select-Object Name, Enabled, UserMayChangePassword |
    Format-Table -AutoSize

$Student = Read-Host 'Student username'
if ([string]::IsNullOrWhiteSpace($Student)) {
    Write-Host 'ERROR: Student username cannot be empty.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

$CreateStudent = $false
if (-not (Get-LocalUserSafe -Name $Student)) {
    Write-Host "Student account '$Student' does not exist." -ForegroundColor Yellow
    $createChoice = Read-Host "Create '$Student' as a passwordless Standard User? (Y/N)"
    if ($createChoice -match '^(y|yes)$') {
        $CreateStudent = $true
    }
    else {
        Write-Host 'No student account was created. Nothing changed.' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit
    }
}

$Admin = Read-Host 'Dedicated admin username [AdminControl]'
if ([string]::IsNullOrWhiteSpace($Admin)) { $Admin = 'AdminControl' }

if ($Student -ieq $Admin) {
    Write-Host 'ERROR: Student and admin usernames must be different.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

$state = Get-DeviceState -Student $Student -Admin $Admin
Show-State -State $state

if (Test-FullyConfigured -State $state) {
    Write-Host 'This device is already configured.' -ForegroundColor Green
    Read-Host 'Press Enter to exit'
    exit
}

if ($CreateStudent) {
    Write-Host "[PLAN] Create '$Student' as a passwordless Standard User." -ForegroundColor Cyan
}
Write-Host 'This device is not fully configured.' -ForegroundColor Yellow
$confirm = Read-Host 'Apply/fix configuration? (Y/N)'
if ($confirm -notmatch '^(y|yes)$') { exit }

try {
    # Create/verify the dedicated administrator first.
    if (-not $state.AdminExists) {
        Write-Host "`nCreating dedicated administrator '$Admin'..." -ForegroundColor Yellow

        $password1 = Read-Host 'New admin password' -AsSecureString
        $password2 = Read-Host 'Confirm admin password' -AsSecureString

        $ptr1 = [IntPtr]::Zero
        $ptr2 = [IntPtr]::Zero
        try {
            $ptr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1)
            $ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2)
            $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1)
            $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)

            if ($plain1 -cne $plain2) { throw 'Passwords do not match.' }
        }
        finally {
            if ($ptr1 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1) }
            if ($ptr2 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2) }
            $plain1 = $null
            $plain2 = $null
        }

        New-LocalUser -Name $Admin -Password $password1 -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
        Write-Host '[OK] Dedicated admin account created.' -ForegroundColor Green
    }

    if (-not (Test-LocalAdministrator -Name $Admin)) {
        Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
        Write-Host "[OK] '$Admin' added to '$AdminGroup'." -ForegroundColor Green
    }

    # Safety check: never create/demote/lock the student until another Administrator is verified.
    if (-not (Test-LocalAdministrator -Name $Admin)) {
        throw 'Dedicated administrator could not be verified. Student account was not changed.'
    }

    # Create the student account if requested. New local users are Standard Users unless added to Administrators.
    if ($CreateStudent -and -not (Get-LocalUserSafe -Name $Student)) {
        New-LocalUser -Name $Student -NoPassword -Description 'School student account' -ErrorAction Stop | Out-Null
        Write-Host "[OK] Passwordless student account '$Student' created." -ForegroundColor Green
    }

    if (-not (Get-LocalUserSafe -Name $Student)) {
        throw "Student account '$Student' could not be found or created."
    }

    if (Test-LocalAdministrator -Name $Student) {
        Remove-LocalGroupMember -Group $AdminGroup -Member $Student -ErrorAction Stop
        Write-Host "[OK] '$Student' changed to Standard User." -ForegroundColor Green
    }

    Set-LocalUser -Name $Student -UserMayChangePassword $false -ErrorAction Stop
    Write-Host "[OK] Password creation/change blocked for '$Student'." -ForegroundColor Green

    $finalState = Get-DeviceState -Student $Student -Admin $Admin
    Show-State -State $finalState

    if (Test-FullyConfigured -State $finalState) {
        Write-Host 'DONE - This laptop is configured.' -ForegroundColor Green
    }
    else {
        Write-Host 'WARNING - Some settings are still incomplete.' -ForegroundColor Yellow
    }
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Read-Host 'Press Enter to exit'
