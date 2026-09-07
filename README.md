# S.A.L.

Small PowerShell console tool for **authorized school-owned Windows 11 PCs**.

S.A.L. uses an **existing Windows standard account** and a separate admin account. It no longer creates the standard account itself.

## Run

Open PowerShell and run:

```powershell
irm "https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1" | iex
```

If PowerShell is not already elevated, Windows asks for administrator permission and S.A.L. relaunches itself.

It also works offline when `SchoolAccountLockdown.ps1` is run locally from a USB drive.

## Main menu

```text
[1] Check & fix
[2] Set up accounts
[3] Admin tools
[4] Remove extra users
[5] Show full status
[0] Exit
```

## Standard account workflow

Create the normal standard account with **Windows Settings first**. This keeps Windows responsible for the account-creation/sign-in experience.

Then use `[2] Set up accounts` in S.A.L. S.A.L. finds local non-admin accounts and shows them as a numbered list:

```text
Standard accounts found:
[1] Bayaraa  (active)
[2] LabUser  (active)

Choose the standard account number:
```

S.A.L. does **not** create a missing standard account anymore. If none are found, it tells you to create one in Windows Settings and run S.A.L. again.

For the selected standard account S.A.L. can:

- make sure the account is enabled;
- make sure it does not have admin access;
- set `UserMayChangePassword` to `False` so the account cannot set/change its own local password.

S.A.L. no longer changes Winlogon/user-tile registry settings during normal setup. The standard account is expected to come from Windows Settings and keep Windows's normal sign-in behavior.

Older S.A.L. installs that saved the account under the old `StudentUser` state key are still recognized.

## Admin account

S.A.L. can create or use a separate admin account. If the requested admin name already exists, it asks before using or changing it.

It can also:

- give an existing account admin access after confirmation;
- change/reset the admin password when requested;
- recreate a missing managed admin from `[1] Check & fix`.

S.A.L. does not add its own minimum password length. Windows password policy still applies.

The admin account is verified before S.A.L. removes admin access from or locks down the standard account.

## Check & fix

After setup, S.A.L. remembers only the selected standard/admin account names, not their passwords.

Later it checks for problems such as:

- missing admin account;
- admin access removed from the admin account;
- standard account disabled;
- standard account accidentally having admin access;
- standard account being allowed to set/change its password.

If the saved standard account was deleted, S.A.L. deliberately does **not** recreate it. Create a replacement standard account in Windows Settings, then run `[2] Set up accounts` again and select it.

## Remove extra users

S.A.L. remembers which local accounts existed before the current run and can offer to remove extra ones after confirmation.

It protects:

- the selected standard account;
- the selected admin account;
- the account currently running S.A.L.;
- Windows built-in/system accounts.

Cleanup removes only the local account object. It does not delete the user's profile folder/data in `C:\Users`.

## Healthy setup

A saved setup is considered healthy when:

- the admin account exists;
- the admin account has admin access;
- the selected standard account exists and is enabled;
- the selected account is still a standard user;
- the selected standard account cannot set/change its own local password.

## Important

Use only on computers you are authorized to administer. Keep the admin password secure and test changes on one spare/test PC before wider deployment.
