#requires -version 5.1
# S.A.L. - simple account setup for authorized school-owned Windows 11 PCs.

$ErrorActionPreference = 'Stop'

$RawScriptUrl = 'https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1'
$UserListRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
$WindowsSystemPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$LogonPolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$SalStatePath = 'HKLM:\SOFTWARE\S.A.L.'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    if (Test-IsAdministrator) { return }

    Write-Host 'S.A.L. needs admin access. Windows will ask for permission...' -ForegroundColor Yellow

    if ($PSCommandPath) {
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    else {
        $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $remote = "irm '${RawScriptUrl}?cb=$cacheBust' | iex"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
        $args = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args | Out-Null
    }
    catch {
        Write-Host "Could not get admin access: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to close'
    }
    exit
}

Ensure-Administrator

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
        foreach ($member in Get-LocalGroupMember -Group $AdminGroup -ErrorAction Stop) {
            if (($member.Name -split '\\')[-1] -ieq $Name) { return $true }
        }
    }
    catch {}
    return $false
}

function Test-ComputerPartOfDomain {
    try {
        return [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    }
    catch { return $false }
}

function Get-RegistryDword {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )

    try {
        if (-not (Test-Path $Path)) { return $null }
        $item = Get-ItemProperty -Path $Path -ErrorAction Stop
        $prop = $item.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $null }
        return [int]$prop.Value
    }
    catch {
        return $null
    }
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$Value
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
}

function Get-StudentSignInState {
    param([Parameter(Mandatory=$true)][string]$Name)

    $student = Get-LocalUserSafe -Name $Name
    $domainJoined = Test-ComputerPartOfDomain
    $userListValue = Get-RegistryDword -Path $UserListRegistryPath -Name $Name
    $hideFastSwitch = Get-RegistryDword -Path $LogonPolicyPath -Name 'HideFastUserSwitching'
    $hideLastUser = Get-RegistryDword -Path $LogonPolicyPath -Name 'DontDisplayLastUserName'
    $enumerateLocal = Get-RegistryDword -Path $WindowsSystemPolicyPath -Name 'EnumerateLocalUsers'

    $exists = [bool]$student
    $enabled = if ($student) { [bool]$student.Enabled } else { $false }
    $notHiddenByName = ($null -eq $userListValue -or $userListValue -ne 0)
    $fastSwitchAllowed = ($null -eq $hideFastSwitch -or $hideFastSwitch -eq 0)
    $lastUserTileAllowed = ($null -eq $hideLastUser -or $hideLastUser -eq 0)
    $localEnumerationAllowed = if ($domainJoined) { $enumerateLocal -eq 1 } else { $true }

    [pscustomobject]@{
        Exists                  = $exists
        Enabled                 = $enabled
        NotHiddenByName         = $notHiddenByName
        FastSwitchAllowed       = $fastSwitchAllowed
        LastUserTileAllowed     = $lastUserTileAllowed
        LocalEnumerationAllowed = $localEnumerationAllowed
        DomainJoined            = $domainJoined
        UserListValue           = $userListValue
        HideFastUserSwitching   = $hideFastSwitch
        DontDisplayLastUserName = $hideLastUser
        EnumerateLocalUsers     = $enumerateLocal
        Ready                   = (
            $exists -and
            $enabled -and
            $notHiddenByName -and
            $fastSwitchAllowed -and
            $lastUserTileAllowed -and
            $localEnumerationAllowed
        )
    }
}

function Test-StudentVisibleAtLogon {
    param([Parameter(Mandatory=$true)][string]$Name)
    return [bool](Get-StudentSignInState -Name $Name).Ready
}

function Ensure-StudentLoginVisibility {
    param([Parameter(Mandatory=$true)][string]$Name)

    $student = Get-LocalUserSafe -Name $Name
    if (-not $student) { throw "Student account '$Name' was not found." }

    if (-not $student.Enabled) {
        Enable-LocalUser -Name $Name -ErrorAction Stop
        Write-Host "[OK] '$Name' is turned on." -ForegroundColor Green
    }

    Set-RegistryDword -Path $UserListRegistryPath -Name $Name -Value 1
    Set-RegistryDword -Path $LogonPolicyPath -Name 'HideFastUserSwitching' -Value 0
    Set-RegistryDword -Path $LogonPolicyPath -Name 'DontDisplayLastUserName' -Value 0

    if (Test-ComputerPartOfDomain) {
        Set-RegistryDword -Path $WindowsSystemPolicyPath -Name 'EnumerateLocalUsers' -Value 1
    }

    $after = Get-StudentSignInState -Name $Name
    if (-not $after.Ready) {
        throw 'Windows still has a sign-in policy blocking this account. A domain/MDM policy may be putting the setting back.'
    }

    Write-Host "[OK] '$Name' is allowed to show on the sign-in / Switch user screen." -ForegroundColor Green
    Write-Host 'A full sign-out or restart is needed for Windows to refresh the user list.' -ForegroundColor Cyan
}

function Read-ConfirmedPassword {
    param([Parameter(Mandatory=$true)][string]$Label)

    $password1 = Read-Host $Label -AsSecureString
    $password2 = Read-Host 'Type the password again' -AsSecureString

    $ptr1 = [IntPtr]::Zero
    $ptr2 = [IntPtr]::Zero

    try {
        $ptr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1)
        $ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2)
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1)
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)

        if ($plain1 -cne $plain2) { throw 'The passwords do not match.' }
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
        if (-not (Test-Path $SalStatePath)) {
            New-Item -Path $SalStatePath -Force | Out-Null
        }

        New-ItemProperty -Path $SalStatePath -Name 'StudentUser' -PropertyType String -Value $Student -Force | Out-Null
        New-ItemProperty -Path $SalStatePath -Name 'AdminUser' -PropertyType String -Value $Admin -Force | Out-Null
    }
    catch {
        Write-Host "[WARN] S.A.L. could not remember these account names: $($_.Exception.Message)" -ForegroundColor Yellow
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
                    Source  = 'Saved setup'
                }
            }
        }
    }
    catch {}

    $students = @(Get-LocalUser | Where-Object { $_.Description -eq 'School student account' })
    $admins = @(Get-LocalUser | Where-Object { $_.Description -eq 'Dedicated school PC administrator' })

    if ($students.Count -eq 1 -and $admins.Count -eq 1) {
        return [pscustomobject]@{
            Student = $students[0].Name
            Admin   = $admins[0].Name
            Source  = 'Found automatically'
        }
    }

    return $null
}

function Get-DeviceState {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $student = Get-LocalUserSafe -Name $Student
    $admin = Get-LocalUserSafe -Name $Admin
    $signIn = Get-StudentSignInState -Name $Student

    [pscustomobject]@{
        AdminExists           = [bool]$admin
        AdminIsAdministrator  = if ($admin) { Test-LocalAdministrator -Name $Admin } else { $false }
        StudentExists         = [bool]$student
        StudentIsEnabled      = if ($student) { [bool]$student.Enabled } else { $false }
        StudentVisibleAtLogon = [bool]$signIn.Ready
        StudentIsStandard     = if ($student) { -not (Test-LocalAdministrator -Name $Student) } else { $false }
        PasswordChangeBlocked = if ($student) { $student.UserMayChangePassword -eq $false } else { $false }
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

    Write-Host "$(Mark $State.AdminExists) Admin account found"
    Write-Host "$(Mark $State.AdminIsAdministrator) Admin access is on"
    Write-Host "$(Mark $State.StudentExists) Student account found"
    Write-Host "$(Mark $State.StudentIsEnabled) Student account is active"
    Write-Host "$(Mark $State.StudentVisibleAtLogon) Student can appear in the Windows user list"
    Write-Host "$(Mark $State.StudentIsStandard) Student is a standard user"
    Write-Host "$(Mark $State.PasswordChangeBlocked) Student cannot set or change a password"
}

function Get-DeviceIssues {
    param(
        [Parameter(Mandatory=$true)][string]$Student,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $state = Get-DeviceState -Student $Student -Admin $Admin
    $issues = @()

    if (-not $state.AdminExists) {
        $issues += "Admin account '$Admin' is missing."
    }
    elseif (-not $state.AdminIsAdministrator) {
        $issues += "'$Admin' is not an admin."
    }

    if (-not $state.StudentExists) {
        $issues += "Student account '$Student' is missing."
        return @($issues)
    }

    if (-not $state.StudentIsEnabled) {
        $issues += "Student account '$Student' is turned off."
    }

    $signIn = Get-StudentSignInState -Name $Student

    if (-not $signIn.NotHiddenByName) {
        $issues += "Windows has '$Student' hidden by name."
    }
    if (-not $signIn.FastSwitchAllowed) {
        $issues += 'Windows has account switching hidden.'
    }
    if (-not $signIn.LastUserTileAllowed) {
        $issues += 'Windows is set not to show the last signed-in user tile.'
    }
    if (-not $signIn.LocalEnumerationAllowed) {
        $issues += 'Windows is not listing local users on this domain-joined PC.'
    }

    if (-not $state.StudentIsStandard) {
        $issues += "Student account '$Student' has admin access."
    }
    if (-not $state.PasswordChangeBlocked) {
        $issues += "Student account '$Student' can set or change a password."
    }

    return @($issues)
}

function Show-LocalUsers {
    Write-Host ''
    Write-Host 'Accounts on this PC:' -ForegroundColor Yellow

    $rows = foreach ($user in Get-LocalUser) {
        if ($user.Name -in @('DefaultAccount','WDAGUtilityAccount')) { continue }

        [pscustomobject]@{
            Name              = $user.Name
            Active            = $user.Enabled
            Admin             = Test-LocalAdministrator -Name $user.Name
            CanChangePassword = $user.UserMayChangePassword
        }
    }

    $rows | Format-Table -AutoSize
}

function Show-SignInDetails {
    param([Parameter(Mandatory=$true)][string]$Student)

    $s = Get-StudentSignInState -Name $Student

    Write-Host ''
    Write-Host 'Windows user-list checks:' -ForegroundColor Yellow
    Write-Host "Account active             : $($s.Enabled)"
    Write-Host "Hidden by account name     : $(-not $s.NotHiddenByName)"
    Write-Host "Account switching allowed  : $($s.FastSwitchAllowed)"
    Write-Host "User tiles allowed         : $($s.LastUserTileAllowed)"

    if ($s.DomainJoined) {
        Write-Host "Local users listed         : $($s.LocalEnumerationAllowed)"
    }

    Write-Host "Ready                      : $($s.Ready)"
}

function Show-Diagnostics {
    Clear-Host
    Write-Host 'S.A.L.' -ForegroundColor Cyan
    Write-Host 'Full status' -ForegroundColor DarkGray

    Show-LocalUsers

    $managed = Get-ManagedAccounts
    Write-Host ''

    if (-not $managed) {
        Write-Host 'S.A.L. does not know the student/admin pair yet. Use [2] Set up accounts first.' -ForegroundColor Yellow
        return
    }

    Write-Host "Student: $($managed.Student)" -ForegroundColor Cyan
    Write-Host "Admin  : $($managed.Admin)" -ForegroundColor Cyan
    Write-Host "Source : $($managed.Source)" -ForegroundColor DarkGray
    Write-Host ''

    $state = Get-DeviceState -Student $managed.Student -Admin $managed.Admin
    Show-State -State $state
    Show-SignInDetails -Student $managed.Student

    $issues = @(Get-DeviceIssues -Student $managed.Student -Admin $managed.Admin)

    if ($issues.Count -eq 0) {
        Write-Host "`n[OK] Everything looks good." -ForegroundColor Green
    }
    else {
        Write-Host "`nThings to fix:" -ForegroundColor Yellow
        foreach ($issue in $issues) {
            Write-Host "  - $issue" -ForegroundColor Yellow
        }
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
        Write-Host '[OK] No extra old accounts found.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'Extra accounts found:' -ForegroundColor Yellow

    foreach ($candidate in $candidates) {
        $suffix = ''
        if ($candidate.Name -ieq [Environment]::UserName) {
            $suffix = '  [YOU ARE USING THIS NOW]'
        }
        Write-Host "  - $($candidate.Name)$suffix"
    }

    Write-Host ''
    Write-Host 'The student, admin, Windows system accounts, and accounts created during this run are protected.' -ForegroundColor DarkGray
    Write-Host 'This removes the account only. Files in C:\Users are not deleted.' -ForegroundColor DarkGray

    $choice = Read-Host 'Remove all accounts listed above? (Y/N)'
    if ($choice -notmatch '^(y|yes)$') {
        Write-Host '[SKIP] Nothing was removed.' -ForegroundColor Yellow
        return
    }

    foreach ($candidate in $candidates) {
        try {
            Remove-LocalUser -Name $candidate.Name -ErrorAction Stop
            Write-Host "[OK] Removed '$($candidate.Name)'." -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not remove '$($candidate.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Invoke-SmartRepair {
    $managed = Get-ManagedAccounts

    if (-not $managed) {
        Write-Host 'No saved setup yet. Use [2] Set up accounts first.' -ForegroundColor Yellow
        return
    }

    $Student = $managed.Student
    $Admin = $managed.Admin

    Write-Host "Student: $Student"
    Write-Host "Admin  : $Admin"
    Write-Host ''

    $state = Get-DeviceState -Student $Student -Admin $Admin
    Show-State -State $state

    $issues = @(Get-DeviceIssues -Student $Student -Admin $Admin)

    if ($issues.Count -eq 0) {
        Write-Host "`n[OK] Everything looks good. Nothing to fix." -ForegroundColor Green
        return
    }

    Write-Host "`nFound $($issues.Count) thing(s) to fix:" -ForegroundColor Yellow
    foreach ($issue in $issues) {
        Write-Host "  - $issue" -ForegroundColor Yellow
    }

    Write-Host ''
    $confirm = Read-Host 'Fix everything listed above? (Y/N)'
    if ($confirm -notmatch '^(y|yes)$') { return }

    try {
        if (-not (Get-LocalUserSafe -Name $Admin)) {
            Write-Host "Admin account '$Admin' is missing. Creating it..." -ForegroundColor Yellow
            $password = Read-ConfirmedPassword -Label 'New admin password'
            New-LocalUser -Name $Admin -Password $password -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Admin account '$Admin' created." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
            Write-Host "[OK] Admin access turned on for '$Admin'." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            throw 'Admin access could not be confirmed, so the student account was left unchanged.'
        }

        if (-not (Get-LocalUserSafe -Name $Student)) {
            $create = Read-Host "Student account '$Student' is missing. Create it with no password? (Y/N)"
            if ($create -notmatch '^(y|yes)$') {
                throw 'Fix cancelled because the student account is missing.'
            }

            New-LocalUser -Name $Student -NoPassword -Description 'School student account' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Student account '$Student' created." -ForegroundColor Green
        }

        Ensure-StudentLoginVisibility -Name $Student

        if (Test-LocalAdministrator -Name $Student) {
            Remove-LocalGroupMember -Group $AdminGroup -Member $Student -ErrorAction Stop
            Write-Host "[OK] Admin access removed from '$Student'." -ForegroundColor Green
        }

        Set-LocalUser -Name $Student -UserMayChangePassword $false -ErrorAction Stop
        Write-Host "[OK] '$Student' can no longer set or change a password." -ForegroundColor Green

        $finalState = Get-DeviceState -Student $Student -Admin $Admin
        Write-Host ''
        Show-State -State $finalState

        if (Test-FullyConfigured -State $finalState) {
            Save-ManagedAccounts -Student $Student -Admin $Admin
            Write-Host "`n[OK] Fixed." -ForegroundColor Green
            Write-Host 'Now fully sign out or restart Windows before checking the user list.' -ForegroundColor Cyan
        }
        else {
            Write-Host "`n[WARN] Some things still need attention." -ForegroundColor Yellow
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
        $Student = Read-Host "Student account [$defaultStudent]"
        if ([string]::IsNullOrWhiteSpace($Student)) { $Student = $defaultStudent }
    }
    else {
        $Student = Read-Host 'Student account name'
    }

    if ([string]::IsNullOrWhiteSpace($Student)) { return }

    if (-not (Get-LocalUserSafe -Name $Student)) {
        Write-Host "Student account '$Student' was not found." -ForegroundColor Red
        return
    }

    Show-SignInDetails -Student $Student
    Write-Host ''

    $confirm = Read-Host 'Apply the Windows user-list fixes? (Y/N)'
    if ($confirm -notmatch '^(y|yes)$') { return }

    try {
        Ensure-StudentLoginVisibility -Name $Student
        Show-SignInDetails -Student $Student

        Write-Host ''
        Write-Host '[OK] Sign-in settings were repaired.' -ForegroundColor Green
        Write-Host 'IMPORTANT: fully sign out or restart Windows now. Locking with Win+L may still show the old cached user list.' -ForegroundColor Cyan
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-AdminMaintenance {
    $managed = Get-ManagedAccounts
    $defaultAdmin = if ($managed) { $managed.Admin } else { 'AdminControl' }

    $Admin = Read-Host "Admin account [$defaultAdmin]"
    if ([string]::IsNullOrWhiteSpace($Admin)) { $Admin = $defaultAdmin }

    if ($managed -and $Admin -ieq $managed.Student) {
        Write-Host 'The student account cannot be used as the admin account.' -ForegroundColor Red
        return
    }

    $account = Get-LocalUserSafe -Name $Admin

    try {
        if (-not $account) {
            $create = Read-Host "'$Admin' does not exist. Create this admin account? (Y/N)"
            if ($create -notmatch '^(y|yes)$') { return }

            $password = Read-ConfirmedPassword -Label 'New admin password'
            New-LocalUser -Name $Admin -Password $password -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
            Write-Host "[OK] '$Admin' created with admin access." -ForegroundColor Green
            return
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            $promote = Read-Host "'$Admin' does not have admin access. Turn it on? (Y/N)"
            if ($promote -match '^(y|yes)$') {
                Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
                Write-Host "[OK] Admin access turned on for '$Admin'." -ForegroundColor Green
            }
        }

        $change = Read-Host "Change the password for '$Admin'? (Y/N)"
        if ($change -match '^(y|yes)$') {
            Write-Host 'Note: resetting another account password can affect encrypted files or saved sign-ins owned by that account.' -ForegroundColor Yellow
            $confirmReset = Read-Host 'Continue? (Y/N)'

            if ($confirmReset -match '^(y|yes)$') {
                $replacement = Read-ConfirmedPassword -Label 'New admin password'
                Set-LocalUser -Name $Admin -Password $replacement -ErrorAction Stop
                Write-Host "[OK] Password changed for '$Admin'." -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-FullSetup {
    Show-LocalUsers

    $Student = Read-Host 'Student account name'
    if ([string]::IsNullOrWhiteSpace($Student)) {
        Write-Host 'Student account name cannot be empty.' -ForegroundColor Red
        return
    }

    $CreateStudent = $false
    if (-not (Get-LocalUserSafe -Name $Student)) {
        $createChoice = Read-Host "'$Student' does not exist. Create it with no password? (Y/N)"
        if ($createChoice -notmatch '^(y|yes)$') { return }
        $CreateStudent = $true
    }

    $Admin = $null
    $AdminExistedAtSelection = $false
    $PromoteExistingAdmin = $false
    $ChangeExistingAdminPassword = $false

    :AdminSelection while ($true) {
        $candidateAdmin = Read-Host 'Admin account name [AdminControl]'
        if ([string]::IsNullOrWhiteSpace($candidateAdmin)) { $candidateAdmin = 'AdminControl' }

        if ($Student -ieq $candidateAdmin) {
            Write-Host 'Student and admin account names must be different.' -ForegroundColor Red
            continue
        }

        $existing = Get-LocalUserSafe -Name $candidateAdmin

        if (-not $existing) {
            $Admin = $candidateAdmin
            break
        }

        Write-Host "`nAccount '$candidateAdmin' already exists." -ForegroundColor Yellow
        Write-Host '[1] Use this account'
        Write-Host '[2] Pick another name'
        Write-Host '[3] Cancel'
        $existingChoice = Read-Host 'Choose 1, 2, or 3'

        if ($existingChoice -eq '1') {
            $Admin = $candidateAdmin
            $AdminExistedAtSelection = $true

            if (-not (Test-LocalAdministrator -Name $Admin)) {
                $promoteChoice = Read-Host "'$Admin' is not an admin. Give it admin access? (Y/N)"
                if ($promoteChoice -match '^(y|yes)$') {
                    $PromoteExistingAdmin = $true
                }
                else {
                    $Admin = $null
                    continue AdminSelection
                }
            }

            $changeChoice = Read-Host "Change the password for '$Admin'? (Y/N)"
            if ($changeChoice -match '^(y|yes)$') {
                Write-Host 'Note: resetting another account password can affect encrypted files or saved sign-ins owned by that account.' -ForegroundColor Yellow
                $resetConfirm = Read-Host 'Continue? (Y/N)'
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
            return
        }
        else {
            Write-Host 'Please choose 1, 2, or 3.' -ForegroundColor Red
        }
    }

    $state = Get-DeviceState -Student $Student -Admin $Admin
    Write-Host ''
    Show-State -State $state

    $maintenance = $PromoteExistingAdmin -or $ChangeExistingAdminPassword

    if ((Test-FullyConfigured -State $state) -and -not $maintenance) {
        Save-ManagedAccounts -Student $Student -Admin $Admin
        Write-Host "`n[OK] This PC is already set up." -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'S.A.L. will make these changes:' -ForegroundColor Cyan

    if ($CreateStudent) { Write-Host "  - Create student account '$Student' with no password." }
    if (-not $state.AdminExists) { Write-Host "  - Create admin account '$Admin'." }
    if ($PromoteExistingAdmin) { Write-Host "  - Give '$Admin' admin access." }
    if ($ChangeExistingAdminPassword) { Write-Host "  - Change '$Admin' password." }

    $signIn = Get-StudentSignInState -Name $Student
    if ($CreateStudent -or -not $signIn.Ready) {
        Write-Host "  - Make '$Student' appear in the Windows user list."
    }

    if ($state.StudentExists -and -not $state.StudentIsStandard) {
        Write-Host "  - Remove admin access from '$Student'."
    }
    if ($state.StudentExists -and -not $state.PasswordChangeBlocked) {
        Write-Host "  - Stop '$Student' from setting or changing a password."
    }

    $confirm = Read-Host 'Continue? (Y/N)'
    if ($confirm -notmatch '^(y|yes)$') { return }

    try {
        if (-not $state.AdminExists) {
            $newAdminPassword = Read-ConfirmedPassword -Label 'New admin password'
            New-LocalUser -Name $Admin -Password $newAdminPassword -Description 'Dedicated school PC administrator' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Admin account '$Admin' created." -ForegroundColor Green
        }
        elseif ($ChangeExistingAdminPassword) {
            $replacementPassword = Read-ConfirmedPassword -Label 'New admin password'
            Set-LocalUser -Name $Admin -Password $replacementPassword -ErrorAction Stop
            Write-Host "[OK] Password changed for '$Admin'." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            if ($AdminExistedAtSelection -and -not $PromoteExistingAdmin) {
                throw "'$Admin' is not an admin and permission to change that was not given."
            }

            Add-LocalGroupMember -Group $AdminGroup -Member $Admin -ErrorAction Stop
            Write-Host "[OK] Admin access turned on for '$Admin'." -ForegroundColor Green
        }

        if (-not (Test-LocalAdministrator -Name $Admin)) {
            throw 'Admin access could not be confirmed, so the student account was left unchanged.'
        }

        if ($CreateStudent -and -not (Get-LocalUserSafe -Name $Student)) {
            New-LocalUser -Name $Student -NoPassword -Description 'School student account' -ErrorAction Stop | Out-Null
            Write-Host "[OK] Student account '$Student' created." -ForegroundColor Green
        }

        if (-not (Get-LocalUserSafe -Name $Student)) {
            throw "Student account '$Student' could not be found or created."
        }

        Ensure-StudentLoginVisibility -Name $Student

        if (Test-LocalAdministrator -Name $Student) {
            Remove-LocalGroupMember -Group $AdminGroup -Member $Student -ErrorAction Stop
            Write-Host "[OK] Admin access removed from '$Student'." -ForegroundColor Green
        }

        Set-LocalUser -Name $Student -UserMayChangePassword $false -ErrorAction Stop
        Write-Host "[OK] '$Student' can no longer set or change a password." -ForegroundColor Green

        $finalState = Get-DeviceState -Student $Student -Admin $Admin
        Write-Host ''
        Show-State -State $finalState

        if (Test-FullyConfigured -State $finalState) {
            Save-ManagedAccounts -Student $Student -Admin $Admin
            Write-Host "`n[OK] Setup finished." -ForegroundColor Green
            Write-Host 'IMPORTANT: fully sign out or restart Windows before checking the student account in the user list.' -ForegroundColor Cyan

            $cleanupNow = Read-Host 'Check for old extra accounts now? (Y/N)'
            if ($cleanupNow -match '^(y|yes)$') {
                Invoke-PreexistingUserCleanup -Student $Student -Admin $Admin
            }
        }
        else {
            Write-Host "`n[WARN] Some things still need attention." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-StartupScreen {
    Clear-Host
    Write-Host 'S.A.L.' -ForegroundColor Cyan
    Write-Host 'School PC account setup' -ForegroundColor DarkGray
    Write-Host ''

    $managed = Get-ManagedAccounts

    if ($managed) {
        Write-Host "Student: $($managed.Student)" -ForegroundColor Cyan
        Write-Host "Admin  : $($managed.Admin)" -ForegroundColor Cyan

        $issues = @(Get-DeviceIssues -Student $managed.Student -Admin $managed.Admin)

        if ($issues.Count -eq 0) {
            Write-Host '[OK] Everything looks good.' -ForegroundColor Green
        }
        else {
            Write-Host "[!] Found $($issues.Count) thing(s) to fix:" -ForegroundColor Yellow
            foreach ($issue in $issues) {
                Write-Host "    - $issue" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host 'No saved setup yet.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '[1] Check & fix'
    Write-Host '[2] Set up accounts'
    Write-Host '[3] Fix student sign-in'
    Write-Host '[4] Admin tools'
    Write-Host '[5] Remove extra users'
    Write-Host '[6] Show full status'
    Write-Host '[0] Exit'
    Write-Host ''
}

:MainLoop while ($true) {
    Show-StartupScreen
    $choice = Read-Host 'Choose an option'

    switch ($choice) {
        '1' {
            Clear-Host
            Write-Host 'S.A.L.' -ForegroundColor Cyan
            Write-Host 'Check & fix' -ForegroundColor DarkGray
            Write-Host ''
            Invoke-SmartRepair
        }
        '2' {
            Clear-Host
            Write-Host 'S.A.L.' -ForegroundColor Cyan
            Write-Host 'Set up accounts' -ForegroundColor DarkGray
            Write-Host ''
            Invoke-FullSetup
        }
        '3' {
            Clear-Host
            Write-Host 'S.A.L.' -ForegroundColor Cyan
            Write-Host 'Fix student sign-in' -ForegroundColor DarkGray
            Write-Host ''
            Invoke-StudentSignInRepair
        }
        '4' {
            Clear-Host
            Write-Host 'S.A.L.' -ForegroundColor Cyan
            Write-Host 'Admin tools' -ForegroundColor DarkGray
            Write-Host ''
            Invoke-AdminMaintenance
        }
        '5' {
            Clear-Host
            Write-Host 'S.A.L.' -ForegroundColor Cyan
            Write-Host 'Remove extra users' -ForegroundColor DarkGray
            Write-Host ''

            $managed = Get-ManagedAccounts
            if ($managed) {
                Invoke-PreexistingUserCleanup -Student $managed.Student -Admin $managed.Admin
            }
            else {
                Write-Host 'Use [2] Set up accounts first so S.A.L. knows which student and admin accounts to keep.' -ForegroundColor Yellow
            }
        }
        '6' {
            Show-Diagnostics
        }
        '0' {
            break MainLoop
        }
        default {
            Write-Host 'Please choose one of the numbers shown in the menu.' -ForegroundColor Red
        }
    }

    Write-Host ''
    Read-Host 'Press Enter to go back'
}
