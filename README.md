# S.A.L.

Small PowerShell console tool for **authorized school-owned Windows 11 PCs**.

S.A.L. opens to a simple menu, remembers the managed **standard account + admin account**, and can check/fix common account problems later.

## Run

Open PowerShell and run:

```powershell
irm "https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1" | iex
```

If PowerShell is not already elevated, Windows asks for administrator permission and S.A.L. relaunches itself.

## Main menu

```text
[1] Check & fix
[2] Set up accounts
[3] Fix standard sign-in
[4] Admin tools
[5] Remove extra users
[6] Show full status
[0] Exit
```

## Standard account

The standard account is the normal everyday account on the school PC. S.A.L. can:

- create it with no password;
- make sure it is enabled;
- remove admin access from it;
- stop it from setting/changing its local password;
- repair Windows settings that can hide it from the sign-in / Switch user screen.

Older S.A.L. installs that used the word `student` are still recognized automatically for compatibility.

## Admin account

S.A.L. can create or use a separate admin account. If the requested admin name already exists, it asks before using or changing it.

It can also:

- give an existing account admin access after confirmation;
- change/reset the admin password when requested;
- recreate a missing managed admin from the Check & fix option.

S.A.L. does not add its own minimum password length. Windows password policy still applies.

## Check & fix

After setup, S.A.L. remembers the standard/admin account names (not their passwords). Later it can check for problems such as:

- missing admin account;
- admin access removed from the admin account;
- missing or disabled standard account;
- standard account hidden from the Windows user list;
- standard account accidentally having admin access;
- standard account being allowed to set/change a password.

It shows what it found and asks before making repairs.

## Fix standard sign-in

This option is for the case where the account exists in PowerShell but does not appear normally in Windows.

It checks/fixes:

- account enabled state;
- per-account Winlogon hiding;
- account switching visibility;
- normal user-tile visibility;
- local-user listing on domain-joined PCs.

After a repair, fully **sign out or restart Windows** before checking again. `Win + L` can still show a cached user list.

## Remove extra users

S.A.L. remembers which local accounts existed before the current run and can offer to remove extra ones after confirmation.

It protects:

- the selected standard account;
- the selected admin account;
- Windows built-in/system accounts;
- accounts created during the current S.A.L. run.

The cleanup removes the local account object only. It does not delete the user's profile folder/data in `C:\Users`.

## Important

Use only on computers you are authorized to administer. Keep the admin password secure and test changes on one spare/test PC before wider deployment.
