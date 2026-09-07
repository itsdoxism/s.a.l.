# S.A.L. — School Account Lockdown

Small PowerShell console tool for **authorized school-owned Windows 11 PCs**.

It checks the machine first and only applies missing settings.

## What it does

- Shows local users.
- Lets you enter the student local account name.
- If that student account does not exist, S.A.L. can create it as a **passwordless Standard User**.
- Lets you choose the dedicated admin account name (default: `AdminControl`).
- Creates the dedicated admin account if it does not exist.
- If the chosen admin name already exists, S.A.L. does **not** silently reuse it. It asks whether to:
  1. use the existing account;
  2. choose another admin name; or
  3. cancel.
- If an existing chosen account is not an Administrator, S.A.L. asks for permission before promoting it.
- For an existing chosen admin, S.A.L. can optionally change/reset its password after an additional confirmation.
- S.A.L. does not impose its own password minimum length; Windows password policy still applies.
- Ensures the dedicated account is in the local Administrators group.
- Changes an existing selected student account to Standard User if necessary.
- Sets `UserMayChangePassword` to `False` for the student account.
- Detects when the laptop is already fully configured.
- Can offer to remove **other local users that existed before S.A.L. started**, but only after asking for permission.
- Never offers the selected student account, dedicated admin account, Windows built-in accounts, or accounts created during the current run for cleanup.
- Cleanup removes the local account object only; it does not delete the user's profile folder/data.
- Does not save the admin password to disk or logs.

## Fastest way to run

Open PowerShell and run:

```powershell
irm "https://raw.githubusercontent.com/itsdoxism/s.a.l./main/SchoolAccountLockdown.ps1" | iex
```

If PowerShell is not already elevated, S.A.L. requests Administrator permission through UAC and relaunches itself.

## New laptop flow

A typical fresh setup can be done entirely inside S.A.L.:

1. Enter the desired student username.
2. If it does not exist, answer `Y` to create it as a passwordless Standard User.
3. Enter the dedicated admin username, or press Enter for `AdminControl`.
4. If the admin account does not exist, enter its password twice.
5. If that admin name already exists, explicitly choose whether to use it, choose another name, or cancel.
6. If the existing account is not already an Administrator, approve or reject promotion.
7. Optionally change/reset the existing admin password.
8. Confirm pending changes with `Y`.
9. S.A.L. verifies the final state and prints `DONE` when complete.
10. If other pre-existing local users are found, S.A.L. lists them and asks whether to remove all listed accounts.

The dedicated administrator is created or verified **before** S.A.L. changes or locks down the student account.

## Existing admin maintenance

When the requested dedicated admin name is already in use:

```text
Local account 'AdminControl' already exists.

[1] Use this existing account
[2] Choose another admin name
[3] Cancel
```

If you choose the existing account and it is not an Administrator, S.A.L. asks before promoting it.

It then asks:

```text
Change/reset password for existing admin 'AdminControl'? (Y/N)
```

Choosing `Y` requires another confirmation before the password is reset. Windows may make EFS-encrypted files or saved credentials belonging to that existing account inaccessible after an administrator password reset, so S.A.L. shows a warning first.

## Extra-user cleanup safety

S.A.L. takes a snapshot of local users before it creates any accounts. Cleanup candidates come only from that original snapshot.

Therefore:

- a newly created student account cannot be selected for cleanup;
- a newly created dedicated admin account cannot be selected for cleanup;
- the chosen student/admin accounts are protected even if they already existed;
- built-in Windows accounts are protected;
- nothing is removed unless you answer `Y` to the cleanup prompt.

If the current signed-in account is one of the cleanup candidates, S.A.L. marks it as `[CURRENT SESSION]` before asking for confirmation.

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

When all checks pass and no admin-maintenance change is pending, the program shows:

```text
This device is already configured.
```

It can still offer cleanup for extra pre-existing local users after this check.

## Important

Use only on computers you are authorized to administer. Keep the dedicated administrator password secure and test the script on one spare/test laptop before wider deployment.
