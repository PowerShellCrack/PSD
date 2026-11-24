<#
.SYNOPSIS
    Installs the apps specified in task sequence variables Applications and Mandatory Applications.
.DESCRIPTION
    Installs the apps specified in task sequence variables Applications and Mandatory Applications.
.LINK
    https://github.com/FriendsOfMDT/PSD
.NOTES
          FileName: PSDApplications.ps1
          Solution: PowerShell Deployment for MDT
          Author: PSD Development Team
          Contact: @Mikael_Nystrom , @jarwidmark , @mniehaus , @AndHammarskjold
          Primary: @jarwidmark 
          Created: 
          Modified: 2026-03-19

          Version - 0.0.1 - () - Finalized functional version 1.
	      Version - 0.0.2 - () - Return code Application installation
          Version - 0.0.3 - () - Fix for dependency processing
          Version - 0.0.4 - () - Log and verify application content download, try/catch logging around content and installer launch

          TODO:

.Example
#>

[CmdletBinding()]
param (

)

# Set scriptversion for logging
$ScriptVersion = "0.0.4"

# Load core modules
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

# Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Load core modules"

# Internal functions

# Function to install a specified app
function Install-PSDApplication
{
    param(
      [parameter(Mandatory=$true, ValueFromPipeline=$true)]
      [string] $id
    )

    process {
        # Make sure we access to the application folder
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Make sure the app exists"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Make sure we access to the application folder"
        if ((Test-Path "DeploymentShare:\Applications") -ne $true)
        {
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): no access to DeploymentShare:\Applications , skipping."
            return 0
        }

        # Make sure the app exists
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Make sure the app exists"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Make sure the app exists DeploymentShare:\Applications\$id"
        if ((Test-Path "DeploymentShare:\Applications\$id") -ne $true)
        {
            #Write-Verbose "$($MyInvocation.MyCommand.Name): Unable to find application $id, skipping."
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Unable to find application $id, skipping."
            return 0
        }

        # Get the app
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Get the app"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Get the app"
        $app = Get-Item "DeploymentShare:\Applications\$id"

        #Write-Verbose "$($MyInvocation.MyCommand.Name): Processing $($app.Name)"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Processing :$($app.Name)"

        # Process dependencies (recursive)
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Process dependencies (recursive)"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Process dependencies (recursive)"
        $app.Dependency | ForEach-Object {
            Install-PSDApplication $_
        }

        # Check if the app has been installed already
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Check if the app has been installed already"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Check if the app has been installed already"
        $alreadyInstalled = @()
        $alreadyInstalled = @((Get-Item tsenvlist:InstalledApplications).Value)
        $found = $false
        $alreadyInstalled | ? {$_ -eq $id} | % {$found = $true}
        if ($found)
        {
            #Write-Verbose "$($MyInvocation.MyCommand.Name): Application $($app.Name) is already installed, skipping."
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Application $($app.Name) is already installed, skipping."
            return
        }

        # TODO: Check supported platforms
        #Write-Verbose "$($MyInvocation.MyCommand.Name): TODO: Check supported platforms"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): TODO: Check supported platforms"

        # TODO: Check for uninstall string
        #Write-Verbose "$($MyInvocation.MyCommand.Name): TODO: Check for uninstall string"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): TODO: Check for uninstall string"

        # Set the working directory
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Set the working directory"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Set the working directory"
        $workingDir = ""
        if ($app.WorkingDirectory -ne "" -and $app.WorkingDirectory -ne ".")
        {
            if ($app.WorkingDirectory -like ".\*")
            {
                # App content is on the deployment share, get it
                #Write-Verbose "$($MyInvocation.MyCommand.Name): App content is on the deployment share, get it"
                Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): App content is on the deployment share, get it"
                try {
                    $appContent = Get-PSDContent -Content "$($app.WorkingDirectory.Substring(2))"
                }
                catch {
                    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Failed to download content for $($app.Name) from $($app.WorkingDirectory): $($_.Exception.Message)" -LogLevel 3
                    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): $($_.ScriptStackTrace)" -LogLevel 3
                    throw
                }

                # Do not start the installer without its content, the resulting return code (1619, 2, ...) hides the real problem
                if (-not (Test-Path -LiteralPath $appContent -PathType Container) -or -not (Get-ChildItem -LiteralPath $appContent -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                    $message = "Content for $($app.Name) was not downloaded, $appContent is missing or empty. Check the Get-PSDContentWeb entries above and the BITS client log (Microsoft-Windows-Bits-Client/Operational)."
                    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): $message" -LogLevel 3
                    throw $message
                }
                Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Content for $($app.Name) is available in $appContent"
                $workingDir = $appContent
            }
            else
            {
                $workingDir = $app.WorkingDirectory
            }
            # TODO: Substitute
            #Write-Verbose "$($MyInvocation.MyCommand.Name): TODO: Substitute"
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): TODO: Substitute"
            # TODO: Validate connection
            #Write-Verbose "$($MyInvocation.MyCommand.Name): TODO: Validate connection"
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): TODO: Validate connection"
        }

        # Install the app
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Install the app"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Install the app"

        if ($app.CommandLine -eq "")
        {
            #Write-Verbose "$($MyInvocation.MyCommand.Name): No command line specified (bundle)."
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): No command line specified (bundle)."
        }
        elseif ($app.CommandLine -ilike "install-package *")
        {
            Invoke-Expression $($app.CommandLine)
        }
        elseif ($app.CommandLine -icontains ".appx" -or $app.CommandLine -icontains ".appxbundle")
        {
            # TODO: Process modern app
            #Write-Verbose "$($MyInvocation.MyCommand.Name): TODO: Process modern app"
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): TODO: Process modern app"
        }
        else
        {
            $cmd = $app.CommandLine
            # TODO: Substitute
            #Write-Verbose "$($MyInvocation.MyCommand.Name): TODO: Substitute"
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): TODO: Substitute"
            #Write-Verbose "$($MyInvocation.MyCommand.Name): About to run: $cmd"
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): About to run: $cmd"
            try {
                if ($workingDir -eq "")
                {

                    $result = Start-Process -FilePath "$toolRoot\bddrun.exe" -ArgumentList $cmd -Wait -Passthru -ErrorAction Stop
                }
                else
                {
                    #Write-Verbose "$($MyInvocation.MyCommand.Name): Setting working directory to $workingDir"
                    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Setting working directory to $workingDir"
                    $result = Start-Process -FilePath "$toolRoot\bddrun.exe" -ArgumentList $cmd -WorkingDirectory $workingDir -Wait -Passthru -ErrorAction Stop
                }
            }
            catch {
                Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Unable to run '$cmd' for application $($app.Name): $($_.Exception.Message)" -LogLevel 3
                Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): $($_.ScriptStackTrace)" -LogLevel 3
                throw
            }
            # TODO: Check return codes
            #Write-Verbose "$($MyInvocation.MyCommand.Name): TODO: Check return codes"
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): TODO: Check return codes"
            #Write-Verbose "$($MyInvocation.MyCommand.Name): Application $($app.Name) return code = $($result.ExitCode)"
            if ($result.ExitCode -notin 0, 3010, 1641) {
                Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Application $($app.Name) return code = $($result.ExitCode) (not a success code, check the installer log and the content in $workingDir)" -LogLevel 2
            }
            else {
                Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Application $($app.Name) return code = $($result.ExitCode)"
            }
        }

        # Update list of installed apps
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Update list of installed apps"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Update list of installed apps"
        $alreadyInstalled += $id
        $tsenvlist:InstalledApplications = $alreadyInstalled

        # Reboot if specified
        #Write-Verbose "$($MyInvocation.MyCommand.Name): Reboot if specified"
        Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Reboot if specified"
        if ($app.Reboot -ieq "TRUE")
        {
            return 3010
            $tsenv:SMSTSRebootRequested = "true"
            $tsenv:SMSTSRetryRequested = "true"
        }
        else
        {
            Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Return code is $($result.ExitCode)"
            return $($result.ExitCode)
        }
    }
}


# Main code
#Write-Verbose "$($MyInvocation.MyCommand.Name): Main code"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Main code"

# Get tools
#Write-Verbose "$($MyInvocation.MyCommand.Name): Get tools"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Get tools"
$toolRoot = Get-PSDContent "Tools\$($tsenv:Architecture)"


# Single application install initiated by a Task Sequence action
# Note: The ApplicationGUID variable isn’t set globally. It’s set only within the scope of the Install Application action/step. One of the hidden mysteries of the task sequence engine :)

Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Checking for single application install step"
If ($tsenv:ApplicationGUID -ne "") {
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Mandatory Single Application install indicated. Guid is $($tsenv:ApplicationGUID)"
    $return = Install-PSDApplication $tsenv:ApplicationGUID
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Mandatory Single Application installed, exiting application step"
    Exit $return
}
else
{
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): No Single Application install found. Continue with checking for dynamic applications"
}
			

# Process applications
#Write-Verbose "$($MyInvocation.MyCommand.Name): Process applications"
Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Process applications"
if ($tsenvlist:MandatoryApplications.Count -ne 0)
{
    #Write-Verbose "$($MyInvocation.MyCommand.Name): Processing $($tsenvlist:MandatoryApplications.Count) mandatory applications."
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Processing $($tsenvlist:MandatoryApplications.Count) mandatory applications."
    $tsenvlist:MandatoryApplications | Install-PSDApplication
}
else
{
    #Write-Verbose "$($MyInvocation.MyCommand.Name): No mandatory applications specified."
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): No mandatory applications specified."
}

if ($tsenvlist:Applications.Count -ne 0)
{
    #Write-Verbose "$($MyInvocation.MyCommand.Name): Processing $($tsenvlist:Applications.Count) applications."
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): Processing $($tsenvlist:Applications.Count) applications."
    $tsenvlist:Applications | % { Install-PSDApplication $_ }
}
else
{
    #Write-Verbose "$($MyInvocation.MyCommand.Name): No applications specified."
    Write-PSDLog -Message "$($MyInvocation.MyCommand.Name): No applications specified."
}
