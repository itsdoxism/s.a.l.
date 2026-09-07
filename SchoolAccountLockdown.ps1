#requires -version 5.1
# School Account Lockdown (S.A.L.)
# Console edition for authorized school-owned Windows 11 PCs.

$ErrorActionPreference = 'Stop'
$RawScriptUrl = 'https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1'
$UserListRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
$WindowsSystemPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$SalStatePath = 'HKLM:\SOFTWARE\S.A.L.'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    if (Test-IsAdministrator) { return }

    Write-Host 'Administrator permission is required. Opening UAC...' -ForegroundColor Yellow

    if ($PSCommandPath) {
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    else {
        # Cache-bust the raw URL so an elevated relaunch does not pick up a stale script.
        $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $remote = "irm '$RawScriptUrl?cb=$cacheBust' | iex"
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

# Snapshot users before S.A.L. creates anything. Cleanup only considers this set.
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

function Test-ComputerPartOfDomain {
    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        return [bool]$computer.PartOfDomain
    }
    catch { return $false }
}

function Test-StudentVisibleAtLogon {
    param([Parameter(Mandatory=$true)][string]$Name)

    $studentObject = Get-LocalUserSafe -Name $Name
    if (-not $studentObject -or -not $studentObject.Enabled) { return $false }

    try {
        if (Test-Path $UserListRegistryPath) {
            $properties = Get-ItemProperty -Path $UserListRegistryPath -ErrorAction Stop
            $entry = $properties.PSObject.Properties[$Name]
            if ($null -ne $entry -and [int]$entry.Value -eq 0) { return $false }
        }
    }
    catch { return $false }

    if (Test-ComputerPartOfDomain) {
        try {
            if (-not (Test-Path $WindowsSystemPolicyPath)) { return $false }
            $policy = Get-ItemProperty -Path $WindowsSystemPolicyPath -Name 'EnumerateLocalUsers' -ErrorAction Stop
            if ([int]$policy.EnumerateLocalUsers -ne 1) { return $false }
        }
        catch { return $false }
    }

    return $true
}

function Ensure-StudentLoginVisibility {
    param([Parameter(Mandatory=$true)][string]$Name)

    $studentObject = Get-LocalUserSafe -Name $Name
    if (-not $studentObject) { throw "Student account '$Name' does not exist." }

    if (-not $studentObject.Enabled) {
        Enable-LocalUser -Name $Name -ErrorAction Stop
        Write-Host "[OK] Student account '$Name' enabled." -ForegroundColor Green
    }

    if (-not (Test-Path $UserListRegistryPath)) {
        New-Item -Path $UserListRegistryPath -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $UserListRegistryPath -Name $Name -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null

    if (Test-ComputerPartOfDomain) {
        if (-not (Test-Path $WindowsSystemPolicyPath)) {
            New-Item -Path $WindowsSystemPolicyPath -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $WindowsSystemPolicyPath -Name 'EnumerateLocalUsers' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        Write-Host '[OK] Local-user enumeration enabled for this domain-joined PC.' -ForegroundColor Green
    }

    Write-Host "[OK] '$Name' is configured to appear on the Windows sign-in screen." -ForegroundColor Green
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
        if ($plain1 -cne $plain2) { throw 'Passwords do not match.' }
    }
    finally {
        if ($ptr1 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1) }
        if ($ptr2 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2) }
        $plain1 = $null
        $plain2 = $null
    }

    return $password1
}

function Save-ManagedAccounts {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    try {
        if (-not (Test-Path $SalStatePath)) { New-Item -Path $SalStatePath -Force | Out-Null }
        New-ItemProperty -Path $SalStatePath -Name 'StudentUser' -PropertyType String -Value $Student -Force | Out-Null
        New-ItemProperty -Path $SalStatePath -Name 'AdminUser' -PropertyType String -Value $Admin -Force | Out-Null
    }
    catch {
        Write-Host "[WARN] Could not save S.A.L. managed-account state: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-ManagedAccounts {
    try {
        if (Test-Path $SalStatePath) {
            $saved = Get-ItemProperty -Path $SalStatePath -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$saved.StudentUser) -and
                -not [string]::IsNullOrWhiteSpace([string]$saved.AdminUser)) {
                return [pscustomobject]@{
                    Student = [string]$saved.StudentUser
                    Admin   = [string]$saved.AdminUser
                    Source  = 'Saved S.A.L. state'
                }
            }
        }
    }
    catch {}

    # Fallback for devices configured before saved state was introduced.
    $students = @(Get-LocalUser | Where-Object { $_.Description -eq 'School student account' })
    $admins = @(Get-LocalUser | Where-Object { $_.Description -eq 'Dedicated school PC administrator' })
    if ($students.Count -eq 1 -and $admins.Count -eq 1) {
        return [pscustomobject]@{
            Student = $students[0].Name
            Admin   = $admins[0].Name
            Source  = 'Auto-detected S.A.L. descriptions'
        }
    }

    return $null
}

function Get-DeviceState {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $studentObject = Get-LocalUserSafe -Name $Student
    $adminObject = Get-LocalUserSafe -Name $Admin

    [pscustomobject]@{
        AdminExists            = [bool]$adminObject
        AdminIsAdministrator   = if ($adminObject) { Test-LocalAdministrator -Name $Admin } else { $false }
        StudentExists          = [bool]$studentObject
        StudentIsEnabled       = if ($studentObject) { [bool]$studentObject.Enabled } else { $false }
        StudentVisibleAtLogon  = if ($studentObject) { Test-StudentVisibleAtLogon -Name $Student } else { $false }
        StudentIsStandard      = if ($studentObject) { -not (Test-LocalAdministrator -Name $Student) } else { $false }
        PasswordChangeBlocked  = if ($studentObject) { $studentObject.UserMayChangePassword -eq $false } else { $false }
    }
}

function Test-FullyConfigured {
    param($State)
    return (
        $State.AdminExists -and
        $State.AdminIsAdministrator -and
        $State.StudentExists -and
        $State.StudentIsEnabled -and
        $State.StudentVisibleAtLogon -and
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

    Write-Host "$(Mark $State.AdminExists) Dedicated admin account exists"
    Write-Host "$(Mark $State.AdminIsAdministrator) Dedicated admin has Administrator rights"
    Write-Host "$(Mark $State.StudentExists) Student account exists"
    Write-Host "$(Mark $State.StudentIsEnabled) Student account is enabled"
    Write-Host "$(Mark $State.StudentVisibleAtLogon) Student account is visible at sign-in"
    Write-Host "$(Mark $State.StudentIsStandard) Student account is Standard User"
    Write-Host "$(Mark $State.PasswordChangeBlocked) Student password creation/change is blocked"
}

function Get-DeviceIssues {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $state = Get-DeviceState -Student $Student -Admin $Admin
    $issues = @()
    if (-not $state.AdminExists) { $issues += "Dedicated admin '$Admin' is missing." }
    elseif (-not $state.AdminIsAdministrator) { $issues += "Dedicated admin '$Admin' does not have Administrator rights." }
    if (-not $state.StudentExists) { $issues += "Student '$Student' is missing." }
    else {
        if (-not $state.StudentIsEnabled) { $issues += "Student '$Student' is disabled." }
        if (-not $state.StudentVisibleAtLogon) { $issues += "Student '$Student' may be hidden from the sign-in / Switch user screen." }
        if (-not $state.StudentIsStandard) { $issues += "Student '$Student' still has Administrator rights." }
        if (-not $state.PasswordChangeBlocked) { $issues += "Student '$Student' can still create/change its local password." }
    }
    return @($issues)
}

function Show-LocalUsers {
    Write-Host ''
    Write-Host 'Local users:' -ForegroundColor Yellow
    $rows = foreach ($user in Get-LocalUser) {
        if ($user.Name -in @('DefaultAccount','WDAGUtilityAccount')) { continue }
        [pscustomobject]@{
            Name = $user.Name
            Enabled = $user.Enabled
            Administrator = Test-LocalAdministrator -Name $user.Name
            MayChangePassword = $user.UserMayChangePassword
        }
    }
    $rows | Format-Table -AutoSize
}

function Show-Diagnostics {
    Clear-Host
    Write-Host 'S.A.L. DIAGNOSTICS' -ForegroundColor Cyan
    Show-LocalUsers

    $managed = Get-ManagedAccounts
    Write-Host ''
    if ($managed) {
        Write-Host "Managed student : $($managed.Student)" -ForegroundColor Cyan
        Write-Host "Managed admin   : $($managed.Admin)" -ForegroundColor Cyan
        Write-Host "Detected from   : $($managed.Source)" -ForegroundColor DarkGray
        Write-Host ''
        $state = Get-DeviceState -Student $managed.Student -Admin $managed.Admin
        Show-State -State $state
        $issues = @(Get-DeviceIssues -Student $managed.Student -Admin $managed.Admin)
        if ($issues.Count -eq 0) {
            Write-Host "`n[OK] No managed-account issues detected." -ForegroundColor Green
        }
        else {
            Write-Host "`nDetected issues:" -ForegroundColor Yellow
            foreach ($issue in $issues) { Write-Host "  - $issue" -ForegroundColor Yellow }
        }
    }
    else {
        Write-Host 'No saved/auto-detected S.A.L. managed account pair was found.' -ForegroundColor Yellow
    }
}

function Invoke-PreexistingUserCleanup {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $protectedNames = @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount','defaultuser0')
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
        if ($candidate.Name -ieq [Environment]::UserName) { $suffix = '  [CURRENT SESSION]' }
        Write-Host "  - $($candidate.Name)$suffix"
    }

    Write-Host ''
    Write-Host 'Managed student/admin, Windows built-ins, and accounts created during this run are protected.' -ForegroundColor DarkGray
    Write-Host 'Only local account objects are removed; profile folders/data are not deleted.' -ForegroundColor DarkGray
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

function Invoke-SmartRepair {
    $managed = Get-ManagedAccounts
    if (-not $managed) {
        Write-Host 'No managed account pair is known yet. Run [2] Setup / reconfigure first.' -ForegroundColor Yellow
        return
    }

    $Student = $managed.Student
    $Admin = $managed.Admin
    Write-Host "Managed student: $Student"
    Write-Host "Managed admin  : $Admin"
    Write-Host ''

    $state = Get-DeviceState -Student $Student -Admin $Admin
    Show-State -State $state
    $issues = @(Get-DeviceIssues -Student $Student -Admin $Admin)
    if ($issues.Count -eq 0) {
        Write-Host "`n[OK] This setup is healthy. Nothing to repair." -ForegroundColor Green
        return
    }

    Write-Host "`nDetected issues:" -ForegroundColor Yellow
    foreach ($issue in $issues) { Write-Host "  - $issue" -ForegroundColor Yellow }
    Write-Host ''
    $confirm = Read-Host 'Repair all detected managed-account issues? (Y/N)'
    if ($confirm -notmatch '^(y|yes)$') { return }

    try {
        if (-not (Get-LocalUserSafe -Name $Admin)) {
            Write-Host "Creating missing dedicated administrator '$Admin'..." -ForegroundColor Yellow
            $newAdminPassword = Read-ConfirmedPassword -Label 'New admin password'
            New-LocalUser -Name $Admin -Password $newAdminPassword -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Dedicated admin '$Admin' created." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
            Write-Host "[OK] '$Admin' granted Administrator rights." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            throw 'Dedicated administrator could not be verified. Student account was not changed.'
        }

        if (-not (Get-LocalUserSafe -Name $Student)) {
            $createStudent = Read-Host "Student '$Student' is missing. Create it as a passwordless Standard User? (Y/N)"
            if ($createStudent -notmatch '^(y|yes)$') { throw 'Student repair cancelled because the managed student account is missing.' }
            New-LocalUser -Name $Student -NoPassword -Description 'School student account' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Passwordless student '$Student' created." -ForegroundColor Green
        }

        Ensure-StudentLoginVisibility -Name $Student

        if (Test-LocalAdministrator -Name $Student) {
            Remove-LocalGroupMember -Group $AdminGroup -Member $Student -ErrorAction Stop
            Write-Host "[OK] '$Student' changed to Standard User." -ForegroundColor Green
        }

        Set-LocalUser -Name $Student -UserMayChangePassword $false -ErrorAction Stop
        Write-Host "[OK] Password creation/change blocked for '$Student'." -ForegroundColor Green

        $finalState = Get-DeviceState -Student $Student -Admin $Admin
        Write-Host ''
        Show-State -State $finalState
        if (Test-FullyConfigured -State $finalState) {
            Save-ManagedAccounts -Student $Student -Admin $Admin
            Write-Host "`nDONE - All detected managed-account issues were repaired." -ForegroundColor Green
            Write-Host 'Sign out or restart once if the student tile does not refresh immediately.' -ForegroundColor Cyan
        }
        else {
            Write-Host "`nWARNING - Some issues remain." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-StudentSignInRepair {
    $managed = Get-ManagedAccounts
    $defaultStudent = if ($managed) { $managed.Student } else { '' }
    if ($defaultStudent) {
        $Student = Read-Host "Student username [$defaultStudent]"
        if ([string]::IsNullOrWhiteSpace($Student)) { $Student = $defaultStudent }
    }
    else {
        $Student = Read-Host 'Student username'
    }

    if ([string]::IsNullOrWhiteSpace($Student)) { return }
    if (-not (Get-LocalUserSafe -Name $Student)) {
        Write-Host "Student '$Student' does not exist." -ForegroundColor Red
        return
    }

    try {
        Ensure-StudentLoginVisibility -Name $Student
        if (Test-StudentVisibleAtLogon -Name $Student) {
            Write-Host "[OK] '$Student' is enabled and configured for sign-in visibility." -ForegroundColor Green
            Write-Host 'Sign out or restart once if Windows has not refreshed the account tile yet.' -ForegroundColor Cyan
        }
        else {
            Write-Host '[WARN] Windows still reports the account as not fully visible.' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-AdminMaintenance {
    $managed = Get-ManagedAccounts
    $defaultAdmin = if ($managed) { $managed.Admin } else { 'AdminControl' }
    $Admin = Read-Host "Admin username [$defaultAdmin]"
    if ([string]::IsNullOrWhiteSpace($Admin)) { $Admin = $defaultAdmin }

    if ($managed -and $Admin -ieq $managed.Student) {
        Write-Host 'The managed student account cannot be used as the dedicated admin.' -ForegroundColor Red
        return
    }

    $account = Get-LocalUserSafe -Name $Admin
    try {
        if (-not $account) {
            $create = Read-Host "Admin '$Admin' does not exist. Create it? (Y/N)"
            if ($create -notmatch '^(y|yes)$') { return }
            $password = Read-ConfirmedPassword -Label 'New admin password'
            New-LocalUser -Name $Admin -Password $password -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
            Write-Host "[OK] '$Admin' created and granted Administrator rights." -ForegroundColor Green
            return
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            $promote = Read-Host "'$Admin' is not an Administrator. Promote it? (Y/N)"
            if ($promote -match '^(y|yes)$') {
                Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
                Write-Host "[OK] '$Admin' granted Administrator rights." -ForegroundColor Green
            }
        }

        $change = Read-Host "Change/reset password for '$Admin'? (Y/N)"
        if ($change -match '^(y|yes)$') {
            Write-Host 'WARNING: An administrator reset can affect EFS-encrypted files or saved credentials owned by that account.' -ForegroundColor Yellow
            $confirmReset = Read-Host 'Continue? (Y/N)'
            if ($confirmReset -match '^(y|yes)$') {
                $replacementPassword = Read-ConfirmedPassword -Label 'New admin password'
                Set-LocalUser -Name $Admin -Password $replacementPassword -ErrorAction Stop
                Write-Host "[OK] Password changed/reset for '$Admin'." -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-FullSetup {
    Show-LocalUsers

    $Student = Read-Host 'Student username'
    if ([string]::IsNullOrWhiteSpace($Student)) {
        Write-Host 'Student username cannot be empty.' -ForegroundColor Red
        return
    }

    $CreateStudent = $false
    if (-not (Get-LocalUserSafe -Name $Student)) {
        Write-Host "Student '$Student' does not exist." -ForegroundColor Yellow
        $createChoice = Read-Host "Create '$Student' as a passwordless Standard User? (Y/N)"
        if ($createChoice -notmatch '^(y|yes)$') { return }
        $CreateStudent = $true
    }

    $Admin = $null
    $AdminExistedAtSelection = $false
    $PromoteExistingAdmin = $false
    $ChangeExistingAdminPassword = $false

    :AdminSelection while ($true) {
        $candidateAdmin = Read-Host 'Dedicated admin username [AdminControl]'
        if ([string]::IsNullOrWhiteSpace($candidateAdmin)) { $candidateAdmin = 'AdminControl' }

        if ($Student -ieq $candidateAdmin) {
            Write-Host 'Student and dedicated admin usernames must be different.' -ForegroundColor Red
            continue
        }

        $existingAdmin = Get-LocalUserSafe -Name $candidateAdmin
        if (-not $existingAdmin) {
            $Admin = $candidateAdmin
            break
        }

        Write-Host "`nLocal account '$candidateAdmin' already exists." -ForegroundColor Yellow
        Write-Host '[1] Use this existing account'
        Write-Host '[2] Choose another admin name'
        Write-Host '[3] Cancel'
        $existingChoice = Read-Host 'Choose [1/2/3]'

        if ($existingChoice -eq '1') {
            $Admin = $candidateAdmin
            $AdminExistedAtSelection = $true

            if (-not (Test-LocalAdministrator -Name $Admin)) {
                $promoteChoice = Read-Host "'$Admin' is not an Administrator. Promote it? (Y/N)"
                if ($promoteChoice -match '^(y|yes)$') { $PromoteExistingAdmin = $true }
                else { $Admin = $null; continue AdminSelection }
            }

            $changeChoice = Read-Host "Change/reset password for existing admin '$Admin'? (Y/N)"
            if ($changeChoice -match '^(y|yes)$') {
                Write-Host 'WARNING: Resetting another local account password can affect EFS-encrypted files or saved credentials.' -ForegroundColor Yellow
                $resetConfirm = Read-Host 'Continue with password reset? (Y/N)'
                if ($resetConfirm -match '^(y|yes)$') { $ChangeExistingAdminPassword = $true }
            }
            break AdminSelection
        }
        elseif ($existingChoice -eq '2') { continue AdminSelection }
        elseif ($existingChoice -eq '3') { return }
        else { Write-Host 'Invalid choice.' -ForegroundColor Red }
    }

    $state = Get-DeviceState -Student $Student -Admin $Admin
    Write-Host ''
    Show-State -State $state
    $MaintenanceRequested = $PromoteExistingAdmin -or $ChangeExistingAdminPassword

    if ((Test-FullyConfigured -State $state) -and -not $MaintenanceRequested) {
        Save-ManagedAccounts -Student $Student -Admin $Admin
        Write-Host "`n[OK] This device is already configured. Managed-account state saved." -ForegroundColor Green
        return
    }

    Write-Host ''
    if ($CreateStudent) { Write-Host "[PLAN] Create passwordless Standard User '$Student'." -ForegroundColor Cyan }
    if (-not $state.AdminExists) { Write-Host "[PLAN] Create dedicated admin '$Admin'." -ForegroundColor Cyan }
    if ($PromoteExistingAdmin) { Write-Host "[PLAN] Promote '$Admin' to Administrator." -ForegroundColor Cyan }
    if ($ChangeExistingAdminPassword) { Write-Host "[PLAN] Change/reset '$Admin' password." -ForegroundColor Cyan }
    if ($state.StudentExists -and (-not $state.StudentIsEnabled -or -not $state.StudentVisibleAtLogon)) {
        Write-Host "[PLAN] Enable/unhide '$Student' for Windows sign-in." -ForegroundColor Cyan
    }
    if ($state.StudentExists -and -not $state.StudentIsStandard) { Write-Host "[PLAN] Remove Administrator rights from '$Student'." -ForegroundColor Cyan }
    if ($state.StudentExists -and -not $state.PasswordChangeBlocked) { Write-Host "[PLAN] Block student password creation/change." -ForegroundColor Cyan }

    $confirm = Read-Host 'Apply configuration/maintenance changes? (Y/N)'
    if ($confirm -notmatch '^(y|yes)$') { return }

    try {
        if (-not $state.AdminExists) {
            $newAdminPassword = Read-ConfirmedPassword -Label 'New admin password'
            New-LocalUser -Name $Admin -Password $newAdminPassword -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Dedicated admin '$Admin' created." -ForegroundColor Green
        }
        elseif ($ChangeExistingAdminPassword) {
            $replacementPassword = Read-ConfirmedPassword -Label 'New admin password'
            Set-LocalUser -Name $Admin -Password $replacementPassword -ErrorAction Stop
            Write-Host "[OK] Password changed/reset for '$Admin'." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            if ($AdminExistedAtSelection -and -not $PromoteExistingAdmin) {
                throw "Existing account '$Admin' is not an Administrator and promotion was not approved."
            }
            Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
            Write-Host "[OK] '$Admin' granted Administrator rights." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            throw 'Dedicated administrator could not be verified. Student account was not changed.'
        }

        if ($CreateStudent -and -not (Get-LocalUserSafe -Name $Student)) {
            New-LocalUser -Name $Student -NoPassword -Description 'School student account' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Passwordless student '$Student' created." -ForegroundColor Green
        }

        if (-not (Get-LocalUserSafe -Name $Student)) { throw "Student '$Student' could not be found or created." }

        Ensure-StudentLoginVisibility -Name $Student

        if (Test-LocalAdministrator -Name $Student) {
            Remove-LocalGroupMember -Group $AdminGroup -Member $Student -ErrorAction Stop
            Write-Host "[OK] '$Student' changed to Standard User." -ForegroundColor Green
        }

        Set-LocalUser -Name $Student -UserMayChangePassword $false -ErrorAction Stop
        Write-Host "[OK] Password creation/change blocked for '$Student'." -ForegroundColor Green

        $finalState = Get-DeviceState -Student $Student -Admin $Admin
        Write-Host ''
        Show-State -State $finalState
        if (Test-FullyConfigured -State $finalState) {
            Save-ManagedAccounts -Student $Student -Admin $Admin
            Write-Host "`nDONE - This laptop is configured." -ForegroundColor Green
            Write-Host 'Sign out or restart once if the new student tile is not visible immediately.' -ForegroundColor Cyan
            $cleanupNow = Read-Host 'Check for extra pre-existing local users now? (Y/N)'
            if ($cleanupNow -match '^(y|yes)$') { Invoke-PreexistingUserCleanup -Student $Student -Admin $Admin }
        }
        else {
            Write-Host "`nWARNING - Some settings are still incomplete." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-StartupScreen {
    Clear-Host
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host '       SCHOOL ACCOUNT LOCKDOWN (S.A.L.)' -ForegroundColor Cyan
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host 'For authorized school-owned PCs only.'
    Write-Host ''

    $managed = Get-ManagedAccounts
    if ($managed) {
        Write-Host "Managed student: $($managed.Student)" -ForegroundColor Cyan
        Write-Host "Managed admin  : $($managed.Admin)" -ForegroundColor Cyan
        $issues = @(Get-DeviceIssues -Student $managed.Student -Admin $managed.Admin)
        if ($issues.Count -eq 0) {
            Write-Host '[OK] Quick scan: managed setup looks healthy.' -ForegroundColor Green
        }
        else {
            Write-Host "[!] Quick scan found $($issues.Count) issue(s):" -ForegroundColor Yellow
            foreach ($issue in $issues) { Write-Host "    - $issue" -ForegroundColor Yellow }
        }
    }
    else {
        Write-Host '[--] No managed S.A.L. account pair saved/detected yet.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '[1] Smart scan + repair managed setup'
    Write-Host '[2] Setup / reconfigure student + admin'
    Write-Host '[3] Repair student sign-in visibility'
    Write-Host '[4] Admin account maintenance'
    Write-Host '[5] Extra local-user cleanup'
    Write-Host '[6] Full diagnostics'
    Write-Host '[0] Exit'
    Write-Host ''
}

while ($true) {
    Show-StartupScreen
    $choice = Read-Host 'Choose an option'

    switch ($choice) {
        '1' { Clear-Host; Write-Host 'SMART REPAIR' -ForegroundColor Cyan; Invoke-SmartRepair }
        '2' { Clear-Host; Write-Host 'SETUP / RECONFIGURE' -ForegroundColor Cyan; Invoke-FullSetup }
        '3' { Clear-Host; Write-Host 'STUDENT SIGN-IN REPAIR' -ForegroundColor Cyan; Invoke-StudentSignInRepair }
        '4' { Clear-Host; Write-Host 'ADMIN MAINTENANCE' -ForegroundColor Cyan; Invoke-AdminMaintenance }
        '5' {
            Clear-Host
            Write-Host 'EXTRA LOCAL-USER CLEANUP' -ForegroundColor Cyan
            $managed = Get-ManagedAccounts
            if ($managed) { Invoke-PreexistingUserCleanup -Student $managed.Student -Admin $managed.Admin }
            else { Write-Host 'Run Setup / reconfigure first so S.A.L. knows which student/admin accounts must be protected.' -ForegroundColor Yellow }
        }
        '6' { Show-Diagnostics }
        '0' { break }
        default { Write-Host 'Invalid option.' -ForegroundColor Red }
    }

    if ($choice -eq '0') { break }
    Write-Host ''
    Read-Host 'Press Enter to return to the main menu'
}
