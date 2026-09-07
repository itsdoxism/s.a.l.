#requires -version 5.1
# S.A.L. - block password changes on an existing Windows standard account.

$ErrorActionPreference = 'Stop'
$RawScriptUrl = 'https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1'

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

function Get-AdminGroupName {
    try {
        $group = Get-CimInstance Win32_Group -Filter "LocalAccount=True AND SID='S-1-5-32-544'" -ErrorAction Stop
        if ($group -and $group.Name) { return $group.Name }
    }
    catch {}

    return 'Administrators'
}

$AdminGroup = Get-AdminGroupName

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

function Get-StandardAccounts {
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
    $accounts = @(Get-StandardAccounts)

    if ($accounts.Count -eq 0) {
        Write-Host ''
        Write-Host 'No standard account was found.' -ForegroundColor Yellow
        Write-Host 'Create one in Windows Settings first, then run S.A.L. again.' -ForegroundColor Cyan
        return $null
    }

    Write-Host ''
    Write-Host 'Standard accounts:' -ForegroundColor Yellow

    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $account = $accounts[$i]
        $status = if ($account.Enabled) { 'active' } else { 'off' }
        $passwordStatus = if ($account.UserMayChangePassword) { 'password change allowed' } else { 'password change blocked' }
        Write-Host "[$($i + 1)] $($account.Name)  ($status, $passwordStatus)"
    }

    while ($true) {
        $choice = Read-Host 'Choose an account number'
        $number = 0

        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $accounts.Count) {
            return $accounts[$number - 1].Name
        }

        Write-Host 'Please choose one of the numbers shown above.' -ForegroundColor Red
    }
}

Ensure-Administrator
Clear-Host
Write-Host 'S.A.L.' -ForegroundColor Cyan
Write-Host 'Standard account password lock' -ForegroundColor DarkGray

$Standard = Select-StandardAccount
if ([string]::IsNullOrWhiteSpace($Standard)) {
    Read-Host 'Press Enter to close'
    exit
}

try {
    if (Test-LocalAdministrator -Name $Standard) {
        throw "'$Standard' is an admin account. S.A.L. only works with standard accounts."
    }

    $before = Get-LocalUser -Name $Standard -ErrorAction Stop

    if ($before.UserMayChangePassword -eq $false) {
        Write-Host ''
        Write-Host "[OK] '$Standard' is a standard account." -ForegroundColor Green
        Write-Host '[OK] Password changes are already blocked.' -ForegroundColor Green
    }
    else {
        Set-LocalUser -Name $Standard -UserMayChangePassword $false -ErrorAction Stop
        $after = Get-LocalUser -Name $Standard -ErrorAction Stop

        if ($after.UserMayChangePassword -ne $false) {
            throw 'Windows did not keep the password-change setting.'
        }

        Write-Host ''
        Write-Host "[OK] '$Standard' is a standard account." -ForegroundColor Green
        Write-Host '[OK] Password changes are now blocked.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host "Check anytime with: net user `"$Standard`"" -ForegroundColor DarkGray
    Write-Host 'Look for: User may change password    No' -ForegroundColor DarkGray
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Read-Host 'Press Enter to close'
