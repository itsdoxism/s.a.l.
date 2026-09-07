# S.A.L. — School Account Lockdown

Small PowerShell console tool for **authorized school-owned Windows 11 PCs**.

It checks the machine first and only applies missing settings.

## What it does

- Shows local users.
- Lets you enter the student local account name.
- If that student account does not exist, S.A.L. can create it as a **passwordless Standard User**.
- Lets you choose the dedicated admin account name (default: `AdminControl`).
- Creates the dedicated admin account if it does not exist.
- Asks you to enter and confirm the admin password when creating that account. S.A.L. does not impose its own minimum length; Windows password policy still applies.
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

A typical fresh setup can now be done entirely inside S.A.L.:

1. Enter the desired student username.
2. If it does not exist, answer `Y` to create it as a passwordless Standard User.
3. Enter the dedicated admin username, or press Enter for `AdminControl`.
4. If the admin account does not exist, enter its password twice.
5. Confirm the changes with `Y`.
6. S.A.L. verifies the final state and prints `DONE` when complete.
7. If other pre-existing local users are found, S.A.L. lists them and asks whether to remove all listed accounts.

The dedicated administrator is created and verified **before** S.A.L. changes or locks down the student account.

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

When all checks pass, the program shows:

```text
This device is already configured.
```

It can still offer cleanup for extra pre-existing local users after this check.

## Important

Use only on computers you are authorized to administer. Keep the dedicated administrator password secure and test the script on one spare/test laptop before wider deployment.
