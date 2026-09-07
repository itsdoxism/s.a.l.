# S.A.L. — School Account Lockdown

Small PowerShell console tool for **authorized school-owned Windows 11 PCs**.

S.A.L. now opens to a main menu instead of immediately asking for usernames. It also remembers the managed student/admin pair after a successful setup and performs a quick health scan on later runs.

## Fastest way to run

Open PowerShell and run:

```powershell
irm "https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1" | iex
```

If PowerShell is not already elevated, S.A.L. requests Administrator permission through UAC and relaunches itself. The elevated relaunch cache-busts the raw GitHub URL so it is less likely to execute an older cached script.

## Main menu

After elevation S.A.L. shows a quick scan and this menu:

```text
[1] Smart scan + repair managed setup
[2] Setup / reconfigure student + admin
[3] Repair student sign-in visibility
[4] Admin account maintenance
[5] Extra local-user cleanup
[6] Full diagnostics
[0] Exit
```

So running the command no longer immediately drops you into the full setup prompts.

## Quick scan and saved state

After a successful setup S.A.L. stores only the managed **student username** and **admin username** under its local HKLM state key. It does **not** store either password.

On later runs S.A.L. can detect problems such as:

- dedicated admin account missing;
- dedicated admin no longer having Administrator rights;
- student account missing;
- student account disabled;
- student hidden from the sign-in / Switch user screen;
- student still having Administrator rights;
- student being allowed to create/change its own local password.

Older S.A.L.-created machines without saved state can also be auto-detected when there is exactly one account with each S.A.L. account description.

## Option 1 — Smart repair

Smart repair uses the saved/auto-detected student and admin names, shows every detected issue, asks for confirmation, and repairs the managed setup.

It can:

- recreate a missing dedicated admin after asking for a new password;
- restore Administrator rights to the dedicated admin;
- recreate a missing student after explicit confirmation;
- enable/unhide the student at Windows sign-in;
- remove Administrator rights from the student;
- block the student from creating/changing its local password.

The dedicated admin is verified before S.A.L. changes the student's privileges.

## Option 2 — Setup / reconfigure

Use this for a new laptop or when changing which accounts S.A.L. manages.

S.A.L. can:

- create a passwordless Standard student account;
- enable/unhide the selected student account;
- create a dedicated admin account;
- safely handle an admin-name collision by asking whether to use it, choose another name, or cancel;
- ask before promoting an existing non-admin account;
- optionally change/reset an existing admin password;
- demote the student from Administrators;
- set `UserMayChangePassword` to `False` for the student;
- save the selected managed student/admin pair for future scans.

S.A.L. does not impose its own minimum password length; Windows password policy still applies.

## Option 3 — Student sign-in repair

This is a focused repair for the case where PowerShell shows a local student account but Windows does not show it normally on the sign-in / Switch user screen.

It:

- enables the local account if disabled;
- forces the account visible in Winlogon `SpecialAccounts\UserList`;
- on domain-joined PCs, enables local-user enumeration.

Windows can still require one sign-out or restart before a newly created account tile refreshes.

## Option 4 — Admin maintenance

Admin maintenance lets an authorized operator:

- inspect/use the saved managed admin by default;
- create a missing admin;
- promote an existing local account after confirmation;
- optionally change/reset its password.

Password resets show a warning because administrator resets can affect EFS-encrypted files or saved credentials owned by that account.

## Option 5 — Extra local-user cleanup

S.A.L. takes a snapshot of local users when the script starts. Cleanup only considers accounts from that original snapshot and always protects:

- the managed student;
- the managed admin;
- Windows built-in accounts;
- accounts created during the current S.A.L. run.

It lists cleanup candidates and asks before deleting them. Cleanup removes the **local account object only**; it does not delete the profile folder/data.

## Option 6 — Full diagnostics

Diagnostics displays local users with important properties and then shows the complete managed-account state plus detected issues.

## Configured state

A device is healthy when:

- the dedicated admin exists and is an Administrator;
- the selected student exists;
- the student is enabled;
- the student is configured to be visible at sign-in;
- the student is a Standard User;
- the student cannot create/change its own local-account password.

## Important

Use only on computers you are authorized to administer. Keep the dedicated administrator password secure and test changes on one spare/test laptop before wider deployment.
