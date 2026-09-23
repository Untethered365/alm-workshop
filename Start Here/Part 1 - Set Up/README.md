# Core Workshop Setup

This sets up your DEV, TEST and PROD environments and connects them to Azure DevOps.

- **Already an admin of a tenant (Path 1)?** Make sure you've [installed the tools](../README.md#install-the-tools), then skip to [Step 1: Run the readiness check](#step-1-run-the-readiness-check).
- **Need a tenant (Path 2)?** Start with [Path 2: Create your own tenant](#path-2-create-your-own-tenant) below.

---

## Path 2: Create your own tenant

A tenant is your own private Microsoft cloud directory. It's free, and you'll be its admin. You'll create four things, in this order:

1. [An Azure account](#a-create-an-azure-account) (this creates your tenant)
2. [A work account](#b-create-your-work-account) inside the tenant
3. [The Power Apps Developer Plan](#c-sign-up-for-the-power-apps-developer-plan) (free)
4. [An Azure DevOps organization](#d-create-your-azure-devops-organization) (free)

> **Use a private/incognito browser window for all of Path 2.** If you're signed in to a work or personal Microsoft account already, the browser will try to use it and you'll end up in the wrong place.

### A. Create an Azure account

1. Open https://azure.microsoft.com and select **Pay as you go**. (You won't actually pay anything. See step 3.)
2. Sign in with a **personal** Microsoft account (Outlook, Hotmail, Live), or create a new one on that page. Don't use your work account.
3. Fill in your details and enter a **credit card**. It just needs a card on file. You're only charged for Azure services you use, and this workshop doesn't use any that cost money.
4. When you're offered support plans, pick **No technical support**.
5. When it finishes, you land in the Azure portal. Your tenant now exists and you're its Global Administrator.

Remember this personal account. You'll use it once more, in step D.

### B. Create your work account

Power Platform **won't accept a personal account** (outlook.com, hotmail.com, gmail.com and so on). So you need a work account inside your new tenant. You'll use it for everything from here on.

1. In the Azure portal (https://portal.azure.com), search for **Microsoft Entra ID** and open it.
2. On the **Overview** page, note your **Primary domain**. It looks like `yournamehotmail.onmicrosoft.com`.
3. Go to **Users** > **New user** > **Create new user**.
   - **User principal name:** `admin` (the domain is already filled in, so you get `admin@yournamehotmail.onmicrosoft.com`)
   - **Display name:** your name
   - **Password:** copy the auto-generated one
4. Open the **Assignments** tab > **Add role** > pick **Global Administrator** > **Select**.
5. Select **Review + create** > **Create**.
6. Open a **new** private window, go to https://portal.azure.com and sign in as your new `admin@...onmicrosoft.com` account.
   - You'll be asked to change the password.
   - You'll probably be asked to set up the **Microsoft Authenticator** app. That's normal: new tenants require it.

**From now on, always sign in with this work account, never your personal one.**

### C. Sign up for the Power Apps Developer Plan

1. Still signed in as your work account, open https://aka.ms/PowerAppsDevPlan.
2. Choose the **Developer Plan** (it may say **Try free** or **Get started free**) and enter your work account email.
3. Complete the sign-up. You land in Power Apps, and it starts creating a first environment called *"(your name)'s Environment"*.

**Leave that environment alone.** It's created without a Dataverse database, and it uses one of your **3 Developer environment** slots. The setup script automatically turns it into your **ALM-DEV** environment: it renames it and adds a database. You don't need to rename or delete it yourself.

### D. Create your Azure DevOps organization

Create the org with your **personal account** from step A, **not** the work account. The personal account owns your Azure subscription, which is what unlocks free pipeline minutes.

1. In a private window, sign in to https://portal.azure.com with your **personal** account.
2. Search for **DevOps** and open **Azure DevOps organizations** > **My Azure DevOps Organizations**.
3. Select **Create new organization** > **Continue**, pick any name (for example `yourname-alm`), and continue.
4. If it asks you to create a first project, give it any name. The setup script creates its own project later.

**Check the org belongs to your tenant.** In the org, open **Organization settings** (bottom left) > **Microsoft Entra**. It should show your tenant's name. If it says it isn't connected, select **Connect directory** and pick your tenant.

**Add your work account to the org.** The setup scripts sign in as your work account, so it needs to be a member:

1. **Organization settings** > **Users** > **Add users**.
2. Enter your work account (`admin@...onmicrosoft.com`), set **Access level** to **Basic**, and add it.
3. **Organization settings** > **Permissions** > **Project Collection Administrators** > **Members** > **Add**, and add your work account.

**Check pipelines can run.** Open **Organization settings** > **Parallel jobs**. Under **Microsoft-hosted**, you should see the free tier. If you see 0 parallel jobs instead, open **Organization settings** > **Billing** > **Set up billing**, pick your Azure subscription, and leave every paid quantity at **0**. That turns on the free tier (1,800 pipeline minutes a month) at no cost.

You're done with Path 2. Now [install the tools](../README.md#install-the-tools) if you haven't yet, and continue with Step 1.

---

## Step 1: Run the readiness check

Open PowerShell in this `Part 1 - Set Up` folder and run:

```powershell
.\Test-Readiness.ps1
```

It signs you in (browser pop-up) and checks, **without changing anything**:

| Check | What it looks at |
|---|---|
| Sign-in | Azure CLI and Power Platform CLI are signed in to the same tenant, with a work account |
| Entra ID | You can create an app registration (by role, by an unactivated role, or by tenant setting) |
| Power Platform | You have room for 3 Developer environments, your tenant lets you create them, and you have the Developer Plan |
| Azure DevOps | You have an org connected to this tenant |
| Hotfix course | You can create a user and environments for them. Only matters if you're taking the hotfix course. |

Each line is **[OK]**, **[FAIL]** or **[WARN]**. Warnings won't stop you. If anything fails, the summary tells you how to fix it, and prints a message you can copy to your IT admin if you need a permission.

Run it again until the summary says **You're ready for the core workshop.**

## Step 2: Run the setup

```powershell
.\Setup-Core.ps1
```

It takes about 10-20 minutes, mostly waiting for environments to be created. It will:

1. Sign you in (reusing the sign-in from the check).
2. Pick your Azure DevOps org. If you have more than one, it asks which.
3. Create **ALM-DEV**, **ALM-TEST** and **ALM-PROD** Developer environments. Any that already exist are reused. If you're short on slots, a Developer environment you own that has **no database** (like the one from the Developer Plan sign-up) is renamed and given a database instead.
4. Create an app registration called **ALM-Workshop-Pipelines** with a client secret (valid 1 year).
5. Add that app as **System Administrator** in all three environments.
6. Create an Azure DevOps project called **ALM-Workshop**, install the **Power Platform Build Tools**, and create a service connection for each environment (named `ALM-DEV`, `ALM-TEST`, `ALM-PROD`).
7. Save everything to `..\my-alm-setup.json`.

**If something fails, fix it and run the script again.** It checks what already exists and only does what's missing.

### Options

| Option | Use it when |
|---|---|
| `-Region europe` | You want your environments outside the US. Other values: `unitedkingdom`, `australia`, `canada`, `asia`, `japan`, `india`, and more. |
| `-AdoOrganization myorg` | You want to skip the org question |
| `-SwitchAccount` | You signed in with the wrong account |
| `-UseDeviceCode` | The browser sign-in won't open |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "...is not digitally signed. You cannot run this script" | Files from a downloaded ZIP are blocked. From the `Start Here` folder, run `Get-ChildItem -Recurse \| Unblock-File`, then try again. |
| "You're signed in with a personal or guest account" | Run with `-SwitchAccount` and sign in with your `admin@...onmicrosoft.com` work account (Path 2, step B). |
| "Couldn't add a database" or "is in a failed state" | In https://admin.powerplatform.microsoft.com, open that environment and select **Add Dataverse**. Or delete it and run the script again to get a fresh one. |
| "You need N more Developer environment(s)" | You own too many Developer environments. Delete ones you don't need at https://admin.powerplatform.microsoft.com > Environments. |
| "No Azure DevOps org connected to this tenant" | Either your work account isn't a member of the org yet (Path 2, step D, "Add your work account to the org"), or the org isn't connected to your tenant (step D, "Check the org belongs to your tenant"). |
| Pipeline says "No hosted parallelism has been purchased" | Set up billing with your Azure subscription (Path 2, step D, "Check pipelines can run"). |
| Browser sign-in never appears | Check the taskbar for a hidden window, or run with `-UseDeviceCode`. |
| A step fails with a timeout or "try again" error | Wait a couple of minutes and run the script again. New accounts and environments can take a few minutes to be ready everywhere. |
