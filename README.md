# S.A.L.

Small PowerShell tool for **authorized school-owned Windows 11 PCs**.

S.A.L. now does one main job: choose an existing Windows **Standard User** and block that account from setting or changing its own local password.

## Workflow

1. Create the normal Standard User in **Windows Settings**.
2. Run S.A.L.
3. Choose the Standard User from the list.
4. S.A.L. sets:

```powershell
Set-LocalUser -Name "AccountName" -UserMayChangePassword $false
```

That is equivalent to:

```cmd
net user AccountName /passwordchg:no
```

S.A.L. does not create the Standard User, change sign-in registry settings, or manage Windows user tiles.

## Run

```powershell
irm "https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1" | iex
```

If PowerShell is not already elevated, Windows asks for administrator permission and S.A.L. relaunches itself.

It also works offline when `SchoolAccountLockdown.ps1` is run locally from a USB drive.

## Example

```text
S.A.L.
Standard account password lock

Standard accounts:
[1] Bayaraa  (active, password change allowed)
[2] LabUser  (active, password change blocked)

Choose an account number: 1

[OK] 'Bayaraa' is a standard account.
[OK] Password changes are now blocked.
```

## Check manually

```cmd
net user Bayaraa
```

Look for:

```text
User may change password    No
```

An administrator can still reset/change the Standard User's password when needed.

## Important

Use only on computers you are authorized to administer.
