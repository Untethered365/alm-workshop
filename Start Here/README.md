# Set Up Your Own ALM Workshop Environment

In this workshop you'll build a real ALM (Application Lifecycle Management) setup: three Power Platform environments (DEV, TEST and PROD) connected to Azure DevOps pipelines that move your solutions between them automatically.

**What you'll end up with:**
- Three Dataverse environments: DEV, TEST and PROD
- An app registration (service principal) your pipelines use to deploy
- An Azure DevOps project, with a ready-made connection to each environment

## Before you start, answer one question: are you an admin of a Microsoft tenant?

- **Yes, I'm an admin.** Great. [Install the tools](#install-the-tools), then [run the readiness check](Part%201%20-%20Set%20Up/README.md#step-1-run-the-readiness-check) to confirm you have everything.
- **No, or I'm not sure.** No problem. We'll walk you through [creating your own free tenant](Part%201%20-%20Set%20Up/README.md#path-2-create-your-own-tenant), where you'll automatically be the admin. It takes about 30 minutes and needs a credit card for identity verification only. You won't be charged.

Either way, you'll finish with the same setup.

> If the readiness check says you're missing permissions in your company's tenant, you have two choices: send the message it prints to your IT admin, or switch to creating your own tenant. Your own tenant is usually faster.

---

## Install the tools

You need a Windows PC with these two free tools. Install both, then **open a new PowerShell window** so it picks them up.

| Tool | Install |
|---|---|
| Azure CLI | [Download the installer](https://aka.ms/installazurecliwindows), or run `winget install -e --id Microsoft.AzureCLI` |
| Power Platform CLI | [Download the installer](https://aka.ms/PowerAppsCLI) (the file is called `powerapps-cli-1.0.msi`; it always installs the latest version) |

Check they're installed:

```powershell
az --version
pac
```

If PowerShell blocks the scripts with a message about execution policy, run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

---

## How it fits together

```
 Path 1: I'm an admin            Path 2: I need a tenant
          |                    (Part 1 README, about 30 min)
          |                                  |
          +---------------+------------------+
                          v
  Part 1 - Set Up\Test-Readiness.ps1   Checks you're ready. Changes nothing.
                          v
  Part 1 - Set Up\Setup-Core.ps1       Builds DEV, TEST, PROD + pipelines setup
                          v
  (later, hotfix course only)
  Part 2 - Hotfix (For later)\Setup-Hotfix.ps1   Adds HFXDEV and HFXTEST
```

| Folder | What's in it |
|---|---|
| [Part 1 - Set Up](Part%201%20-%20Set%20Up/README.md) | Creating your own tenant, the readiness check, and the main setup. **Start here.** |
| [Part 2 - Hotfix (For later)](Part%202%20-%20Hotfix%20%28For%20later%29/README.md) | Extra setup for the hotfix course. Only needed later, after Part 1. |

## Signing in

The scripts never ask for your password. They open the normal Microsoft sign-in page in your browser. You'll sign in **twice** the first time (once for Azure CLI, once for the Power Platform CLI). Use the same account both times.

- The browser window sometimes opens **behind** PowerShell. Check your taskbar.
- If your account can see more than one tenant, the script asks you to pick one.
- If the browser won't open (for example on a remote desktop), add `-UseDeviceCode` and follow the code prompt instead.
- To use a different account, add `-SwitchAccount`.

## Your details file

The setup scripts save everything they create to `my-alm-setup.json` in this folder: environment URLs, your app ID and the **client secret**. You'll need these values during the workshop.

**Keep this file private.** The secret gives full access to your environments. Don't email it, don't commit it to Git, and delete it after the workshop.
