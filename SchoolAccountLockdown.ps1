#requires -version 5.1
# S.A.L. - simple account setup for authorized school-owned Windows 11 PCs.

$ErrorActionPreference = 'Stop'

$RawScriptUrl = 'https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1'
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

function Get-StandardCandidates {
    $protectedNames = @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount','defaultuser0')

    return @(
        Get-LocalUser |
            Where-Object {
                $name = $_.Name
                $sid = [string]$_.SID

                ($protectedNames -notcontains $name) -and
                ($sid -notmatch '-(500|501|503|504)$') -and
                (-not (Test-LocalAdministrator -Name $name))
            } |
            Sort-Object Name
    )
}

function Select-StandardAccount {
    $accounts = @(Get-StandardCandidates)

    if ($accounts.Count -eq 0) {
        Write-Host ''
        Write-Host 'No standard account was found.' -ForegroundColor Yellow
        Write-Host 'Create the standard account in Windows Settings first, then run S.A.L. again.' -ForegroundColor Cyan
        Write-Host 'S.A.L. no longer creates standard accounts itself.' -ForegroundColor DarkGray
        return $null
    }

    Write-Host ''
    Write-Host 'Standard accounts found:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $account = $accounts[$i]
        $status = if ($account.Enabled) { 'active' } else { 'off' }
        Write-Host "[$($i + 1)] $($account.Name)  ($status)"
    }

    while ($true) {
        $choice = Read-Host 'Choose the standard account number'
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $accounts.Count) {
            return $accounts[$number - 1].Name
        }
        Write-Host 'Please choose one of the numbers shown above.' -ForegroundColor Red
    }
}

function Save-ManagedAccounts {
    param(
        [Parameter(Mandatory=$true)][string]$Standard,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    try {
        if (-not (Test-Path $SalStatePath)) { New-Item -Path $SalStatePath -Force | Out-Null }
        New-ItemProperty -Path $SalStatePath -Name 'StandardUser' -PropertyType String -Value $Standard -Force | Out-Null
        New-ItemProperty -Path $SalStatePath -Name 'AdminUser' -PropertyType String -Value $Admin -Force | Out-Null
        # Keep the old key so PCs configured by older S.A.L. builds still work.
        New-ItemProperty -Path $SalStatePath -Name 'StudentUser' -PropertyType String -Value $Standard -Force | Out-Null
    }
    catch {
        Write-Host "[WARN] S.A.L. could not remember these account names: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-ManagedAccounts {
    try {
        if (Test-Path $SalStatePath) {
            $saved = Get-ItemProperty -Path $SalStatePath -ErrorAction Stop
            $standard = [string]$saved.StandardUser
            if ([string]::IsNullOrWhiteSpace($standard)) { $standard = [string]$saved.StudentUser }
            $admin = [string]$saved.AdminUser

            if (-not [string]::IsNullOrWhiteSpace($standard) -and -not [string]::IsNullOrWhiteSpace($admin)) {
                return [pscustomobject]@{
                    Standard = $standard
                    Admin    = $admin
                }
            }
        }
    }
    catch {}

    return $null
}

function Get-DeviceState {
    param(
        [Parameter(Mandatory=$true)][string]$Standard,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $standardAccount = Get-LocalUserSafe -Name $Standard
    $adminAccount = Get-LocalUserSafe -Name $Admin

    [pscustomobject]@{
        AdminExists           = [bool]$adminAccount
        AdminIsAdministrator  = if ($adminAccount) { Test-LocalAdministrator -Name $Admin } else { $false }
        StandardExists        = [bool]$standardAccount
        StandardIsEnabled     = if ($standardAccount) { [bool]$standardAccount.Enabled } else { $false }
        StandardIsStandard    = if ($standardAccount) { -not (Test-LocalAdministrator -Name $Standard) } else { $false }
        PasswordChangeBlocked = if ($standardAccount) { $standardAccount.UserMayChangePassword -eq $false } else { $false }
    }
}

function Test-FullyConfigured {
    param($State)
    return (
        $State.AdminExists -and
        $State.AdminIsAdministrator -and
        $State.StandardExists -and
        $State.StandardIsEnabled -and
        $State.StandardIsStandard -and
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
    Write-Host "$(Mark $State.StandardExists) Standard account found"
    Write-Host "$(Mark $State.StandardIsEnabled) Standard account is active"
    Write-Host "$(Mark $State.StandardIsStandard) Account is a standard user"
    Write-Host "$(Mark $State.PasswordChangeBlocked) Standard account cannot set or change a password"
}

function Get-DeviceIssues {
    param(
        [Parameter(Mandatory=$true)][string]$Standard,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $state = Get-DeviceState -Standard $Standard -Admin $Admin
    $issues = @()

    if (-not $state.AdminExists) { $issues += "Admin account '$Admin' is missing." }
    elseif (-not $state.AdminIsAdministrator) { $issues += "'$Admin' is not an admin." }

    if (-not $state.StandardExists) {
        $issues += "Standard account '$Standard' is missing. Create it in Windows Settings, then use Set up accounts again."
        return @($issues)
    }

    if (-not $state.StandardIsEnabled) { $issues += "Standard account '$Standard' is turned off." }
    if (-not $state.StandardIsStandard) { $issues += "Standard account '$Standard' has admin access." }
    if (-not $state.PasswordChangeBlocked) { $issues += "Standard account '$Standard' can set or change a password." }

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
            Type              = if (Test-LocalAdministrator -Name $user.Name) { 'Admin' } else { 'Standard' }
            CanChangePassword = $user.UserMayChangePassword
        }
    }

    $rows | Format-Table -AutoSize
}

function Show-Diagnostics {
    Clear-Host
    Write-Host 'S.A.L.' -ForegroundColor Cyan
    Write-Host 'Full status' -ForegroundColor DarkGray
    Show-LocalUsers

    $managed = Get-ManagedAccounts
    Write-Host ''

    if (-not $managed) {
        Write-Host 'No saved setup yet. Use [2] Set up accounts.' -ForegroundColor Yellow
        return
    }

    Write-Host "Standard: $($managed.Standard)" -ForegroundColor Cyan
    Write-Host "Admin   : $($managed.Admin)" -ForegroundColor Cyan
    Write-Host ''

    $state = Get-DeviceState -Standard $managed.Standard -Admin $managed.Admin
    Show-State -State $state

    $issues = @(Get-DeviceIssues -Standard $managed.Standard -Admin $managed.Admin)
    if ($issues.Count -eq 0) {
        Write-Host "`n[OK] Everything looks good." -ForegroundColor Green
    }
    else {
        Write-Host "`nThings to fix:" -ForegroundColor Yellow
        foreach ($issue in $issues) { Write-Host "  - $issue" -ForegroundColor Yellow }
    }
}

function Invoke-PreexistingUserCleanup {
    param(
        [Parameter(Mandatory=$true)][string]$Standard,
        [Parameter(Mandatory=$true)][string]$Admin
    )

    $protectedNames = @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount','defaultuser0')
    $candidates = @(
        $InitialLocalUsers |
            Where-Object {
                $name = $_.Name
                $sid = [string]$_.SID

                ($name -ine $Standard) -and
                ($name -ine $Admin) -and
                ($name -ine [Environment]::UserName) -and
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
    foreach ($candidate in $candidates) { Write-Host "  - $($candidate.Name)" }

    Write-Host ''
    Write-Host 'The standard account, admin, current account, and Windows system accounts are protected.' -ForegroundColor DarkGray
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

    $Standard = $managed.Standard
    $Admin = $managed.Admin

    Write-Host "Standard: $Standard"
    Write-Host "Admin   : $Admin"
    Write-Host ''

    $state = Get-DeviceState -Standard $Standard -Admin $Admin
    Show-State -State $state

    $issues = @(Get-DeviceIssues -Standard $Standard -Admin $Admin)
    if ($issues.Count -eq 0) {
        Write-Host "`n[OK] Everything looks good. Nothing to fix." -ForegroundColor Green
        return
    }

    Write-Host "`nFound $($issues.Count) thing(s) to fix:" -ForegroundColor Yellow
    foreach ($issue in $issues) { Write-Host "  - $issue" -ForegroundColor Yellow }

    if (-not $state.StandardExists) {
        Write-Host ''
        Write-Host 'S.A.L. will not recreate the standard account.' -ForegroundColor Yellow
        Write-Host 'Create one in Windows Settings, then use [2] Set up accounts to select it.' -ForegroundColor Cyan
        return
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
            throw 'Admin access could not be confirmed, so the standard account was left unchanged.'
        }

        if (-not (Get-LocalUserSafe -Name $Standard)) {
            throw 'The saved standard account no longer exists.'
        }

        $standardAccount = Get-LocalUserSafe -Name $Standard
        if (-not $standardAccount.Enabled) {
            Enable-LocalUser -Name $Standard -ErrorAction Stop
            Write-Host "[OK] '$Standard' turned on." -ForegroundColor Green
        }

        if (Test-LocalAdministrator -Name $Standard) {
            Remove-LocalGroupMember -Group $AdminGroup -Member $Standard -ErrorAction Stop
            Write-Host "[OK] Admin access removed from '$Standard'." -ForegroundColor Green
        }

        Set-LocalUser -Name $Standard -UserMayChangePassword $false -ErrorAction Stop
        Write-Host "[OK] '$Standard' can no longer set or change a password." -ForegroundColor Green

        $finalState = Get-DeviceState -Standard $Standard -Admin $Admin
        Write-Host ''
        Show-State -State $finalState

        if (Test-FullyConfigured -State $finalState) {
            Save-ManagedAccounts -Standard $Standard -Admin $Admin
            Write-Host "`n[OK] Fixed." -ForegroundColor Green
        }
        else {
            Write-Host "`n[WARN] Some things still need attention." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-AdminMaintenance {
    $managed = Get-ManagedAccounts
    $defaultAdmin = if ($managed) { $managed.Admin } else { 'AdminControl' }

    $Admin = Read-Host "Admin account [$defaultAdmin]"
    if ([string]::IsNullOrWhiteSpace($Admin)) { $Admin = $defaultAdmin }

    if ($managed -and $Admin -ieq $managed.Standard) {
        Write-Host 'The standard account cannot be used as the admin account.' -ForegroundColor Red
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

    $Standard = Select-StandardAccount
    if ([string]::IsNullOrWhiteSpace($Standard)) { return }

    $saved = Get-ManagedAccounts
    $defaultAdmin = if ($saved) { $saved.Admin } else { 'AdminControl' }

    $Admin = $null
    $AdminExistedAtSelection = $false
    $PromoteExistingAdmin = $false
    $ChangeExistingAdminPassword = $false

    :AdminSelection while ($true) {
        $candidateAdmin = Read-Host "Admin account name [$defaultAdmin]"
        if ([string]::IsNullOrWhiteSpace($candidateAdmin)) { $candidateAdmin = $defaultAdmin }

        if ($Standard -ieq $candidateAdmin) {
            Write-Host 'Standard and admin account names must be different.' -ForegroundColor Red
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
                if ($promoteChoice -match '^(y|yes)$') { $PromoteExistingAdmin = $true }
                else { $Admin = $null; continue AdminSelection }
            }

            $changeChoice = Read-Host "Change the password for '$Admin'? (Y/N)"
            if ($changeChoice -match '^(y|yes)$') {
                Write-Host 'Note: resetting another account password can affect encrypted files or saved sign-ins owned by that account.' -ForegroundColor Yellow
                $resetConfirm = Read-Host 'Continue? (Y/N)'
                if ($resetConfirm -match '^(y|yes)$') { $ChangeExistingAdminPassword = $true }
            }

            break AdminSelection
        }
        elseif ($existingChoice -eq '2') { continue AdminSelection }
        elseif ($existingChoice -eq '3') { return }
        else { Write-Host 'Please choose 1, 2, or 3.' -ForegroundColor Red }
    }

    $state = Get-DeviceState -Standard $Standard -Admin $Admin
    Write-Host ''
    Show-State -State $state

    $maintenance = $PromoteExistingAdmin -or $ChangeExistingAdminPassword
    if ((Test-FullyConfigured -State $state) -and -not $maintenance) {
        Save-ManagedAccounts -Standard $Standard -Admin $Admin
        Write-Host "`n[OK] This PC is already set up." -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'S.A.L. will make these changes:' -ForegroundColor Cyan
    if (-not $state.AdminExists) { Write-Host "  - Create admin account '$Admin'." }
    if ($PromoteExistingAdmin) { Write-Host "  - Give '$Admin' admin access." }
    if ($ChangeExistingAdminPassword) { Write-Host "  - Change '$Admin' password." }
    if (-not $state.StandardIsEnabled) { Write-Host "  - Turn on '$Standard'." }
    if (-not $state.StandardIsStandard) { Write-Host "  - Remove admin access from '$Standard'." }
    if (-not $state.PasswordChangeBlocked) { Write-Host "  - Stop '$Standard' from setting or changing a password." }

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
            throw 'Admin access could not be confirmed, so the standard account was left unchanged.'
        }

        $standardAccount = Get-LocalUserSafe -Name $Standard
        if (-not $standardAccount) {
            throw "Standard account '$Standard' no longer exists. Create it in Windows Settings and run setup again."
        }

        if (-not $standardAccount.Enabled) {
            Enable-LocalUser -Name $Standard -ErrorAction Stop
            Write-Host "[OK] '$Standard' turned on." -ForegroundColor Green
        }

        if (Test-LocalAdministrator -Name $Standard) {
            Remove-LocalGroupMember -Group $AdminGroup -Member $Standard -ErrorAction Stop
            Write-Host "[OK] Admin access removed from '$Standard'." -ForegroundColor Green
        }

        Set-LocalUser -Name $Standard -UserMayChangePassword $false -ErrorAction Stop
        Write-Host "[OK] '$Standard' can no longer set or change a password." -ForegroundColor Green

        $finalState = Get-DeviceState -Standard $Standard -Admin $Admin
        Write-Host ''
        Show-State -State $finalState

        if (Test-FullyConfigured -State $finalState) {
            Save-ManagedAccounts -Standard $Standard -Admin $Admin
            Write-Host "`n[OK] Setup finished." -ForegroundColor Green

            $cleanupNow = Read-Host 'Check for old extra accounts now? (Y/N)'
            if ($cleanupNow -match '^(y|yes)$') {
                Invoke-PreexistingUserCleanup -Standard $Standard -Admin $Admin
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
        Write-Host "Standard: $($managed.Standard)" -ForegroundColor Cyan
        Write-Host "Admin   : $($managed.Admin)" -ForegroundColor Cyan

        $issues = @(Get-DeviceIssues -Standard $managed.Standard -Admin $managed.Admin)
        if ($issues.Count -eq 0) {
            Write-Host '[OK] Everything looks good.' -ForegroundColor Green
        }
        else {
            Write-Host "[!] Found $($issues.Count) thing(s) to fix:" -ForegroundColor Yellow
            foreach ($issue in $issues) { Write-Host "    - $issue" -ForegroundColor Yellow }
        }
    }
    else {
        $standardCount = @(Get-StandardCandidates).Count
        Write-Host "Standard accounts found: $standardCount" -ForegroundColor DarkGray
        Write-Host 'No saved setup yet.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '[1] Check & fix'
    Write-Host '[2] Set up accounts'
    Write-Host '[3] Admin tools'
    Write-Host '[4] Remove extra users'
    Write-Host '[5] Show full status'
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
            Write-Host 'Admin tools' -ForegroundColor DarkGray
            Write-Host ''
            Invoke-AdminMaintenance
        }
        '4' {
            Clear-Host
            Write-Host 'S.A.L.' -ForegroundColor Cyan
            Write-Host 'Remove extra users' -ForegroundColor DarkGray
            Write-Host ''

            $managed = Get-ManagedAccounts
            if ($managed) {
                Invoke-PreexistingUserCleanup -Standard $managed.Standard -Admin $managed.Admin
            }
            else {
                Write-Host 'Use [2] Set up accounts first so S.A.L. knows which standard and admin accounts to keep.' -ForegroundColor Yellow
            }
        }
        '5' { Show-Diagnostics }
        '0' { break MainLoop }
        default { Write-Host 'Please choose one of the numbers shown in the menu.' -ForegroundColor Red }
    }

    Write-Host ''
    Read-Host 'Press Enter to go back'
}
