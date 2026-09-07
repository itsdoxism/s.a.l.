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

# Snapshot the local accounts that existed BEFORE S.A.L. creates anything.
# Cleanup later only considers accounts from this snapshot, so accounts created
# during this run can never be accidentally selected for cleanup.
$InitialLocalUsers = @(Get-LocalUser | Select-Object Name, SID)

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

function Read-ConfirmedPassword {
    param([Parameter(Mandatory=$true)][string]$Label)

    $password1 = Read-Host $Label -AsSecureString
    $password2 = Read-Host 'Confirm admin password' -AsSecureString

    $ptr1 = [IntPtr]::Zero
    $ptr2 = [IntPtr]::Zero

    try {
        $ptr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1)
        $ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2)
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1)
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)

        if ($plain1 -cne $plain2) {
            throw 'Passwords do not match.'
        }
    }
    finally {
        if ($ptr1 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1) }
        if ($ptr2 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2) }
        $plain1 = $null
        $plain2 = $null
    }

    return $password1
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

function Invoke-PreexistingUserCleanup {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    # Never offer Windows built-in/system accounts for deletion.
    $protectedNames = @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')

    $candidates = @(
        $InitialLocalUsers |
            Where-Object {
                $name = $_.Name
                $sid = [string]$_.SID

                ($name -ine $Student) -and
                ($name -ine $Admin) -and
                ($protectedNames -notcontains $name) -and
                ($sid -notmatch '-(500|501|503|504)$')
            } |
            Where-Object { Get-LocalUserSafe -Name $_.Name }
    )

    if ($candidates.Count -eq 0) {
        Write-Host '[OK] No extra pre-existing local users found.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'Extra local users that existed BEFORE this S.A.L. run:' -ForegroundColor Yellow
    foreach ($candidate in $candidates) {
        $suffix = ''
        if ($candidate.Name -ieq [Environment]::UserName) {
            $suffix = '  [CURRENT SESSION]'
        }
        Write-Host "  - $($candidate.Name)$suffix"
    }

    Write-Host ''
    Write-Host 'The selected student account, dedicated admin account, Windows built-ins,' -ForegroundColor DarkGray
    Write-Host 'and any account created during this run are NOT cleanup candidates.' -ForegroundColor DarkGray
    Write-Host 'Only the local account objects are removed; profile folders/data are not deleted.' -ForegroundColor DarkGray

    $cleanupChoice = Read-Host 'Delete ALL listed pre-existing local users? (Y/N)'
    if ($cleanupChoice -notmatch '^(y|yes)$') {
        Write-Host '[SKIP] Extra local users were left unchanged.' -ForegroundColor Yellow
        return
    }

    foreach ($candidate in $candidates) {
        try {
            Remove-LocalUser -Name $candidate.Name -ErrorAction Stop
            Write-Host "[OK] Removed local user '$($candidate.Name)'." -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not remove '$($candidate.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
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

# Resolve the dedicated administrator name. If the name already exists,
# S.A.L. never silently takes it over: the operator explicitly chooses to use it,
# choose a different name, or cancel.
$Admin = $null
$AdminExistedAtSelection = $false
$PromoteExistingAdmin = $false
$ChangeExistingAdminPassword = $false

:AdminSelection while ($true) {
    $candidateAdmin = Read-Host 'Dedicated admin username [AdminControl]'
    if ([string]::IsNullOrWhiteSpace($candidateAdmin)) { $candidateAdmin = 'AdminControl' }

    if ($Student -ieq $candidateAdmin) {
        Write-Host 'Student and dedicated admin usernames must be different. Choose another admin name.' -ForegroundColor Red
        continue
    }

    $existingAdmin = Get-LocalUserSafe -Name $candidateAdmin
    if (-not $existingAdmin) {
        $Admin = $candidateAdmin
        $AdminExistedAtSelection = $false
        break
    }

    Write-Host ''
    Write-Host "Local account '$candidateAdmin' already exists." -ForegroundColor Yellow
    Write-Host '[1] Use this existing account'
    Write-Host '[2] Choose another admin name'
    Write-Host '[3] Cancel'
    $existingChoice = Read-Host 'Choose [1/2/3]'

    if ($existingChoice -eq '1') {
        $Admin = $candidateAdmin
        $AdminExistedAtSelection = $true
        $PromoteExistingAdmin = $false
        $ChangeExistingAdminPassword = $false

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            Write-Host "'$Admin' exists but is NOT an Administrator." -ForegroundColor Yellow
            $promoteChoice = Read-Host "Promote '$Admin' to Administrator? (Y/N)"
            if ($promoteChoice -match '^(y|yes)$') {
                $PromoteExistingAdmin = $true
            }
            else {
                Write-Host 'Existing account was not selected as the dedicated administrator.' -ForegroundColor Yellow
                $Admin = $null
                continue AdminSelection
            }
        }

        Write-Host ''
        $changeChoice = Read-Host "Change/reset password for existing admin '$Admin'? (Y/N)"
        if ($changeChoice -match '^(y|yes)$') {
            Write-Host 'WARNING: Resetting another local account password can make EFS-encrypted files or saved credentials for that account inaccessible.' -ForegroundColor Yellow
            $resetConfirm = Read-Host 'Continue with the password reset? (Y/N)'
            if ($resetConfirm -match '^(y|yes)$') {
                $ChangeExistingAdminPassword = $true
            }
        }

        break AdminSelection
    }
    elseif ($existingChoice -eq '2') {
        continue AdminSelection
    }
    elseif ($existingChoice -eq '3') {
        Write-Host 'Cancelled. Nothing changed.' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit
    }
    else {
        Write-Host 'Invalid choice. Choose 1, 2, or 3.' -ForegroundColor Red
        continue AdminSelection
    }
}

$state = Get-DeviceState -Student $Student -Admin $Admin
Show-State -State $state

$MaintenanceRequested = $PromoteExistingAdmin -or $ChangeExistingAdminPassword

if ((Test-FullyConfigured -State $state) -and -not $MaintenanceRequested) {
    Write-Host 'This device is already configured.' -ForegroundColor Green
    Invoke-PreexistingUserCleanup -Student $Student -Admin $Admin
    Read-Host 'Press Enter to exit'
    exit
}

if ($CreateStudent) {
    Write-Host "[PLAN] Create '$Student' as a passwordless Standard User." -ForegroundColor Cyan
}
if ($PromoteExistingAdmin) {
    Write-Host "[PLAN] Promote existing '$Admin' to Administrator." -ForegroundColor Cyan
}
if ($ChangeExistingAdminPassword) {
    Write-Host "[PLAN] Change/reset password for existing admin '$Admin'." -ForegroundColor Cyan
}

Write-Host 'This device has pending configuration/maintenance changes.' -ForegroundColor Yellow
$confirm = Read-Host 'Apply/fix configuration? (Y/N)'
if ($confirm -notmatch '^(y|yes)$') { exit }

try {
    # Create/verify the dedicated administrator first.
    if (-not $state.AdminExists) {
        Write-Host "`nCreating dedicated administrator '$Admin'..." -ForegroundColor Yellow
        $newAdminPassword = Read-ConfirmedPassword -Label 'New admin password'

        New-LocalUser -Name $Admin -Password $newAdminPassword -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
        Write-Host '[OK] Dedicated admin account created.' -ForegroundColor Green
    }
    elseif ($ChangeExistingAdminPassword) {
        $replacementPassword = Read-ConfirmedPassword -Label 'New admin password'
        Set-LocalUser -Name $Admin -Password $replacementPassword -ErrorAction Stop
        Write-Host "[OK] Password changed/reset for '$Admin'." -ForegroundColor Green
    }

    if (-not (Test-LocalAdministrator -Name $Admin)) {
        # Existing non-admin accounts are promoted only after explicit approval above.
        if ($AdminExistedAtSelection -and -not $PromoteExistingAdmin) {
            throw "Existing account '$Admin' is not an Administrator and promotion was not approved."
        }

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
        Invoke-PreexistingUserCleanup -Student $Student -Admin $Admin
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
