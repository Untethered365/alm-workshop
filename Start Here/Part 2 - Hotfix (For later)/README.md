# Hotfix Course Setup

The hotfix course adds two more environments, **HFXDEV** and **HFXTEST**, where you fix a bug in production without disturbing work already in progress in DEV.

**Do the [core setup](../Part%201%20-%20Set%20Up/README.md) first.** This script builds on it.

## Why a second account?

Each person can own at most **3 Developer environments**, and the core setup already uses all three (DEV, TEST, PROD).

So the hotfix environments belong to a separate **service account**, a second user in your tenant with its own allowance of 3. The script creates it, has it create the two environments, and makes **you** a System Administrator in them so you can work there as normal.

```
You (admin@...)                     ALM Service Account
  owns: ALM-DEV                       owns: ALM-HFXDEV
        ALM-TEST                            ALM-HFXTEST
        ALM-PROD                      (you're System Administrator in both)
```

Your pipeline service principal from the core setup is added to the hotfix environments too.

The service account has a second job: the hotfix pipeline **signs in as it with a username and password** to reset the HFXDEV environment and create connections, which a service principal can't do. That's why it must not require MFA (next section).

## Step 1: Make sure the service account won't be asked for MFA

A pipeline can't answer an MFA prompt, so the service account has to be exempt.

**If you created your own tenant (Path 2):** new tenants have Microsoft's **security defaults** turned on, and those force MFA on every account. Since this tenant is only for the workshop, turn them off:

1. Go to https://entra.microsoft.com as your admin account.
2. **Overview** > **Properties** > **Manage security defaults**.
3. Set **Security defaults** to **Disabled**, pick a reason (for example "My organization is using Conditional Access" or "Other"), and **Save**.

This video walks through it: https://youtu.be/JyYZGscr5lU

> Only do this in a tenant you made for the workshop. It turns off MFA enforcement for everyone in that tenant, so keep your admin account's password strong.

**If you're using your company's tenant (Path 1):** don't turn off security defaults. Ask your IT team to **exclude the service account from MFA with a Conditional Access policy**. The script tells you the account's name once it's created.

If you skip this step, the script still works: it warns you if security defaults are on, and stops with instructions if the account is already being asked for MFA. With security defaults on, sign-in usually works for the first ~14 days, then Microsoft starts requiring MFA setup and the hotfix pipeline fails.

## Step 2: Run the script

You need to be able to create users (**User Administrator** or **Global Administrator**). If you made your own tenant, you are.

Open PowerShell in this `Part 2 - Hotfix (For later)` folder:

```powershell
.\Setup-Hotfix.ps1
```

It takes about 10 minutes. It will:

1. Read your core setup from `..\my-alm-setup.json`.
2. Create the service account `alm.serviceaccount@<your domain>` with a random password, and give it a Power Apps Developer Plan license.
3. Check that the service account can sign in without MFA.
4. Sign in **as the service account** and create **ALM-HFXDEV** and **ALM-HFXTEST**, each with a Dataverse database. They're owned by the service account, so they don't use your slots.
5. Add **you** and your **pipeline service principal** as System Administrator in both.
6. Print the values you'll need in the hotfix lessons: each environment's URL and ID, and the service account's username. The password is saved in `..\my-alm-setup.json`.

It's safe to run again if anything fails.

## Step 3: The hotfix lessons

The script doesn't touch Azure DevOps. In the hotfix lessons you create, using the values it printed:

- The **service connections** for HFXDEV and HFXTEST, plus a **username/password** service connection for the service account
- The **HFXDEV** and **HFXTEST Environment Variables** groups

## Troubleshooting

| Problem | Fix |
|---|---|
| "Can't find my-alm-setup.json" | Run Part 1 (`Setup-Core.ps1` in the `Part 1 - Set Up` folder) first, from the same download. |
| "The service account is being asked for MFA" | Do Step 1 above, then run the script again. |
| "Your tenant has no Power Apps Developer Plan licenses" | Sign in once at https://aka.ms/PowerAppsDevPlan **as the service account** (its password is in `my-alm-setup.json`), sign up for the Developer Plan, then run the script again. |
| Timeout or "try again" errors | New accounts and environments take a few minutes to be ready everywhere. Wait and run the script again. |
