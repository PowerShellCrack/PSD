# PSD vs MDT

PSD extends MDT with a PowerShell-based deployment runtime and WPF wizard while retaining the Deployment Workbench, deployment-share layout, and task-sequence engine. It does not provide every MDT scenario or a drop-in replacement for every MDT script.

Reviewed against this repository's working tree on November 27, 2026, including PSDWizardNew 3.0.1 changes. This describes implemented capabilities, not end-to-end certification of every OS release. The MDT column is a historical feature comparison, not a statement of current Microsoft support.

For the purpose of every PowerShell file, see the [Script and Module Matrix](./PowerShell%20Deployment%20-%20Script%20and%20Module%20Matrix.md). Recent wizard changes are described in the [PSDWizardNew changelog](../Scripts/PSDWizardNew/CHANGELOG.md).

## Support Matrix

`x` = implemented; `partial` = limited implementation (see comment); blank = not implemented or not established here. Roadmap entries retain earlier intentions and are not release commitments.

Feature | PSD | MDT | On Roadmap |Comment
--|--|--|--|--
Windows 11 OSD | x | | |
Server 2019+ OSD | x | | |
Http(s) deployments | x | | |
UNC Deployments | partial | x | no | SMB/UNC connection and content-copy paths exist in PSDStart and PSDDeploymentShare. HTTP/HTTPS remains the preferred deployment approach; this is not a claim of full MDT scenario parity.
WinPE deployments | x | x | |
Desktop deployments |  | x | yes |
Capture Deployments | | x | no |
Pause Deployments | | x | yes | This is similar to LTISuspend
Profile Selection | partial | x | | WizardSelectionProfile filters wizard applications using MDT selection profiles and retains mandatory applications; not full selection-profile parity across all content types.
Litetouch OSD | x | x | |
ZeroTouch OSD | x | x | | Follow the [ZeroTouch guide](./Powershell%20Deployment%20-%20ZeroTouch%20Guide.md); when processed settings skip every wizard pane, deployment can continue without opening the wizard.
Linked Deployment Shares | | x | no | http deployment should help reduces this need
Database Support | | x | |
MDT Logging (SLShare) | x | x | | PSDCopyLogs packages logs for BITS upload; configure the server endpoint with Set-PSDLogInstance.
Debugging | x | | | PSD logging plus a wizard debug console for TSEnv values, lists, state, logs, and commands; enabled by PSDDebug=YES, -Debug, or -DevelopmentMode. Password values are masked in diagnostic views.
Deployment Workbench | x |x| | There is discussion of developing a new deployment workbench
UDI Designer | | x | maybe |
Wizard Themes | x | | | Classic and Dark WPF/XAML themes.
Wizard Custom Pages | x | x | | PSD uses XAML panes and XML definitions/conditions. MDT LTI uses its own wizard definitions; UDI Designer belongs to MDT's UDI integration, not the PSD wizard.
Multiple Language support | partial | x | yes | OS locale, keyboard, and time-zone selection are implemented. Bundled wizard UI definitions are en-US; OS locale selection is not the same as translated wizard pages.
Organizational Branding | x | | | Use branding image during PSDWizard
User State Migration | | x | no |
UserExit Scripts | partial | x | | PSDStart runs PowerShell scripts from PSDResources/UserExitScripts after rules processing and before the wizard. MDT-style INI UserExit before/after callbacks in PSDGather are still unimplemented.
Precheck Readiness | x | | | Configurable readiness functions and wizard enforcement with explicit skip/bypass settings. The bundled Computer_Readiness.ps1 functions are success-only samples, not real hardware checks.
Roles and Features installation | x | x | | Wizard selections and configured OS roles/services/features are installed together by PSDRoleInstall. ServerManager.xml selects client/server/Core catalogs by target OS/build or OSRoleIndex. Existing task sequences need the installation step added.
Task Sequence-specific wizard settings | x | x | | Selecting a task sequence reprocesses its rules and refreshes dependent lists, applications, roles, and visible panes without retaining the previous sequence's settings.
Wizard field validation | x | x | | Active pages validate task-sequence selection, computer name, domain/workgroup details, and administrator password confirmation before navigation.
Wizard development mode | x | | | Explicit -DevelopmentMode enables local wizard simulation; normal deployment requires PSD's TSEnv drive. Simulation does not validate a complete deployment.
Windows Update / WSUS | x | x | | PSDWindowsUpdate uses the Windows Update API and supports a WSUSServer property.
Prestart Menu (disk wipe, static IP, etc) | x | | | New in PSD 2.30
BranchCache | x | x | |
Custom Properties | x | x | | Declared custom properties are processed by PSDGather.
DriverGroups | | x | yes | Full MDT DriverGroups selection is not implemented. DriverGroup001 can be mapped to DriverPath for convenience; use DriverPath, GenericDriverPath, and FallbackDriverPath with packages created by [New-PSDDriverPackage.ps1](../Tools/New-PSDDriverPackage.ps1).
Packages | | x | no |
Domain Join | x | x| | This must still be done via LAN; Offline Domain Join (ODJ) support is not there yet
Event Monitoring | x | x| | There is some limitations with this
WinPE Dart Support | x | | | 
Workbench Dart Remote Control |  | x | | https://github.com/FriendsOfMDT/PSD/issues/83
Offline Media | | x | yes | Offline media is on the TODO list
Application Bundles | x | x | | Dependency-backed bundles from Applications.xml are resolved in the wizard and exported with their dependencies; mandatory/required selections are retained. PSDApplications processes dependencies during installation.
Applications Deployments Only  | | x | yes | This is part of the Desktop deployments development
Autopilot Support | | | yes | An Intune Group/Device Role wizard field is not by itself Autopilot provisioning support.
Azure Image Builder support | | | maybe | some discussion around this.
Reverse Proxy | | | maybe | 
802.1x support | | | maybe |
PowerShell 7 or higher support | | | unknown | Since the native PowerShell in Windows and WinPE is 5.1, that is the one being used. Some testing has been done in PowerShell 7. 


> NOTE: even though some of these items are on the roadmap, there are no estimated release dates as to when they will be available. 

## Upgrade considerations

- Upgrade the deployment share and regenerate boot media so clients load the current wizard module.
