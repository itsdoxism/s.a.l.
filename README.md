# S.A.L. — School Account Lockdown

Small PowerShell console tool for **authorized school-owned Windows 11 PCs**.

It checks the machine first and only applies missing settings.

## What it does

- Shows local users.
- Lets you choose the student local account.
- Lets you choose the dedicated admin account name (default: `AdminControl`).
- Creates the dedicated admin account if it does not exist.
- Requires a 12+ character admin password when creating that account.
- Ensures the dedicated account is in the local Administrators group.
- Changes the selected student account to Standard User.
- Sets `UserMayChangePassword` to `False` for the student account.
- Detects when the laptop is already fully configured.
- Does not save the admin password to disk or logs.

## Fastest way to run

Open PowerShell and run:

```powershell
irm "https://raw.githubusercontent.com/itsdoxism/s.a.l/main/SchoolAccountLockdown.ps1" | iex
```

If PowerShell is not already elevated, S.A.L. requests Administrator permission through UAC and relaunches itself.

## Local run

You can also clone/download the repository and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\SchoolAccountLockdown.ps1
```

or double-click `Run.cmd`.

## Configured state

A device is considered fully configured when:

- the dedicated admin account exists;
- that account is an Administrator;
- the selected student account exists;
- the student account is not an Administrator;
- the student cannot change/create its own local-account password.

When all checks pass, the program shows:

```text
This device is already configured.
```

## Important

Use only on computers you are authorized to administer. Keep the dedicated administrator password secure and test the script on one spare/test laptop before wider deployment.
