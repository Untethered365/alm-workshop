# Hotfix Course Setup

The hotfix course adds two more environments, **HFXDEV** and **HFXTEST**, where you fix a bug in production without disturbing work already in progress in DEV.

**Do the [core setup](../Part%201%20-%20Set%20Up/README.md) first.** This script builds on it.

## Why a second account?

Each person can own at most **3 Developer environments**, and the core setup already uses all three (DEV, TEST, PROD).

So the hotfix environments belong to a separate **service account**, a second user in your tenant with its own allowance of 3. You don't sign in as it. The script creates it, gives it the environments, and makes **you** a System Administrator in them so you can work there as normal.

```
You (admin@...)                     ALM Service Account
  owns: ALM-DEV                       owns: ALM-HFXDEV
        ALM-TEST                            ALM-HFXTEST
        ALM-PROD                      (you're System Administrator in both)
```

Your pipeline service principal from the core setup is added to the hotfix environments too, so the same pipelines can deploy there.

## What you need

On top of the core setup, you need to be able to:

| Permission | Why |
|---|---|
| **User Administrator** (or Global Administrator) | To create the service account |
| **Power Platform Administrator** (or Global Administrator) | To create environments owned by the service account |

If you made your own tenant (Path 2), you're a Global Administrator and have both. Otherwise, check with:

```powershell
& '..\Part 1 - Set Up\Test-Readiness.ps1'
```

Section 6 of the output covers the hotfix course.

## Run it

Open PowerShell in this `Part 2 - Hotfix (For later)` folder:

```powershell
.\Setup-Hotfix.ps1
```

It takes about 10 minutes. It will:

1. Read your core setup from `..\my-alm-setup.json`.
2. Create the service account `alm.serviceaccount@<your domain>` with a random password, and give it a Power Apps Developer Plan license.
3. Create **ALM-HFXDEV** and **ALM-HFXTEST**, owned by the service account.
4. Add **you** and your **pipeline service principal** as System Administrator in both.
5. Create Azure DevOps service connections named `ALM-HFXDEV` and `ALM-HFXTEST`.
6. Save the service account password and the new environment URLs to `..\my-alm-setup.json`.

It's safe to run again if anything fails.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Can't find my-alm-setup.json" | Run Part 1 (`Setup-Core.ps1` in the `Part 1 - Set Up` folder) first, from the same download. |
| "Your tenant has no Power Apps Developer Plan licenses" | Sign in once at https://aka.ms/PowerAppsDevPlan **as the service account** (its password is in `my-alm-setup.json`), sign up for the Developer Plan, then run the script again. |
| Fails while adding you or the service principal, mentioning sign-in or MFA | The script briefly signs in as the service account with its password. If your tenant requires MFA for every sign-in (for example, a company Conditional Access policy), that's blocked. Ask your admin to exclude the service account from MFA, or use your own tenant (Path 2). |
| Timeout or "try again" errors | New accounts and environments take a few minutes to be ready everywhere. Wait and run the script again. |
