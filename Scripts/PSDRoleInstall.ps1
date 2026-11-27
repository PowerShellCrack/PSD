<#
.SYNOPSIS
    Installs Roles, Role services and Features
.DESCRIPTION
    Installs the roles, role services and features of the task sequence. What the task sequence names itself (OSRoles, OSRoleServices and
    OSFeatures, as set by its Install Roles and Features step or CustomSettings.ini) and what was selected in the PSD wizard (OptionalOSRoles,
    OptionalOSRoleServices and OptionalOSFeatures) are installed together, each item once.
    Windows Server uses the ServerManager module (Add-WindowsFeature), Windows client uses Enable-WindowsOptionalFeature.
.LINK
    https://github.com/FriendsOfMDT/PSD
.NOTES
          FileName: PSDRoleInstall.ps1
          Solution: PowerShell Deployment for MDT
          Author: PSD Development Team
          Contact: @Mikael_Nystrom , @jarwidmark , @mniehaus , @AndHammarskjold
          Primary: @jarwidmark 
          Created: 2019-05-17
          Modified: 2026-11-27

          Version - 0.0.1 - () - Finalized functional version 1.
          Version - 0.0.2 - () - Install the wizard's Optional* selections together with OSRoles, OSRoleServices and OSFeatures; each item once;
                                 log items that do not exist on this OS and failed installs instead of ignoring them; look the features up once.

          TODO:

.Example
#>

param (

)

# Set scriptversion for logging
$ScriptVersion = "0.0.2"

# Load core modules
Import-Module Microsoft.BDD.TaskSequenceModule -Scope Global
Import-Module PSDUtility
Import-Module PSDDeploymentShare

# Check for debug in PowerShell and TSEnv
if($TSEnv:PSDDebug -eq "YES"){
    $Global:PSDDebug = $true
}
if($PSDDebug -eq $true)
{
    $verbosePreference = "Continue"
}

Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Starting: $($MyInvocation.MyCommand.Name) - Version $ScriptVersion"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): The task sequencer log is located at $("$tsenv:_SMSTSLogPath\SMSTS.LOG"). For task sequence failures, please consult this log."
Write-PSDEvent -MessageID 41000 -severity 1 -Message "Starting: $($MyInvocation.MyCommand.Name)"


# Check if we booted from WinPE
$Global:BootfromWinPE = $false
if ($env:SYSTEMDRIVE -eq "X:"){
    $Global:BootfromWinPE = $true
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): This script should only run in the full OS."
    Exit 0
}

Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property OSRoleIndex is $($tsenv:OSRoleIndex)"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property IsServerOS is $($TSEnv:IsServerOS)"

Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property OSRoles is $($tsenv:OSRoles)"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property OSRoleServices is $($tsenv:OSRoleServices)"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property OSFeatures is $($tsenv:OSFeatures)"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property OptionalOSRoles is $($tsenv:OptionalOSRoles)"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property OptionalOSRoleServices is $($tsenv:OptionalOSRoleServices)"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Property OptionalOSFeatures is $($tsenv:OptionalOSFeatures)"

# Items from the task sequence and from the wizard are installed together; each item once, in the order roles, role services, features
function Merge-PSDRoleList {
    param([string[]]$Value)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Value) {
        foreach ($item in ([string]$entry -split '[,;]')) {
            $item = $item.Trim()
            if ($item -and $list -notcontains $item) { $list.Add($item) }
        }
    }
    return ,$list.ToArray()
}

$OSRoles = Merge-PSDRoleList $tsenv:OSRoles, $tsenv:OptionalOSRoles
$OSRoleServices = Merge-PSDRoleList $tsenv:OSRoleServices, $tsenv:OptionalOSRoleServices
$OSFeatures = Merge-PSDRoleList $tsenv:OSFeatures, $tsenv:OptionalOSFeatures

$Requested = New-Object System.Collections.Generic.List[object]
$Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($group in @(@('OSRole', $OSRoles), @('OSRoleService', $OSRoleServices), @('OSFeature', $OSFeatures))) {
    foreach ($name in $group[1]) {
        if ($Seen.Add($name)) { $Requested.Add([pscustomobject]@{ Kind = $group[0]; Name = $name }) }
    }
}

if ($Requested.Count -eq 0) {
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): No roles, role services or features were specified, nothing to install"
    Exit 0
}

# IsServerOS comes from the gather; ask the OS when it is not set
$IsServer = $false
if ($TSEnv:IsServerOS -eq 'True') { $IsServer = $true }
elseif ([string]::IsNullOrEmpty($TSEnv:IsServerOS)) {
    $IsServer = ((Get-CimInstance -ClassName Win32_OperatingSystem).ProductType -ne 1)
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): IsServerOS is not set, the operating system is a $(if($IsServer){'server'}else{'client'})"
}

$Installed = 0
$AlreadyInstalled = 0
$NotAvailable = 0
$Failed = 0
$RestartNeeded = $false

# Look the features up once
$Available = @{}
if ($IsServer) {
    Import-Module ServerManager
    Get-WindowsFeature | ForEach-Object { $Available[$_.Name] = $_ }
}
else {
    Get-WindowsOptionalFeature -Online | ForEach-Object { $Available[$_.FeatureName] = $_ }
}

foreach ($Item in $Requested) {
    $Feature = $Available[$Item.Name]
    if (-not $Feature) {
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): $($Item.Kind) $($Item.Name) is not available on this operating system" -LogLevel 2
        $NotAvailable++
        continue
    }

    $IsInstalled = if ($IsServer) { $Feature.InstallState -eq 'Installed' } else { $Feature.State -eq 'Enabled' }
    if ($IsInstalled) {
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): $($Item.Kind) $($Item.Name) is already installed"
        $AlreadyInstalled++
        continue
    }

    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Adding $($Item.Kind): $($Item.Name)"
    Show-PSDActionProgress -Message "Adding $($Item.Kind): $($Item.Name)"
    try {
        if ($IsServer) {
            $Result = Add-WindowsFeature -Name $Feature.Name -ErrorAction Stop
            $Succeeded = [bool]$Result.Success
            $NeedsRestart = ($Result.RestartNeeded -eq "YES")
        }
        else {
            $Result = Enable-WindowsOptionalFeature -Online -FeatureName $Feature.FeatureName -All -NoRestart -ErrorAction Stop
            $Succeeded = $true
            $NeedsRestart = ($Result.RestartNeeded -eq "True")
        }
        if ($Succeeded) { $Installed++ }
        else {
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): $($Item.Kind) $($Item.Name) was not installed: $($Result.ExitCode)" -LogLevel 3
            $Failed++
        }
        if ($NeedsRestart) { $RestartNeeded = $true }
    }
    catch {
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): $($Item.Kind) $($Item.Name) failed: $($_.Exception.Message)" -LogLevel 3
        $Failed++
    }
}

Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Installed $Installed, already installed $AlreadyInstalled, not available $NotAvailable, failed $Failed"

if($RestartNeeded -eq $true){
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Reboot needed"
    $tsenv:SMSTSRebootRequested = "true"
    Exit 3010
}
else{
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Reboot not needed"
    Exit 0
}
