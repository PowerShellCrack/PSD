# PSD Script and Module Matrix

This inventory covers every `.ps1` script and `.psm1` module in this repository, including tools, plugins, samples, and legacy files. Reviewed against the working tree on November 27, 2026: **48 files (41 scripts and 7 modules)**.

Paths are relative to the repository root. Descriptions reflect the current implementation, not just the comment-based help, which is outdated in some files. A file being present does not mean it is part of the default deployment path or that its feature is fully supported.

For feature availability, see the [PSD vs MDT support matrix](./PowerShell%20Deployment%20-%20PSD%20vs%20MDT.md). For logging and development guidance, see the [Toolkit Reference](./PowerShell%20Deployment%20-%20Toolkit%20Reference.md).

## Installation and boot-image integration

| File | Use | General purpose |
| --- | --- | --- |
| [Install-PSD.ps1](../Install-PSD.ps1) | Deployment-share installation/upgrade | Creates or upgrades a PSD-enabled MDT deployment share, copies PSD files, and configures the share's deployment resources and templates. |
| [Scripts/PSDUpdateExit.ps1](../Scripts/PSDUpdateExit.ps1) | Deployment-share update hook | Customizes boot-image generation at MDT update stages, including WinPE keyboard locale and boot files. Runs during share updates, not as a client task-sequence step. |
| [Plugins/OSDToolkit/Set-PSDBootImage2PintEnabled.ps1](../Plugins/OSDToolkit/Set-PSDBootImage2PintEnabled.ps1) | Optional boot-image plugin | Adds 2Pint Software's OSD Toolkit to generated boot media for its content-transfer/BranchCache integration. Requires the external toolkit. |

## Deployment startup and task-sequence scripts

These scripts normally run with PSD's task-sequence environment and modules loaded; they are not general-purpose scripts to run on an administrator's workstation.

| File | Use | General purpose |
| --- | --- | --- |
| [Scripts/PSDStart.ps1](../Scripts/PSDStart.ps1) | Main deployment entry point | Starts or resumes deployment, processes rules, connects to the share, caches resources, runs startup UserExit scripts and the current wizard, and hands control to the MDT task-sequence engine. |
| [Scripts/PSDStartLoader.ps1](../Scripts/PSDStartLoader.ps1) | Alternate/older startup implementation | Contains a separate startup flow using the WPF loader for device details and progress. The current main entry point is `PSDStart.ps1`, which also uses the loader module. |
| [Scripts/PSDApplications.ps1](../Scripts/PSDApplications.ps1) | Application installation | Installs selected and mandatory applications, recursively processes dependencies, retrieves installer content, and tracks installed application GUIDs. |
| [Scripts/PSDApplyOS.ps1](../Scripts/PSDApplyOS.ps1) | OS image deployment | Retrieves and applies the selected Windows image, injects staged drivers, and prepares boot configuration. |
| [Scripts/PSDConfigure.ps1](../Scripts/PSDConfigure.ps1) | Unattended setup | Updates the target OS's `Unattend.xml` using deployment settings and configuration mappings. |
| [Scripts/PSDCopyLogs.ps1](../Scripts/PSDCopyLogs.ps1) | Log collection/upload | Packages deployment logs and uploads them to the configured `SLShare` endpoint using BITS. |
| [Scripts/PSDCustomization.ps1](../Scripts/PSDCustomization.ps1) | Optional customization example | With `-Config Custom`, builds a computer name from the BIOS serial number and saves task-sequence variables. Other configurations currently perform no customization. |
| [Scripts/PSDDrivers.ps1](../Scripts/PSDDrivers.ps1) | WinPE driver staging | Downloads model, generic, and fallback driver packages, expands ZIP/WIM packages into the target's Drivers folder, and logs driver metadata for subsequent injection. |
| [Scripts/PSDExportDriversInWinPE.ps1](../Scripts/PSDExportDriversInWinPE.ps1) | Incomplete stub | Loads task-sequence/PSD modules and logs a start event. Despite its filename, it currently does not export drivers. |
| [Scripts/PSDFinal.ps1](../Scripts/PSDFinal.ps1) | End-of-deployment cleanup | Clears deployment autologon settings and removes temporary deployment/driver data and markers. |
| [Scripts/PSDGather.ps1](../Scripts/PSDGather.ps1) | Gather task-sequence step | Invokes the gather module to refresh local information and, when requested, process deployment rules into task-sequence variables. |
| [Scripts/PSDPartition.ps1](../Scripts/PSDPartition.ps1) | Disk preparation | Partitions and formats the deployment disk using the script's BIOS/UEFI layouts. Destructive: use only against the intended deployment disk. |
| [Scripts/PSDPowerShell.ps1](../Scripts/PSDPowerShell.ps1) | Run PowerShell Script step | Resolves/downloads the script named by task-sequence settings and launches PowerShell with the configured parameters. |
| [Scripts/PSDPrestart.ps1](../Scripts/PSDPrestart.ps1) | XML-driven prestart commands | Executes commands from `X:\Deploy\Prestart\PSDPrestart.xml` when that file exists. Separate from the native/WPF prestart menus. |
| [Scripts/PSDRoleInstall.ps1](../Scripts/PSDRoleInstall.ps1) | Roles/features installation | Installs configured roles, role services, and features together with the wizard's `OptionalOS*` selections, deduplicates requests, logs failures, and reports reboot requirements. |
| [Scripts/PSDRoleUnInstall.ps1](../Scripts/PSDRoleUnInstall.ps1) | Roles/features removal | Removes configured Windows Server roles/services/features or disables client optional features. Uses a separate, older removal implementation; do not assume parity with the install script's optional-selection handling. |
| [Scripts/PSDSetVariable.ps1](../Scripts/PSDSetVariable.ps1) | Set variable step | Sets a task-sequence variable using the supplied name and value. |
| [Scripts/PSDTattoo.ps1](../Scripts/PSDTattoo.ps1) | Deployment identification | Records deployment information in the registry and WMI for later identification and troubleshooting. |
| [Scripts/PSDTBA.ps1](../Scripts/PSDTBA.ps1) | Unsupported-step placeholder | Logs that a requested feature or scenario has not yet been implemented. It is not an implementation of the replaced MDT step. |
| [Scripts/PSDUpdateDisk.ps1](../Scripts/PSDUpdateDisk.ps1) | Boot-entry refresh | Runs `bcdedit.exe` and logs its output to refresh/read boot entries on hardware that needs this step. Does not apply an OS image despite its header description. |
| [Scripts/PSDValidate.ps1](../Scripts/PSDValidate.ps1) | Deployment validation step | Contains OS-install permission and refresh client/server compatibility checks. Separate from the wizard's extensible readiness page; not a complete hardware-readiness assessment. |
| [Scripts/PSDWindowsUpdate.ps1](../Scripts/PSDWindowsUpdate.ps1) | Windows updates | Uses the Windows Update COM API to search, download, and install updates; configures a local WSUS endpoint when `WSUSServer` is supplied and tracks reboot requirements. |
| [Scripts/ZTIOSRolePS.ps1](../Scripts/ZTIOSRolePS.ps1) | MDT compatibility script | MDT-provided ServerManager wrapper for installing/removing a Windows Server feature and returning failure/reboot exit codes. Separate from PSD's role-installation script. |

## Shared modules

| File | Use | General purpose |
| --- | --- | --- |
| [Scripts/PSDDeploymentShare.psm1](../Scripts/PSDDeploymentShare.psm1) | Share access and content retrieval | Connects to HTTP/HTTPS, UNC, or local content sources; exposes the deployment provider and retrieves/tests cached content. Web downloads include BITS-to-WebClient fallback and download checks. |
| [Scripts/PSDGather.psm1](../Scripts/PSDGather.psm1) | Device discovery and INI rules | Gathers hardware/OS/network information and processes Bootstrap/CustomSettings rules using property mappings, writing results into task-sequence variables. MDT-style INI `UserExit` callbacks remain unimplemented. |
| [Scripts/PSDStartLoader.psm1](../Scripts/PSDStartLoader.psm1) | WPF startup/prestart UI | Provides the loader, progress displays, device/network details, prestart tools, and debugging windows used during deployment startup. |
| [Scripts/PSDUtility.psm1](../Scripts/PSDUtility.psm1) | Common PSD runtime helpers | Provides logging/events, local cache paths, variable persistence, file operations, network checks, certificates, progress, and deployment information dialogs. |
| [Scripts/PSDWizardNew.psm1](../Scripts/PSDWizardNew.psm1) | Current deployment wizard | Implements the runspace-based WPF wizard: task-sequence-dependent rules/pages, applications and bundles, roles/features, locale/disk choices, readiness/field validation, diagnostics, and explicit development mode. |
| [Scripts/PSDWizard.psm1](../Scripts/PSDWizard.psm1) | Legacy wizard module | Loads the original XAML wizard and transfers control values to/from task-sequence variables. Retained in the repository, but not selected by the current main startup script. |
| [Scripts/ZTIUtility.psm1](../Scripts/ZTIUtility.psm1) | MDT compatibility module | Initializes MDT's PowerShell module search path and loads `Microsoft.BDD.TaskSequenceModule` for MDT compatibility scripts. |

## Wizard helpers, samples, and troubleshooting

| File | Use | General purpose |
| --- | --- | --- |
| [Scripts/PSDWizard.xaml.Initialize.ps1](../Scripts/PSDWizard.xaml.Initialize.ps1) | Legacy wizard initializer | Populates the old wizard's task-sequence tree and handles expansion/selection. Its validation function is a TODO stub. |
| [Scripts/PSDWizardNew/PSDWizard.Helper.ps1](../Scripts/PSDWizardNew/PSDWizard.Helper.ps1) | Older wizard helper | Initializes wizard paths/settings and supplies environment/editor detection and helper logic for the earlier wizard architecture. Do not confuse it with the current module's `-DevelopmentMode` entry point. |
| [Scripts/PSDHelper.ps1](../Scripts/PSDHelper.ps1) | Interactive troubleshooting | Sets the module search path and imports the MDT task-sequence and core PSD modules into an interactive session. |
| [Scripts/PSDTest.ps1](../Scripts/PSDTest.ps1) | Demonstration script | Demonstrates parameters, task-sequence-variable logging, progress messages, and a timed prompt for a Run PowerShell Script step. Not an automated test suite. |
| [PSDResources/Prestart/PSDPrestartMenu.ps1](../PSDResources/Prestart/PSDPrestartMenu.ps1) | Native prestart menu sample | Provides a console menu for disk/network inspection, static IP configuration, PowerShell, and DaRT when included in the boot image. |
| [PSDResources/Prestart/PSDPrestartScript.ps1](../PSDResources/Prestart/PSDPrestartScript.ps1) | Prestart initialization | Updates BGInfo boot status when available and precompiles PowerShell/CIM assemblies with NGEN. |
| [PSDResources/Readiness/Computer_Readiness.ps1](../PSDResources/Readiness/Computer_Readiness.ps1) | Readiness extension sample | Defines sample UEFI, TPM, AD DS, and Intune functions returning `Message` and `Ready`. All currently return success without checking the device; replace them with real checks before relying on readiness enforcement. |
| [PSDResources/UserExitScripts/UserExistScript001.ps1](../PSDResources/UserExitScripts/UserExistScript001.ps1) | Startup UserExit sample | Logs execution; includes a commented computer-naming example. Runs through PSD's startup hook, not MDT's INI UserExit callback mechanism. The filename intentionally matches the repository's existing spelling. |

## Administrator/server tools

Run these on the appropriate management/deployment server with the privileges and prerequisites described in their help. They are not client task-sequence steps.

| File | Use | General purpose |
| --- | --- | --- |
| [Tools/New-PSDDriverPackage.ps1](../Tools/New-PSDDriverPackage.ps1) | Driver packaging | Builds ZIP or WIM driver packages from drivers imported into MDT, with source/package folders for PSD driver delivery. |
| [Tools/New-PSDRestPS.ps1](../Tools/New-PSDRestPS.ps1) | Optional REST service setup | Deploys RestPS routes/listener configuration and installs it as a Windows service using NSSM; supports service testing. Requires external RestPS/NSSM components. |
| [Tools/New-PSDRootCACert.ps1](../Tools/New-PSDRootCACert.ps1) | Certificate setup | Creates a self-signed root CA certificate, trusts it locally, and exports its public certificate into the deployment share's root-certificate resources for clients. |
| [Tools/New-PSDServerCert.ps1](../Tools/New-PSDServerCert.ps1) | HTTPS certificate setup | Creates a server certificate signed by the configured PSD root CA and configures the IIS HTTPS binding. |
| [Tools/New-PSDWebInstance.ps1](../Tools/New-PSDWebInstance.ps1) | IIS prerequisite installation | Installs the IIS roles/features needed to host PSD deployment content. |
| [Tools/Set-PSDLogInstance.ps1](../Tools/Set-PSDLogInstance.ps1) | Server-side logging setup | Configures an IIS virtual directory and access settings for deployment-log uploads. |
| [Tools/Set-PSDWebInstance.ps1](../Tools/Set-PSDWebInstance.ps1) | Deployment web endpoint setup | Configures IIS to expose a deployment share through a virtual directory with the settings required for PSD web downloads. |

## Maintenance notes

- Add, remove, or rename the corresponding row whenever a PowerShell file changes in the repository.
- Keep samples, incomplete stubs, and retained legacy implementations explicitly labeled.
- Current wizard changes are detailed in the [PSDWizardNew changelog](../Scripts/PSDWizardNew/CHANGELOG.md).
- Wizard role selections need an enabled task-sequence step running `PSDRoleInstall.ps1`. Updated client/server templates include it; existing task sequences must be updated separately.
- A catalog entry for a newer OS build is not proof that an end-to-end deployment has been validated on that release.
