<#
.SYNOPSIS
    Module for the PSD Wizard - Version 3.0.1
.DESCRIPTION
    Completely rebuilt PowerShell Deployment Wizard with runspace-based UI architecture,
    optimized performance, and fixed critical bugs from v2.3.6
.LINK
    https://github.com/FriendsOfMDT/PSD
.NOTES
    FileName: PSDWizardNew.psm1
    Solution: PowerShell Deployment for MDT
    Purpose: Modern, responsive wizard for PSD deployments
    Author: PSD Development Team
    Contact: Dick Tracy (@PowershellCrack)
    Primary: Dick Tracy (@PowershellCrack)
    Created: 2020-01-12
    Modified: 2026-11-23
    Version: 3.0.1
    VERSION 3.0.1 CHANGES: (see PSDWizardNew\CHANGELOG.md)
        FIXED: List dropdowns (Org Unit, Intune Group, Device Role) empty because control names are case sensitive
        FIXED: Settings of one Task Sequence carried over to another (mandatory applications, lists, skip properties)
        Debug console (PSDDebug=YES) and a busy indicator while a Task Sequence selection is processed
    VERSION 3.0.0 CHANGES:
        Complete rewrite from scratch with optimized logic
        Runspace-based UI architecture for responsiveness
        FIXED: Application selection (apps in CS.ini always installed)
        FIXED: Domain admin validation (rejected valid username formats)
        FIXED: TaskSequence skip logic (SkipTaskSequence=YES caused restart)
        FIXED: Dummy application requirement (returns empty array, not null)
        Development mode support for testing outside WinPE
        Improved error handling with try/catch/finally
        All functions follow <Verb>-PSDWizard<Action> naming convention
        Modern PowerShell best practices throughout
        Synchronized state management with hashtable
        Async data loading operations
        Enhanced logging and debugging capabilities

    ARCHITECTURE:
        - Entry Point: Show-PSDWizard
        - State Management: Initialize-PSDWizardState, Get/Set-PSDWizardState
        - Runspace Management: Start/Stop-PSDWizardRunspace
        - UI Layer: Invoke-PSDWizard (runspace-based)
        - Business Logic: All validation/export functions
        - Data Layer: TSEnv interaction functions

    TODO:
        - Support Autopilot Tasksequence
        - Support additional languages
        - Additional themes (Windows 11 OOBE, Circular buttons)
#>

#Requires -Version 5.1

#region MODULE VARIABLES

# Module-level state management
$script:PSDWizardState = $null
$script:PSDWizardRunspace = $null
$script:PSDWizardUI = $null
$script:PSDWizardSyncHash = $null

# Last log entries of this session, shown by the debug console
$script:PSDWizardLogBuffer = New-Object 'System.Collections.Generic.List[string]'

# Development mode flag
$script:IsDevelopmentMode = $false

# Version information
$script:ModuleVersion = '3.0.1'
$script:ModuleDate = '2026-11-23'

#endregion

#region CORE UTILITY FUNCTIONS

Function Test-PSDWizardEnvironment {
    <#
    .SYNOPSIS
        Detects if running in WinPE or development environment
    .DESCRIPTION
        Determines the execution environment to enable development mode testing
        outside of WinPE. Checks for TSEnv object and WinPE registry keys.
    .OUTPUTS
        [PSCustomObject] with properties: IsWinPE, IsDevelopment, TSEnvAvailable
    .EXAMPLE
        $env = Test-PSDWizardEnvironment
        if ($env.IsDevelopment) { Write-Host "Running in development mode" }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param()

    # Initialize environment info hashtable
    $envInfo = [PSCustomObject]@{
        IsWinPE = $false
        IsDevelopment = $false
        TSEnvAvailable = $false
    }

    try {
        # check if running in WinPE
        $winPEKey = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT' -ErrorAction SilentlyContinue
        if ($winPEKey) {
            $envInfo.IsWinPE = $true
        }
        # check for tsenv drive
        $tsenvDrive = Get-PSDrive -Name 'TSEnv' -ErrorAction SilentlyContinue
        if ($tsenvDrive) {
            $envInfo.TSEnvAvailable = $true
        }
        # set development mode based on environment
        $envInfo.IsDevelopment = $false
        $script:IsDevelopmentMode = $false
    }
    catch {
        Write-PSDLog -Message "Error detecting environment: $($_.Exception.Message)" -LogLevel 2
    }

    return $envInfo
}

Function Write-PSDWizardLog {
    <#
    .SYNOPSIS
        Enhanced logging function for PSDWizard with optional development mode output
    .DESCRIPTION
        Centralizes logging with support for both PSDLog and console output in development mode
    .PARAMETER Message
        The message to log
    .PARAMETER LogLevel
        Log level: 1=Information, 2=Warning, 3=Error
    .PARAMETER Component
        Component name (defaults to function name)
    .EXAMPLE
        Write-PSDWizardLog -Message "Initialization complete" -Component Initialize-PSDWizard
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1,3)]
        [int]$LogLevel = 1,

        [Parameter(Mandatory=$false)]
        [string]$Component = $null
    )
    # Determine the component name if not provided
    if ([string]::IsNullOrWhiteSpace($Component)) {
        $Component = (Get-PSCallStack)[1].Command
    }
    # Keep the last entries in memory for the debug console
    $levelText = switch ($LogLevel) { 2 { 'WARN' } 3 { 'ERROR' } default { 'INFO' } }
    $script:PSDWizardLogBuffer.Add(('{0:HH:mm:ss} {1,-5} [{2}] {3}' -f (Get-Date), $levelText, $Component, $Message))
    if ($script:PSDWizardLogBuffer.Count -gt 2000) {
        $script:PSDWizardLogBuffer.RemoveRange(0, 500)
    }

    # Log the message using PSDLog if available
    if (Get-Command Write-PSDLog -ErrorAction SilentlyContinue) {
        $logMessage = "{0}: {1}" -f $Component, $Message
        Write-PSDLog -Message $logMessage -LogLevel $LogLevel

        # Keep the standard PSD log intact while also collecting Wizard-specific entries.
        $psdLogPath = Get-Variable -Name PSDLogPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace([string]$psdLogPath)) {
            $psdLogDirectory = Split-Path -Parent $psdLogPath
            if ([string]::IsNullOrWhiteSpace($psdLogDirectory)) {
                $psdLogDirectory = (Get-Location).Path
            }
            $wizardLogPath = Join-Path $psdLogDirectory 'PSDWizardNew.log'
            if ($wizardLogPath -ine $psdLogPath) {
                Write-PSDLog -Message $logMessage -LogLevel $LogLevel -OutputLogFile $wizardLogPath
            }
        }
    }
    # Output to console if in development mode
    if ($script:IsDevelopmentMode) {
        $prefix = switch ($LogLevel) {
            1 { '[INFO]' }
            2 { '[WARN]' }
            3 { '[ERROR]' }
            default { '[INFO]' }
        }
        Write-Host "$prefix [$Component] $Message"
    }
}

#endregion

#region STATE MANAGEMENT FUNCTIONS

Function Initialize-PSDWizardState {
    <#
    .SYNOPSIS
        Initializes the wizard state management hashtable
    .DESCRIPTION
        Creates a synchronized hashtable for cross-thread state management in runspace architecture.
        Stores all wizard state, UI elements, and configuration data.
    .EXAMPLE
        $state = Initialize-PSDWizardState -DevelopmentMode
    .PARAMETER DevelopmentMode
        Enable development mode for testing outside WinPE
    .OUTPUTS
        [hashtable] Synchronized state hashtable
    .EXAMPLE
        $state = Initialize-PSDWizardState -DevelopmentMode
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    Param(
        [Parameter(Mandatory=$false)]
        [switch]$DevelopmentMode
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Initializing wizard state..." -Component $FunctionName

    # Create synchronized hashtable for cross-thread access
    $syncHash = [hashtable]::Synchronized(@{
        # Environment
        IsDevelopmentMode = $DevelopmentMode.IsPresent
        IsWinPE = $false
        TSEnvAvailable = $false

        # UI State
        Window = $null
        XAMLContent = $null
        UIElements = @{}
        CurrentPage = $null
        IsLoaded = $false
        IsClosing = $false
        IsClosed = $false

        # Wizard Data
        SelectedApplications = @()
        SelectedTaskSequence = $null
        ValidationErrors = @()
        UserSelections = @{}

        # Runspace Management
        Runspace = $null
        PowerShell = $null
        AsyncHandle = $null

        # Configuration
        ResourcePath = $null
        Language = 'en-US'
        Theme = 'Classic'
        Version = $script:ModuleVersion

        # Progress Tracking
        ProgressStatus = 'Initializing'
        ProgressPercent = 0
        ProgressIndeterminate = $true

        # Error State
        Error = $null
        hadCritError = $false

        # Timestamps
        InitializeTime = Get-Date
        LastUpdate = Get-Date
    })

    Write-PSDWizardLog -Message "Wizard state initialized successfully" -Component $FunctionName
    return $syncHash
}

Function Get-PSDWizardState {
    <#
    .SYNOPSIS
        Retrieves values from the wizard state hashtable
    .DESCRIPTION
        Safely retrieves state values with optional default values for missing keys
    .PARAMETER Key
        The state key to retrieve
    .PARAMETER Default
        Default value if key doesn't exist
    .OUTPUTS
        The value stored in state, or default
    .EXAMPLE
        $currentPage = Get-PSDWizardState -Key 'CurrentPage' -Default 'Welcome'
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Key,

        [Parameter(Mandatory=$false)]
        $Default = $null
    )

    # Determine the component name for logging if not provided
    $FunctionName = $MyInvocation.MyCommand.Name

    if ($null -eq $script:PSDWizardSyncHash) {
        Write-PSDWizardLog -Message "State not initialized" -LogLevel 2 -Component $FunctionName
        return $Default
    }

    # Return the value if the key exists in the state hashtable
    if ($script:PSDWizardSyncHash.ContainsKey($Key)) {
        return $script:PSDWizardSyncHash[$Key]
    }

    return $Default
}

Function Set-PSDWizardState {
    <#
    .SYNOPSIS
        Sets values in the wizard state hashtable
    .DESCRIPTION
        Safely updates state values with timestamp tracking
    .PARAMETER Key
        The state key to set
    .PARAMETER Value
        The value to store
    .EXAMPLE
        Set-PSDWizardState -Key 'CurrentPage' -Value 'TaskSequence'
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Key,

        [Parameter(Mandatory=$true)]
        $Value
    )

    # Determine the component name for logging if not provided
    $FunctionName = $MyInvocation.MyCommand.Name

    if ($null -eq $script:PSDWizardSyncHash) {
        Write-PSDWizardLog -Message "State not initialized, cannot set key: $Key" -LogLevel 3 -Component $FunctionName
        return
    }

    $script:PSDWizardSyncHash[$Key] = $Value
    $script:PSDWizardSyncHash['LastUpdate'] = Get-Date

    Write-PSDWizardLog -Message "State updated: $Key" -Component $FunctionName
}

#endregion

#region RUNSPACE FUNCTIONS

Function Start-PSDWizardRunspace {
    <#
    .SYNOPSIS
        Initializes and starts the UI runspace
    .DESCRIPTION
        Creates a new STA runspace for the WPF UI thread, preventing UI freezes during data operations.
        Loads required functions and variables into the runspace scope.
    .PARAMETER SyncHash
        The synchronized state hashtable
    .PARAMETER ScriptBlock
        The scriptblock to execute in the runspace
    .OUTPUTS
        [PSCustomObject] with Runspace, PowerShell, and AsyncHandle properties
    .EXAMPLE
        $rs = Start-PSDWizardRunspace -SyncHash $state -ScriptBlock $uiScript
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Creating UI runspace..." -Component $FunctionName

    try {
        # Create runspace
        $Runspace = [runspacefactory]::CreateRunspace()
        $Runspace.ApartmentState = "STA"
        $Runspace.ThreadOptions = "ReuseThread"
        $Runspace.Open()

        # Pass syncHash to runspace
        $Runspace.SessionStateProxy.SetVariable("syncHash", $SyncHash)
        $SyncHash.Runspace = $Runspace

        # Create PowerShell instance
        $PowerShell = [PowerShell]::Create()
        $PowerShell.Runspace = $Runspace
        $PowerShell.AddScript($ScriptBlock) | Out-Null

        # Start async execution
        $AsyncHandle = $PowerShell.BeginInvoke()

        # Register cleanup event
        Register-ObjectEvent -InputObject $Runspace -EventName 'AvailabilityChanged' -Action {
            if ($Sender.RunspaceAvailability -eq "Available") {
                $Sender.Closeasync()
                $Sender.Dispose()
                [GC]::Collect()
            }
        } | Out-Null

        Write-PSDWizardLog -Message "UI runspace started successfully" -Component $FunctionName

        return [PSCustomObject]@{
            Runspace = $Runspace
            PowerShell = $PowerShell
            AsyncHandle = $AsyncHandle
        }
    }
    catch {
        Write-PSDWizardLog -Message "Failed to start runspace: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
       throw
    }
}

Function Stop-PSDWizardRunspace {
    <#
    .SYNOPSIS
        Stops and cleans up the UI runspace
    .DESCRIPTION
        Properly disposes of runspace resources and performs garbage collection
    .PARAMETER RunspaceInfo
        The runspace information object from Start-PSDWizardRunspace
    .EXAMPLE
        Stop-PSDWizardRunspace -RunspaceInfo $rs
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [PSCustomObject]$RunspaceInfo
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Stopping UI runspace..." -Component $FunctionName

    # Attempt to stop and clean up the UI runspace
    try {
        if ($null -ne $RunspaceInfo) {
            if ($null -ne $RunspaceInfo.PowerShell) {
                $RunspaceInfo.PowerShell.Stop()
                $RunspaceInfo.PowerShell.Dispose()
            }

            if ($null -ne $RunspaceInfo.Runspace) {
                $RunspaceInfo.Runspace.Close()
                $RunspaceInfo.Runspace.Dispose()
            }
        }

        # Clean up script-level variables
        $script:PSDWizardRunspace = $null
        $script:PSDWizardUI = $null

        # Force garbage collection
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        Write-PSDWizardLog -Message "UI runspace stopped successfully" -Component $FunctionName
    }
    catch {
        Write-PSDWizardLog -Message "Error stopping runspace: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

#endregion

#region DEFINITION & CONDITION FUNCTIONS

Function Get-PSDWizardDefinitions {
    <#
    .SYNOPSIS
        Retrieves definition file sections (optimized)
    .DESCRIPTION
        Parses XML definition files for wizard configuration with enhanced error handling
    .PARAMETER Xml
        The XML document to parse
    .PARAMETER Section
        The section to retrieve: Global, WelcomeWizard, or Pane
    .OUTPUTS
        [Xml.XmlElement] The requested section
    .EXAMPLE
        $global = Get-PSDWizardDefinitions -Xml $xml -Section Global
    #>
    [CmdletBinding()]
    [OutputType([Xml.XmlElement])]
    Param(
        [Parameter(Mandatory=$true)]
        [xml]$Xml,

        [Parameter(Mandatory=$false)]
        [ValidateSet('Global', 'WelcomeWizard', 'Pane')]
        [string]$Section = 'Global'
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Attempt to retrieve the requested section from the XML
    try {
        if ($null -eq $Xml.Wizard) {
            Write-PSDWizardLog -Message "Invalid XML structure: Wizard node not found" -LogLevel 3 -Component $FunctionName
            return $null
        }
        # Ensure the requested section exists within the XML structure
        $result = switch ($Section) {
            'Global' { $Xml.Wizard.Global }
            'WelcomeWizard' { $Xml.Wizard.WelcomeWizard }
            'Pane' { $Xml.Wizard.Pane }
            default { $null }
        }

        if ($null -eq $result) {
            Write-PSDWizardLog -Message "Section '$Section' not found in XML" -LogLevel 2 -Component $FunctionName
        }

        return $result
    }
    catch {
        Write-PSDWizardLog -Message "Error parsing XML: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        return $null
    }
}

Function Get-PSDWizardThemeDefinition {
    <#
    .SYNOPSIS
        Retrieves theme definition file sections (optimized)
    .DESCRIPTION
        Parses theme XML files for UI styling and layout with improved null handling
    .PARAMETER Xml
        The theme XML document
    .PARAMETER Section
        The section to retrieve
    .OUTPUTS
        Theme definition object
    .EXAMPLE
        $template = Get-PSDWizardThemeDefinition -Xml $themeXml -Section ThemeTemplate
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [xml]$Xml,

        [Parameter(Mandatory=$false)]
        [ValidateSet('ThemeTemplate', 'PanesTemplate', 'WelcomeWizard', 'Pane', 'PaneStartingMargin')]
        [string]$Section
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Attempt to retrieve the requested section from the theme XML
    try {
        if ($null -eq $Xml.Theme) {
            Write-PSDWizardLog -Message "Invalid theme XML structure" -LogLevel 3 -Component $FunctionName
            return $null
        }

        # Initialize the result variable to null before attempting to retrieve the section
        $result = switch ($Section) {
            'ThemeTemplate' { $Xml.Theme.Global.TemplateReference }
            'WelcomeWizard' { $Xml.Theme.Global.WelcomeWizardReference }
            'PanesTemplate' { $Xml.Theme.PaneDefinitions.PanesTemplate.'#cdata-section'.Trim() }
            'PaneStartingMargin' { $Xml.Theme.PaneDefinitions.PaneStartingMargin.'#cdata-section'.Trim() }
            'Pane' { $Xml.Theme.PaneDefinitions.Pane }
            default { $Xml.Theme }
        }

        return $result
    }
    catch {
        Write-PSDWizardLog -Message "Error parsing theme XML: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        return $null
    }
}

Function Get-PSDWizardCondition {
    <#
    .SYNOPSIS
        Converts XSL condition statements to PowerShell (optimized)
    .DESCRIPTION
        Translates XML condition syntax to executable PowerShell scriptblocks with improved parsing
    .PARAMETER Condition
        The XSL condition string
    .PARAMETER TSEnvSettings
        TSEnv settings (hashtable or PSCustomObject) for variable resolution
    .PARAMETER Passthru
        Return scriptblock instead of evaluating
    .OUTPUTS
        [bool] or [scriptblock] depending on -Passthru
    .EXAMPLE
        $result = Get-PSDWizardCondition -Condition 'Property("SkipWizard") <> "YES"' -TSEnvSettings $tsenv
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Condition,

        [Parameter(Mandatory=$false)]
        $TSEnvSettings,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    try {
        # Convert TSEnv properties to variables
        if ($TSEnvSettings) {
            # Handle both hashtable and PSCustomObject
            if ($TSEnvSettings -is [hashtable]) {
                foreach ($key in $TSEnvSettings.Keys) {
                    # Skip empty/null keys and underscore variables
                    if ([string]::IsNullOrWhiteSpace($key) -or $key -match "^_") {
                        continue
                    }

                    $varValue = $TSEnvSettings[$key]

                    # Preserve string values as-is for string comparisons
                    # Don't convert "YES"/"NO" to boolean - this breaks conditions like:
                    # UCase(Property("SkipIntuneGroup")) == "NO"

                    New-Variable -Name $key -Value $varValue -Scope Local -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                # PSCustomObject format
                foreach ($item in $TSEnvSettings) {
                    if ($null -eq $item -or [string]::IsNullOrWhiteSpace($item.Name)) {
                        continue
                    }

                    $varName = $item.Name
                    if ($varName -match "^_") { continue }

                    $varValue = $item.Value

                    # Preserve string values as-is for string comparisons
                    # Don't convert "YES"/"NO" to boolean - this breaks conditions

                    New-Variable -Name $varName -Value $varValue -Scope Local -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Convert operators: <> to -ne, == to -eq, etc.
        $psCondition = $Condition -replace '<>', ' -ne ' `
                                  -replace '==', ' -eq ' `
                                  -replace '=', ' -eq ' `
                                  -replace '<=', ' -le ' `
                                  -replace '>=', ' -ge ' `
                                  -replace '<', ' -lt ' `
                                  -replace '>', ' -gt '

        # Convert UCase() function calls - handle null values properly
        # UCase(Property("x")) becomes ([string]$x).ToUpper() to handle nulls
        # In regex replacement: $$ = literal $, $1 = backreference, so $$$ $1 = $SkipXxx
        $psCondition = [regex]::Replace($psCondition, 'UCase\s*\(\s*Property\s*\(\s*"([^"]+)"\s*\)\s*\)', '([string]$$$1).ToUpper()', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        # Remove any remaining standalone UCASE/UCase calls
        $psCondition = [regex]::Replace($psCondition, 'UCase\s*\(([^)]+)\)', '([string]$1).ToUpper()', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        # Convert Property("name") or Property(name) to $name (already handled ToUpper above)
        $psCondition = [regex]::Replace($psCondition, 'Property\s*\(\s*"([^"]+)"\)', '$$$1')
        $psCondition = [regex]::Replace($psCondition, 'Property\s*\(([^)]+)\)', '$$$1')

        # Handle Properties() for arrays/wildcards
        if ($psCondition -match 'Properties') {
            $propertiesMatches = [regex]::Matches($psCondition, 'Properties\("([^"]+)"\)')
            $propertyIndex = 0
            foreach ($match in $propertiesMatches) {
                $propertyPattern = $match.Groups[1].Value -replace '\(\*\)$', '*'
                $propertyValues = @()

                if ($TSEnvSettings -is [hashtable]) {
                    $matchingKeys = @($TSEnvSettings.Keys | Where-Object { [string]$_ -like $propertyPattern } | Sort-Object)
                    foreach ($key in $matchingKeys) {
                        $propertyValue = $TSEnvSettings[$key]
                        if ($propertyValue -is [array]) {
                            $propertyValues += $propertyValue
                        }
                        elseif ($null -ne $propertyValue) {
                            $propertyValues += $propertyValue
                        }
                    }
                }
                elseif ($TSEnvSettings) {
                    foreach ($property in @($TSEnvSettings | Where-Object { $_.Name -like $propertyPattern } | Sort-Object Name)) {
                        if ($property.Value -is [array]) {
                            $propertyValues += $property.Value
                        }
                        elseif ($null -ne $property.Value) {
                            $propertyValues += $property.Value
                        }
                    }
                }

                $variableName = "__PSDWizardProperties$propertyIndex"
                New-Variable -Name $variableName -Value $propertyValues -Scope Local -Force
                $psCondition = $psCondition.Replace($match.Value, ('$' + $variableName))
                $propertyIndex++
            }
            $psCondition = $psCondition -replace '\bin\b', ' -in '
        }

        # Handle logical operators
        if ($psCondition -match '\s+or\s+|\s+and\s+') {
            $psCondition = '(' + ($psCondition -replace '\bor\b', ') -or (' -replace '\band\b', ') -and (') + ')'
        }

        # Convert boolean strings
        $psCondition = $psCondition -replace '"True"', '$True' -replace '"False"', '$False'

        # Clean up whitespace
        $psCondition = ($psCondition -replace '\s+', ' ').Trim()

        # Debug output in development mode
        if ($script:IsDevelopmentMode) {
            Write-PSDWizardLog -Message "Condition transformed: '$Condition' => '$psCondition'" -Component $FunctionName
        }

        # Create scriptblock
        $scriptblock = [scriptblock]::Create($psCondition)

        if ($Passthru) {
            return $scriptblock
        }
        else {
            return (Invoke-Command -ScriptBlock $scriptblock)
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error parsing condition '$Condition': $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        Write-PSDWizardLog -Message "Transformed condition was: '$psCondition'" -LogLevel 2 -Component $FunctionName
        return $false
    }
}

#endregion

#region TSENV FUNCTIONS

Function Get-PSDWizardTSEnvProperty {
    <#
    .SYNOPSIS
        Gets TSEnv property values (FIXED: returns empty array instead of null)
    .DESCRIPTION
        Retrieves Task Sequence environment variables with wildcard support.
        FIXED: Returns @() instead of $null when no properties found (fixes dummy app bug)
    .PARAMETER Name
        Property name (supports wildcards)
    .PARAMETER WildCard
        Enable wildcard matching
    .PARAMETER ValueOnly
        Return only the value
    .PARAMETER NoExpand
        Don't expand embedded variables
    .OUTPUTS
        Property object(s) or values. Returns empty array @() when no matches found.
    .EXAMPLE
        $apps = Get-PSDWizardTSEnvProperty 'Applications' -WildCard
        # Returns @() if no apps, not $null
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [switch]$WildCard,

        [Parameter(Mandatory=$false)]
        [switch]$ValueOnly,

        [Parameter(Mandatory=$false)]
        [switch]$NoExpand
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    $results = @()  # FIXED: Initialize as empty array, not null

    try {
        # Check if TSEnv is available
        if ($script:IsDevelopmentMode) {
            Write-PSDWizardLog -Message "Development mode: Getting property '$Name' from TSEnvSettings" -Component $FunctionName

            # Try to get from PSDWizardSyncHash.TSEnvSettings
            if ($script:PSDWizardSyncHash -and $script:PSDWizardSyncHash.TSEnvSettings) {
                if ($WildCard) {
                    # Get all variables matching pattern
                    $matchingKeys = $script:PSDWizardSyncHash.TSEnvSettings.Keys | Where-Object { $_ -like $Name }

                    # Iterate over each matching key and retrieve its value
                    foreach ($key in $matchingKeys) {
                        $value = $script:PSDWizardSyncHash.TSEnvSettings[$key]
                        # Add the value to the results array
                        if ($ValueOnly) {
                            $results += $value
                        }
                        else {
                            # Add the property as a PSCustomObject to the results array
                            $results += [PSCustomObject]@{
                                Name = $key
                                Value = $value
                            }
                        }
                    }
                }
                else {
                    # Get specific variable
                    if ($script:PSDWizardSyncHash.TSEnvSettings.ContainsKey($Name)) {
                        $value = $script:PSDWizardSyncHash.TSEnvSettings[$Name]

                        # Add the value to the results array or as a PSCustomObject based on $ValueOnly
                        if ($ValueOnly) {
                            $results = $value
                        }
                        else {
                            # Add the property as a PSCustomObject to the results array
                            $results = [PSCustomObject]@{
                                Name = $Name
                                Value = $value
                            }
                        }
                    }
                    else {
                        Write-PSDWizardLog -Message "Property '$Name' not found in TSEnvSettings" -LogLevel 2 -Component $FunctionName
                    }
                }
            }

            return $results
        }

        if (-not (Get-PSDrive -Name 'TSEnv' -ErrorAction SilentlyContinue)) {
            throw "PSD TSEnv: drive is unavailable while reading '$Name'. Ensure PSD initialized the task-sequence environment before launching the wizard."
        }

        Write-PSDWizardLog -Message "Getting property '$Name' from TSEnv: drive" -Component $FunctionName
        # Check if the property name contains wildcard characters
        if ($WildCard) {
            # Retrieve all matching properties from the TSEnv: drive
            foreach ($item in (Get-ChildItem -Path 'TSEnv:' | Where-Object { $_.Name -like $Name })) {
                # Process each matching property from the TSEnv: drive
                if ($ValueOnly) {
                    $results += $item.Value
                }
                else {
                    # Add the property as a PSCustomObject to the results array
                    $results += [PSCustomObject]@{
                        Name = $item.Name
                        Value = $item.Value
                    }
                }
            }
        }
        else {
            # Attempt to retrieve the specific property from the TSEnv: drive
            $item = Get-Item -Path "TSEnv:\$Name" -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                # Process the retrieved property from the TSEnv: drive
                if ($ValueOnly) {
                    $results = $item.Value
                }
                else {
                    # Add the property as a PSCustomObject to the results array
                    $results = [PSCustomObject]@{
                        Name = $Name
                        Value = $item.Value
                    }
                }
            }
            else {
                Write-PSDWizardLog -Message "Property '$Name' not found in TSEnv: drive" -LogLevel 2 -Component $FunctionName
            }
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error accessing TSEnv: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        # Return empty array on error - CRITICAL FIX
        $results = @()
    }

    # CRITICAL FIX: Ensure we always return an array, never null
    if ($null -eq $results) {
        $results = @()
    }

    return $results
}

Function Set-PSDWizardTSEnvProperty {
    <#
    .SYNOPSIS
        Sets TSEnv property values (optimized)
    .DESCRIPTION
        Updates Task Sequence environment variables with validation
    .PARAMETER Name
        Property name
    .PARAMETER Value
        Property value
    .PARAMETER Passthru
        Return the property object
    .EXAMPLE
        Set-PSDWizardTSEnvProperty -Name 'OSDComputerName' -Value 'PC-001'
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Attempt to set the TSEnv property with error handling
    try {
        # Check if we are in development mode and handle accordingly
        if ($script:IsDevelopmentMode) {
            Write-PSDWizardLog -Message "Development mode: Setting $Name = $Value in TSEnvSettings" -Component $FunctionName

            # Update PSDWizardSyncHash.TSEnvSettings
            if ($script:PSDWizardSyncHash -and $script:PSDWizardSyncHash.TSEnvSettings) {
                $script:PSDWizardSyncHash.TSEnvSettings[$Name] = $Value
            }

            if ($Passthru) {
                return [PSCustomObject]@{ Name = $Name; Value = $Value }
            }
            return
        }

        # Ensure the TSEnv: drive is available before attempting to set the property
        if (-not (Get-PSDrive -Name 'TSEnv' -ErrorAction SilentlyContinue)) {
            throw "PSD TSEnv: drive is unavailable while setting '$Name'. Ensure PSD initialized the task-sequence environment before launching the wizard."
        }
        # Set the TSEnv property with error handling
        Set-Item -LiteralPath "TSEnv:\$Name" -Value $Value -Force -ErrorAction Stop | Out-Null

        Write-PSDWizardLog -Message "Property '$Name' set to '$Value'" -Component $FunctionName

        if ($Passthru) {
            return [PSCustomObject]@{ Name = $Name; Value = $Value }
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error setting TSEnv property '$Name': $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        throw
    }
}

Function Remove-PSDWizardTSEnvProperty {
    <#
    .SYNOPSIS
        Removes TSEnv property values (optimized)
    .DESCRIPTION
        Deletes Task Sequence environment variables with wildcard support
    .PARAMETER Name
        Property name (supports wildcards with -WildCard)
    .PARAMETER WildCard
        Enable wildcard matching
    .EXAMPLE
        Remove-PSDWizardTSEnvProperty -Name 'Applications*' -WildCard
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [switch]$WildCard
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    # Attempt to remove the TSEnv property with error handling
    try {
        # Check if we are in development mode and handle accordingly
        if ($script:IsDevelopmentMode) {
            Write-PSDWizardLog -Message "Development mode: Removing TSEnv property '$Name' from TSEnvSettings (WildCard=$WildCard)" -Component $FunctionName

            # Remove from PSDWizardSyncHash.TSEnvSettings
            if ($script:PSDWizardSyncHash -and $script:PSDWizardSyncHash.TSEnvSettings) {
                if ($WildCard) {
                    # Find all keys in TSEnvSettings that match the wildcard pattern
                    $matchingKeys = @($script:PSDWizardSyncHash.TSEnvSettings.Keys | Where-Object { $_ -like $Name })
                    foreach ($key in $matchingKeys) {
                        $script:PSDWizardSyncHash.TSEnvSettings.Remove($key)
                        Write-PSDWizardLog -Message "Removed property '$key' from TSEnvSettings" -Component $FunctionName
                    }
                }
                else {
                    # Remove the specific key from TSEnvSettings if it exists
                    if ($script:PSDWizardSyncHash.TSEnvSettings.ContainsKey($Name)) {
                        $script:PSDWizardSyncHash.TSEnvSettings.Remove($Name)
                        Write-PSDWizardLog -Message "Removed property '$Name' from TSEnvSettings" -Component $FunctionName
                    }
                }
            }

            return
        }

        if (-not (Get-PSDrive -Name 'TSEnv' -ErrorAction SilentlyContinue)) {
            throw "PSD TSEnv: drive is unavailable while clearing '$Name'. Ensure PSD initialized the task-sequence environment before launching the wizard."
        }
        if ($WildCard) {
            # Retrieve all matching properties from the TSEnv: drive
            $matchingItems = @(Get-ChildItem -Path 'TSEnv:' | Where-Object { $_.Name -like $Name })
            foreach ($item in $matchingItems) {
                Set-Item -LiteralPath "TSEnv:\$($item.Name)" -Value "" -Force -ErrorAction Stop | Out-Null
                Write-PSDWizardLog -Message "Cleared property: $($item.Name)" -Component $FunctionName
            }
        }
        else {
            # Remove the specific property from the TSEnv: drive
            Set-Item -LiteralPath "TSEnv:\$Name" -Value "" -Force -ErrorAction Stop | Out-Null
            Write-PSDWizardLog -Message "Cleared property: $Name" -Component $FunctionName
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error removing TSEnv property '$Name': $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

Function Get-PSDWizardListControl {
    <#
    .SYNOPSIS
        Finds the TSEnvList_<name> control for a list, ignoring the case of the name.
    .DESCRIPTION
        The task sequence environment returns property names in upper case (DOMAINOUS001), while the controls are named
        after the property (TSEnvList_DomainOUs) and FindName is case sensitive.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$true)]
        [string]$ListName
    )

    $controlName = "TSEnvList_$ListName"
    # Find the actual control name in the UIElements hashtable, ignoring case
    $actualName = @($SyncHash.UIElements.Keys | Where-Object { [string]$_ -ieq $controlName }) | Select-Object -First 1
    if ($actualName) {
        return $Window.FindName([string]$actualName)
    }
    # If the control was not found in the UIElements hashtable, try to find it directly by name in the window
    return $Window.FindName($controlName)
}

Function Get-PSDWizardTSEnvLists {
    <#
    .SYNOPSIS
        Collects the numbered task sequence properties (DomainOUs001, DomainOUs002, ...) into named lists.
    .DESCRIPTION
        The TSEnvList: drive is only a view over numbered TSEnv: variables: setting tsenvlist:DomainOUs writes DOMAINOUS001, DOMAINOUS002, ...
        and reading it reads them back. The wizard already has every TSEnv: variable in its snapshot, so the lists are built from that.
        The same code works in WinPE and in development mode, where there is no drive.
    .PARAMETER TSEnvSettings
        The TSEnv: snapshot
    .OUTPUTS
        [hashtable] List name to values, sorted by number. The list names keep the casing of the TS environment (upper case).
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [hashtable]$TSEnvSettings
    )

    $lists = @{}
    # Return an empty hashtable if no TSEnvSettings are provided
    if (-not $TSEnvSettings) {
        return $lists
    }

    $numberedProperties = @{}
    foreach ($key in $TSEnvSettings.Keys) {
        # Match the key against the pattern for numbered properties (e.g., PropertyName001)
        $match = [regex]::Match([string]$key, '^(?<Name>.+?)(?<Index>\d{3})$')
        if (-not $match.Success) {
            continue
        }
        # Extract the base name and index from the key
        $name = $match.Groups['Name'].Value

        # Applications and mandatory applications are handled by the Applications page
        if ($name -in @('Applications', 'MandatoryApplications')) {
            continue
        }

        # Initialize the array for this base name if it doesn't exist yet
        if (-not $numberedProperties.ContainsKey($name)) {
            $numberedProperties[$name] = @()
        }

        # Add the current key and its value to the array for this base name
        $numberedProperties[$name] += [PSCustomObject]@{
            Index = [int]$match.Groups['Index'].Value
            Value = $TSEnvSettings[$key]
        }
    }

    # Iterate over each base name and build the final lists
    foreach ($name in $numberedProperties.Keys) {
        # Sort the values by their index and filter out any that are null or whitespace
        $values = @($numberedProperties[$name] | Sort-Object Index | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.Value)
        } | ForEach-Object { $_.Value })

        # Only add the list to the final output if it contains any values
        if ($values.Count -gt 0) {
            $lists[$name] = $values
        }
    }

    return $lists
}

#endregion

#region LOCALE AND TIMEZONE FUNCTIONS

Function Resolve-PSDWizardLocalePath {
    <#
    .SYNOPSIS
        Finds the folder that holds PSDListOfLanguages.xml and PSDListOfTimeZoneIndex.xml.
    .DESCRIPTION
        The indexes live in the deployment share's Scripts folder, one level above the wizard's resource folder (Scripts\PSDWizardNew).
        The candidates are checked in order and the first folder with the language index wins.
    .PARAMETER ResourcePath
        The wizard resource folder (Scripts\PSDWizardNew)
    .PARAMETER ControlPath
        The deployment share Control folder
    .OUTPUTS
        [string] The folder, or the resource folder when no index was found
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$ResourcePath,

        [Parameter(Mandatory=$false)]
        [string]$ControlPath
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    $candidates = @()
    if ($ResourcePath) {
        $candidates += $ResourcePath
        $candidates += (Split-Path -Parent $ResourcePath)
    }
    # PSDStart sets ScriptRoot to the cached or shared Scripts folder
    if ($env:ScriptRoot) {
        $candidates += $env:ScriptRoot
    }
    if ($ControlPath) {
        $candidates += (Join-Path (Split-Path -Parent $ControlPath) 'Scripts')
    }
    $candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)

    foreach ($candidate in $candidates) {
        # Combine the path as text: Join-Path fails for a candidate on a drive that does not exist
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($candidate, 'PSDListOfLanguages.xml')) -ErrorAction SilentlyContinue) {
            Write-PSDWizardLog -Message "Found the language and time zone indexes in $candidate" -Component $FunctionName
            return $candidate
        }
    }

    Write-PSDWizardLog -Message "PSDListOfLanguages.xml was not found in: $($candidates -join '; ')" -LogLevel 2 -Component $FunctionName
    return $ResourcePath
}

Function Get-PSDWizardLocale {
    <#
    .SYNOPSIS
        Loads list of locales from XML file
    .DESCRIPTION
        Reads PSDListOfLanguages.xml and returns array of locale objects with
        properties: ID, Name, Language, Culture, KeyboardID, KeyboardLayout
    .PARAMETER Path
        Path to Scripts folder containing PSDListOfLanguages.xml
    .OUTPUTS
        [array] Array of locale objects
    .EXAMPLE
        $locales = Get-PSDWizardLocale -Path "\\deploy\Scripts"
    #>
    [CmdletBinding()]
    [OutputType([array])]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$Path
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    try {
        # Determine path to XML file
        if (-not $Path) {
            $Path = Split-Path -Parent $PSScriptRoot
            # Check if there is a Scripts folder within the current path and update the path accordingly
            if (Test-Path "$Path\Scripts") {
                $Path = "$Path\Scripts"
            }
        }

        # Construct the full path to the XML file containing the list of locales
        $xmlFile = Join-Path $Path "PSDListOfLanguages.xml"
        Write-PSDWizardLog -Message "Loading locales from: $xmlFile" -Component $FunctionName

        if (Test-Path $xmlFile) {
            # Parse the XML data and convert it into an array of PSCustomObjects representing locales
            [xml]$xmlData = Get-Content $xmlFile -Raw
            $locales = $xmlData.Locales.Locale | ForEach-Object {
                [PSCustomObject]@{
                    ID = $_.ID
                    Name = $_.Name
                    Language = $_.Language
                    Culture = $_.Culture
                    KeyboardID = $_.KeyboardID
                    KeyboardLayout = $_.KeyboardLayout
                }
            }

            Write-PSDWizardLog -Message "Loaded $($locales.Count) locales" -Component $FunctionName
            return $locales
        }
        else {
            Write-PSDWizardLog -Message "XML file not found ($xmlFile), returning sample data of 10 languages" -LogLevel 2 -Component $FunctionName

            # Return sample data if file not found
            return @(
                [PSCustomObject]@{ ID='0409'; Name='English (United States)'; Language='English'; Culture='en-US'; KeyboardID='00000409'; KeyboardLayout='0409:00000409' }
                [PSCustomObject]@{ ID='0809'; Name='English (United Kingdom)'; Language='English'; Culture='en-GB'; KeyboardID='00000809'; KeyboardLayout='0809:00000809' }
                [PSCustomObject]@{ ID='0c09'; Name='English (Australia)'; Language='English'; Culture='en-AU'; KeyboardID='00000c09'; KeyboardLayout='0c09:00000c09' }
                [PSCustomObject]@{ ID='1009'; Name='English (Canada)'; Language='English'; Culture='en-CA'; KeyboardID='00001009'; KeyboardLayout='1009:00001009' }
                [PSCustomObject]@{ ID='040c'; Name='French (France)'; Language='French'; Culture='fr-FR'; KeyboardID='0000040c'; KeyboardLayout='040c:0000040c' }
                [PSCustomObject]@{ ID='0407'; Name='German (Germany)'; Language='German'; Culture='de-DE'; KeyboardID='00000407'; KeyboardLayout='0407:00000407' }
                [PSCustomObject]@{ ID='040a'; Name='Spanish (Spain)'; Language='Spanish'; Culture='es-ES'; KeyboardID='0000040a'; KeyboardLayout='040a:0000040a' }
                [PSCustomObject]@{ ID='0410'; Name='Italian (Italy)'; Language='Italian'; Culture='it-IT'; KeyboardID='00000410'; KeyboardLayout='0410:00000410' }
                [PSCustomObject]@{ ID='0411'; Name='Japanese (Japan)'; Language='Japanese'; Culture='ja-JP'; KeyboardID='00000411'; KeyboardLayout='0411:00000411' }
                [PSCustomObject]@{ ID='0804'; Name='Chinese (China)'; Language='Chinese'; Culture='zh-CN'; KeyboardID='00000804'; KeyboardLayout='0804:00000804' }
            )
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error loading locales: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        return @()
    }
}

Function Get-PSDWizardTimeZoneIndex {
    <#
    .SYNOPSIS
        Loads list of time zones from XML file
    .DESCRIPTION
        Reads PSDListOfTimeZoneIndex.xml and returns array of timezone objects with
        properties: id, TimeZone, DisplayName, Name, UTC
    .PARAMETER Path
        Path to Scripts folder containing PSDListOfTimeZoneIndex.xml
    .OUTPUTS
        [array] Array of timezone objects
    .EXAMPLE
        $timezones = Get-PSDWizardTimeZoneIndex -Path "\\deploy\Scripts"
    #>
    [CmdletBinding()]
    [OutputType([array])]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$Path
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    try {
        # Determine path to XML file
        if (-not $Path) {
            $Path = Split-Path -Parent $PSScriptRoot
            if (Test-Path "$Path\Scripts") {
                $Path = "$Path\Scripts"
            }
        }
        # Ensure the path exists
        $xmlFile = Join-Path $Path "PSDListOfTimeZoneIndex.xml"
        Write-PSDWizardLog -Message "Loading timezones from: $xmlFile" -Component $FunctionName

        if (Test-Path $xmlFile) {
            # Load the XML data from the file into an XML object
            [xml]$xmlData = Get-Content $xmlFile -Raw
            $timezones = $xmlData.TimeZoneIndex.Index | ForEach-Object {
                [PSCustomObject]@{
                    id = $_.id
                    TimeZone = $_.TimeZone
                    DisplayName = $_.DisplayName
                    Name = $_.Name
                    UTC = $_.UTC
                }
            }

            Write-PSDWizardLog -Message "Loaded $($timezones.Count) timezones" -Component $FunctionName
            return $timezones
        }
        else {
            Write-PSDWizardLog -Message "XML file not found ($xmlFile), returning sample data of 12 time zones" -LogLevel 2 -Component $FunctionName

            # Return sample data if file not found
            return @(
                [PSCustomObject]@{ id='4'; TimeZone='(GMT-08:00) Pacific Standard Time'; DisplayName='Pacific Standard Time'; Name='Pacific Time (US and Canada)'; UTC='UTC-08:00' }
                [PSCustomObject]@{ id='10'; TimeZone='(GMT-07:00) Mountain Standard Time'; DisplayName='Mountain Standard Time'; Name='Mountain Time (US and Canada)'; UTC='UTC-07:00' }
                [PSCustomObject]@{ id='20'; TimeZone='(GMT-06:00) Central Standard Time'; DisplayName='Central Standard Time'; Name='Central Time (US and Canada)'; UTC='UTC-06:00' }
                [PSCustomObject]@{ id='35'; TimeZone='(GMT-05:00) Eastern Standard Time'; DisplayName='Eastern Standard Time'; Name='Eastern Time (US and Canada)'; UTC='UTC-05:00' }
                [PSCustomObject]@{ id='85'; TimeZone='(GMT) GMT Standard Time'; DisplayName='GMT Standard Time'; Name='Greenwich Mean Time: Dublin, Edinburgh, Lisbon, London'; UTC='UTC' }
                [PSCustomObject]@{ id='110'; TimeZone='(GMT+01:00) W. Europe Standard Time'; DisplayName='W. Europe Standard Time'; Name='Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna'; UTC='UTC+01:00' }
                [PSCustomObject]@{ id='145'; TimeZone='(GMT+02:00) E. Europe Standard Time'; DisplayName='E. Europe Standard Time'; Name='Bucharest'; UTC='UTC+02:00' }
                [PSCustomObject]@{ id='158'; TimeZone='(GMT+03:00) Russian Standard Time'; DisplayName='Russian Standard Time'; Name='Moscow, St. Petersburg, Volgograd'; UTC='UTC+03:00' }
                [PSCustomObject]@{ id='190'; TimeZone='(GMT+05:30) India Standard Time'; DisplayName='India Standard Time'; Name='Chennai, Kolkata, Mumbai, New Delhi'; UTC='UTC+05:30' }
                [PSCustomObject]@{ id='210'; TimeZone='(GMT+08:00) China Standard Time'; DisplayName='China Standard Time'; Name='Beijing, Chongqing, Hong Kong, Urumqi'; UTC='UTC+08:00' }
                [PSCustomObject]@{ id='235'; TimeZone='(GMT+09:00) Tokyo Standard Time'; DisplayName='Tokyo Standard Time'; Name='Osaka, Sapporo, Tokyo'; UTC='UTC+09:00' }
                [PSCustomObject]@{ id='255'; TimeZone='(GMT+10:00) AUS Eastern Standard Time'; DisplayName='AUS Eastern Standard Time'; Name='Canberra, Melbourne, Sydney'; UTC='UTC+10:00' }
            )
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error loading timezones: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        return @()
    }
}

#endregion

#region VALIDATION FUNCTIONS

Function Test-PSDWizardDomainAccountName {
    <#
    .SYNOPSIS
        Tests whether a domain account name uses supported syntax.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$AccountName
    )

    # Validate only AD-forbidden characters instead of rejecting valid account punctuation with an allow-list.
    $account = $AccountName.Trim()
    if ([string]::IsNullOrWhiteSpace($account) -or $account -match '[\x00-\x1F]') {
        return $false
    }

    # Check for domain\username or username@domain.com formats and extract the username part
    if ($account -match '\\') {
        # Split the account into domain and username parts
        $parts = $account -split '\\', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            return $false
        }
        # Ensure the username part is not empty
        $account = $parts[1]
    }
    elseif ($account -match '@') {
        # Split the account into username and domain parts for UPN format
        $parts = $account -split '@', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
            return $false
        }
        # Ensure the domain part is not empty
        $account = $parts[0]
    }

    return -not [string]::IsNullOrWhiteSpace($account) -and $account -notmatch '["/\\\[\]:;|=,+*?<>]'
}

Function Confirm-PSDWizardOSDJoinAccount {
    <#
    .SYNOPSIS
        Validates OSD join account username (FIXED)
    .DESCRIPTION
        Validates domain join account with support for multiple formats:
        - DOMAIN\username
        - username@domain.com
        - username
        FIXED: No longer rejects valid domain\user and UPN formats
    .PARAMETER UserNameObject
        The TextBox control containing the username
    .PARAMETER OutputObject
        The output TextBox for validation messages
    .PARAMETER Passthru
        Return validation result
    .OUTPUTS
        [bool] Validation result
    .EXAMPLE
        $valid = Confirm-PSDWizardOSDJoinAccount -UserNameObject $txtUser -Passthru
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TextBox]$UserNameObject,

        [Parameter(Mandatory=$false)]
        $OutputObject,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Trim any leading or trailing whitespace from the username
    $username = $UserNameObject.Text.Trim()
    $isValid = $false
    $message = ""

    # Validate the username using the domain account name rules
    if ([string]::IsNullOrWhiteSpace($username)) {
        $message = "Username cannot be empty"
        $isValid = $false
    }
    elseif (Test-PSDWizardDomainAccountName -AccountName $username) {
        $isValid = $true
        $message = "Valid domain join account"
    }
    else {
        # If the username is not valid, provide an appropriate error message
        $message = "Account contains a character not supported by Active Directory"
    }

    Write-PSDWizardLog -Message "Account validation: '$username' = $isValid" -Component $FunctionName

    # Update UI if output object provided
    if ($OutputObject) {
        # Update the output object's text and color based on validation result
        $OutputObject.Text = $message
        if ($isValid) {
            $OutputObject.Foreground = "Green"
        }
        else {
            $OutputObject.Foreground = "Red"
        }
    }

    # Return the validation result if the Passthru switch is specified
    if ($Passthru) {
        return $isValid
    }
}

Function Invoke-PSDWizardFieldValidation {
    <#
    .SYNOPSIS
        Unified validation handler for wizard input fields
    .DESCRIPTION
        Validates any wizard field based on its control name and updates validation UI
    .PARAMETER Window
        The WPF window containing the controls
    .PARAMETER ControlName
        Name of the control to validate
    .PARAMETER ValidationCanvasName
        Name of the validation output control
    .PARAMETER UpdateNextButton
        Whether to enable/disable the Next button based on validation result
    .OUTPUTS
        [bool] Validation result
    .EXAMPLE
        Invoke-PSDWizardFieldValidation -Window $wnd -ControlName 'TSEnv_OSDComputerName' -ValidationCanvasName '_detTabValidation_Name' -UpdateNextButton
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [string]$ControlName,

        [Parameter(Mandatory=$false)]
        [string]$ValidationCanvasName,

        [Parameter(Mandatory=$false)]
        [switch]$UpdateNextButton
    )

    $FunctionName = 'Invoke-PSDWizardFieldValidation'
    # Initialize validation result and message
    $isValid = $true
    $message = ""

    # Get the control
    $control = $Window.FindName($ControlName)
    if (-not $control) {
        Write-PSDWizardLog -Message "Control '$ControlName' not found" -LogLevel 2 -Component $FunctionName
        return $false
    }
    # Retrieve the current value of the control for validation
    $value = $control.Text.Trim()

    # Determine validation type based on control name
    # Determine the type of validation to perform based on the control name
    # Use a regular expression switch to select the appropriate validation logic
    switch -Regex ($ControlName) {
        'OSDComputerName' {
            if ([string]::IsNullOrWhiteSpace($value)) {
                # Empty is technically invalid, but don't block navigation (user might not have set it yet)
                $message = ""
                $isValid = $true
            }
            elseif ($value.Length -gt 15) {
                $message = "Cannot exceed 15 characters"
                $isValid = $false
            }
            elseif ($value -match '[^a-zA-Z0-9\-]') {
                $message = "Only letters, numbers, and hyphens allowed"
                $isValid = $false
            }
            elseif ($value -match '^-' -or $value -match '-$') {
                $message = "Cannot start or end with hyphen"
                $isValid = $false
            }
            else {
                $isValid = $true
                $message = "Valid computer name"
            }
        }

        'JoinDomain' {
            if ([string]::IsNullOrWhiteSpace($value)) {
                # Empty is valid - user might choose workgroup
                $isValid = $true
                $message = ""
            }
            else {
                # FQDN validation
                $fqdnRegex = '(?=^.{3,253}$)(^(((?!-)[a-zA-Z0-9-]{1,63}(?<!-))|((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63})$)'
                if ($value -notmatch $fqdnRegex) {
                    $message = "Invalid domain name format"
                    $isValid = $false
                }
                else {
                    $isValid = $true
                    $message = "Valid domain name"
                }
            }
        }

        'JoinWorkgroup' {
            if ([string]::IsNullOrWhiteSpace($value)) {
                # Empty is valid - user might choose domain
                $isValid = $true
                $message = ""
            }
            else {
                # Workgroup name validation rules
                if ($value.Length -gt 15) {
                    $message = "Cannot exceed 15 characters"
                    $isValid = $false
                }
                elseif ($value -match '[^a-zA-Z0-9\-_]') {
                    $message = "Only letters, numbers, hyphens, underscores allowed"
                    $isValid = $false
                }
                elseif ($value -match '^[-_]') {
                    $message = "Cannot start with - or _"
                    $isValid = $false
                }
                else {
                    $isValid = $true
                    $message = "Valid workgroup name"
                }
            }
        }

        'DomainAdmin|OSDAddAdmin' {
            # Validate domain admin or OSD add admin accounts
            if ([string]::IsNullOrWhiteSpace($value)) {
                # Empty is valid (might be optional)
                $isValid = $true
                $message = ""
            }
            else {
                # Semicolon-separated list for OSDAddAdmin
                $accounts = $value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                $allAccountsValid = $true
                $invalidAccount = ""

                # Iterate through each account and validate its format
                foreach ($account in $accounts) {
                    # Skip empty accounts (shouldn't happen due to previous filtering)
                    if (-not (Test-PSDWizardDomainAccountName -AccountName $account)) {
                        $allAccountsValid = $false
                        $invalidAccount = $account
                        break
                    }
                }

                # Determine the overall validation result based on individual account checks
                if ($allAccountsValid) {
                    $isValid = $true
                    if ($accounts.Count -gt 1) {
                        $message = "Valid accounts ($($accounts.Count))"
                    }
                    else {
                        $message = "Valid domain join account"
                    }
                }
                else {
                    # Handle the case where at least one account is invalid
                    $isValid = $false
                    $message = "Invalid account format: $invalidAccount"
                }
            }
        }

        'DomainAdminDomain' {
            if ([string]::IsNullOrWhiteSpace($value)) {
                # Empty shown as optional, but comprehensive validation will catch it
                $isValid = $true
                $message = ""
            }
            else {
                # FQDN validation for the domain admin domain
                # Regular expression for validating fully qualified domain names (FQDN)
                $fqdnRegex = '(?=^.{3,253}$)(^(((?!-)[a-zA-Z0-9-]{1,63}(?<!-))|((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63})$)'
                if ($value -notmatch $fqdnRegex) {
                    $message = "Invalid domain name format"
                    $isValid = $false
                }
                else {
                    $isValid = $true
                    $message = "Valid domain name"
                }
            }
        }

        default {
            Write-PSDWizardLog -Message "No validation rule for control '$ControlName'" -LogLevel 1 -Component $FunctionName
            return $true
        }
    }

    # Update validation canvas if provided
    if ($ValidationCanvasName) {
        # The ValidationCanvasName points to the TextBox (e.g., _detTabValidation_Name)
        # We need to also control the parent Canvas and the Alert/Check icons
        $validationTextBox = $Window.FindName($ValidationCanvasName)

        # Get parent canvas name by removing "_Name" suffix
        $parentCanvasName = $ValidationCanvasName -replace '_Name$', ''
        $parentCanvas = $Window.FindName($parentCanvasName)

        # Get alert and check icon names
        $alertIconName = $ValidationCanvasName -replace '_Name$', '_Alert'
        $checkIconName = $ValidationCanvasName -replace '_Name$', '_Check'
        $alertIcon = $Window.FindName($alertIconName)
        $checkIcon = $Window.FindName($checkIconName)

        if ([string]::IsNullOrWhiteSpace($message)) {
            # Hide entire validation canvas when no message
            if ($parentCanvas) {
                $parentCanvas.Visibility = "Hidden"
            }
            if ($validationTextBox) {
                $validationTextBox.Text = ""
            }
        }
        else {
            # Show validation with appropriate styling
            if ($parentCanvas) {
                $parentCanvas.Visibility = "Visible"
                $parentCanvas.Background = if ($isValid) { "LightGreen" } else { "LightPink" }
            }

            # Update the validation message and styling for the user interface
            if ($validationTextBox) {
                $validationTextBox.Text = $message
                $validationTextBox.Foreground = if ($isValid) { "Green" } else { "Red" }
            }

            # Show/hide alert and check icons based on validation state
            if ($alertIcon) {
                $alertIcon.Visibility = if ($isValid) { "Hidden" } else { "Visible" }
            }
            if ($checkIcon) {
                $checkIcon.Visibility = if ($isValid) { "Visible" } else { "Hidden" }
            }
        }
    }

    # Update Next button if requested
    if ($UpdateNextButton) {
        # Find the Next button in the window
        $btnNext = $Window.FindName('_wizNext')
        if ($btnNext) {
            # Log the action of updating the Next button's enabled state
            Write-PSDWizardLog -Message "Setting Next button IsEnabled = $isValid for '$ControlName'" -Component $FunctionName
            $btnNext.IsEnabled = $isValid

            # Also manage tab navigation - disable future tabs when Next is disabled
            $tabControl = $Window.FindName('_wizTabControl')
            if ($tabControl) {
                $currentTabIndex = $tabControl.SelectedIndex

                if (-not $isValid) {
                    # Validation failed - disable all tabs after current one
                    # This prevents users from clicking ahead when validation fails
                    for ($i = $currentTabIndex + 1; $i -lt $tabControl.Items.Count; $i++) {
                        # Only disable if not already visited
                        if ($script:VisitedTabs -and $i -notin $script:VisitedTabs) {
                            $tabControl.Items[$i].IsEnabled = $false
                        }
                    }
                    Write-PSDWizardLog -Message "Disabled forward tabs (validation failed)" -Component $FunctionName
                }
                else {
                    # Validation passed - enable next tab
                    if ($currentTabIndex + 1 -lt $tabControl.Items.Count) {
                        $tabControl.Items[$currentTabIndex + 1].IsEnabled = $true
                    }
                }
            }
        }
        else {
            Write-PSDWizardLog -Message "Next button '_wizNext' not found in window" -LogLevel 2 -Component $FunctionName
        }
    }
    else {
        Write-PSDWizardLog -Message "UpdateNextButton not requested for '$ControlName'" -Component $FunctionName
    }

    Write-PSDWizardLog -Message "Validated '$ControlName' = $isValid ($message)" -Component $FunctionName
    return $isValid
}

Function Confirm-PSDWizardComputerName {
    <#
    .SYNOPSIS
        Validates computer name (legacy wrapper - use Invoke-PSDWizardFieldValidation)
    .DESCRIPTION
        Validates computer name against Windows naming rules with improved regex
    .PARAMETER ComputerNameObject
        The TextBox control containing the computer name
    .PARAMETER OutputObject
        The output TextBox for validation messages
    .PARAMETER Passthru
        Return validation result
    .OUTPUTS
        [bool] Validation result
    .EXAMPLE
        $valid = Confirm-PSDWizardComputerName -ComputerNameObject $txtComputer -Passthru
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TextBox]$ComputerNameObject,

        [Parameter(Mandatory=$false)]
        $OutputObject,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Retrieve and trim the computer name from the TextBox control
    $computerName = $ComputerNameObject.Text.Trim()
    $isValid = $false
    $message = ""

    # Initialize validation state and message
    # Perform validation checks on the computer name
    if ([string]::IsNullOrWhiteSpace($computerName)) {
        $message = "Computer name cannot be empty"
        $isValid = $false
    }
    elseif ($computerName.Length -gt 15) {
        $message = "Computer name cannot exceed 15 characters"
        $isValid = $false
    }
    elseif ($computerName -match '[^a-zA-Z0-9\-]') {
        $message = "Computer name can only contain letters, numbers, and hyphens"
        $isValid = $false
    }
    elseif ($computerName -match '^-' -or $computerName -match '-$') {
        $message = "Computer name cannot start or end with a hyphen"
        $isValid = $false
    }
    else {
        $isValid = $true
        $message = "Valid computer name"
    }

    Write-PSDWizardLog -Message "Computer name validation: '$computerName' = $isValid" -Component $FunctionName

    if ($OutputObject) {
        # OutputObject is the TextBox (e.g., _detTabValidation_Name)
        # Need to also control parent Canvas
        $wnd = [System.Windows.Window]::GetWindow($OutputObject)
        if ($wnd -and $OutputObject.Name) {
            # Determine the parent Canvas name by removing the '_Name' suffix from the TextBox name
            $parentCanvasName = $OutputObject.Name -replace '_Name$', ''
            $parentCanvas = $wnd.FindName($parentCanvasName)
            # Find the parent Canvas control in the window by its name
            $alertIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Alert')
            $checkIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Check')

            # Update the parent Canvas visibility and background color based on the validation result
            if ($parentCanvas) {
                $parentCanvas.Visibility = "Visible"
                $parentCanvas.Background = if ($isValid) { "LightGreen" } else { "LightPink" }
            }
            # Update the TextBox with the validation message and color based on the validation result
            $OutputObject.Text = $message
            $OutputObject.Foreground = if ($isValid) { "Green" } else { "Red" }
            # Update the alert and check icons based on the validation result
            if ($alertIcon) { $alertIcon.Visibility = if ($isValid) { "Hidden" } else { "Visible" } }
            if ($checkIcon) { $checkIcon.Visibility = if ($isValid) { "Visible" } else { "Hidden" } }
        }
    }

    if ($Passthru) {
        return $isValid
    }
}

Function Confirm-PSDWizardFQDN {
    <#
    .SYNOPSIS
        Validates domain name (FQDN)
    .DESCRIPTION
        Validates domain name against FQDN naming rules
    .PARAMETER DomainNameObject
        The TextBox control containing the domain name
    .PARAMETER OutputObject
        The output TextBox for validation messages
    .PARAMETER Passthru
        Return validation result
    .OUTPUTS
        [bool] Validation result
    .EXAMPLE
        $valid = Confirm-PSDWizardFQDN -DomainNameObject $txtDomain -Passthru
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TextBox]$DomainNameObject,

        [Parameter(Mandatory=$false)]
        $OutputObject,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    # Retrieve and trim the domain name from the TextBox control
    $domainName = $DomainNameObject.Text.Trim()
    # Initialize validation state and message
    $isValid = $false
    $message = ""

    # FQDN regex: allows domain.com, sub.domain.com, etc.
    # Must be 3-253 characters, each label 1-63 chars
    # This regex will be used to validate the domain name format
    $fqdnRegex = '(?=^.{3,253}$)(^(((?!-)[a-zA-Z0-9-]{1,63}(?<!-))|((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63})$)'

    if ([string]::IsNullOrWhiteSpace($domainName)) {
        $message = "Domain name cannot be empty"
        $isValid = $false
    }
    elseif ($domainName -notmatch $fqdnRegex) {
        $message = "Invalid domain name (e.g., contoso.com)"
        $isValid = $false
    }
    else {
        $isValid = $true
        $message = "Valid domain name"
    }

    Write-PSDWizardLog -Message "Domain name validation: '$domainName' = $isValid" -Component $FunctionName

    if ($OutputObject) {
        # Update the output TextBox and related UI elements with the validation result
        $wnd = [System.Windows.Window]::GetWindow($OutputObject)
        if ($wnd -and $OutputObject.Name) {
            # Determine the parent Canvas and associated alert/check icons based on the output TextBox name
            $parentCanvasName = $OutputObject.Name -replace '_Name$', ''
            $parentCanvas = $wnd.FindName($parentCanvasName)
            $alertIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Alert')
            $checkIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Check')

            # Update the parent Canvas visibility and background color based on the validation result
            if ($parentCanvas) {
                $parentCanvas.Visibility = "Visible"
                $parentCanvas.Background = if ($isValid) { "LightGreen" } else { "LightPink" }
            }

            # Update the output TextBox with the validation message and color based on the validation result
            $OutputObject.Text = $message
            $OutputObject.Foreground = if ($isValid) { "Green" } else { "Red" }

            # Update the alert and check icons based on the validation result
            if ($alertIcon) { $alertIcon.Visibility = if ($isValid) { "Hidden" } else { "Visible" } }
            if ($checkIcon) { $checkIcon.Visibility = if ($isValid) { "Visible" } else { "Hidden" } }
        }
    }

    if ($Passthru) {
        return $isValid
    }
}

Function Confirm-PSDWizardWorkgroup {
    <#
    .SYNOPSIS
        Validates workgroup name
    .DESCRIPTION
        Validates workgroup name against Windows naming rules
    .PARAMETER WorkgroupNameObject
        The TextBox control containing the workgroup name
    .PARAMETER OutputObject
        The output TextBox for validation messages
    .PARAMETER Passthru
        Return validation result
    .OUTPUTS
        [bool] Validation result
    .EXAMPLE
        $valid = Confirm-PSDWizardWorkgroup -WorkgroupNameObject $txtWorkgroup -Passthru
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TextBox]$WorkgroupNameObject,

        [Parameter(Mandatory=$false)]
        $OutputObject,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    # Retrieve and trim the workgroup name from the TextBox control
    $workgroupName = $WorkgroupNameObject.Text.Trim()
    # Initialize validation state and message
    $isValid = $false
    $message = ""

    # Perform validation checks on the workgroup name
    # Check if the workgroup name is empty, exceeds length limits, contains invalid characters, or starts with prohibited characters
    if ([string]::IsNullOrWhiteSpace($workgroupName)) {
        $message = "Workgroup name cannot be empty"
        $isValid = $false
    }
    elseif ($workgroupName.Length -gt 15) {
        $message = "Workgroup name cannot exceed 15 characters"
        $isValid = $false
    }
    elseif ($workgroupName -match '[^a-zA-Z0-9\-_]') {
        $invalidChar = $Matches[0]
        $message = "Invalid character: [$invalidChar]"
        $isValid = $false
    }
    elseif ($workgroupName -match '^[-_]') {
        $message = "Workgroup name cannot start with - or _"
        $isValid = $false
    }
    else {
        $isValid = $true
        $message = "Valid workgroup name"
    }

    # Log the validation result for debugging purposes
    Write-PSDWizardLog -Message "Workgroup name validation: '$workgroupName' = $isValid" -Component $FunctionName

    if ($OutputObject) {
        # Update the output TextBox and related UI elements with the validation result
        $wnd = [System.Windows.Window]::GetWindow($OutputObject)
        if ($wnd -and $OutputObject.Name) {
            # Determine the parent Canvas and associated alert/check icons based on the output TextBox name
            $parentCanvasName = $OutputObject.Name -replace '_Name$', ''
            $parentCanvas = $wnd.FindName($parentCanvasName)
            # Find the alert and check icons associated with the output TextBox
            $alertIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Alert')
            $checkIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Check')

            # Update the parent Canvas visibility and background color based on the validation result
            if ($parentCanvas) {
                $parentCanvas.Visibility = "Visible"
                $parentCanvas.Background = if ($isValid) { "LightGreen" } else { "LightPink" }
            }

            # Update the output TextBox with the validation message and color based on the validation result
            $OutputObject.Text = $message
            $OutputObject.Foreground = if ($isValid) { "Green" } else { "Red" }

            # Update the alert and check icons based on the validation result
            if ($alertIcon) { $alertIcon.Visibility = if ($isValid) { "Hidden" } else { "Visible" } }
            if ($checkIcon) { $checkIcon.Visibility = if ($isValid) { "Visible" } else { "Hidden" } }
        }
    }

    if ($Passthru) {
        return $isValid
    }
}

Function Confirm-PSDWizardUserName {
    <#
    .SYNOPSIS
        Validates user name
    .DESCRIPTION
        Validates a domain join account user name
    .PARAMETER UserNameObject
        The TextBox control containing the user name
    .PARAMETER OutputObject
        The output TextBox for validation messages
    .PARAMETER Passthru
        Return validation result
    .OUTPUTS
        [bool] Validation result
    .EXAMPLE
        $valid = Confirm-PSDWizardUserName -UserNameObject $txtUser -Passthru
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TextBox]$UserNameObject,

        [Parameter(Mandatory=$false)]
        $OutputObject,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    # Retrieve and trim the user name from the TextBox control
    # Initialize validation state and message
    $userName = $UserNameObject.Text.Trim()
    $isValid = $false
    $message = ""

    # Perform validation checks on the user name
    if ([string]::IsNullOrWhiteSpace($userName)) {
        $message = "User name cannot be empty"
        $isValid = $false
    }
    elseif (Test-PSDWizardDomainAccountName -AccountName $userName) {
        $isValid = $true
        $message = "Valid domain join account"
    }
    else {
        $message = "Account contains a character not supported by Active Directory"
        $isValid = $false
    }

    Write-PSDWizardLog -Message "User name validation: '$userName' = $isValid" -Component $FunctionName

    if ($OutputObject) {
        # Update the output TextBox and related UI elements with the validation result
        # Determine the parent Canvas and associated alert/check icons based on the output TextBox name
        # Find the alert and check icons associated with the output TextBox
        # Update the parent Canvas visibility and background color based on the validation result
        # Update the output TextBox with the validation message and color based on the validation result
        # Update the alert and check icons based on the validation result
        $wnd = [System.Windows.Window]::GetWindow($OutputObject)
        if ($wnd -and $OutputObject.Name) {
            # Determine the parent Canvas and associated alert/check icons based on the output TextBox name
            $parentCanvasName = $OutputObject.Name -replace '_Name$', ''
            $parentCanvas = $wnd.FindName($parentCanvasName)
            # Find the alert and check icons associated with the output TextBox
            $alertIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Alert')
            $checkIcon = $wnd.FindName($OutputObject.Name -replace '_Name$', '_Check')

            # Update the parent Canvas visibility and background color based on the validation result
            if ($parentCanvas) {
                # Make the parent Canvas visible before setting its background color
                $parentCanvas.Visibility = "Visible"
                $parentCanvas.Background = if ($isValid) { "LightGreen" } else { "LightPink" }
            }

            # Update the output TextBox with the validation message and color based on the validation result
            $OutputObject.Text = $message
            $OutputObject.Foreground = if ($isValid) { "Green" } else { "Red" }

            # Update the alert and check icons based on the validation result
            if ($alertIcon) { $alertIcon.Visibility = if ($isValid) { "Hidden" } else { "Visible" } }
            if ($checkIcon) { $checkIcon.Visibility = if ($isValid) { "Visible" } else { "Hidden" } }
        }
    }

    if ($Passthru) {
        return $isValid
    }
}

Function Get-PSDWizardTSOSGUID {
    <#
    .SYNOPSIS
        Get the OSGUID from a Task Sequence
    .DESCRIPTION
        Reads the TS.xml file and extracts the OSGUID from the BDD_InstallOS step
    .PARAMETER TaskSequenceID
        The Task Sequence ID
    .PARAMETER ControlPath
        The control folder path (default: from SyncHash)
    .OUTPUTS
        [string] The OSGUID if found, $null otherwise
    .EXAMPLE
        $osGuid = Get-PSDWizardTSOSGUID -TaskSequenceID 'WIN11-001'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$TaskSequenceID,

        [Parameter(Mandatory=$false)]
        [string]$ControlPath
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    try {
        # Get control path from SyncHash if not specified
        if ([string]::IsNullOrWhiteSpace($ControlPath)) {
            # Attempt to retrieve the ControlPath from the global SyncHash if not explicitly provided
            if ($script:PSDWizardSyncHash -and $script:PSDWizardSyncHash.ControlPath) {
                $ControlPath = $script:PSDWizardSyncHash.ControlPath
            }
            else {
                Write-PSDWizardLog -Message "No ControlPath specified and no SyncHash available" -LogLevel 2 -Component $FunctionName
                return $null
            }
        }

        # Build path to TS.xml
        $tsXmlPath = Join-Path $ControlPath "$TaskSequenceID\TS.xml"

        # Log the path to the TS.xml for debugging purposes
        if (-not (Test-Path $tsXmlPath)) {
            Write-PSDWizardLog -Message "TS.xml not found: $tsXmlPath" -LogLevel 1 -Component $FunctionName
            return $null
        }

        # Load and parse the TS.xml
        [xml]$tsXml = Get-Content $tsXmlPath -Encoding UTF8

        # Find the BDD_InstallOS step and extract OSGUID
        # Attempt to locate the BDD_InstallOS step within the Task Sequence XML
        $installOSStep = $tsXml.sequence.group.step | Where-Object { $_.Type -eq 'BDD_InstallOS' } | Select-Object -First 1

        # Log the retrieved BDD_InstallOS step for debugging purposes
        # Ensure that the BDD_InstallOS step and its default variable list are available before attempting to extract OSGUID
        if ($installOSStep -and $installOSStep.defaultVarList -and $installOSStep.defaultVarList.variable) {
            $osGuidVar = $installOSStep.defaultVarList.variable | Where-Object { $_.Name -eq 'OSGUID' } | Select-Object -First 1
            # If the OSGUID variable is found, extract its value and log it
            if ($osGuidVar) {
                $osGuid = $osGuidVar.'#text'
                Write-PSDWizardLog -Message "Found OSGUID for TS '$TaskSequenceID': $osGuid" -Component $FunctionName
                return $osGuid
            }
        }

        Write-PSDWizardLog -Message "No OSGUID found in TS '$TaskSequenceID'" -LogLevel 1 -Component $FunctionName
        return $null
    }
    catch {
        Write-PSDWizardLog -Message "Error reading TS.xml for '$TaskSequenceID': $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        return $null
    }
}

Function Update-PSDWizardPageVisibility {
    <#
    .SYNOPSIS
        Applies definition-driven visibility to generated wizard panes.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    # Initialize counters for visible, collapsed, and missing panes
    $visibleCount = 0
    $collapsedCount = 0
    $missingCount = 0
    Write-PSDWizardLog -Message "Evaluating visibility for $(@($SyncHash.DynamicPaneConditions.Keys).Count) dynamic panes; TaskSequenceID='$($SyncHash.TSEnvSettings['TaskSequenceID'])'" -Component $FunctionName
    # Iterate through each dynamic pane and evaluate its visibility based on the defined conditions
    foreach ($paneId in $SyncHash.DynamicPaneConditions.Keys) {
        $page = $Window.FindName("_wiz$paneId")
        # If the page is not found, increment the missing count and continue to the next pane
        if (-not $page) {
            $missingCount++
            continue
        }
        # Evaluate each condition for the current pane to determine its visibility
        $showPage = $true
        # Iterate through each condition for the current pane
        foreach ($condition in $SyncHash.DynamicPaneConditions[$paneId]) {
            if (-not (Get-PSDWizardCondition -Condition $condition -TSEnvSettings $SyncHash.TSEnvSettings)) {
                $showPage = $false
                break
            }
        }
        # Set the visibility of the page based on the evaluation of its conditions
        $page.Visibility = if ($showPage) { 'Visible' } else { 'Collapsed' }
        # Increment the appropriate counter based on the visibility of the page
        if ($showPage) { $visibleCount++ } else { $collapsedCount++ }
        Write-PSDWizardLog -Message "Pane '$paneId' visibility=$($page.Visibility)" -Component $FunctionName
    }

    $tabControl = $Window.FindName('_wizTabControl')
    if ($tabControl) {
        Update-PSDWizardNavigationState -Window $Window -TabControl $tabControl
    }
    Write-PSDWizardLog -Message "Visibility evaluation complete: visible=$visibleCount, collapsed=$collapsedCount, missing=$missingCount" -Component $FunctionName
}

Function Update-PSDWizardDependentControlSelections {
    <#
    .SYNOPSIS
        Restores dependent control selections after Task Sequence rules change.
    .DESCRIPTION
        This function iterates through the Task Sequence environment lists and updates the corresponding control selections
        in the wizard window based on the saved settings in the $SyncHash.TSEnvSettings hashtable.
    .PARAMETER Window
        The wizard window containing the controls to be updated.
    .PARAMETER SyncHash
        The hashtable containing the Task Sequence environment settings and lists.
    .EXAMPLE
        Update-PSDWizardDependentControlSelections -Window $wizardWindow -SyncHash $syncHash
        This example updates the dependent control selections in the specified wizard window based on the provided Task Sequence environment settings.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    if (-not $SyncHash.TSEnvSettings) {
        Write-PSDWizardLog -Message "Dependent-control synchronization skipped: TSEnvSettings unavailable" -LogLevel 2 -Component $FunctionName
        return
    }
    # Initialize counters for list matches, locale matches, time zone matches, and disk match status
    $listMatches = 0
    $localeMatches = 0
    $timeZoneMatches = 0
    $diskMatched = $false

    # Iterate through each Task Sequence environment list and update the corresponding control selection based on the saved settings.
    foreach ($listName in @($SyncHash.TSEnvLists.Keys)) {
        $control = Get-PSDWizardListControl -Window $Window -SyncHash $SyncHash -ListName $listName
        $value = [string]$SyncHash.TSEnvSettings[$listName]
        if ($control -and $control.PSObject.Properties['SelectedItem'] -and -not [string]::IsNullOrWhiteSpace($value)) {
            $matchingItem = @($control.Items | Where-Object { $_.ToString() -eq $value }) | Select-Object -First 1
            if ($matchingItem) { $control.SelectedItem = $matchingItem; $listMatches++ }
        }
    }

    # Restore the selections for all Task Sequence environment lists based on the saved settings.
    # not automatically handled by the previous loop, so we handle locale-specific controls separately.
    $localeMappings = @(
        @{ Names = @('_locTabSystemLocale'); Property = 'SystemLocale' }
        @{ Names = @('_locTabKeyboardLocale'); Property = 'KeyboardLocale' }
        @{ Names = @('_locTabLanguage'); Property = 'UILanguage' }
    )
    # Iterate through each locale mapping and update the corresponding control selection based on the saved settings.
    foreach ($mapping in $localeMappings) {
        $control = $mapping.Names | ForEach-Object { $Window.FindName($_) } | Where-Object { $_ } | Select-Object -First 1
        $value = [string]$SyncHash.TSEnvSettings[$mapping.Property]
        if (-not $control -or [string]::IsNullOrWhiteSpace($value)) { continue }
        # Find the matching item in the control's items based on the property type and the saved value.
        $matchingItem = if ($mapping.Property -eq 'KeyboardLocale') {
            @($control.Items | Where-Object { $_.KeyboardLayout -ieq $value -or $_.Culture -ieq $value -or $_.Name -ieq $value -or $_.ID -ieq $value -or $_.KeyboardID -ieq $value }) | Select-Object -First 1
        }
        else {
            # Find the matching item in the control's items based on the saved value for non-keyboard locale properties.
            @($control.Items | Where-Object { $_.Culture -ieq $value -or $_.Name -ieq $value -or $_.Language -ieq $value }) | Select-Object -First 1
        }
        if ($matchingItem) { $control.SelectedItem = $matchingItem; $localeMatches++ }
    }

    # Set the time zone controls based on the TimeZoneName and TimeZone settings.
    foreach ($propertyName in @('TimeZoneName', 'TimeZone')) {
        $controlName = if ($propertyName -eq 'TimeZoneName') { '_locTabTimeZoneName' } else { '_locTabTimeZone' }
        $control = $Window.FindName($controlName)
        $value = [string]$SyncHash.TSEnvSettings[$propertyName]
        # Skip this iteration if the control is not found or the value is null or whitespace.
        if ($control -and -not [string]::IsNullOrWhiteSpace($value)) {
            $matchingItem = @($control.Items | Where-Object { $_.TimeZone -ieq $value -or $_.DisplayName -ieq $value -or $_.Name -ieq $value }) | Select-Object -First 1
            if ($matchingItem) { $control.SelectedItem = $matchingItem; $timeZoneMatches++ }
        }
    }

    # Set the target disk control and value based on the OSDDiskIndex setting.
    $targetDisk = $Window.FindName('_cmbTargetDisk')
    $diskValue = [string]$SyncHash.TSEnvSettings['OSDDiskIndex']
    # Set the target disk based on the OSDDiskIndex setting.
    if ($targetDisk -and -not [string]::IsNullOrWhiteSpace($diskValue)) {
        $diskIndex = 0
        # Initialize the disk index to 0 before attempting to parse the disk value.
        if ([int]::TryParse($diskValue, [ref]$diskIndex)) {
            $matchingDisk = @($targetDisk.Items | Where-Object { [int]$_ -eq $diskIndex }) | Select-Object -First 1
            if ($null -ne $matchingDisk) { $targetDisk.SelectedItem = $matchingDisk; $diskMatched = $true }
        }
    }
    Write-PSDWizardLog -Message "Dependent-control synchronization complete: lists=$listMatches, locales=$localeMatches, timezones=$timeZoneMatches, disk=$diskMatched" -Component $FunctionName
}

Function Get-PSDWizardTSRoleStep {
    <#
    .SYNOPSIS
        Reads the Install Roles and Features step of a task sequence.
    .DESCRIPTION
        Task sequences that carry their own Install Roles and Features step (BDD_InstallRoles) keep the catalog ID and the lists in the
        step's variables. The wizard reads them so it can use the same catalog and show those items as already selected.
    .PARAMETER TaskSequenceID
        The Task Sequence ID
    .PARAMETER ControlPath
        The control folder path
    .OUTPUTS
        [pscustomobject] with OSRoleIndex, OSRoles, OSRoleServices and OSFeatures (empty when the task sequence has no enabled step)
    .EXAMPLE
        $step = Get-PSDWizardTSRoleStep -TaskSequenceID 'SVR22STD_PSD' -ControlPath 'E:\PSD-Forked\Control'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$TaskSequenceID,

        [Parameter(Mandatory=$true)]
        [string]$ControlPath
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    $result = [pscustomobject]@{ OSRoleIndex = ''; OSRoles = @(); OSRoleServices = @(); OSFeatures = @() }
    $tsXmlPath = Join-Path $ControlPath "$TaskSequenceID\TS.xml"
    if (-not (Test-Path -LiteralPath $tsXmlPath)) { return $result }

    try {
        [xml]$tsXml = Get-Content -LiteralPath $tsXmlPath -Encoding UTF8
        $steps = @($tsXml.SelectNodes('//step[@type="BDD_InstallRoles"]') | Where-Object { $_.GetAttribute('disable') -ne 'true' })
        foreach ($step in $steps) {
            foreach ($variable in @($step.SelectNodes('./defaultVarList/variable'))) {
                $name = $variable.GetAttribute('name')
                $value = [string]$variable.InnerText
                if ($name -eq 'OSRoleIndex') {
                    if (-not $result.OSRoleIndex -and $value.Trim()) { $result.OSRoleIndex = $value.Trim() }
                }
                elseif ($name -in 'OSRoles', 'OSRoleServices', 'OSFeatures') {
                    $result.$name = @($result.$name) + @($value -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
            }
        }
        if ($steps.Count -gt 0) {
            Write-PSDWizardLog -Message "Task sequence '$TaskSequenceID' has $($steps.Count) Install Roles and Features step(s): OSRoleIndex='$($result.OSRoleIndex)', roles=$(@($result.OSRoles).Count), role services=$(@($result.OSRoleServices).Count), features=$(@($result.OSFeatures).Count)" -Component $FunctionName
        }
    }
    catch {
        Write-PSDWizardLog -Message "Unable to read the Install Roles and Features step of '$TaskSequenceID': $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
    return $result
}

Function Get-PSDWizardRoleContext {
    <#
    .SYNOPSIS
        Works out what kind of operating system a task sequence installs, to pick its role and feature catalog.
    .DESCRIPTION
        Windows 11 and Windows Server share build numbers, so the build alone cannot tell the catalogs apart. This looks at, in order:
          1. OSRoleIndex (TSEnv or the task sequence's Install Roles and Features step): the catalog ID to use as is.
          2. The operating system the task sequence installs (OperatingSystems.xml): Flags (Server*), name and image name for server or
             client, the image name for Server Core, and the Build for the version.
          3. The task sequence template (PSDServer.xml or PSDClient.xml) when the operating system is not in OperatingSystems.xml.
    .PARAMETER SyncHash
        The wizard hashtable with TaskSequences, OperatingSystems, ControlPath and TSEnvSettings.
    .PARAMETER TaskSequenceID
        The selected Task Sequence ID.
    .OUTPUTS
        [pscustomobject] with IsServer ($null when it cannot be told), IsCore, Build (0 when unknown), OSRoleIndex, OperatingSystem, Reason and TaskSequenceStep
    .EXAMPLE
        $context = Get-PSDWizardRoleContext -SyncHash $syncHash -TaskSequenceID 'SVR22STD_PSD'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$true)]
        [string]$TaskSequenceID
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    $reasons = New-Object System.Collections.Generic.List[string]
    $step = Get-PSDWizardTSRoleStep -TaskSequenceID $TaskSequenceID -ControlPath $SyncHash.ControlPath

    # The operating system of the task sequence; hidden operating systems are not in the wizard list, so read the file for those
    $osGuid = Get-PSDWizardTSOSGUID -TaskSequenceID $TaskSequenceID -ControlPath $SyncHash.ControlPath
    $os = $null
    if ($osGuid) {
        $os = @($SyncHash.OperatingSystems | Where-Object { ([string]$_.guid).Trim('{}') -eq ([string]$osGuid).Trim('{}') }) | Select-Object -First 1
        $osXml = Join-Path $SyncHash.ControlPath 'OperatingSystems.xml'
        if (-not $os -and (Test-Path -LiteralPath $osXml)) {
            [xml]$osDoc = Get-Content -LiteralPath $osXml -Encoding UTF8
            $os = @($osDoc.oss.os | Where-Object { ([string]$_.guid).Trim('{}') -eq ([string]$osGuid).Trim('{}') }) | Select-Object -First 1
        }
    }
    $ts = @($SyncHash.TaskSequences | Where-Object { $_.ID -eq $TaskSequenceID }) | Select-Object -First 1
    $template = [string]$ts.TaskSequenceTemplate

    $osText = if ($os) { @([string]$os.Name, [string]$os.Description, [string]$os.ImageName) -join ' ' } else { '' }
    $flags = if ($os) { [string]$os.Flags } else { '' }

    # Build: the third part of 10.0.20348.3091, else the version in the name
    $build = 0
    if ($os -and ([string]$os.Build) -match '^\d+\.\d+\.(\d+)') { $build = [int]$Matches[1] }
    if ($build -le 0 -and $osText) {
        $build = switch -Regex ($osText) {
            'Server\s*2025' { 26100; break }
            'Server\s*2022' { 20348; break }
            'Server\s*2019' { 17763; break }
            'Windows\s*11'  { 22000; break }
            default { 0 }
        }
        if ($build -gt 0) { $reasons.Add("build $build taken from the operating system name") }
    }
    elseif ($build -gt 0) { $reasons.Add("build $build from OperatingSystems.xml") }

    # Server or client: the operating system's flags and name first, the task sequence template when there is no operating system
    $isServer = $null
    if ($os) {
        if ($flags -match '^Server' -or $osText -match 'Windows\s+Server') { $isServer = $true; $reasons.Add("operating system '$($os.Name)' is a server (flags '$flags')") }
        elseif ($flags -or $osText -match 'Windows\s*(\d|Vista|XP)') { $isServer = $false; $reasons.Add("operating system '$($os.Name)' is a client (flags '$flags')") }
    }
    if ($template) {
        $templateServer = if ($template -match 'Server') { $true } elseif ($template -match 'Client') { $false } else { $null }
        if ($null -eq $isServer -and $null -ne $templateServer) { $isServer = $templateServer; $reasons.Add("task sequence template '$template'") }
        elseif ($null -ne $templateServer -and $templateServer -ne $isServer) {
            Write-PSDWizardLog -Message "Task sequence template '$template' and operating system '$($os.Name)' disagree on server or client; using the operating system" -LogLevel 2 -Component $FunctionName
        }
    }

    # Server Core: raw image names say CORE. Official media since Server 2016 name the Core image plainly ("Windows Server 2022 Standard") and label
    # the other "(Desktop Experience)". Any other name, such as a custom image, is taken to have the desktop experience.
    $isCore = $false
    if ($isServer -and $os) {
        $imageText = @([string]$os.ImageName, [string]$os.Name, [string]$os.Description) -join ' '
        if ($imageText -match 'Desktop Experience') { $isCore = $false }
        elseif ($imageText -match 'CORE') { $isCore = $true }
        elseif (([string]$os.ImageName) -cmatch 'SERVER(STANDARD|DATACENTER|ENTERPRISE|WEB|SOLUTION)\b') { $isCore = $false }
        elseif ($build -ge 14393 -and ([string]$os.ImageName).Trim() -match '^Windows Server \d{4}( R2)? (Standard|Datacenter)( Evaluation)?$') { $isCore = $true }
        $reasons.Add($(if ($isCore) { 'image is Server Core' } else { 'image has the desktop experience' }))
    }

    # OSRoleIndex wins when it is set: the same value the Deployment Workbench writes into the step
    $roleIndex = [string]$SyncHash.TSEnvSettings['OSRoleIndex']
    if ([string]::IsNullOrWhiteSpace($roleIndex)) { $roleIndex = [string]$step.OSRoleIndex }
    if (-not [string]::IsNullOrWhiteSpace($roleIndex)) { $reasons.Insert(0, "OSRoleIndex $roleIndex is set") }

    [pscustomobject]@{
        TaskSequenceID   = $TaskSequenceID
        OperatingSystem  = if ($os) { [string]$os.Name } else { '' }
        Build            = $build
        IsServer         = $isServer
        IsCore           = $isCore
        OSRoleIndex      = $roleIndex.Trim()
        Reason           = $reasons -join '; '
        TaskSequenceStep = $step
    }
}

Function Select-PSDWizardRoleCatalog {
    <#
    .SYNOPSIS
        Picks the <Roles> entry of ServerManager.xml that matches an operating system.
    .DESCRIPTION
        The file is the native MDT ServerManager.xml. Every <Roles> element is one operating system; PSD adds MinBuild and MaxBuild to them.
        With an OSRoleIndex the entry with that ID is used (as ZTIOSRole.wsf does). Without one the entries are filtered by Server and Core,
        and the one with the highest MinBuild at or below the build wins, so a build newer than every entry (a new Windows 11 or Windows Server
        release) uses the newest catalog until a newer entry is added. Entries without MinBuild are only used through an OSRoleIndex.
    .PARAMETER Catalog
        The loaded ServerManager.xml
    .PARAMETER Context
        The result of Get-PSDWizardRoleContext
    .OUTPUTS
        [pscustomobject] with Node and Reason, or $null when nothing matches
    .EXAMPLE
        $selection = Select-PSDWizardRoleCatalog -Catalog $catalog -Context $context
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    Param(
        [Parameter(Mandatory=$true)]
        [xml]$Catalog,

        [Parameter(Mandatory=$true)]
        $Context
    )

    $roleIndex = 0
    if ($Context.OSRoleIndex) {
        if ([int]::TryParse($Context.OSRoleIndex, [ref]$roleIndex)) {
            $node = $Catalog.SelectSingleNode("/OSRoles/Roles[@ID='$roleIndex']")
            if ($node) { return [pscustomobject]@{ Node = $node; Reason = "OSRoleIndex $roleIndex" } }
        }
        Write-PSDWizardLog -Message "OSRoleIndex '$($Context.OSRoleIndex)' is not in the role catalog; choosing by operating system" -LogLevel 2 -Component 'Select-PSDWizardRoleCatalog'
    }
    if ($null -eq $Context.IsServer) { return $null }

    $build = if ($Context.Build -gt 0) { [int]$Context.Build } else { [int]::MaxValue }
    $server = if ($Context.IsServer) { 'yes' } else { 'no' }
    $candidates = @($Catalog.OSRoles.Roles | Where-Object { $_.Server -eq $server -and $_.MinBuild })
    $coreChoices = @(if ($Context.IsServer -and $Context.IsCore) { 'yes' }; 'no')

    foreach ($core in $coreChoices) {
        $sameKind = @($candidates | Where-Object { $_.Core -eq $core })
        $match = @($sameKind | Where-Object { [int]$_.MinBuild -le $build -and (-not $_.MaxBuild -or $build -le [int]$_.MaxBuild) } | Sort-Object { [int]$_.MinBuild } -Descending) | Select-Object -First 1
        $how = "build $($Context.Build) is in MinBuild $($match.MinBuild) - MaxBuild $($match.MaxBuild)"
        if (-not $match) {
            $match = @($sameKind | Where-Object { [int]$_.MinBuild -le $build } | Sort-Object { [int]$_.MinBuild } -Descending) | Select-Object -First 1
            $how = "build $($Context.Build) is newer than the catalogs, using the newest (MinBuild $($match.MinBuild))"
        }
        if ($match) {
            if ($Context.IsCore -and $core -eq 'no') { $how += '; no Server Core catalog, using the desktop experience one' }
            return [pscustomobject]@{ Node = $match; Reason = $how }
        }
    }
    return $null
}

Function Get-PSDWizardRoleDescendant {
    <#
    .SYNOPSIS
        Returns every entry below a role tree entry.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        $Entry
    )
    foreach ($child in $Entry.Children) {
        $child
        Get-PSDWizardRoleDescendant -Entry $child
    }
}

Function Update-PSDWizardRoleEntryState {
    <#
    .SYNOPSIS
        Sets a role tree entry's check box from its children: checked when all are, unchecked when none are, otherwise indeterminate.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        $Entry
    )
    if ($Entry.Children.Count -eq 0) { return }
    # An item the task sequence already installs stays checked whatever its children are
    if ($Entry.Locked) { $Entry.CheckBox.IsChecked = $true; return }
    $checked = @($Entry.Children | Where-Object { $_.CheckBox.IsChecked -eq $true }).Count
    $unchecked = @($Entry.Children | Where-Object { $_.CheckBox.IsChecked -eq $false }).Count
    $Entry.CheckBox.IsChecked = if ($checked -eq $Entry.Children.Count) { $true } elseif ($unchecked -eq $Entry.Children.Count) { $false } else { $null }
}

Function Write-PSDWizardRoleSelection {
    <#
    .SYNOPSIS
        Writes the checked roles, role services and features to OptionalOSRoles, OptionalOSRoleServices and OptionalOSFeatures.
    .DESCRIPTION
        Every checked item is written, so a role that was selected with all of its role services lists them all and unchecking one of them
        leaves it out. A partly checked role is not written itself: installing a role service brings the role it needs, and the role on its
        own would bring its default role services back. Items the task sequence already installs (locked) are left to the task sequence.
    .PARAMETER State
        The role tree state ($script:PSDWizardRoleState)
    .EXAMPLE
        Write-PSDWizardRoleSelection -State $script:PSDWizardRoleState
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$State
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    foreach ($type in @($State.TypeToProperty.Keys)) {
        $propertyName = $State.TypeToProperty[$type]
        $values = @($State.Entries | Where-Object { $_.Type -eq $type -and -not $_.Locked -and $_.CheckBox.IsChecked -eq $true } | ForEach-Object { $_.Id })
        $text = $values -join ','
        if ([string]$State.SyncHash.TSEnvSettings[$propertyName] -ceq $text) { continue }

        $targetField = $State.Window.FindName("TSEnv_$propertyName")
        if ($targetField) { $targetField.Text = $text }
        if ($State.SyncHash.TSEnvSettings) { $State.SyncHash.TSEnvSettings[$propertyName] = $text }
        try {
            Set-PSDWizardTSEnvProperty -Name $propertyName -Value $text | Out-Null
        }
        catch {
            Write-PSDWizardLog -Message "Unable to write $propertyName from role selection: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        }
        Write-PSDWizardLog -Message "Updated $propertyName from the role catalog selection: $text" -Component $FunctionName
    }
}

Function Invoke-PSDWizardRoleClick {
    <#
    .SYNOPSIS
        Handles a click on a role tree check box.
    .DESCRIPTION
        A role (an item with children below it) selects or clears everything below it: all of it when anything below is unchecked,
        none when all of it is checked. A child changes its parents' state, so a role is checked when all its children are, indeterminate
        when some are. Items the task sequence already installs cannot be changed.
    .PARAMETER Entry
        The role tree entry of the clicked check box
    .EXAMPLE
        Invoke-PSDWizardRoleClick -Entry $checkBox.DataContext
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        $Entry
    )

    $state = $script:PSDWizardRoleState
    if (-not $state) { return }

    if ($Entry.Children.Count -gt 0) {
        $below = @(Get-PSDWizardRoleDescendant -Entry $Entry | Where-Object { -not $_.Locked })
        $select = @($below | Where-Object { $_.CheckBox.IsChecked -ne $true }).Count -gt 0
        foreach ($item in $below) { $item.CheckBox.IsChecked = $select }
        Update-PSDWizardRoleEntryState -Entry $Entry
    }
    $parent = $Entry.Parent
    while ($parent) {
        Update-PSDWizardRoleEntryState -Entry $parent
        $parent = $parent.Parent
    }
    Write-PSDWizardRoleSelection -State $state
}

Function Add-PSDWizardRoleTreeNode {
    <#
    .SYNOPSIS
        Adds the children of a catalog node to the role tree.
    .DESCRIPTION
        Elements with an Id become check boxes (Role, RoleService and Feature). Elements without an Id are group headings such as "Roles" and
        "Feature" and only show their children. The entries are kept in the state so selections can be cascaded and written.
    .PARAMETER Items
        The ItemCollection of the tree or tree item to add to
    .PARAMETER Node
        The catalog node whose children are added
    .PARAMETER ParentEntry
        The entry of the closest parent with an Id, or $null
    .PARAMETER State
        The role tree state
    .PARAMETER Selected
        Ids that start checked (earlier selections)
    .PARAMETER Locked
        Ids the task sequence already installs; checked and not changeable
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        $Items,

        [Parameter(Mandatory=$true)]
        [System.Xml.XmlNode]$Node,

        $ParentEntry,

        [Parameter(Mandatory=$true)]
        [hashtable]$State,

        [hashtable]$Selected = @{},

        [hashtable]$Locked = @{}
    )

    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $id = ([string]$child.GetAttribute('Id')).Trim()
        $displayName = [string]$child.GetAttribute('DisplayName')
        $item = [System.Windows.Controls.TreeViewItem]::new()

        if (-not $id) {
            # A heading: its text is the header, the top ones start open
            $item.Header = $displayName
            $item.IsExpanded = ($null -eq $ParentEntry)
            [void]$Items.Add($item)
            Add-PSDWizardRoleTreeNode -Items $item.Items -Node $child -ParentEntry $ParentEntry -State $State -Selected $Selected -Locked $Locked
            continue
        }

        $isLocked = $Locked.ContainsKey($id)
        $checkBox = [System.Windows.Controls.CheckBox]::new()
        $checkBox.Content = $displayName
        $checkBox.ToolTip = if ($isLocked) { "$id (installed by the task sequence)" } else { "$id ($($child.LocalName))" }
        $checkBox.IsChecked = $isLocked -or $Selected.ContainsKey($id)
        $checkBox.IsEnabled = -not $isLocked
        $checkBox.Margin = [System.Windows.Thickness]::new(0, 1, 4, 1)

        $entry = [pscustomobject]@{
            Id       = $id
            Type     = [string]$child.LocalName
            CheckBox = $checkBox
            Item     = $item
            Parent   = $ParentEntry
            Children = New-Object System.Collections.ArrayList
            Locked   = $isLocked
        }
        # The data stays in DataContext: the Dark theme's check box and tree item styles use Tag and the header template for their own purposes
        $checkBox.DataContext = $entry
        $checkBox.Add_Click({ param($sender, $eventArgs) Invoke-PSDWizardRoleClick -Entry $sender.DataContext })

        # The Dark theme's tree item header template renders the header as text; a null one shows the check box itself
        $item.HeaderTemplate = $null
        $item.Header = $checkBox
        $item.IsExpanded = $false
        [void]$Items.Add($item)
        [void]$State.Entries.Add($entry)
        if ($ParentEntry) { [void]$ParentEntry.Children.Add($entry) }

        Add-PSDWizardRoleTreeNode -Items $item.Items -Node $child -ParentEntry $entry -State $State -Selected $Selected -Locked $Locked
        if ($entry.Children.Count -gt 0) { $checkBox.IsThreeState = $true }
    }
}

Function Initialize-PSDWizardRoleFeatureList {
    <#
    .SYNOPSIS
        Loads the role and feature catalog for the selected operating system into the Roles and Features tree.
    .DESCRIPTION
        Finds the catalog (the native MDT ServerManager.xml) entry for the operating system the selected task sequence installs, and shows it
        as a tree of check boxes. Selecting a role selects what is below it, which can then be cleared one by one. The checked items are
        written to OptionalOSRoles, OptionalOSRoleServices and OptionalOSFeatures for PSDRoleInstall.ps1; items the task sequence already
        installs (OSRoles, OSRoleServices and OSFeatures, or its Install Roles and Features step) show checked and cannot be cleared.
    .PARAMETER Window
        The window object that contains the role and feature tree control (_rolesFeatureTree).
    .PARAMETER SyncHash
        The hashtable containing the task sequence environment settings and other relevant data.
    .EXAMPLE
        Initialize-PSDWizardRoleFeatureList -Window $mainWindow -SyncHash $syncHash
        This example demonstrates how to call the function with the required parameters.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Starting role/feature initialization. ResourcePath='$($SyncHash.ResourcePath)', ControlPath='$($SyncHash.ControlPath)'" -Component $FunctionName
    $script:PSDWizardRoleState = $null
    $tree = $Window.FindName('_rolesFeatureTree')
    if (-not $tree) {
        if ($Window.FindName('_rolesFeatureList')) {
            Write-PSDWizardLog -Message "The theme's Roles and Features pane still has the flat _rolesFeatureList; it needs a TreeView named _rolesFeatureTree" -LogLevel 2 -Component $FunctionName
        }
        return
    }

    $tree.Items.Clear()
    # Clear the role and feature tree before loading new items.
    $status = $Window.FindName('_rolesCatalogStatus')
    if (-not ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings['SkipRoleSelection'] -ieq 'NO')) {
        Write-PSDWizardLog -Message "Role selection skipped: SkipRoleSelection='$($SyncHash.TSEnvSettings['SkipRoleSelection'])'" -Component $FunctionName
        if ($status) { $status.Text = 'Role selection is skipped for this deployment.' }
        return
    }

    # Determine the task sequence ID from the sync hash. This ID is used to locate the corresponding operating system catalog.
    $taskSequenceId = [string]$SyncHash.TSEnvSettings['TaskSequenceID']
    if ([string]::IsNullOrWhiteSpace($taskSequenceId)) {
        Write-PSDWizardLog -Message "Cannot initialize role catalog because TaskSequenceID is empty" -LogLevel 2 -Component $FunctionName
        if ($status) { $status.Text = 'Select a Task Sequence to load its operating system catalog.' }
        return
    }

    # Server or client, Core, build and OSRoleIndex of the operating system the task sequence installs
    $context = Get-PSDWizardRoleContext -SyncHash $SyncHash -TaskSequenceID $taskSequenceId
    Write-PSDWizardLog -Message "Role context for '$taskSequenceId': server=$($context.IsServer), core=$($context.IsCore), build=$($context.Build), OSRoleIndex='$($context.OSRoleIndex)' ($($context.Reason))" -Component $FunctionName
    if ($null -eq $context.IsServer -and -not $context.OSRoleIndex) {
        Write-PSDWizardLog -Message "Unable to tell if Task Sequence '$taskSequenceId' installs a server or a client operating system" -LogLevel 2 -Component $FunctionName
        if ($status) { $status.Text = "Unable to tell which operating system Task Sequence '$taskSequenceId' installs." }
        return
    }

    # The catalog is the native MDT ServerManager.xml, next to the wizard folder in the deployment share's Scripts
    $scriptsPath = if ($SyncHash.ResourcePath) { Split-Path -Parent $SyncHash.ResourcePath } else { $PSScriptRoot }
    $catalogPath = Join-Path $scriptsPath 'ServerManager.xml'
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        Write-PSDWizardLog -Message "Role catalog was not found at '$catalogPath'" -LogLevel 2 -Component $FunctionName
        if ($status) { $status.Text = 'The role catalog (ServerManager.xml) was not found.' }
        return
    }
    try { [xml]$catalog = Get-Content -LiteralPath $catalogPath -Raw }
    catch {
        Write-PSDWizardLog -Message "Role catalog '$catalogPath' could not be read: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        if ($status) { $status.Text = 'The role catalog (ServerManager.xml) could not be read.' }
        return
    }

    $selection = Select-PSDWizardRoleCatalog -Catalog $catalog -Context $context
    if (-not $selection) {
        Write-PSDWizardLog -Message "No role catalog matches '$($context.OperatingSystem)' (server=$($context.IsServer), core=$($context.IsCore), build=$($context.Build)) in '$catalogPath'" -LogLevel 2 -Component $FunctionName
        if ($status) { $status.Text = "No role catalog is configured for $(if ($context.OperatingSystem) { $context.OperatingSystem } else { 'this operating system' })." }
        return
    }
    $catalogNode = $selection.Node

    $typeToProperty = @{
        Role = 'OptionalOSRoles'
        RoleService = 'OptionalOSRoleServices'
        Feature = 'OptionalOSFeatures'
    }
    # Earlier selections (this wizard, CustomSettings.ini) start checked; what the task sequence installs anyway is checked and locked
    $selected = @{}
    foreach ($propertyName in $typeToProperty.Values) {
        foreach ($value in @([string]$SyncHash.TSEnvSettings[$propertyName] -split '[,;]')) { if ($value.Trim()) { $selected[$value.Trim()] = $true } }
    }
    $locked = @{}
    foreach ($propertyName in 'OSRoles', 'OSRoleServices', 'OSFeatures') {
        foreach ($value in @([string]$SyncHash.TSEnvSettings[$propertyName] -split '[,;]') + @($context.TaskSequenceStep.$propertyName)) { if ($value -and $value.Trim()) { $locked[$value.Trim()] = $true } }
    }

    $state = @{
        Entries = New-Object System.Collections.ArrayList
        Window = $Window
        SyncHash = $SyncHash
        TypeToProperty = $typeToProperty
    }
    $script:PSDWizardRoleState = $state
    Add-PSDWizardRoleTreeNode -Items $tree.Items -Node $catalogNode -ParentEntry $null -State $state -Selected $selected -Locked $locked
    if ($state.Entries.Count -eq 0) {
        Write-PSDWizardLog -Message "Role catalog invalid: '$($catalogNode.DisplayName)' (ID $($catalogNode.ID)) in '$catalogPath' has no roles or features" -LogLevel 2 -Component $FunctionName
        if ($status) { $status.Text = "Role catalog not found for $($context.OperatingSystem)." }
        return
    }

    # Children were added after their parents, so walking backwards settles every role from the state of what is below it
    for ($i = $state.Entries.Count - 1; $i -ge 0; $i--) { Update-PSDWizardRoleEntryState -Entry $state.Entries[$i] }
    # Open the branches that hold something checked
    foreach ($entry in @($state.Entries | Where-Object { $_.CheckBox.IsChecked -ne $false })) {
        $container = $entry.Item.Parent
        while ($container -is [System.Windows.Controls.TreeViewItem]) { $container.IsExpanded = $true; $container = $container.Parent }
    }
    Write-PSDWizardLog -Message "Role catalog '$($catalogNode.DisplayName)' (ID $($catalogNode.ID), $($selection.Reason)) loaded from '$catalogPath': items=$($state.Entries.Count), selected=$($selected.Count), installed by the task sequence=$($locked.Count)" -Component $FunctionName

    # Drop earlier selections the catalog does not have (for instance from another task sequence's operating system)
    Write-PSDWizardRoleSelection -State $state

    if ($status) { $status.Text = "$($catalogNode.DisplayName): $($state.Entries.Count) selectable items" }
}

Function Confirm-PSDWizardPassword {
    <#
    .SYNOPSIS
        Validates password matching (optimized)
    .DESCRIPTION
        Ensures password and confirmation match with canvas validation support
    .PARAMETER PasswordObject
        The PasswordBox control
    .PARAMETER ConfirmedPasswordObject
        The confirmation PasswordBox control
    .PARAMETER OutputObject
        The output TextBox for validation messages
    .PARAMETER UpdateNextButton
        If set, enables/disables Next button based on validation
    .PARAMETER Passthru
        Return validation result
    .OUTPUTS
        [bool] Validation result
    .EXAMPLE
        Confirm-PSDWizardPassword -PasswordObject $adminpassword -ConfirmedPasswordObject $adminpasswordConfirm -OutputObject $_admTabValidation_Name -UpdateNextButton -Passthru
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.PasswordBox]$PasswordObject,

        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.PasswordBox]$ConfirmedPasswordObject,

        [Parameter(Mandatory=$false)]
        $OutputObject,

        [Parameter(Mandatory=$false)]
        [switch]$UpdateNextButton,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    # Retrieve the function name for logging purposes
    $password = $PasswordObject.Password
    $confirmPassword = $ConfirmedPasswordObject.Password
    $isValid = $false
    $message = ""

    # Check if either field has content
    $hasContent = (-not [string]::IsNullOrEmpty($password)) -or (-not [string]::IsNullOrEmpty($confirmPassword))

    # If either field has content, BOTH must match
    if ($hasContent) {
        # If one is empty but not both, that's invalid
        if ([string]::IsNullOrEmpty($password) -or [string]::IsNullOrEmpty($confirmPassword)) {
            $isValid = $false
            $message = "Please enter password in both fields"
        }
        # Both have values - check if they match (case-sensitive)
        elseif ($password -ceq $confirmPassword) {
            $isValid = $true
            $message = "Passwords match"
        }
        else {
            $isValid = $false
            $message = "Passwords do not match"
        }
    }
    else {
        # Both empty - allow (password might be optional)
        $isValid = $true
        $message = ""
    }

    Write-PSDWizardLog -Message ("{0}: Validation result = {1}, Message = '{2}'" -f $FunctionName, $isValid, $message) -Component $FunctionName

    if ($OutputObject) {
        # Update validation canvas and message
        $wnd = [System.Windows.Window]::GetWindow($OutputObject)
        if ($wnd) {
            # Attempt to locate the parent Canvas and associated alert/check icons based on the output TextBox name
            $parentCanvas = $wnd.FindName(($OutputObject.Name -replace '_Name$', ''))
            $alertIcon = $wnd.FindName(($OutputObject.Name -replace '_Name$', '_Alert'))
            $checkIcon = $wnd.FindName(($OutputObject.Name -replace '_Name$', '_Check'))

            if ($parentCanvas) {
                # Hide canvas for empty passwords, show for valid/invalid
                if ([string]::IsNullOrEmpty($message)) {
                    $parentCanvas.Visibility = "Hidden"
                }
                else {
                    # Show the parent Canvas and set its background color based on the validation result
                    $parentCanvas.Visibility = "Visible"
                    $parentCanvas.Background = if ($isValid) { "LightGreen" } else { "LightPink" }
                }
            }

            # Update the output TextBox and its associated alert/check icons based on the validation result
            $OutputObject.Text = $message
            $OutputObject.Foreground = if ($isValid) { "Green" } else { "Red" }

            # Update the visibility of the alert and check icons based on the validation result
            if ($alertIcon) { $alertIcon.Visibility = if ($isValid -or [string]::IsNullOrEmpty($message)) { "Hidden" } else { "Visible" } }
            if ($checkIcon) { $checkIcon.Visibility = if ($isValid -and -not [string]::IsNullOrEmpty($message)) { "Visible" } else { "Hidden" } }

            # Update Next button if requested based on the validation result
            if ($UpdateNextButton) {
                $nextButton = $wnd.FindName('_wizNext')
                if ($nextButton) {
                    # Enable Next only if passwords are valid (matching) or both empty
                    $shouldEnable = $isValid

                    # Determine if the Next button should be enabled based on the password validation result
                    if ([string]::IsNullOrEmpty($password) -and [string]::IsNullOrEmpty($confirmPassword)) {
                        Write-PSDWizardLog -Message ("{0}: Passwords empty, allowing navigation" -f $FunctionName) -Component $FunctionName
                    }
                    else {
                        Write-PSDWizardLog -Message ("{0}: Next button IsEnabled = {1} (passwords must match)" -f $FunctionName, $isValid) -Component $FunctionName
                    }

                    # Apply the determined enable state to the Next button
                    $nextButton.IsEnabled = $shouldEnable

                    # Also manage tab navigation - disable future tabs when passwords don't match
                    $tabControl = $wnd.FindName('_wizTabControl')
                    if ($tabControl) {
                        # Retrieve the index of the currently selected tab for managing tab navigation
                        $currentTabIndex = $tabControl.SelectedIndex

                        if (-not $shouldEnable) {
                            # Password validation failed - disable all tabs after current one
                            # Iterate through all tabs after the current one and disable them if they haven't been visited
                            for ($i = $currentTabIndex + 1; $i -lt $tabControl.Items.Count; $i++) {
                                if ($script:VisitedTabs -and $i -notin $script:VisitedTabs) {
                                    $tabControl.Items[$i].IsEnabled = $false
                                }
                            }
                        }
                        else {
                            # Password validation passed - enable next tab
                            if ($currentTabIndex + 1 -lt $tabControl.Items.Count) {
                                $tabControl.Items[$currentTabIndex + 1].IsEnabled = $true
                            }
                        }
                    }
                }
            }
        }
    }

    if ($Passthru) {
        return $isValid
    }
}

function Confirm-PSDWizardDomainRequirements {
    <#
    .SYNOPSIS
        Validates all required domain join fields are filled

    .DESCRIPTION
        When Domain radio is selected, ensures all mandatory domain fields are completed:
        - Domain name (must be valid FQDN)
        - Domain join account username (must be valid)
        Optionally validates domain join account password matching if passwords are entered.
        This provides page-level validation for domain join operations.

    .PARAMETER Window
        The window object containing the domain join controls

    .PARAMETER ValidationCanvasName
        Name of the validation canvas to update (typically '_detTabValidation3_Name')

    .PARAMETER UpdateNextButton
        If set, enables/disables the Next button based on all domain requirements

    .EXAMPLE
        Confirm-PSDWizardDomainRequirements -Window $Window -ValidationCanvasName '_detTabValidation3_Name' -UpdateNextButton
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$false)]
        [string]$ValidationCanvasName,

        [Parameter(Mandatory=$false)]
        [switch]$UpdateNextButton
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message ("{0}: Validating domain join requirements" -f $FunctionName) -Component $FunctionName

    # Check if domain radio is selected
    $domainRadio = $Window.FindName('_JoinDomainRadio')
    # Log the state of the domain radio button for debugging purposes
    Write-PSDWizardLog -Message ("{0}: Domain radio button is checked: {1}" -f $FunctionName, $isDomainMode) -Component $FunctionName
    $isDomainMode = $domainRadio -and $domainRadio.IsChecked -eq $true

    if (-not $isDomainMode) {
        Write-PSDWizardLog -Message ("{0}: Not in domain mode, skipping domain validation" -f $FunctionName) -Component $FunctionName
        return $true
    }

    # Get all domain controls
    $domainField = $Window.FindName('TSEnv_JoinDomain')
    $domainAdminField = $Window.FindName('TSEnv_DomainAdmin')
    $domainAdminDomainField = $Window.FindName('TSEnv_DomainAdminDomain')
    $domainAdminPasswordField = $Window.FindName('TSEnv_DomainAdminPassword')
    $domainAdminConfirmPasswordField = $Window.FindName('_DomainAdminConfirmPassword')
    # Log the retrieved domain controls for debugging purposes
    $allValid = $true
    $validationMessages = @()

    # Validate domain name (required and must be valid FQDN)
    if ($domainField) {
        # Retrieve the current value of the domain field for validation purposes
        $domainValue = $domainField.Text
        if ([string]::IsNullOrWhiteSpace($domainValue)) {
            $allValid = $false
            $validationMessages += "Domain name is required"
        }
        else {
            # Validate FQDN format
            # Log the domain value before validating its format
            $fqdnRegex = '(?=^.{3,253}$)(^(((?!-)[a-zA-Z0-9-]{1,63}(?<!-))|((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63})$)'
            if ($domainValue -notmatch $fqdnRegex) {
                $allValid = $false
                $validationMessages += "Invalid domain name format"
            }
        }
    }

    # Validate domain join account username (required)
    if ($domainAdminField) {
        # Log the retrieved domain admin username for debugging purposes
        $adminValue = $domainAdminField.Text
        if ([string]::IsNullOrWhiteSpace($adminValue)) {
            $allValid = $false
            $validationMessages += "Domain join account is required"
        }
        elseif (-not (Test-PSDWizardDomainAccountName -AccountName $adminValue)) {
            $allValid = $false
            $validationMessages += "Domain join account contains an unsupported character"
        }
    }

    # Validate domain admin domain (required)
    if ($domainAdminDomainField) {
        # Log the retrieved domain admin domain for debugging purposes
        $adminDomainValue = $domainAdminDomainField.Text
        if ([string]::IsNullOrWhiteSpace($adminDomainValue)) {
            $allValid = $false
            $validationMessages += "Domain join account domain is required"
        }
        else {
            # Validate FQDN format
            $fqdnRegex = '(?=^.{3,253}$)(^(((?!-)[a-zA-Z0-9-]{1,63}(?<!-))|((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63})$)'
            if ($adminDomainValue -notmatch $fqdnRegex) {
                $allValid = $false
                $validationMessages += "Invalid domain join account domain format"
            }
        }
    }

    # Validate domain join account passwords (required and must match)
    if ($domainAdminPasswordField -and $domainAdminConfirmPasswordField) {
        $password = $domainAdminPasswordField.Password
        $confirmPassword = $domainAdminConfirmPasswordField.Password

        # Log the retrieved domain admin password and confirmation password for debugging purposes (do not log the actual password in a real environment)
        if ([string]::IsNullOrEmpty($password)) {
            $allValid = $false
            $validationMessages += "Domain join account password is required"
        }
        elseif ([string]::IsNullOrEmpty($confirmPassword)) {
            $allValid = $false
            $validationMessages += "Please confirm the domain join account password"
        }
        elseif ($password -cne $confirmPassword) {
            $allValid = $false
            $validationMessages += "Domain join account passwords do not match"
        }
    }

    # Update validation canvas if provided
    if ($ValidationCanvasName) {
        # Log the validation result for the domain join account fields before updating the UI
        $validationTextBox = $Window.FindName($ValidationCanvasName)
        if ($validationTextBox) {
            # Retrieve the parent canvas, alert icon, and check icon for the validation UI elements
            $parentCanvas = $Window.FindName(($ValidationCanvasName -replace '_Name$', ''))
            $alertIcon = $Window.FindName(($ValidationCanvasName -replace '_Name$', '_Alert'))
            $checkIcon = $Window.FindName(($ValidationCanvasName -replace '_Name$', '_Check'))

            if ($allValid) {
                # Hide the parent canvas and clear the validation message when all fields are valid
                if ($parentCanvas) { $parentCanvas.Visibility = "Hidden" }
                $validationTextBox.Text = ""
            }
            else {
                # Show the parent canvas and display the validation message when any field is invalid
                $message = $validationMessages -join "; "
                if ($parentCanvas) {
                    $parentCanvas.Visibility = "Visible"
                    $parentCanvas.Background = "LightPink"
                }
                # Update the validation text box with the composed message and set its foreground color
                $validationTextBox.Text = $message
                $validationTextBox.Foreground = "Red"

                # Update the visibility of the alert and check icons based on the validation result
                if ($alertIcon) { $alertIcon.Visibility = "Visible" }
                if ($checkIcon) { $checkIcon.Visibility = "Hidden" }
            }
        }
    }

    # Update Next button if requested
    if ($UpdateNextButton) {
        $nextButton = $Window.FindName('_wizNext')
        if ($nextButton) {
            $nextButton.IsEnabled = $allValid
            Write-PSDWizardLog -Message ("{0}: Domain requirements {1}, Next button IsEnabled = {2}" -f $FunctionName, $(if($allValid){"met"}else{"not met"}), $allValid) -Component $FunctionName

            # Also manage tab navigation - disable future tabs when requirements not met
            $tabControl = $Window.FindName('_wizTabControl')
            if ($tabControl) {
                $currentTabIndex = $tabControl.SelectedIndex

                if (-not $allValid) {
                    # Requirements not met - disable all tabs after current one
                    for ($i = $currentTabIndex + 1; $i -lt $tabControl.Items.Count; $i++) {
                        # Log the tab index being evaluated for potential disabling
                        if ($script:VisitedTabs -and $i -notin $script:VisitedTabs) {
                            $tabControl.Items[$i].IsEnabled = $false
                        }
                    }
                }
                else {
                    # Requirements met - enable next tab
                    if ($currentTabIndex + 1 -lt $tabControl.Items.Count) {
                        $tabControl.Items[$currentTabIndex + 1].IsEnabled = $true
                    }
                }
            }
        }
    }

    Write-PSDWizardLog -Message ("{0}: Domain validation result = {1}" -f $FunctionName, $allValid) -Component $FunctionName
    return $allValid
}

function Invoke-PSDWizardReadinessChecks {
    <#
    .SYNOPSIS
        Runs deployment readiness validation checks

    .DESCRIPTION
        Executes up to 4 readiness check functions from a specified script.
        Updates validation canvases with results and controls Next button based on
        SkipReadinessCheck and PSDReadinessAllowBypass settings.

        Respects these TSEnv properties:
        - SkipReadinessCheck: If "YES", skips all checks
        - PSDReadinessAllowBypass: If "YES", allows navigation even if checks fail
        - PSDReadinessScript: Name of script file in PSDResources\Readiness\
        - PSDReadinessCheck1-4: Function names to call from the readiness script

    .PARAMETER Window
        The window object containing the deployment readiness page controls

    .PARAMETER ResourcePath
        Path to PSDResources folder containing Readiness scripts

    .PARAMETER TSEnvSettings
        Hashtable containing TS environment variables

    .EXAMPLE
        Invoke-PSDWizardReadinessChecks -Window $Window -ResourcePath "C:\Deploy\Scripts\PSDWizardNew" -TSEnvSettings $SyncHash.TSEnvSettings
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [string]$ResourcePath,

        [Parameter(Mandatory=$false)]
        [hashtable]$TSEnvSettings
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message ("{0}: Starting readiness checks" -f $FunctionName) -Component $FunctionName

    for ($i = 1; $i -le 4; $i++) {
        $canvasName = "_depTabValidation0$i"
        $canvas = $Window.FindName($canvasName)
        $textBox = $Window.FindName("${canvasName}_Name")
        $alertIcon = $Window.FindName("${canvasName}_Alert")
        $checkIcon = $Window.FindName("${canvasName}_Check")
        if ($canvas) { $canvas.Visibility = 'Hidden' }
        if ($textBox) { $textBox.Text = '' }
        if ($alertIcon) { $alertIcon.Visibility = 'Hidden' }
        if ($checkIcon) { $checkIcon.Visibility = 'Hidden' }
    }

    # Check if readiness checks should be skipped
    $skipChecks = $false
    if ($TSEnvSettings -and $TSEnvSettings.ContainsKey('SkipReadinessCheck')) {
        $skipChecks = $TSEnvSettings['SkipReadinessCheck'] -ieq 'YES'
    }

    if ($skipChecks) {
        Write-PSDWizardLog -Message ("{0}: SkipReadinessCheck=YES, hiding all validation canvases" -f $FunctionName) -Component $FunctionName

        # Hide all 4 validation canvases
        for ($i = 1; $i -le 4; $i++) {
            $canvasName = "_depTabValidation0$i"
            $canvas = $Window.FindName($canvasName)
            # Log the canvas being evaluated for potential hiding
            if ($canvas) {
                $canvas.Visibility = "Hidden"
            }
        }

        # Enable Next button
        $nextButton = $Window.FindName('_wizNext')
        if ($nextButton) {
            $nextButton.IsEnabled = $true
        }

        return $true
    }

    # Get readiness script name
    # Log the readiness script being retrieved from the environment settings
    $readinessScript = $null
    if ($TSEnvSettings -and $TSEnvSettings.ContainsKey('PSDReadinessScript')) {
        $readinessScript = $TSEnvSettings['PSDReadinessScript']
    }

    if ([string]::IsNullOrWhiteSpace($readinessScript)) {
        Write-PSDWizardLog -Message ("{0}: No PSDReadinessScript specified, hiding validation canvases" -f $FunctionName) -LogLevel 2 -Component $FunctionName

        # Hide all validation canvases since no readiness script is specified
        for ($i = 1; $i -le 4; $i++) {
            # Log the canvas being evaluated for potential hiding
            $canvasName = "_depTabValidation0$i"
            $canvas = $Window.FindName($canvasName)
            if ($canvas) {
                $canvas.Visibility = "Hidden"
            }
        }
        return $true
    }

    # Support both a wizard-local resource folder and PSD's deployment-root PSDResources folder.
    $resourceParent = Split-Path -Parent $ResourcePath
    $deploymentRoot = Split-Path -Parent $resourceParent
    $readinessCandidates = @(
        (Join-Path $ResourcePath "PSDResources\Readiness\$readinessScript"),
        (Join-Path $deploymentRoot "PSDResources\Readiness\$readinessScript")
    ) | Select-Object -Unique
    $readinessPath = $null
    foreach ($candidate in $readinessCandidates) {
        if (Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue) {
            $readinessPath = $candidate
            break
        }
    }

    if (-not $readinessPath) {
        $readinessPath = $readinessCandidates[-1]
        Write-PSDWizardLog -Message ("{0}: Readiness script not found: $readinessPath" -f $FunctionName) -LogLevel 3 -Component $FunctionName
        return $false
    }

    Write-PSDWizardLog -Message ("{0}: Loading readiness script: $readinessPath" -f $FunctionName) -Component $FunctionName

    # Dot-source the readiness script to load its functions
    try {
        . $readinessPath
        Write-PSDWizardLog -Message ("{0}: Readiness script loaded successfully" -f $FunctionName) -Component $FunctionName
    }
    catch {
        Write-PSDWizardLog -Message ("{0}: Error loading readiness script: $($_.Exception.Message)" -f $FunctionName) -LogLevel 3 -Component $FunctionName
        return $false
    }

    # Run each readiness check (up to 4)
    $allChecksPassed = $true
    $checksRun = 0

    # Iterate through each readiness check and update the corresponding validation canvas
    for ($i = 1; $i -le 4; $i++) {
        $checkKey = 'PSDReadinessCheck{0:D3}' -f $i
        if (-not $TSEnvSettings -or -not $TSEnvSettings.ContainsKey($checkKey)) {
            $checkKey = "PSDReadinessCheck$i"
        }
        $canvasName = "_depTabValidation0$i"

        # Log the readiness check and corresponding canvas being evaluated
        $canvas = $Window.FindName($canvasName)
        $textBox = $Window.FindName("${canvasName}_Name")
        $alertIcon = $Window.FindName("${canvasName}_Alert")
        $checkIcon = $Window.FindName("${canvasName}_Check")

        # Check if this readiness check is defined
        if ($TSEnvSettings -and $TSEnvSettings.ContainsKey($checkKey)) {
            $functionName = $TSEnvSettings[$checkKey]
            # Log the function name for the readiness check being evaluated
            if ([string]::IsNullOrWhiteSpace($functionName)) {
                if ($canvas) { $canvas.Visibility = "Hidden" }
                continue
            }

            Write-PSDWizardLog -Message ("{0}: Running check $i`: $functionName" -f $FunctionName) -Component $FunctionName

            try {
                # Call the readiness function
                $result = & $functionName
                $checksRun++

                # Parse result
                $ready = $result.Ready -eq $true -or $result.Ready -ieq 'True'
                $message = $result.Message

                Write-PSDWizardLog -Message ("{0}: Check $i result - Ready: $ready, Message: '$message'" -f $FunctionName) -Component $FunctionName

                # Update validation canvas
                if ($canvas) {
                    $canvas.Visibility = "Visible"
                    $canvas.Background = if ($ready) { "LightGreen" } else { "LightPink" }
                }
                # Log the readiness check result before updating the UI
                if ($textBox) {
                    $textBox.Text = $message
                    $textBox.Foreground = if ($ready) { "Green" } else { "Red" }
                }
                # Update the visibility of the alert and check icons based on the readiness result
                if ($alertIcon) {
                    $alertIcon.Visibility = if ($ready) { "Hidden" } else { "Visible" }
                }
                # Update the visibility of the check icon based on the readiness result
                if ($checkIcon) {
                    $checkIcon.Visibility = if ($ready) { "Visible" } else { "Hidden" }
                }

                if (-not $ready) {
                    $allChecksPassed = $false
                }
            }
            catch {
                Write-PSDWizardLog -Message ("{0}: Error running check $i ($functionName): $($_.Exception.Message)" -f $FunctionName) -LogLevel 2 -Component $FunctionName

                # Show error in canvas
                if ($canvas) {
                    $canvas.Visibility = "Visible"
                    $canvas.Background = "LightPink"
                }
                # Log the error and update the UI to reflect the failed readiness check
                if ($textBox) {
                    $textBox.Text = "Error: $($_.Exception.Message)"
                    $textBox.Foreground = "Red"
                }
                # Update the visibility of the alert and check icons to reflect the failed readiness check
                if ($alertIcon) { $alertIcon.Visibility = "Visible" }
                if ($checkIcon) { $checkIcon.Visibility = "Hidden" }

                $allChecksPassed = $false
            }
        }
        else {
            # No check defined for this slot - hide the canvas
            if ($canvas) {
                $canvas.Visibility = "Hidden"
            }
        }
    }

    Write-PSDWizardLog -Message ("{0}: Ran $checksRun readiness checks, All passed: $allChecksPassed" -f $FunctionName) -Component $FunctionName

    # Determine if Next button should be enabled
    # Check PSDReadinessAllowBypass setting
    $allowBypass = $false
    if ($TSEnvSettings -and $TSEnvSettings.ContainsKey('PSDReadinessAllowBypass')) {
        # Log the value of the PSDReadinessAllowBypass setting from the environment settings
        $allowBypass = $TSEnvSettings['PSDReadinessAllowBypass'] -ieq 'YES' -or $TSEnvSettings['PSDReadinessAllowBypass'] -ieq 'True'
    }
    # Log the final decision on whether the Next button should be enabled based on readiness checks and bypass setting
    $enableNext = $allChecksPassed -or $allowBypass
    Write-PSDWizardLog -Message ("{0}: PSDReadinessAllowBypass=$allowBypass, Enabling Next button: $enableNext" -f $FunctionName) -Component $FunctionName

    # Find the Next button in the wizard window and set its enabled state based on readiness checks and bypass setting
    $nextButton = $Window.FindName('_wizNext')
    if ($nextButton) {
        $nextButton.IsEnabled = $enableNext
    }

    return $allChecksPassed
}

#endregion

#region STRING MANIPULATION AND VARIABLE EXPANSION

Function Get-PSDWizardRandomAlphanumericString {
    <#
    .SYNOPSIS
        Generate random alphanumeric string
    .DESCRIPTION
        Creates a random string of specified length using alphanumeric characters (0-9, A-Z, a-z).
        Used for %RAND% variable expansion in computer names and other dynamic properties.
    .PARAMETER Length
        Length of the random string to generate (default: 8)
    .OUTPUTS
        [string] Random alphanumeric string
    .EXAMPLE
        Get-PSDWizardRandomAlphanumericString -Length 5
        # Output: "A3DF3"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$false)]
        [int]$Length = 8
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    # Log the start of the random string generation process
    # Attempt to generate the random string
    try {
        $randomString = -join ((0x30..0x39) + (0x41..0x5A) + (0x61..0x7A) | Get-Random -Count $Length | ForEach-Object { [char]$_ })
        Write-PSDWizardLog -Message "Generated random string of length $Length" -Component $FunctionName
        return $randomString
    }
    catch {
        Write-PSDWizardLog -Message "Error generating random string: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        throw
    }
}

Function Set-PSDWizardStringLength {
    <#
    .SYNOPSIS
        Adjusts string to specified length by trimming or padding
    .DESCRIPTION
        Trims or pads a string to the exact length specified, preserving leading zeros.
        Used for truncating serial numbers, MAC addresses, and other variable expansions.
    .PARAMETER InputString
        The string to adjust
    .PARAMETER Length
        Target length for the string
    .PARAMETER TrimDirection
        Direction to trim/pad from: 'Left' or 'Right' (default: 'Right'). Right keeps the leftmost characters; Left keeps the rightmost characters.
    .OUTPUTS
        [string] Adjusted string
    .EXAMPLE
        "00123456" | Set-PSDWizardStringLength -Length 4 -TrimDirection Right
        # Output: "0012"
    .EXAMPLE
        "00123456" | Set-PSDWizardStringLength -Length 4 -TrimDirection Left
        # Output: "3456"
    .EXAMPLE
        "0012" | Set-PSDWizardStringLength -Length 7 -TrimDirection Left
        # Output: "0000012"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [string]$InputString,

        [Parameter(Mandatory=$true, Position=1)]
        [int]$Length,

        [Parameter(Mandatory=$false, Position=2)]
        [ValidateSet('Left', 'Right')]
        [string]$TrimDirection = 'Right'
    )

    Begin {
        $FunctionName = $MyInvocation.MyCommand.Name
    }
    Process {
        # Log the input string and target length before attempting adjustment
        try {
            if ($InputString.Length -gt $Length) {
                # Trim the string if it's longer than the desired length
                if ($TrimDirection -eq 'Right') {
                    $result = $InputString.Substring(0, $Length)
                }
                else {
                    # Trim from the left if the trim direction is 'Left'
                    $result = $InputString.Substring($InputString.Length - $Length)
                }
                Write-PSDWizardLog -Message "Trimmed string from $($InputString.Length) to $Length chars ($TrimDirection)" -Component $FunctionName
            }
            elseif ($InputString.Length -lt $Length) {
                # Pad the string with zeros if it's shorter
                if ($TrimDirection -eq 'Right') {
                    $result = $InputString.PadRight($Length, '0')
                }
                else {
                    $result = $InputString.PadLeft($Length, '0')
                }
                Write-PSDWizardLog -Message "Padded string from $($InputString.Length) to $Length chars ($TrimDirection)" -Component $FunctionName
            }
            else {
                $result = $InputString
            }

            return $result
        }
        catch {
            Write-PSDWizardLog -Message "Error adjusting string length: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
            throw
        }
    }
}

Function Expand-PSDWizardString {
    <#
    .SYNOPSIS
        Expands dynamic variables in strings
    .DESCRIPTION
        Processes strings containing dynamic variables and replaces them with actual values.
        Supports variables from TSEnv and special hardware-based variables:
        - %SERIAL% or %SERIAL:n% - System serial number (optionally truncated to n chars)
        - %RAND% or %RAND:n% - Random alphanumeric string (optionally n chars long)
        - %MACADDRESS% or %MACADDRESS:n% - Primary MAC address without colons
        - %ASSETTAG% or %ASSETTAG:n% - System asset tag
        - %{TSEnvVar}% - Any Task Sequence variable

        Supports truncation syntax:
        - %SERIAL:5% - Keep the first 5 characters; trim from the right
        - %5:SERIAL% - Keep the last 5 characters; trim from the left
        - n:VARIABLE or VARIABLE:n formats supported
    .PARAMETER InputString
        String containing variables to expand
    .OUTPUTS
        [string] Expanded string with variables replaced
    .EXAMPLE
        Expand-PSDWizardString "PSD-%SERIAL:5%"
        # Output: "PSD-56789" (using actual serial number)
    .EXAMPLE
        Expand-PSDWizardString "PSD-%RAND:7%"
        # Output: "PSD-A3DF321" (random output)
    .EXAMPLE
        Expand-PSDWizardString "%PREFIX%-%SITE%-%SERIAL:6%"
        # Output: "DTO-LAB-456789" (where PREFIX=DTO, SITE=LAB from TSEnv)
    .EXAMPLE
        Expand-PSDWizardString "PSD-%MACADDRESS:6%"
        # Output: "PSD-00155D" (using MAC address 00:15:5D:00:00:01)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [AllowEmptyString()]
        [string]$InputString
    )

    Begin {
        $FunctionName = $MyInvocation.MyCommand.Name
    }

    Process {
        # Return empty string if input is empty
        if ([string]::IsNullOrWhiteSpace($InputString)) {
            return $InputString
        }

        # Check if string contains any variables
        if ($InputString -notmatch '%') {
            Write-PSDWizardLog -Message "No variables found in string: $InputString" -Component $FunctionName
            return $InputString
        }

        Write-PSDWizardLog -Message "Expanding variables in string: $InputString" -Component $FunctionName
        # Log the initial result before any variable expansion
        $result = $InputString

        # Find all %...% patterns using regex
        $pattern = '%([^%]+)%'
        # Not $matches - that is an automatic variable and -match below would clobber it
        $varMatches = [regex]::Matches($InputString, $pattern)

        # Iterate over each variable match and perform the necessary expansion and truncation
        foreach ($match in $varMatches) {
            $fullMatch = $match.Value              # e.g., "%SERIAL:5%"
            $innerText = $match.Groups[1].Value    # e.g., "SERIAL:5"

            # Parse variable name and optional truncation
            $varName = $innerText
            $truncateLength = 0
            $truncateDirection = 'Right'

            # Check for truncation syntax: SERIAL:5 or 5:SERIAL
            if ($innerText -match '^(\d{1,2}):(.+)$') {
                # Format: 5:SERIAL (left truncation)
                $truncateLength = [int]$Matches[1]
                $varName = $Matches[2]
                $truncateDirection = 'Left'
            }
            elseif ($innerText -match '^(.+):(\d{1,2})$') {
                # Format: SERIAL:5 (right truncation)
                $varName = $Matches[1]
                $truncateLength = [int]$Matches[2]
                $truncateDirection = 'Right'
            }

            # Get the replacement value based on variable type
            $replacement = $null

            # Determine the replacement value based on the variable name using a switch statement
            switch -Regex ($varName) {
                '^SERIAL(NUMBER)?$' {
                    $replacement = Get-PSDWizardTSEnvProperty 'SerialNumber' -ValueOnly
                    if ([string]::IsNullOrEmpty($replacement)) {
                        Write-PSDWizardLog -Message "SERIAL variable has no value, keeping placeholder" -LogLevel 1 -Component $FunctionName
                    }
                    else {
                        Write-PSDWizardLog -Message "Found SERIAL: $replacement" -Component $FunctionName
                    }
                }

                '^RAND$' {
                    # Calculate length for RAND if not specified
                    if ($truncateLength -eq 0) {
                        $truncateLength = 15 - ($InputString -replace '%.*?RAND.*?%', '').Length
                        if ($truncateLength -lt 1) { $truncateLength = 6 }
                        if ($truncateLength -gt 15) { $truncateLength = 15 }
                    }
                    # Generate the random alphanumeric string based on the calculated length
                    $replacement = Get-PSDWizardRandomAlphanumericString -Length $truncateLength
                    Write-PSDWizardLog -Message "Generated RAND($truncateLength): $replacement" -Component $FunctionName
                    $truncateLength = 0  # Already sized correctly
                }

                '^MACADDRESS$' {
                    $replacement = Get-PSDWizardTSEnvProperty 'MacAddress' -ValueOnly
                    if ([string]::IsNullOrEmpty($replacement)) {
                        Write-PSDWizardLog -Message "MACADDRESS variable has no value, keeping placeholder" -LogLevel 1 -Component $FunctionName
                    }
                    else {
                        # Remove colons/hyphens from MAC address
                        $replacement = ($replacement -replace ':', '') -replace '-', ''
                        Write-PSDWizardLog -Message "Found MACADDRESS: $replacement" -Component $FunctionName
                    }
                }

                '^ASSETTAG$' {
                    $replacement = Get-PSDWizardTSEnvProperty 'AssetTag' -ValueOnly
                    if ([string]::IsNullOrEmpty($replacement)) {
                        Write-PSDWizardLog -Message "ASSETTAG variable has no value, keeping placeholder" -LogLevel 1 -Component $FunctionName
                    }
                    else {
                        Write-PSDWizardLog -Message "Found ASSETTAG: $replacement" -Component $FunctionName
                    }
                }

                default {
                    # PSDGather resolves CustomSettings before the wizard launches.
                    $replacement = Get-PSDWizardTSEnvProperty $varName -ValueOnly
                    if ([string]::IsNullOrEmpty($replacement)) {
                        Write-PSDWizardLog -Message "TSEnv variable '$varName' not found, keeping placeholder" -LogLevel 1 -Component $FunctionName
                    }
                    else {
                        Write-PSDWizardLog -Message "Found TSEnv variable ${varName}: $replacement" -Component $FunctionName
                    }
                }
            }

            # Apply truncation if needed and replacement was found
            if (-not [string]::IsNullOrEmpty($replacement) -and $truncateLength -gt 0) {
                $replacement = $replacement | Set-PSDWizardStringLength -Length $truncateLength -TrimDirection $truncateDirection
            }

            # MDT substitutes an empty string for variables that resolve to nothing. Leaving the
            # literal %VAR% behind produces an invalid computer name and fails length validation.
            if ([string]::IsNullOrEmpty($replacement)) {
                Write-PSDWizardLog -Message "Variable '$varName' resolved to empty - substituting empty string" -LogLevel 2 -Component $FunctionName
                $replacement = ''
            }

            # Literal replace: a value containing $ would be treated as a substitution pattern by -replace
            $result = $result.Replace($fullMatch, $replacement)
        }

        $result = $result.ToUpper()
        Write-PSDWizardLog -Message "Expanded string result: $result" -Component $FunctionName

        return $result
    }
}

#endregion

#region TEST FUNCTIONS

Function Test-PSDWizardApplicationExist {
    <#
    .SYNOPSIS
        Checks if applications are available for selection
    .DESCRIPTION
        Tests whether applications exist in deployment share or loaded data.
        Used in page conditions to show/hide Applications page.
    .OUTPUTS
        [bool] True if applications exist, False otherwise
    .EXAMPLE
        if (Test-PSDWizardApplicationExist) { "Show Applications page" }
    #>
    [CmdletBinding()]
    Param()

    $FunctionName = $MyInvocation.MyCommand.Name

    try {
        # Check if running in DevelopmentMode with loaded data
        if ($script:IsDevelopmentMode) {
            $appCount = if ($script:PSDWizardSyncHash) { @($script:PSDWizardSyncHash.Applications).Count } else { 0 }
            Write-PSDWizardLog -Message "Found $appCount applications in DevelopmentMode" -Component $FunctionName
            return ($appCount -gt 0)
        }

        # For non-DevelopmentMode, default to showing page
        # (In production, Get-PSDWizardTSChildItem would query deployment share)
        Write-PSDWizardLog -Message "Not in DevelopmentMode - defaulting to true" -Component $FunctionName
        return $true
    }
    catch {
        Write-PSDWizardLog -Message "Error checking applications: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        return $true  # Default to showing page if check fails
    }
}

#endregion

#region APPLICATION FUNCTIONS

Function Export-PSDWizardApplication {
    <#
    .SYNOPSIS
        Exports application selections to TSEnv (FIXED)
    .DESCRIPTION
        Properly clears all Applications### variables before writing new selections.
        FIXED: Now completely removes old app entries before adding new ones
    .PARAMETER SelectedApplications
        Array of selected application GUIDs
    .PARAMETER FieldObject
        The UI field object containing selections
    .OUTPUTS
        [string[]] Array of application GUIDs
    .EXAMPLE
        Export-PSDWizardApplication -SelectedApplications $apps
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    Param(
        [Parameter(Mandatory=$false)]
        [string[]]$SelectedApplications,

        [Parameter(Mandatory=$false)]
        $FieldObject
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Exporting application selections..." -Component $FunctionName

    try {
        # CRITICAL FIX: Remove ALL existing Applications### variables first
        Write-PSDWizardLog -Message "Clearing all existing application variables..." -Component $FunctionName
        Remove-PSDWizardTSEnvProperty -Name 'Applications*' -WildCard

        # If no applications selected, we're done
        if ($null -eq $SelectedApplications -or $SelectedApplications.Count -eq 0) {
            if ($script:IsDevelopmentMode -and $script:PSDWizardSyncHash) {
                if (-not $script:PSDWizardSyncHash.TSEnvLists) { $script:PSDWizardSyncHash.TSEnvLists = @{} }
                $script:PSDWizardSyncHash.TSEnvLists['Applications'] = @()
            }
            elseif (Get-PSDrive -Name 'TSEnvList' -ErrorAction SilentlyContinue) {
                Set-Item -LiteralPath 'TSEnvList:\Applications' -Value @() -Force -ErrorAction SilentlyContinue
            }
            Write-PSDWizardLog -Message "No applications selected, all variables cleared" -Component $FunctionName
            return @()
        }

        # TSEnvList:Applications is the array consumed by PSDApplications.ps1.
        if ($script:IsDevelopmentMode -and $script:PSDWizardSyncHash) {
            if (-not $script:PSDWizardSyncHash.TSEnvLists) { $script:PSDWizardSyncHash.TSEnvLists = @{} }
            $script:PSDWizardSyncHash.TSEnvLists['Applications'] = @($SelectedApplications)
        }
        elseif (Get-PSDrive -Name 'TSEnvList' -ErrorAction SilentlyContinue) {
            Set-Item -LiteralPath 'TSEnvList:\Applications' -Value @($SelectedApplications) -Force -ErrorAction Stop
        }

        # Write new selections with proper indexing
        $index = 1
        foreach ($appGuid in $SelectedApplications) {
            # Log the application GUID being processed before setting the environment variable
            $varName = "Applications{0:D3}" -f $index
            Set-PSDWizardTSEnvProperty -Name $varName -Value $appGuid
            Write-PSDWizardLog -Message "Set $varName = $appGuid" -Component $FunctionName
            $index++
        }

        Write-PSDWizardLog -Message "Exported $($SelectedApplications.Count) applications successfully" -Component $FunctionName
        return $SelectedApplications
    }
    catch {
        Write-PSDWizardLog -Message "Error exporting applications: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        throw
    }
}

Function Get-PSDWizardSelectedApplications {
    <#
    .SYNOPSIS
        Retrieves selected applications from UI (optimized)
    .DESCRIPTION
        Gets the currently selected applications from the wizard UI with improved null handling
    .PARAMETER FieldObject
        The UI field object
    .PARAMETER InputObject
        Array of application objects
    .PARAMETER Identifier
        Property to use as identifier (default: GUID)
    .PARAMETER Passthru
        Return the full application objects
    .OUTPUTS
        Array of application GUIDs or objects
    .EXAMPLE
        $apps = Get-PSDWizardSelectedApplications -FieldObject $appList -InputObject $allApps
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        $FieldObject,

        [Parameter(Mandatory=$false)]
        $InputObject,

        [Parameter(Mandatory=$false)]
        [string]$Identifier = 'GUID',

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    $selectedApps = @()

    try {
        if ($null -eq $FieldObject) {
            Write-PSDWizardLog -Message "No field object provided" -LogLevel 2 -Component $FunctionName
            return $selectedApps
        }

        # Get selected items from UI control
        $selectedItems = $FieldObject.SelectedItems

        # if no items are selected, log and return an empty array
        if ($null -eq $selectedItems -or $selectedItems.Count -eq 0) {
            Write-PSDWizardLog -Message "No applications selected in UI" -Component $FunctionName
            return $selectedApps
        }

        # Process each selected item and extract the necessary information based on the Passthru switch and Identifier property
        foreach ($item in $selectedItems) {
            if ($Passthru) {
                $selectedApps += $item
            }
            else {
                # Extract identifier property
                if ($item.PSObject.Properties[$Identifier]) {
                    $selectedApps += $item.$Identifier
                }
            }
        }

        Write-PSDWizardLog -Message "Retrieved $($selectedApps.Count) selected applications" -Component $FunctionName
        return $selectedApps
    }
    catch {
        Write-PSDWizardLog -Message "Error retrieving selected applications: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        return @()
    }
}

Function Get-PSDWizardApplicationDependencies {
    <#
    .SYNOPSIS
        Resolves an application's dependency GUIDs recursively.
    .DESCRIPTION
        This function takes an application GUID and a list of application objects, and recursively resolves all dependency GUIDs for the specified application.
        It returns an array of GUIDs representing all resolved dependencies.
    .PARAMETER ApplicationGuid
        The GUID of the application for which to resolve dependencies.
    .PARAMETER Applications
        The list of application objects to search for dependencies.
    .EXAMPLE
        $dependencies = Get-PSDWizardApplicationDependencies -ApplicationGuid "dcc7f082-fa8b-4a3d-9765-923d594f9367" -Applications $allApplications
        This example retrieves all dependency GUIDs for the specified application.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$ApplicationGuid,

        [Parameter(Mandatory=$true)]
        [object[]]$Applications
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Resolving dependencies for application '$ApplicationGuid' against $(@($Applications).Count) catalog entries" -Component $FunctionName

    $byGuid = @{}
    # Build a lookup table by application GUID for quick access to application objects
    foreach ($application in @($Applications)) {
        if ($application.guid) { $byGuid[[string]$application.guid] = $application }
    }

    # Initialize collections for resolved dependencies, visited nodes, and the processing queue
    $resolved = [System.Collections.Generic.List[string]]::new()
    $visited = @{}
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue([string]$ApplicationGuid)

    # Process the queue to resolve all dependencies recursively
    while ($queue.Count -gt 0) {
        $currentGuid = [string]$queue.Dequeue()
        if ($visited.ContainsKey($currentGuid)) { continue }
        $visited[$currentGuid] = $true

        # Skip processing if the current GUID is not in the lookup table
        if (-not $byGuid.ContainsKey($currentGuid)) {
            Write-PSDWizardLog -Message "Dependency GUID '$currentGuid' was not found in the application catalog" -LogLevel 2 -Component $FunctionName
            continue
        }
        # Iterate over each dependency node for the current application
        foreach ($dependencyNode in @($byGuid[$currentGuid].SelectNodes('./Dependency'))) {
            # Extract the dependency GUID from the current dependency node
            $dependencyGuid = [string]$dependencyNode.InnerText
            if ([string]::IsNullOrWhiteSpace($dependencyGuid)) {
                Write-PSDWizardLog -Message "Application '$currentGuid' contains an empty dependency entry" -LogLevel 2 -Component $FunctionName
                continue
            }
            if ($visited.ContainsKey($dependencyGuid)) {
                Write-PSDWizardLog -Message "Skipping already visited dependency '$dependencyGuid' while resolving '$ApplicationGuid'" -Component $FunctionName
                continue
            }
            if (-not $resolved.Contains($dependencyGuid)) { $resolved.Add($dependencyGuid) }
            Write-PSDWizardLog -Message "Resolved dependency '$dependencyGuid' from '$currentGuid'" -Component $FunctionName
            $queue.Enqueue($dependencyGuid)
        }
    }

    Write-PSDWizardLog -Message "Resolved $($resolved.Count) dependencies for application '$ApplicationGuid'" -Component $FunctionName
    return [string[]]$resolved
}

Function Get-PSDWizardApplicationDisplayItems {
    <#
    .SYNOPSIS
        Builds application ListBox rows, including selected hidden dependencies.
    .DESCRIPTION
        Builds a collection of application display items for the ListBox, including handling selected hidden dependencies.
        The function takes a synchronization hash containing the application catalog and visible applications, a list of selected GUIDs, a list of mandatory GUIDs,
        and an optional dependency resolver script block. It returns an array of objects representing the display items for the ListBox.
    .PARAMETER SyncHash
        A hashtable containing the application catalog and visible applications.
    .PARAMETER SelectedGuids
        An array of GUIDs representing the initially selected applications.
    .PARAMETER MandatoryGuids
        An array of GUIDs representing applications that must always be selected.
    .PARAMETER DependencyResolver
        An optional script block used to resolve application dependencies.
    .EXAMPLE
        $displayItems = Get-PSDWizardApplicationDisplayItems -SyncHash $syncHash -SelectedGuids $selectedGuids -MandatoryGuids $mandatoryGuids -DependencyResolver $resolver
        This example retrieves the display items for the ListBox, including handling selected hidden dependencies.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$false)]
        [string[]]$SelectedGuids = @(),

        [Parameter(Mandatory=$false)]
        [string[]]$MandatoryGuids = @(),

        [Parameter(Mandatory=$false)]
        [scriptblock]$DependencyResolver
    )
    $FunctionName = $MyInvocation.MyCommand.Name
    # Initialize the display catalog with visible applications
    $catalog = @($SyncHash.ApplicationCatalog)
    $visible = @($SyncHash.Applications)
    Write-PSDWizardLog -Message "Building application display rows: catalog=$($catalog.Count), visible=$($visible.Count), selected=$(@($SelectedGuids).Count), mandatory=$(@($MandatoryGuids).Count)" -Component $FunctionName
    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Mark all selected and mandatory GUIDs as selected
    foreach ($guid in @($SelectedGuids) + @($MandatoryGuids)) {
        if (-not [string]::IsNullOrWhiteSpace($guid)) { [void]$selected.Add([string]$guid) }
    }

    # Initialize the set of required dependencies for the selected applications
    $requiredByBundle = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Iterate over each selected application to determine its dependencies
    foreach ($guid in @($selected)) {
        $application = @($catalog | Where-Object { [string]$_.guid -ieq $guid }) | Select-Object -First 1
        # Check if the application has any dependencies defined in the catalog
        if ($application -and @($application.SelectNodes('./Dependency')).Count -gt 0) {
            # Determine the dependencies for the current application either via the provided dependency resolver or the default method
            $dependencies = if ($DependencyResolver) {
                & $DependencyResolver -ApplicationGuid $guid -Applications $catalog
            }
            else {
                Get-PSDWizardApplicationDependencies -ApplicationGuid $guid -Applications $catalog
            }
            # Add each dependency to the selected set and mark it as required by the bundle
            foreach ($dependencyGuid in @($dependencies)) {
                [void]$selected.Add($dependencyGuid)
                [void]$requiredByBundle.Add($dependencyGuid)
            }
            Write-PSDWizardLog -Message "Application '$guid' contributed $(@($dependencies).Count) dependency selections" -Component $FunctionName
        }
    }

    # Bundle parents are selected from the dropdown; only normal apps and dependencies belong in the checklist.
    $bundleGuids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($application in $catalog) {
        if (@($application.SelectNodes('./Dependency')).Count -gt 0) {
            [void]$bundleGuids.Add([string]$application.guid)
        }
    }

    $displayCatalog = @($visible | Where-Object { -not $bundleGuids.Contains([string]$_.guid) })
    foreach ($guid in @($selected)) {
        # Retrieve the application object from the catalog based on the current GUID
        $application = @($catalog | Where-Object { [string]$_.guid -ieq $guid }) | Select-Object -First 1
        if ($application -and -not $bundleGuids.Contains([string]$application.guid) -and -not (@($displayCatalog | Where-Object { [string]$_.guid -ieq $guid }).Count)) {
            $displayCatalog += $application
        }
    }

    $hiddenDependencyCount = 0
    # Count and log hidden dependencies in the display catalog
    foreach ($application in $displayCatalog) {
        $isHiddenDependency = ([string]$application.hide -ieq 'True') -and $requiredByBundle.Contains([string]$application.guid)
        if ($isHiddenDependency) { $hiddenDependencyCount++ }
        Write-PSDWizardLog -Message "Application row '$($application.Name)': selected=$($selected.Contains([string]$application.guid)), hiddenDependency=$isHiddenDependency" -Component $FunctionName
        [PSCustomObject]@{
            guid = [string]$application.guid
            Name = [string]$application.Name
            DisplayName = if ($isHiddenDependency) { "$($application.Name) (required by bundle)" } else { [string]$application.Name }
            ShortName = if ($application.ShortName) { [string]$application.ShortName } else { [string]$application.Name }
            Version = if ($application.Version) { [string]$application.Version } else { '' }
            Publisher = if ($application.Publisher) { [string]$application.Publisher } else { '' }
            Selected = $selected.Contains([string]$application.guid)
            IsMandatory = $MandatoryGuids -contains [string]$application.guid
            IsRequiredDependency = $isHiddenDependency
            IsSelectable = -not $isHiddenDependency
        }
    }
    Write-PSDWizardLog -Message "Built $($displayCatalog.Count) application display rows; hidden dependency rows=$hiddenDependencyCount" -Component $FunctionName
}

#endregion

#region TASK SEQUENCE FUNCTIONS

Function Export-PSDWizardTaskSequence {
    <#
    .SYNOPSIS
        Exports task sequence selection to TSEnv (FIXED)
    .DESCRIPTION
        Handles task sequence selection including SkipTaskSequence logic.
        FIXED: Properly handles SkipTaskSequence=YES without causing restart
    .PARAMETER TaskSequenceID
        The selected task sequence ID
    .PARAMETER AllowSkip
        Allow skipping task sequence selection
    .OUTPUTS
        [string] The task sequence ID
    .EXAMPLE
        Export-PSDWizardTaskSequence -TaskSequenceID 'WIN11-001' -AllowSkip
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TaskSequenceID,

        [Parameter(Mandatory=$false)]
        [switch]$AllowSkip
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Exporting task sequence selection..." -Component $FunctionName

    try {
        # Check if skipping is enabled
        $skipTS = Get-PSDWizardTSEnvProperty -Name 'SkipTaskSequence' -ValueOnly

        if ($skipTS -eq 'YES') {
            Write-PSDWizardLog -Message "SkipTaskSequence=YES detected" -Component $FunctionName

            if ($AllowSkip) {
                # FIXED: Get default/existing TaskSequenceID instead of forcing selection
                $existingTS = Get-PSDWizardTSEnvProperty -Name 'TaskSequenceID' -ValueOnly

                # Check if there is an existing TaskSequenceID before deciding to skip
                if (-not [string]::IsNullOrWhiteSpace($existingTS)) {
                    Write-PSDWizardLog -Message "Using existing TaskSequenceID: $existingTS" -Component $FunctionName
                    return $existingTS
                }
                else {
                    Write-PSDWizardLog -Message "No existing TaskSequenceID, wizard will be skipped" -Component $FunctionName
                    return ""
                }
            }
        }

        # Validate TaskSequenceID if not skipping
        if ([string]::IsNullOrWhiteSpace($TaskSequenceID)) {
            if (-not $AllowSkip) {
                Write-PSDWizardLog -Message "No task sequence selected and skip not allowed" -LogLevel 2 -Component $FunctionName
                throw "Task Sequence must be selected"
            }
            else {
                Write-PSDWizardLog -Message "No task sequence selected, continuing..." -Component $FunctionName
                return ""
            }
        }

        # Set the task sequence ID
        Set-PSDWizardTSEnvProperty -Name 'TaskSequenceID' -Value $TaskSequenceID
        Write-PSDWizardLog -Message "TaskSequenceID set to: $TaskSequenceID" -Component $FunctionName

        return $TaskSequenceID
    }
    catch {
        Write-PSDWizardLog -Message "Error exporting task sequence: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        throw
    }
}

Function Start-PSDWizardSpinner {
    <#
    .SYNOPSIS
        Starts a small borderless window with a spinning ring on its own thread.
    .DESCRIPTION
        The wizard UI thread is blocked while task sequence rules are reprocessed, so nothing on that thread can animate.
        The ring is driven by a separate STA runspace with its own dispatcher and is controlled through flags in the
        returned synchronized hashtable (Show, Left, Top, Quit). The window is only shown on request.
    .OUTPUTS
        [hashtable] The control hashtable, or $null when the spinner could not be started
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    Param(
        [Parameter(Mandatory=$false)]
        [switch]$NoWait
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Initialize the synchronized hashtable for controlling the spinner window
    $spin = [hashtable]::Synchronized(@{ 
        Ready = $false
        Show = $false
        Visible = $false
        Quit = $false
        Angle = [double]0
        Left = [double]0
        Top = [double]0
        Error = $null
    })

    try {
        # Create and configure the STA runspace for the spinner window
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('spin', $spin)

        # Define the script block that will run in the STA runspace to create and manage the spinner window
        $spinnerScript = {
            try {
                [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework')
                [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')
                [void][System.Reflection.Assembly]::LoadWithPartialName('WindowsBase')

                # The ring is 43 wide so its 5 wide stroke fits inside the 48 wide window
                $ring = New-Object System.Windows.Shapes.Ellipse
                $ring.Width = 43
                $ring.Height = 43
                $ring.Stroke = [System.Windows.Media.Brushes]::White
                $ring.StrokeThickness = 5
                $ring.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('20,7')
                $ring.StrokeDashCap = [System.Windows.Media.PenLineCap]::Round
                $ring.HorizontalAlignment = 'Center'
                $ring.VerticalAlignment = 'Center'
                $ring.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
                $rotate = New-Object System.Windows.Media.RotateTransform
                $ring.RenderTransform = $rotate

                # Create the spinner window and configure its properties
                $window = New-Object System.Windows.Window
                $window.WindowStyle = 'None'
                $window.AllowsTransparency = $true
                $window.Background = [System.Windows.Media.Brushes]::Transparent
                $window.ShowInTaskbar = $false
                $window.ShowActivated = $false
                $window.Focusable = $false
                $window.Topmost = $true
                $window.ResizeMode = 'NoResize'
                $window.WindowStartupLocation = 'Manual'
                $window.Width = 48
                $window.Height = 48
                $window.Cursor = [System.Windows.Input.Cursors]::Wait
                $window.Content = $ring

                # Store the window and rotate transform in the synchronized hashtable for later control
                $spin.Window = $window
                $spin.Rotate = $rotate

                # A timer on this thread turns the ring and follows the flags set by the wizard thread
                $timer = New-Object System.Windows.Threading.DispatcherTimer
                $timer.Interval = [TimeSpan]::FromMilliseconds(33)
                $timer.Add_Tick({
                    try {
                        # Check if the spinner should quit and close the window if so
                        if ($spin.Quit) {
                            $spin.Window.Close()
                            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                            return
                        }
                        # Update the spinner window position and rotation if it should be shown
                        if ($spin.Show) {
                            if (-not $spin.Window.IsVisible) {
                                $spin.Window.Left = $spin.Left
                                $spin.Window.Top = $spin.Top
                                $spin.Window.Show()
                            }
                            $spin.Rotate.Angle = ($spin.Rotate.Angle + 14) % 360
                            $spin.Angle = $spin.Rotate.Angle
                            $spin.Visible = $true
                        }
                        elseif ($spin.Window.IsVisible) {
                            # Hide the spinner window when it should not be shown
                            $spin.Window.Hide()
                            $spin.Visible = $false
                        }
                    }
                    catch {
                        $spin.Error = $_.Exception.Message
                    }
                })
                $timer.Start()

                # Show the window once off-screen so WPF initializes now instead of on the first real use
                $window.Left = -10000
                $window.Top = -10000
                $window.Show()
                $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
                $window.Hide()

                $spin.Ready = $true
                [System.Windows.Threading.Dispatcher]::Run()
            }
            catch {
                $spin.Error = $_.Exception.Message
            }
        }

        $powerShell = [PowerShell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript($spinnerScript)
        $spin.Runspace = $runspace
        $spin.PowerShell = $powerShell
        $spin.Handle = $powerShell.BeginInvoke()

        # The caller can wait for the window itself (see Wait-PSDWizardSpinner)
        if ($NoWait) {
            return $spin
        }

        # Wait for the window to be built
        if (-not (Wait-PSDWizardSpinner -Spinner $spin)) {
            return $null
        }

        Write-PSDWizardLog -Message "Spinner window started" -Component $FunctionName
        return $spin
    }
    catch {
        Write-PSDWizardLog -Message "Unable to start the spinner window: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        return $null
    }
}

Function Wait-PSDWizardSpinner {
    <#
    .SYNOPSIS
        Waits until the spinner window thread is ready.
    .OUTPUTS
        [bool] True when the spinner is ready to be used
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Spinner
    )

    $timeout = [DateTime]::Now.AddSeconds(5)
    while (-not $Spinner.Ready -and -not $Spinner.Error -and [DateTime]::Now -lt $timeout) {
        Start-Sleep -Milliseconds 50
    }
    if (-not $Spinner.Ready) {
        Write-PSDWizardLog -Message "Spinner window did not start: $($Spinner.Error)" -LogLevel 2 -Component $MyInvocation.MyCommand.Name
        $Spinner.Quit = $true
        return $false
    }
    return $true
}

Function Close-PSDWizardSpinner {
    <#
    .SYNOPSIS
        Stops the spinner window thread started by Start-PSDWizardSpinner.
    .PARAMETER SyncHash
        The synchronized state hashtable holding the spinner
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $spin = $SyncHash.BusySpinner
    $SyncHash.BusySpinner = $null
    if (-not $spin) {
        return
    }

    try {
        $spin.Show = $false
        $spin.Quit = $true
        $timeout = [DateTime]::Now.AddSeconds(2)
        while ($spin.Handle -and -not $spin.Handle.IsCompleted -and [DateTime]::Now -lt $timeout) {
            Start-Sleep -Milliseconds 50
        }
        $spin.PowerShell.Dispose()
        $spin.Runspace.Close()
        $spin.Runspace.Dispose()
    }
    catch {
        Write-PSDWizardLog -Message "Error closing the spinner window: $($_.Exception.Message)" -LogLevel 2 -Component $MyInvocation.MyCommand.Name
    }
}

Function Set-PSDWizardBusyIndicator {
    <#
    .SYNOPSIS
        Shows or hides a busy overlay with a spinning ring over the whole wizard window.
    .DESCRIPTION
        The overlay is added to the window's root grid the first time it is used, so it works with every theme.
        The ring is drawn by a small window on its own thread (see Start-PSDWizardSpinner) because the UI thread
        cannot animate anything while it is busy. If that window cannot be started, a static ring is shown instead.
    .PARAMETER Window
        The wizard window
    .PARAMETER SyncHash
        The synchronized state hashtable, used to keep the overlay controls
    .PARAMETER Message
        The text shown under the ring
    .PARAMETER Hide
        Hide the overlay instead of showing it
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$false)]
        [string]$Message = 'Please wait...',

        [Parameter(Mandatory=$false)]
        [switch]$Hide
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    try {
        # Show the busy indicator while performing the operation
        $rootGrid = $Window.Content -as [System.Windows.Controls.Grid]
        if (-not $rootGrid) {
            return
        }

        # Initialize the busy indicator if it hasn't been created yet
        if (-not $SyncHash.BusyOverlay) {
            # Create the spinning ring for the busy indicator
            $ring = New-Object System.Windows.Shapes.Ellipse
            $ring.Width = 48
            $ring.Height = 48
            $ring.Stroke = [System.Windows.Media.Brushes]::White
            $ring.StrokeThickness = 5
            $ring.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('20,7')
            $ring.StrokeDashCap = [System.Windows.Media.PenLineCap]::Round
            $ring.HorizontalAlignment = 'Center'
            $ring.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
            $rotate = New-Object System.Windows.Media.RotateTransform
            $ring.RenderTransform = $rotate

            # Set the initial message for the busy indicator
            $text = New-Object System.Windows.Controls.TextBlock
            $text.Foreground = [System.Windows.Media.Brushes]::White
            $text.FontSize = 16
            $text.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)
            $text.HorizontalAlignment = 'Center'
            $text.TextAlignment = 'Center'

            # Create a panel to hold the busy indicator elements
            $panel = New-Object System.Windows.Controls.StackPanel
            $panel.HorizontalAlignment = 'Center'
            $panel.VerticalAlignment = 'Center'
            $panel.Children.Add($ring) | Out-Null
            $panel.Children.Add($text) | Out-Null

            # The translucent background also swallows mouse clicks on the controls underneath
            $overlay = New-Object System.Windows.Controls.Border
            $overlay.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(190, 0, 0, 0))
            $overlay.Visibility = 'Collapsed'
            $overlay.Child = $panel
            [System.Windows.Controls.Panel]::SetZIndex($overlay, 1000)
            $rootGrid.Children.Add($overlay) | Out-Null

            # Store references to the busy indicator elements in the sync hash
            $SyncHash.BusyOverlay = $overlay
            $SyncHash.BusyText = $text
            $SyncHash.BusyRotate = $rotate
            $SyncHash.BusyRing = $ring
        }

        # If hiding the busy indicator, stop the spinner window and collapse the overlay
        if ($Hide) {
            if ($SyncHash.BusySpinner) {
                $SyncHash.BusySpinner.Show = $false
                $timeout = [DateTime]::Now.AddMilliseconds(300)
                while ($SyncHash.BusySpinner.Visible -and [DateTime]::Now -lt $timeout) { Start-Sleep -Milliseconds 10 }
            }
            $SyncHash.BusyRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
            $SyncHash.BusyOverlay.Visibility = 'Collapsed'
            [System.Windows.Input.Mouse]::OverrideCursor = $null
        }
        else {
            # If showing the busy indicator, update the message and make the overlay visible
            $SyncHash.BusyText.Text = $Message

            # The ring inside the overlay is the fallback: it stays hidden while the spinner window (below) is used, so there is only one ring
            $useSpinnerWindow = $Window.IsVisible -and -not $SyncHash.BusySpinnerFailed
            $SyncHash.BusyRing.Visibility = if ($useSpinnerWindow) { 'Hidden' } else { 'Visible' }
            $SyncHash.BusyOverlay.Visibility = 'Visible'
            [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait

            # This ring only turns while the UI thread is free, it is the fallback for the spinner window below
            $duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(1))
            $animation = New-Object System.Windows.Media.Animation.DoubleAnimation ([double]0), ([double]360), $duration
            $animation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $SyncHash.BusyRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $animation)

            # Draw the overlay now, before the work that follows blocks the UI thread
            $Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

            # The UI thread cannot animate while it is blocked, so a separate window on its own thread turns the ring
            if ($useSpinnerWindow) {
                if (-not $SyncHash.BusySpinner) {
                    $SyncHash.BusySpinner = Start-PSDWizardSpinner
                    if (-not $SyncHash.BusySpinner) { $SyncHash.BusySpinnerFailed = $true }
                }
                $spinner = $SyncHash.BusySpinner
                if ($spinner -and -not (Wait-PSDWizardSpinner -Spinner $spinner)) {
                    # Started in the background when the wizard opened but never became ready
                    Close-PSDWizardSpinner -SyncHash $SyncHash
                    $SyncHash.BusySpinnerFailed = $true
                    $spinner = $null
                }
                if ($spinner) {
                    # Place the spinner window over the ring (device pixels to device independent units)
                    $SyncHash.BusyOverlay.UpdateLayout()
                    $screenPoint = $SyncHash.BusyRing.PointToScreen((New-Object System.Windows.Point(0, 0)))
                    $source = [System.Windows.PresentationSource]::FromVisual($SyncHash.BusyRing)
                    $position = $source.CompositionTarget.TransformFromDevice.Transform($screenPoint)
                    $spinner.Left = [double]$position.X
                    $spinner.Top = [double]$position.Y
                    $spinner.Show = $true

                    $timeout = [DateTime]::Now.AddMilliseconds(500)
                    while (-not $spinner.Visible -and [DateTime]::Now -lt $timeout) { Start-Sleep -Milliseconds 10 }
                }
                else {
                    # No spinner window, show the static ring so there is still something on screen
                    $SyncHash.BusyRing.Visibility = 'Visible'
                }
            }
        }
    }
    catch {
        Write-PSDWizardLog -Message "Unable to update the busy indicator: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

Function Update-PSDWizardTaskSequenceRules {
    <#
    .SYNOPSIS
        Applies the selected Task Sequence settings and refreshes dependent wizard state.
    .DESCRIPTION
        Reprocessing the CustomSettings rules can take a while, so a busy indicator is shown until it is done.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$TaskSequenceID,

        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )
    # Show the busy indicator while applying the task sequence settings
    Set-PSDWizardBusyIndicator -Window $Window -SyncHash $SyncHash -Message 'Grabbing task sequence properties...'
    try {
        # Apply the task sequence settings using the core function
        Update-PSDWizardTaskSequenceRulesCore -TaskSequenceID $TaskSequenceID -Window $Window -SyncHash $SyncHash
    }
    finally {
        # Hide the busy indicator after applying the task sequence settings
        Set-PSDWizardBusyIndicator -Window $Window -SyncHash $SyncHash -Hide

        # Let the debug console (when open) show what the selection changed
        Update-PSDWizardDebugConsole
    }
}

Function Update-PSDWizardTaskSequenceRulesCore {
    <#
    .SYNOPSIS
        Applies the selected Task Sequence settings and refreshes dependent wizard state.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$TaskSequenceID,

        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Load the custom settings from the specified path and prepare the rule settings for the given TaskSequenceID
    $customSettingsPath = Join-Path $SyncHash.ControlPath 'CustomSettings.ini'
    $customSettings = if (Test-Path -LiteralPath $customSettingsPath) {
        # Import the custom settings from the specified path
        Import-PSDWizardCustomSettings -Path $customSettingsPath
    }
    else {
        @{}
    }

    # Extract the rule settings for the specified TaskSequenceID from the custom settings
    $ruleSettings = $customSettings[$TaskSequenceID]
    $currentRuleProperties = if ($ruleSettings) { @($ruleSettings.Keys) } else { @() }

    # PSDGather owns rule processing. It may only be imported into the caller's scope, which this module cannot see.
    $invokeRule = $null
    $getSettings = $null
    if (-not $script:IsDevelopmentMode) {
        # Locate the PSDGather module, which owns the rule processing
        $gatherModule = Get-Module -Name PSDGather | Select-Object -First 1
        if (-not $gatherModule) {
            $gatherModule = Import-Module PSDGather -Global -PassThru -ErrorAction SilentlyContinue -Verbose:$false
        }
        if ($gatherModule) {
            $invokeRule = $gatherModule.ExportedCommands['Invoke-PSDRule']
            $getSettings = $gatherModule.ExportedCommands['Get-PSDSettings']
        }
        if (-not $invokeRule) { $invokeRule = Get-Command Invoke-PSDRule -ErrorAction SilentlyContinue }
        if (-not $getSettings) { $getSettings = Get-Command Get-PSDSettings -ErrorAction SilentlyContinue }
        # Do not clear the current settings if they cannot be gathered again
        if (-not $invokeRule -or -not (Get-Variable -Name iniFile -Scope Global -ValueOnly -ErrorAction SilentlyContinue)) {
            Write-PSDWizardLog -Message "PSDGather rules are not available (Invoke-PSDRule found: $([bool]$invokeRule)); settings for [$TaskSequenceID] were not reprocessed and the current settings are unchanged" -LogLevel 3 -Component $FunctionName
            Set-PSDWizardTSEnvProperty -Name 'TaskSequenceID' -Value $TaskSequenceID
            $SyncHash.TSEnvSettings['TaskSequenceID'] = $TaskSequenceID
            return
        }
    }

    # Determine the properties that need to be cleared from the task sequence environment.
    # Settings applied before the wizard opened (for example by a DefaultGateway rule that maps to a Task Sequence section) are not tracked,
    # so the properties of every Task Sequence section are treated as applied. That keeps settings meant for one Task Sequence from carrying over to another.
    $taskSequenceSectionProperties = @(foreach ($taskSequence in @($SyncHash.TaskSequences)) {
        $sectionSettings = $customSettings[[string]$taskSequence.ID]
        if ($sectionSettings) { $sectionSettings.Keys }
    })
    $propertiesToClear = @(@($SyncHash.TaskSequenceRuleProperties) + $taskSequenceSectionProperties + $currentRuleProperties |
        Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)

    # Numbered properties (DomainOUs001, ...) are cleared once per list, all other properties one by one
    $listNamesToClear = @($propertiesToClear | ForEach-Object {
        if ($_ -match '^(?<Name>.+?)\d{3}$') { $Matches['Name'] }
    } | Sort-Object -Unique)
    $plainPropertiesToClear = @($propertiesToClear | Where-Object { $_ -notmatch '^.+?\d{3}$' -and $_ -ne 'TaskSequenceID' })
    $currentListNames = @($currentRuleProperties | ForEach-Object {
        if ($_ -match '^(?<Name>.+?)\d{3}$') { $Matches['Name'] }
    } | Sort-Object -Unique)

    foreach ($listName in $listNamesToClear) {
        # Remove all task sequence environment properties that match the list name pattern
        Remove-PSDWizardTSEnvProperty -Name "$listName*" -WildCard
        # Clear the corresponding list from the TSEnvList drive if it exists
        if (-not $script:IsDevelopmentMode -and (Get-PSDrive -Name 'TSEnvList' -ErrorAction SilentlyContinue)) {
            Set-Item -LiteralPath "TSEnvList:\$listName" -Value @() -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($propertyName in $plainPropertiesToClear) {
        # Remove the property from the task sequence environment if it is not part of a numbered list
        Remove-PSDWizardTSEnvProperty -Name $propertyName
    }

    # Ensure the TaskSequenceID is set in the task sequence environment
    Set-PSDWizardTSEnvProperty -Name 'TaskSequenceID' -Value $TaskSequenceID

    # If in development mode, update the task sequence environment settings with the current rule properties
    if ($script:IsDevelopmentMode) {
        # Update the task sequence environment settings with the current rule properties in development mode
        foreach ($propertyName in $currentRuleProperties) {
            $SyncHash.TSEnvSettings[$propertyName] = $ruleSettings[$propertyName]
        }

        # Cleared properties the selected section does not set fall back to [Default] (first value wins, lists are replaced as a whole)
        $defaultRuleSettings = $customSettings['Default']
        foreach ($propertyName in @($defaultRuleSettings.Keys)) {
            if ($propertyName -match '^(?<Name>.+?)\d{3}$') {
                $restore = $Matches['Name'] -in $listNamesToClear -and $Matches['Name'] -notin $currentListNames
            }
            else {
                $restore = $propertyName -in $plainPropertiesToClear -and [string]::IsNullOrWhiteSpace([string]$SyncHash.TSEnvSettings[$propertyName])
            }
            if ($restore) {
                $SyncHash.TSEnvSettings[$propertyName] = $defaultRuleSettings[$propertyName]
            }
        }
    }
    # If not in development mode, let PSDGather reprocess the custom settings section for the TaskSequenceID
    else {
        Write-PSDWizardLog -Message "Reprocessing CustomSettings section [$TaskSequenceID]" -Component $FunctionName
        try {
            # Invoke the rule for the current TaskSequenceID to reprocess the custom settings section
            & $invokeRule -RuleName $TaskSequenceID
        }
        catch {
            Write-PSDWizardLog -Message "Invoke-PSDRule failed for [$TaskSequenceID]: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        }

        # Cleared properties the selected section does not set fall back to [Default]. Only those are processed, running the whole
        # section again would add its lists a second time. PSDGather keeps the rules: first value wins and tokens are resolved.
        try {
            $defaultSection = (Get-Variable -Name iniFile -Scope Global -ValueOnly -ErrorAction SilentlyContinue)['Default']
            if ($getSettings -and $defaultSection) {
                $fallbackSection = [ordered]@{}
                foreach ($propertyName in @($defaultSection.Keys)) {
                    if ($propertyName -match '^(?<Name>.+?)\d{3}$') {
                        $restore = $Matches['Name'] -in $listNamesToClear -and $Matches['Name'] -notin $currentListNames
                    }
                    else {
                        $restore = $propertyName -in $plainPropertiesToClear
                    }
                    if ($restore) { $fallbackSection[$propertyName] = $defaultSection[$propertyName] }
                }
                if ($fallbackSection.Count -gt 0) {
                    Write-PSDWizardLog -Message "Restoring $($fallbackSection.Count) [Default] values that [$TaskSequenceID] does not set" -Component $FunctionName
                    & $getSettings $fallbackSection
                }
            }
        }
        catch {
            Write-PSDWizardLog -Message "Unable to restore [Default] values after [$TaskSequenceID]: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        }

        # iterate over each key in the current task sequence environment settings and remove it
        foreach ($key in @($SyncHash.TSEnvSettings.Keys)) {
            $SyncHash.TSEnvSettings.Remove($key)
        }

        # iterate over each property in the current task sequence environment and rebuild the settings in the sync hash
        foreach ($property in @(Get-PSDWizardTSEnvProperty '*' -WildCard)) {
            if ($property.Name) {
                # Only include properties that have a valid name before adding them to the sync hash
                $SyncHash.TSEnvSettings[[string]$property.Name] = $property.Value
            }
        }
    }

    # update the script-level hash with the current rule properties and task sequence environment settings
    $SyncHash.TaskSequenceRuleProperties = $currentRuleProperties
    $SyncHash.TSEnvSettings['TaskSequenceID'] = $TaskSequenceID
    $SyncHash.TSEnvLists = Get-PSDWizardTSEnvLists -TSEnvSettings $SyncHash.TSEnvSettings
    Write-PSDWizardLog -Message "Lists after applying [$TaskSequenceID]: $((@($SyncHash.TSEnvLists.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, @($SyncHash.TSEnvLists[$_]).Count }) -join ', '))" -Component $FunctionName

    # iterate through the UI elements that correspond to TSEnv settings and update their values accordingly
    foreach ($entry in @($SyncHash.UIElements.GetEnumerator() | Where-Object { $_.Key -like 'TSEnv_*' })) {
        $propertyName = ([string]$entry.Key).Substring('TSEnv_'.Length)
        # Retrieve the value for the current property from the task sequence environment settings, or use an empty string if not present
        $value = if ($SyncHash.TSEnvSettings.ContainsKey($propertyName)) {
            $SyncHash.TSEnvSettings[$propertyName]
        }
        else {
            ''
        }
        # if the value is an array, join its elements into a comma-separated string
        if ($value -is [array]) {
            $value = $value -join ', '
        }
        # Update the UI element with the corresponding TSEnv setting value
        switch ($entry.Value.GetType().Name) {
            'PasswordBox' {
                $entry.Value.Password = [string]$value
                # A password supplied by CustomSettings/TSEnv is already confirmed (MDT has no confirm box)
                if ($entry.Key -eq 'TSEnv_AdminPassword') {
                    $adminConfirmBox = $Window.FindName('_ConfirmAdminPassword')
                    if ($adminConfirmBox) { $adminConfirmBox.Password = [string]$value }
                }
                elseif ($entry.Key -eq 'TSEnv_DomainAdminPassword') {
                    $domainConfirmBox = $Window.FindName('_DomainAdminConfirmPassword')
                    if ($domainConfirmBox) { $domainConfirmBox.Password = [string]$value }
                }
            }
            'Label' { $entry.Value.Content = [string]$value }
            default {
                if ($entry.Value.PSObject.Properties['Text']) {
                    $entry.Value.Text = [string]$value
                }
            }
        }
    }

    # Iterate over each list name that needs to be cleared and remove its items from the corresponding UI list control
    foreach ($listName in $listNamesToClear) {
        $listControl = Get-PSDWizardListControl -Window $Window -SyncHash $SyncHash -ListName $listName
        # Skip processing if the list control is not found or does not have an 'Items' property
        if ($listControl -and $listControl.PSObject.Properties['Items']) {
            $listControl.Items.Clear()
        }
    }

    # Repopulate the numbered TSEnv lists with the updated values
    foreach ($listName in $SyncHash.TSEnvLists.Keys) {
        $listControl = Get-PSDWizardListControl -Window $Window -SyncHash $SyncHash -ListName $listName
        # Skip processing if the list control is not found or does not have an 'Items' property
        if (-not $listControl -or -not $listControl.PSObject.Properties['Items']) {
            continue
        }
        # Clear the existing items in the list control before adding the updated values
        $listControl.Items.Clear()
        foreach ($value in $SyncHash.TSEnvLists[$listName]) {
            $listControl.Items.Add($value) | Out-Null
        }
    }

    # Show the device details page
    $deviceDetailsPage = $Window.FindName('_wizDeviceDetails')
    if ($deviceDetailsPage) {
        $deviceDetailsPage.Visibility = 'Visible'
    }
    # Save the current JoinDomain and JoinWorkgroup settings to script-level variables for later use
    $script:SavedJoinDomain = [string]$SyncHash.TSEnvSettings['JoinDomain']
    $script:SavedJoinWorkgroup = [string]$SyncHash.TSEnvSettings['JoinWorkgroup']
    $domainRadio = $Window.FindName('_JoinDomainRadio')
    $workgroupRadio = $Window.FindName('_JoinWorkgroupRadio')
    $domainGrid = $Window.FindName('_grdJoinDomain')
    $workgroupGrid = $Window.FindName('_grdJoinWorkgroup')

    # Handle the visibility and selection of the domain and workgroup radio buttons and their corresponding grids based on saved settings
    if ($domainRadio -and -not [string]::IsNullOrWhiteSpace($script:SavedJoinDomain)) {
        $domainRadio.IsChecked = $true
        if ($domainGrid) { $domainGrid.Visibility = 'Visible' }
        if ($workgroupGrid) { $workgroupGrid.Visibility = 'Collapsed' }
    }
    elseif ($workgroupRadio -and -not [string]::IsNullOrWhiteSpace($script:SavedJoinWorkgroup)) {
        $workgroupRadio.IsChecked = $true
        if ($domainGrid) { $domainGrid.Visibility = 'Collapsed' }
        if ($workgroupGrid) { $workgroupGrid.Visibility = 'Visible' }
    }

    # Handle the DomainOUs list and MachineObjectOU text box visibility and values
    $ouValues = @($SyncHash.TSEnvLists['DomainOUs'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $ouList = $Window.FindName('TSEnvList_DomainOUs')
    $ouText = $Window.FindName('TSEnv_MachineObjectOU')
    # If there are multiple OU values, show the list; otherwise, show the text box for a single OU value
    if ($ouValues.Count -gt 1 -and $ouList) {
        $ouList.Items.Insert(0, '<Not specified>')
        $ouList.SelectedIndex = 0
        $ouList.Visibility = 'Visible'
        if ($ouText) { $ouText.Visibility = 'Hidden' }
    }
    else {
        # If there is only one OU value, set it in the text box and update the corresponding TSEnv setting
        if ($ouList) { $ouList.Visibility = 'Hidden' }
        if ($ouText) {
            $ouText.Text = if ($ouValues.Count -eq 1) { [string]$ouValues[0] } else { '' }
            $ouText.Visibility = 'Visible'
        }
        # Update the TSEnv setting for the machine object OU if there is exactly one OU value
        if ($ouValues.Count -eq 1) {
            $SyncHash.TSEnvSettings['MachineObjectOU'] = [string]$ouValues[0]
            Set-PSDWizardTSEnvProperty -Name 'MachineObjectOU' -Value ([string]$ouValues[0])
        }
    }

    # Handle the Applications and MandatoryApplications sections, including the visibility and selection of applications in the UI
    $sectionApplicationKeys = @($currentRuleProperties | Where-Object { $_ -match '^(Applications|MandatoryApplications)\d{3}$' })
    $selectedApplicationGuids = @($currentRuleProperties | Where-Object { $_ -match '^Applications\d{3}$' } | ForEach-Object { [string]$ruleSettings[$_] } | Where-Object { $_ })
    $mandatoryApplicationGuids = @($currentRuleProperties | Where-Object { $_ -match '^MandatoryApplications\d{3}$' } | ForEach-Object { [string]$ruleSettings[$_] } | Where-Object { $_ })
    $visibleApplicationGuids = @($selectedApplicationGuids + $mandatoryApplicationGuids | Select-Object -Unique)
    # Store the mandatory application GUIDs and the visible applications in the script-level hash for later use
    $SyncHash.MandatoryApplicationGuids = $mandatoryApplicationGuids
    $visibleCatalog = if ($SyncHash.VisibleApplicationCatalog) { @($SyncHash.VisibleApplicationCatalog) } else { @($SyncHash.ApplicationCatalog | Where-Object { $_.hide -ne 'True' }) }
    $SyncHash.Applications = if ($sectionApplicationKeys.Count -gt 0) {
        @($SyncHash.ApplicationCatalog | Where-Object { $_.guid -in $visibleApplicationGuids })
    }
    else {
        $visibleCatalog
    }

    # Find the application control in the UI and update its items based on the current application catalog and visibility settings
    $applicationControl = @('_appTabList', '_appTabDatagrid', '_lstApplications', 'TSEnv_Applications', '_dgApplications') | ForEach-Object {
        $Window.FindName($_)
    } | Where-Object { $_ } | Select-Object -First 1

    # If an application control is found, refresh its items to reflect the current application catalog and visibility settings
    if ($applicationControl) {
        $SyncHash.IsRefreshingTaskSequenceRules = $true
        try {
            # Clear the existing items in the application control before adding the updated items
            $applicationControl.ItemsSource = $null
            $applicationControl.Items.Clear()
            if ($applicationControl.GetType().Name -eq 'ListBox') {
                $displayItems = @(Get-PSDWizardApplicationDisplayItems -SyncHash $SyncHash -SelectedGuids $visibleApplicationGuids -MandatoryGuids $mandatoryApplicationGuids)
                foreach ($item in $displayItems) {
                    $applicationControl.Items.Add($item) | Out-Null
                    if ($item.Selected) { $applicationControl.SelectedItems.Add($item) | Out-Null }
                }
            }
            else {
                # Add each application from the catalog to the application control, marking it as selected if it is visible
                foreach ($application in $SyncHash.Applications) {
                # Create a new item for the application control based on the current application and its visibility status
                $item = [PSCustomObject]@{
                    guid = $application.guid
                    Name = $application.Name
                    ShortName = if ($application.ShortName) { $application.ShortName } else { $application.Name }
                    Version = if ($application.Version) { $application.Version } else { '' }
                    Publisher = if ($application.Publisher) { $application.Publisher } else { '' }
                    IsMandatory = $application.guid -in $mandatoryApplicationGuids
                }
                # Add the new item to the application control and select it if it is visible
                    $applicationControl.Items.Add($item) | Out-Null
                    if ($item.guid -in $visibleApplicationGuids) {
                        $applicationControl.SelectedItems.Add($item) | Out-Null
                    }
                }
            }
        }
        finally {
            $SyncHash.IsRefreshingTaskSequenceRules = $false
        }
    }
    # Update dependent control selections based on the current state
    Update-PSDWizardDependentControlSelections -Window $Window -SyncHash $SyncHash
    # Update the visibility of all pages and initialize the role feature list based on the current state
    Update-PSDWizardPageVisibility -Window $Window -SyncHash $SyncHash
    # Initialize the role feature list based on the current state
    Initialize-PSDWizardRoleFeatureList -Window $Window -SyncHash $SyncHash

    Write-PSDWizardLog -Message "Task Sequence '$TaskSequenceID' rules applied; JoinDomain=$(-not [string]::IsNullOrWhiteSpace($script:SavedJoinDomain)), JoinWorkgroup=$(-not [string]::IsNullOrWhiteSpace($script:SavedJoinWorkgroup)), OUs=$($ouValues.Count), Applications=$($SyncHash.Applications.Count)" -Component $FunctionName
}

#endregion

#region SPLASHSCREEN FUNCTIONS

#region DEBUG CONSOLE FUNCTIONS

Function ConvertTo-PSDWizardDebugText {
    <#
    .SYNOPSIS
        Formats a task sequence value for the debug console and masks passwords.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        $Value
    )

    if ($Name -match 'password|pwd|secret') {
        if ([string]::IsNullOrEmpty([string]$Value)) { return '' }
        return '********'
    }
    if ($Value -is [array]) {
        return (@($Value | ForEach-Object { [string]$_ }) -join '; ')
    }
    return [string]$Value
}

Function Get-PSDWizardDebugLiveVariable {
    <#
    .SYNOPSIS
        Reads every variable from the TSEnv: drive without writing to the wizard log.
    .OUTPUTS
        [hashtable] Available (bool) and Variables (name to value)
    #>
    [CmdletBinding()]
    Param()

    $variables = @{}
    $available = $false
    if (-not $script:IsDevelopmentMode -and (Get-PSDrive -Name 'TSEnv' -ErrorAction SilentlyContinue)) {
        try {
            foreach ($item in @(Get-ChildItem -Path 'TSEnv:' -ErrorAction Stop)) {
                if ($item.Name) { $variables[[string]$item.Name] = $item.Value }
            }
            $available = $true
        }
        catch {
            $available = $false
        }
    }
    return @{ Available = $available; Variables = $variables }
}

Function Get-PSDWizardDebugVariableRow {
    <#
    .SYNOPSIS
        Builds the rows of the TSEnv: tab: the live TSEnv: value, the wizard's snapshot of it and what changed.
    .DESCRIPTION
        State is 'differs' when the wizard's snapshot no longer matches TSEnv:, and 'changed' or 'new' when the value changed since
        the previous refresh (kept until the changes are cleared).
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $ctx = $SyncHash.DebugConsole
    $live = Get-PSDWizardDebugLiveVariable
    $snapshot = $SyncHash.TSEnvSettings
    if (-not $snapshot) { $snapshot = @{} }

    $names = @(@($live.Variables.Keys) + @($snapshot.Keys) + $(if ($ctx.Baseline) { @($ctx.Baseline.Keys) }) | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $firstRefresh = $null -eq $ctx.Baseline
    $baseline = @{}

    $rows = foreach ($name in $names) {
        $liveRaw = if ($live.Available -and $live.Variables.ContainsKey($name)) { ConvertTo-PSDWizardDebugText -Name '' -Value $live.Variables[$name] } else { '' }
        $snapshotRaw = if ($snapshot.ContainsKey($name)) { ConvertTo-PSDWizardDebugText -Name '' -Value $snapshot[$name] } else { '' }
        $current = if ($live.Available) { $liveRaw } else { $snapshotRaw }
        $baseline[$name] = $current

        # Remember what changed since the previous refresh until the changes are cleared
        if (-not $firstRefresh) {
            if ($ctx.Baseline.ContainsKey($name)) {
                if ($ctx.Baseline[$name] -ne $current) {
                    $ctx.Changes[$name] = if ([string]::IsNullOrEmpty($current)) { 'removed' } else { 'changed' }
                }
            }
            elseif (-not [string]::IsNullOrEmpty($current)) {
                $ctx.Changes[$name] = 'new'
            }
        }

        $state = ''
        if ($live.Available -and $liveRaw -ne $snapshotRaw) { $state = 'differs' }
        elseif ($ctx.Changes.ContainsKey($name)) { $state = $ctx.Changes[$name] }

        [pscustomobject]@{
            Name     = $name
            Live     = if ($live.Available) { ConvertTo-PSDWizardDebugText -Name $name -Value $liveRaw } else { '(TSEnv: not available)' }
            Snapshot = ConvertTo-PSDWizardDebugText -Name $name -Value $snapshotRaw
            State    = $state
        }
    }
    $ctx.Baseline = $baseline
    return @($rows)
}

Function Get-PSDWizardDebugListRow {
    <#
    .SYNOPSIS
        Builds the rows of the Lists tab: what the wizard built for its dropdowns next to what the TSEnvList: drive returns.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $driveLists = @{}
    $driveAvailable = $false
    if (-not $script:IsDevelopmentMode -and (Get-PSDrive -Name 'TSEnvList' -ErrorAction SilentlyContinue)) {
        try {
            foreach ($item in @(Get-ChildItem -Path 'TSEnvList:' -ErrorAction Stop)) {
                if ($item.Name) { $driveLists[[string]$item.Name] = @($item.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }
            }
            $driveAvailable = $true
        }
        catch {
            $driveAvailable = $false
        }
    }

    $wizardLists = if ($SyncHash.TSEnvLists) { $SyncHash.TSEnvLists } else { @{} }
    $names = @(@($wizardLists.Keys) + @($driveLists.Keys) | ForEach-Object { [string]$_ } | Sort-Object -Unique)

    $rows = foreach ($name in $names) {
        $wizardValues = @($wizardLists[$name])
        $driveValues = @($driveLists[$name])
        $state = ''
        # Applications are not built into dropdown lists, so they are not compared
        if ($driveAvailable -and $name -notin @('Applications', 'MandatoryApplications') -and $wizardValues.Count -ne $driveValues.Count) {
            $state = 'differs'
        }
        $shown = if ($wizardValues.Count -gt 0) { $wizardValues } else { $driveValues }
        [pscustomobject]@{
            List   = $name
            Wizard = $wizardValues.Count
            Drive  = if ($driveAvailable) { $driveValues.Count } else { 'n/a' }
            Values = (@($shown | ForEach-Object { [string]$_ }) -join '; ')
            State  = $state
        }
    }
    return @($rows)
}

Function Get-PSDWizardDebugStateText {
    <#
    .SYNOPSIS
        Summarizes the wizard's own state for the Wizard state tab.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $add = { param($label, $value) $lines.Add(('{0,-30} {1}' -f $label, $value)) }

    & $add 'Module version' $script:ModuleVersion
    & $add 'Development mode' $script:IsDevelopmentMode
    & $add 'Theme / language' "$($SyncHash.Theme) / $($SyncHash.Language)"
    & $add 'Resource path' $SyncHash.ResourcePath
    & $add 'Control path' $SyncHash.ControlPath
    & $add 'TaskSequenceID (snapshot)' ([string]$SyncHash.TSEnvSettings['TaskSequenceID'])
    if (-not $script:IsDevelopmentMode -and (Get-PSDrive -Name 'TSEnv' -ErrorAction SilentlyContinue)) {
        & $add 'TaskSequenceID (TSEnv:)' ([string](Get-Item -Path 'TSEnv:\TaskSequenceID' -ErrorAction SilentlyContinue).Value)
    }
    & $add 'Task sequences loaded' @($SyncHash.TaskSequences).Count
    & $add 'Applications shown' @($SyncHash.Applications).Count
    & $add 'Mandatory application GUIDs' (@($SyncHash.MandatoryApplicationGuids) -join ', ')
    & $add 'TSEnv settings in snapshot' @($SyncHash.TSEnvSettings.Keys).Count
    & $add 'Lists built' (@($SyncHash.TSEnvLists.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, @($SyncHash.TSEnvLists[$_]).Count }) -join ', ')
    & $add 'Keys applied by last TS' (@($SyncHash.TaskSequenceRuleProperties) -join ', ')
    & $add 'Spinner window' $(if ($SyncHash.BusySpinnerFailed) { 'failed' } elseif ($SyncHash.BusySpinner) { 'running' } else { 'not started' })

    $lines.Add('')
    $lines.Add('Pages')
    $tabControl = $SyncHash.Window.FindName('_wizTabControl')
    if ($tabControl) {
        foreach ($item in $tabControl.Items) {
            $lines.Add(('  {0,-26} {1,-14} {2}' -f ([string]$item.Header), $item.Visibility, $(if ($item.IsSelected) { '<- current' } else { '' })))
        }
    }
    return ($lines -join "`r`n")
}

Function Get-PSDWizardDebugLogLine {
    <#
    .SYNOPSIS
        Returns the log lines for the Log tab, either from this wizard session or from the PSD log file.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$Source = 'session',

        [Parameter(Mandatory=$false)]
        [string]$Filter = ''
    )

    $lines = @()
    if ($Source -like 'PSD*') {
        $logPath = Get-Variable -Name PSDLogPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($logPath -and (Test-Path -LiteralPath $logPath)) {
            $lines = @(Get-Content -LiteralPath $logPath -Tail 400 -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_ -match '<!\[LOG\[(?<m>.*?)\]LOG\]!><time="(?<t>[^"]{8})[^"]*".*?type="(?<ty>\d)"') {
                    $level = switch ($Matches['ty']) { '2' { 'WARN' } '3' { 'ERROR' } default { 'INFO' } }
                    '{0} {1,-5} {2}' -f $Matches['t'], $level, $Matches['m']
                }
                else { $_ }
            })
        }
        else {
            $lines = @("The PSD log file was not found ($logPath).")
        }
    }
    else {
        $lines = @($script:PSDWizardLogBuffer | Select-Object -Last 400)
    }

    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $lines = @($lines | Where-Object { $_ -like "*$Filter*" })
    }
    return $lines
}

Function Update-PSDWizardDebugConsole {
    <#
    .SYNOPSIS
        Refreshes the debug console. Does nothing when the console is not open.
    .DESCRIPTION
        Called when a tab is selected, from the Refresh button and after a task sequence selection, so the tabs follow what the wizard does.
    #>
    [CmdletBinding()]
    Param()

    $SyncHash = $script:PSDWizardSyncHash
    $ctx = if ($SyncHash) { $SyncHash.DebugConsole } else { $null }
    if (-not $ctx -or -not $ctx.Window -or -not $ctx.Window.IsVisible) {
        return
    }

    try {
        # The variables are read on every refresh so changes are noticed even while another tab is shown
        $variableRows = @(Get-PSDWizardDebugVariableRow -SyncHash $SyncHash)
        $selected = [string]$ctx.Tabs.SelectedItem.Name

        switch ($selected) {
            'tabVariables' {
                $filter = $ctx.VariableFilter.Text
                $rows = @($variableRows | Where-Object {
                    ([string]::IsNullOrWhiteSpace($filter) -or $_.Name -like "*$filter*" -or $_.Live -like "*$filter*" -or $_.Snapshot -like "*$filter*") -and
                    (-not $ctx.OnlyChanged.IsChecked -or $_.State)
                })
                $ctx.VariableGrid.ItemsSource = $rows
                $ctx.Status.Text = "$($rows.Count) of $($variableRows.Count) variables, $(@($variableRows | Where-Object State).Count) changed or differing"
            }
            'tabLists' {
                $rows = @(Get-PSDWizardDebugListRow -SyncHash $SyncHash)
                $ctx.ListGrid.ItemsSource = $rows
                $ctx.Status.Text = "$($rows.Count) lists"
            }
            'tabState' {
                $ctx.StateText.Text = Get-PSDWizardDebugStateText -SyncHash $SyncHash
                $ctx.Status.Text = 'Wizard state'
            }
            'tabLog' {
                $lines = @(Get-PSDWizardDebugLogLine -Source ([string]$ctx.LogSource.SelectedItem) -Filter $ctx.LogFilter.Text)
                $ctx.LogText.Text = $lines -join "`r`n"
                $ctx.LogText.ScrollToEnd()
                $ctx.Status.Text = "$($lines.Count) log lines"
            }
            default {
                $ctx.Status.Text = 'Run a command in the wizard session. $SyncHash is the wizard state, $Window the wizard window.'
            }
        }
    }
    catch {
        $ctx.Status.Text = "Refresh failed: $($_.Exception.Message)"
    }
}

Function Invoke-PSDWizardDebugCommand {
    <#
    .SYNOPSIS
        Runs a command in the wizard's own session and shows the output in the console tab.
    .DESCRIPTION
        The command runs on the wizard thread, so it sees the same TSEnv: and TSEnvList: drives, modules and state as the wizard.
        The wizard waits while it runs. $SyncHash (wizard state) and $Window (wizard window) are available to the command.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$Command
    )

    $SyncHash = $script:PSDWizardSyncHash
    $ctx = if ($SyncHash) { $SyncHash.DebugConsole } else { $null }
    if (-not $ctx -or [string]::IsNullOrWhiteSpace($Command)) {
        return
    }

    $Window = $SyncHash.Window
    $ctx.History.Add($Command) | Out-Null
    $ctx.HistoryIndex = $ctx.History.Count

    $started = Get-Date
    try {
        # A script block keeps error messages about the command itself and still sees $SyncHash and $Window
        $text = & ([scriptblock]::Create($Command)) *>&1 | Out-String -Width 200
    }
    catch {
        $text = ($_ | Out-String)
    }
    $elapsed = ((Get-Date) - $started).TotalMilliseconds

    $ctx.Output.AppendText("PS> $Command`r`n$text`r`n")
    if ($ctx.Output.Text.Length -gt 60000) {
        $ctx.Output.Text = $ctx.Output.Text.Substring($ctx.Output.Text.Length - 40000)
    }
    $ctx.Output.ScrollToEnd()
    $ctx.Status.Text = ('Ran in {0:N0} ms' -f $elapsed)
}

Function Save-PSDWizardDebugSnapshot {
    <#
    .SYNOPSIS
        Writes the variables, lists, wizard state and log of the debug console to a text file next to the PSD logs.
    .OUTPUTS
        [string] The path of the snapshot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    Param()

    $SyncHash = $script:PSDWizardSyncHash
    $logPath = Get-Variable -Name PSDLogPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $folder = if ($logPath) { Split-Path -Parent $logPath } else { $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) { $folder = $env:TEMP }
    $path = Join-Path $folder ('PSDWizard_Debug_{0:yyyyMMdd_HHmmss}.txt' -f (Get-Date))

    $sections = @()
    $sections += '===== Wizard state ====='
    $sections += Get-PSDWizardDebugStateText -SyncHash $SyncHash
    $sections += ''
    $sections += '===== Lists ====='
    $sections += (Get-PSDWizardDebugListRow -SyncHash $SyncHash | Format-Table List, Wizard, Drive, State, Values -AutoSize -Wrap | Out-String -Width 250)
    $sections += '===== TSEnv: variables ====='
    $sections += (Get-PSDWizardDebugVariableRow -SyncHash $SyncHash | Format-Table Name, Live, Snapshot, State -AutoSize -Wrap | Out-String -Width 250)
    $sections += '===== Wizard log (this session) ====='
    $sections += (Get-PSDWizardDebugLogLine -Source 'session') -join "`r`n"

    Set-Content -LiteralPath $path -Value ($sections -join "`r`n") -Encoding UTF8
    return $path
}

Function Show-PSDWizardDebugConsole {
    <#
    .SYNOPSIS
        Opens the debug console next to the wizard, or brings it to the front when it is already open.
    #>
    [CmdletBinding()]
    Param()

    $FunctionName = $MyInvocation.MyCommand.Name
    $SyncHash = $script:PSDWizardSyncHash
    if (-not $SyncHash -or -not $SyncHash.Window) {
        return
    }

    if ($SyncHash.DebugConsole -and $SyncHash.DebugConsole.Window -and $SyncHash.DebugConsole.Window.IsVisible) {
        $SyncHash.DebugConsole.Window.Activate() | Out-Null
        Update-PSDWizardDebugConsole
        return
    }

    try {
        $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSD Wizard Debug Console" Width="860" Height="540" ShowInTaskbar="False" Topmost="True"
        WindowStartupLocation="Manual" FontFamily="Segoe UI" FontSize="12">
    <DockPanel>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="6">
            <Button x:Name="btnRefresh" Content="Refresh" Width="80" Margin="0,0,6,0"/>
            <Button x:Name="btnClearChanges" Content="Clear changes" Width="100" Margin="0,0,6,0"/>
            <Button x:Name="btnSave" Content="Save snapshot" Width="100" Margin="0,0,10,0"/>
            <TextBlock x:Name="txtStatus" VerticalAlignment="Center" Foreground="Gray"/>
        </StackPanel>
        <TabControl x:Name="tabs" Margin="6,0,6,6">
            <TabItem Header="TSEnv:" x:Name="tabVariables">
                <DockPanel>
                    <DockPanel DockPanel.Dock="Top" Margin="0,6">
                        <TextBlock Text="Filter" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <CheckBox x:Name="chkOnlyChanged" Content="Only changed or differing" DockPanel.Dock="Right" Margin="8,0,0,0" VerticalAlignment="Center"/>
                        <TextBox x:Name="txtVariableFilter"/>
                    </DockPanel>
                    <DataGrid x:Name="gridVariables" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="210"/>
                            <DataGridTextColumn Header="TSEnv: (live)" Binding="{Binding Live}" Width="*"/>
                            <DataGridTextColumn Header="Wizard snapshot" Binding="{Binding Snapshot}" Width="*"/>
                            <DataGridTextColumn Header="State" Binding="{Binding State}" Width="70"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>
            <TabItem Header="Lists" x:Name="tabLists">
                <DataGrid x:Name="gridLists" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal" Margin="0,6,0,0">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="List" Binding="{Binding List}" Width="170"/>
                        <DataGridTextColumn Header="Wizard" Binding="{Binding Wizard}" Width="60"/>
                        <DataGridTextColumn Header="TSEnvList:" Binding="{Binding Drive}" Width="80"/>
                        <DataGridTextColumn Header="Values" Binding="{Binding Values}" Width="*"/>
                        <DataGridTextColumn Header="State" Binding="{Binding State}" Width="70"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
            <TabItem Header="Wizard state" x:Name="tabState">
                <TextBox x:Name="txtState" IsReadOnly="True" FontFamily="Consolas, Lucida Console, Courier New" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="0,6,0,0"/>
            </TabItem>
            <TabItem Header="Log" x:Name="tabLog">
                <DockPanel>
                    <DockPanel DockPanel.Dock="Top" Margin="0,6">
                        <ComboBox x:Name="cmbLogSource" DockPanel.Dock="Right" Width="190" Margin="8,0,0,0">
                            <ComboBoxItem Content="This wizard session" IsSelected="True"/>
                            <ComboBoxItem Content="PSD log file (tail)"/>
                        </ComboBox>
                        <TextBlock Text="Filter" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBox x:Name="txtLogFilter"/>
                    </DockPanel>
                    <TextBox x:Name="txtLog" IsReadOnly="True" FontFamily="Consolas, Lucida Console, Courier New" FontSize="11" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                </DockPanel>
            </TabItem>
            <TabItem Header="Console" x:Name="tabConsole">
                <Grid Margin="0,6,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBox x:Name="txtOutput" IsReadOnly="True" FontFamily="Consolas, Lucida Console, Courier New" Background="#1E1E1E" Foreground="#DCDCDC" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                    <DockPanel Grid.Row="1" Margin="0,6,0,0">
                        <Button x:Name="btnClearOutput" Content="Clear" Width="60" DockPanel.Dock="Right" Margin="6,0,0,0"/>
                        <Button x:Name="btnRun" Content="Run" Width="60" DockPanel.Dock="Right" Margin="6,0,0,0"/>
                        <TextBlock Text="PS&gt;" VerticalAlignment="Center" FontFamily="Consolas, Lucida Console, Courier New" Margin="0,0,6,0"/>
                        <TextBox x:Name="txtInput" FontFamily="Consolas, Lucida Console, Courier New"/>
                    </DockPanel>
                </Grid>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
'@
        $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
        $window.Owner = $SyncHash.Window

        # Place it beside the wizard, inside the work area
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $window.Left = [Math]::Max(0, [Math]::Min($workArea.Width - $window.Width, $SyncHash.Window.Left + 30))
        $window.Top = [Math]::Max(0, [Math]::Min($workArea.Height - $window.Height, $SyncHash.Window.Top + 30))

        # The handlers below run after this function returned, so they reach the controls through the shared state
        $SyncHash.DebugConsole = @{
            Window         = $window
            Tabs           = $window.FindName('tabs')
            Status         = $window.FindName('txtStatus')
            VariableGrid   = $window.FindName('gridVariables')
            VariableFilter = $window.FindName('txtVariableFilter')
            OnlyChanged    = $window.FindName('chkOnlyChanged')
            ListGrid       = $window.FindName('gridLists')
            StateText      = $window.FindName('txtState')
            LogText        = $window.FindName('txtLog')
            LogFilter      = $window.FindName('txtLogFilter')
            LogSource      = $window.FindName('cmbLogSource')
            Output         = $window.FindName('txtOutput')
            Input          = $window.FindName('txtInput')
            Baseline       = $null
            Changes        = @{}
            History        = New-Object 'System.Collections.Generic.List[string]'
            HistoryIndex   = 0
        }
        $ctx = $SyncHash.DebugConsole

        $window.FindName('btnRefresh').Add_Click({ Update-PSDWizardDebugConsole })
        $window.FindName('btnClearChanges').Add_Click({
            $script:PSDWizardSyncHash.DebugConsole.Changes = @{}
            Update-PSDWizardDebugConsole
        })
        $window.FindName('btnSave').Add_Click({
            $savedPath = Save-PSDWizardDebugSnapshot
            $script:PSDWizardSyncHash.DebugConsole.Status.Text = "Saved $savedPath"
        })
        $ctx.Tabs.Add_SelectionChanged({
            param($sender, $e)
            # Selection events of controls inside a tab bubble up, only react to the tab itself
            if ($e.OriginalSource -is [System.Windows.Controls.TabControl]) { Update-PSDWizardDebugConsole }
        })
        $ctx.VariableFilter.Add_TextChanged({ Update-PSDWizardDebugConsole })
        $ctx.OnlyChanged.Add_Click({ Update-PSDWizardDebugConsole })
        $ctx.LogFilter.Add_TextChanged({ Update-PSDWizardDebugConsole })
        $ctx.LogSource.Add_SelectionChanged({
            param($sender, $e)
            Update-PSDWizardDebugConsole
        })

        # Color the rows that changed or differ
        $colorRow = {
            param($sender, $e)
            $state = [string]$e.Row.Item.State
            $e.Row.Background = switch ($state) {
                'differs' { [System.Windows.Media.Brushes]::MistyRose }
                'changed' { [System.Windows.Media.Brushes]::LightGoldenrodYellow }
                'new'     { [System.Windows.Media.Brushes]::Honeydew }
                'removed' { [System.Windows.Media.Brushes]::Lavender }
                default   { [System.Windows.Media.Brushes]::White }
            }
        }
        $ctx.VariableGrid.Add_LoadingRow($colorRow)
        $ctx.ListGrid.Add_LoadingRow($colorRow)

        # Console input: Enter runs the command, Up and Down walk through the history
        $ctx.Input.Add_PreviewKeyDown({
            param($sender, $e)
            $console = $script:PSDWizardSyncHash.DebugConsole
            switch ($e.Key) {
                'Return' {
                    $e.Handled = $true
                    $command = $sender.Text
                    $sender.Clear()
                    Invoke-PSDWizardDebugCommand -Command $command
                }
                'Up' {
                    $e.Handled = $true
                    if ($console.HistoryIndex -gt 0) { $console.HistoryIndex--; $sender.Text = $console.History[$console.HistoryIndex]; $sender.CaretIndex = $sender.Text.Length }
                }
                'Down' {
                    $e.Handled = $true
                    if ($console.HistoryIndex -lt $console.History.Count - 1) { $console.HistoryIndex++; $sender.Text = $console.History[$console.HistoryIndex]; $sender.CaretIndex = $sender.Text.Length }
                    else { $console.HistoryIndex = $console.History.Count; $sender.Clear() }
                }
            }
        })
        $window.FindName('btnRun').Add_Click({
            $console = $script:PSDWizardSyncHash.DebugConsole
            $command = $console.Input.Text
            $console.Input.Clear()
            Invoke-PSDWizardDebugCommand -Command $command
            $console.Input.Focus() | Out-Null
        })
        $window.FindName('btnClearOutput').Add_Click({ $script:PSDWizardSyncHash.DebugConsole.Output.Clear() })
        $window.Add_Closed({ $script:PSDWizardSyncHash.DebugConsole = $null })

        $ctx.Output.Text = ("Commands run in the wizard session, so TSEnv: and TSEnvList: show what the wizard sees.`r`n" +
            "`$SyncHash is the wizard state and `$Window the wizard window. Examples:`r`n" +
            "  Get-ChildItem tsenv: | Sort-Object Name`r`n  (Get-Item tsenvlist:DomainOUs).Value`r`n  `$SyncHash.TSEnvLists`r`n`r`n")

        $window.Add_ContentRendered({ Update-PSDWizardDebugConsole })
        $window.Show()
        Write-PSDWizardLog -Message "Debug console opened" -Component $FunctionName
    }
    catch {
        Write-PSDWizardLog -Message "Unable to open the debug console: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        $SyncHash.DebugConsole = $null
    }
}

Function Initialize-PSDWizardDebugButton {
    <#
    .SYNOPSIS
        Shows the theme's Debug Console button (_wizDebugConsole) when debug is on (PSDDebug=YES, -Debug or development mode).
    .DESCRIPTION
        The button is part of each theme's template so it can be styled with the theme; it stays hidden until debug is on.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    if (-not $SyncHash.DebugMode) {
        return
    }

    $FunctionName = $MyInvocation.MyCommand.Name
    $button = $Window.FindName('_wizDebugConsole')
    if (-not $button) {
        Write-PSDWizardLog -Message "Debug is on but theme '$($SyncHash.Theme)' has no _wizDebugConsole button, add it to the theme's template to use the debug console" -LogLevel 2 -Component $FunctionName
        return
    }

    $button.Visibility = 'Visible'
    $button.Add_Click({ Show-PSDWizardDebugConsole })
    Write-PSDWizardLog -Message "Debug console button shown" -Component $FunctionName
}

#endregion

Function Show-PSDWizardSplashScreen {
    <#
    .SYNOPSIS
        Shows the wizard splashscreen in a runspace
    .DESCRIPTION
        Displays an animated splashscreen while the wizard initializes.
        Runs in a separate STA runspace for responsiveness.
    .PARAMETER Theme
        The theme name (Classic, Dark, Modern, etc.)
    .PARAMETER Language
        The language code (default: en-US)
    .OUTPUTS
        [hashtable] Synchronized hashtable with runspace references
    .EXAMPLE
        $splash = Show-PSDWizardSplashScreen -Theme 'Modern' -Language 'en-US'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$Theme = 'Classic',

        [Parameter(Mandatory=$false)]
        [string]$Language = 'en-US'
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Starting splashscreen..." -Component $FunctionName

    # Create synchronized hashtable
    $syncHash = [hashtable]::Synchronized(@{})
    $syncHash.Theme = $Theme
    $syncHash.Language = $Language

    # Create runspace
    $PSDRunSpace = [runspacefactory]::CreateRunspace()
    $syncHash.Runspace = $PSDRunSpace
    $PSDRunSpace.ApartmentState = "STA"
    $PSDRunSpace.ThreadOptions = "ReuseThread"
    $PSDRunSpace.Open() | Out-Null
    $PSDRunSpace.SessionStateProxy.SetVariable("syncHash", $syncHash)

    # Splashscreen scriptblock
    $splashScript = {
        [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework')

        # Theme colors
        $themeConfig = switch ($syncHash.Theme) {
            'Classic' { @{ BG='#004275'; FG='#ffffff'; State='Normal'; Width='600'; WinBG='#004275' } }
            'Dark'    { @{ BG='#343447'; FG='#A0A0A0'; State='Normal'; Width='600'; WinBG='#343447' } }
            'Modern'  { @{ BG='#004275'; FG='#FFE8EDF9'; State='Maximized'; Width='1024'; WinBG='#1f1f1f' } }
            default   { @{ BG='#004275'; FG='#ffffff'; State='Normal'; Width='600'; WinBG='#004275' } }
        }

        # Language strings
        $langStrings = switch ($syncHash.Language) {
            'en-US' { @{ Title='Loading PSD Wizard...'; Status='Please wait...' } }
            default { @{ Title='Loading PSD Wizard...'; Status='Please wait...' } }
        }

        # XAML template
        $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowState="Normal" ResizeMode="NoResize" WindowStyle="None"
        Title="Splashscreen" WindowStartupLocation="CenterScreen"
        Background="$($themeConfig.WinBG)" Height="180" Width="$($themeConfig.Width)">
    <Grid Background="$($themeConfig.BG)">
        <StackPanel Orientation="Vertical" Width="500" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Label x:Name="lblTitle" Content="$($langStrings.Title)" Foreground="$($themeConfig.FG)" Height="70" FontSize="30"/>
            <ProgressBar x:Name="ProgressBar" Height="20" IsIndeterminate="False" Value="0" Foreground="$($themeConfig.FG)"/>
            <TextBox x:Name="txtStatus" Text="$($langStrings.Status)" HorizontalContentAlignment="Left"
                     BorderThickness="0" Background="$($themeConfig.BG)" Foreground="$($themeConfig.FG)"
                     FontSize="16" Margin="10,5,0,0" IsEnabled="False"/>
        </StackPanel>
    </Grid>
</Window>
"@
        # Load the XAML into a WPF window object
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $syncHash.window = [Windows.Markup.XamlReader]::Load($reader)

        # Store controls
        $syncHash.ProgressBar = $syncHash.window.FindName('ProgressBar')
        $syncHash.txtStatus = $syncHash.window.FindName('txtStatus')
        $syncHash.lblTitle = $syncHash.window.FindName('lblTitle')

        # Window events
        $syncHash.Window.Add_Loaded({ $syncHash.isLoaded = $true })
        $syncHash.Window.Add_Closing({ $syncHash.isClosing = $true })
        $syncHash.Window.Add_Closed({ $syncHash.isClosed = $true })

        # Keep splashscreen on top while launching
        $syncHash.Window.Topmost = $true
        $syncHash.Window.ShowDialog()
        $syncHash.Error = $Error
    }

    # Start runspace
    $Pwshell = [PowerShell]::Create()
    $Pwshell.AddScript($splashScript) | Out-Null
    $Pwshell.Runspace = $PSDRunSpace
    $AsyncHandle = $Pwshell.BeginInvoke()
    $syncHash.PowerShell = $Pwshell
    $syncHash.AsyncHandle = $AsyncHandle

    # Wait for window to actually load before returning
    $timeout = 0
    while (-not $syncHash.isLoaded -and $timeout -lt 50) {
        Start-Sleep -Milliseconds 100
        $timeout++
    }

    if ($syncHash.Error) {
        Write-PSDWizardLog -Message "Splashscreen error: $($syncHash.Error)" -LogLevel 3 -Component $FunctionName
    }
    else {
        Write-PSDWizardLog -Message "Splashscreen started successfully" -Component $FunctionName
    }

    return $syncHash
}

Function Close-PSDWizardSplashScreen {
    <#
    .SYNOPSIS
        Closes the splashscreen runspace
    .DESCRIPTION
        Properly disposes of splashscreen window and runspace resources
    .PARAMETER Runspace
        The splashscreen synchronized hashtable from Show-PSDWizardSplashScreen
    .EXAMPLE
        Close-PSDWizardSplashScreen -Runspace $splash
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [hashtable]$Runspace
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Attempt to close the splashscreen window and dispose of associated runspace resources
    try {
        # Check if the splashscreen runspace and window are valid before attempting to close it
        if ($null -ne $Runspace -and -not $Runspace.RunspaceDisposed -and $null -ne $Runspace.window) {
            $Runspace.window.Dispatcher.Invoke([action]{
                $Runspace.window.Close()
            }, "Normal")

            # End the asynchronous invocation and dispose of the PowerShell instance if they exist
            if ($Runspace.PowerShell -and $Runspace.AsyncHandle) {
                $null = $Runspace.PowerShell.EndInvoke($Runspace.AsyncHandle)
                $Runspace.PowerShell.Dispose()
            }
            # Close and dispose of the runspace if it exists
            if ($Runspace.Runspace) {
                $Runspace.Runspace.Close()
                $Runspace.Runspace.Dispose()
            }
            # Mark the runspace as disposed to prevent further operations on it
            $Runspace.RunspaceDisposed = $true

            Write-PSDWizardLog -Message "Splashscreen closed" -Component $FunctionName
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error closing splashscreen: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

Function Update-PSDWizardProgressBar {
    <#
    .SYNOPSIS
        Updates the splashscreen progress bar
    .DESCRIPTION
        Updates progress status, percentage, or switches between determinate/indeterminate modes
    .PARAMETER Runspace
        The splashscreen synchronized hashtable
    .PARAMETER PercentComplete
        Progress percentage (0-100)
    .PARAMETER Step
        Current step number
    .PARAMETER MaxSteps
        Total number of steps
    .PARAMETER Indeterminate
        Switch to indeterminate mode
    .PARAMETER Status
        Status message to display
    .PARAMETER Color
        Progress bar color (default: uses theme color)
    .EXAMPLE
        Update-PSDWizardProgressBar -Runspace $splash -Status "Loading resources..." -PercentComplete 50
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Runspace,

        [Parameter(Mandatory=$false)]
        [ValidateRange(0,100)]
        [int]$PercentComplete,

        [Parameter(Mandatory=$false)]
        [int]$Step,

        [Parameter(Mandatory=$false)]
        [int]$MaxSteps,

        [Parameter(Mandatory=$false)]
        [switch]$Indeterminate,

        [Parameter(Mandatory=$false)]
        [string]$Status,

        [Parameter(Mandatory=$false)]
        [string]$Color
    )

    $FunctionName = $MyInvocation.MyCommand.Name

    # Ensure that the runspace and its window are valid before attempting to update the progress bar
    try {
        if ($null -eq $Runspace -or $null -eq $Runspace.window) {
            return
        }

        # Invoke the update on the UI thread to ensure thread safety
        $Runspace.window.Dispatcher.Invoke([action]{
            # Update progress mode
            if ($Indeterminate) {
                $Runspace.ProgressBar.IsIndeterminate = $true
            }
            else {
                $Runspace.ProgressBar.IsIndeterminate = $false
                # If PercentComplete is not specified, but Step and MaxSteps are, calculate the percentage based on the current step and total steps
                if ($PSBoundParameters.ContainsKey('PercentComplete')) {
                    $Runspace.ProgressBar.Value = $PercentComplete
                }
                elseif ($PSBoundParameters.ContainsKey('Step') -and $PSBoundParameters.ContainsKey('MaxSteps')) {
                    $percent = [math]::Round(($Step / $MaxSteps) * 100)
                    $Runspace.ProgressBar.Value = $percent
                }
            }

            # Update status text
            if (-not [string]::IsNullOrWhiteSpace($Status)) {
                $Runspace.txtStatus.Text = $Status
            }

            # Update color if specified
            if (-not [string]::IsNullOrWhiteSpace($Color)) {
                $Runspace.ProgressBar.Foreground = $Color
            }

            # Force UI to refresh/render the changes
            $Runspace.ProgressBar.UpdateLayout()
        }, "Normal")

        # Small delay to allow UI thread to process and render the changes
        Start-Sleep -Milliseconds 100

        Write-PSDWizardLog -Message "Progress updated: $Status" -Component $FunctionName
    }
    catch {
        Write-PSDWizardLog -Message "Error updating progress: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

#endregion

#region UI BUILDER FUNCTIONS

Function Format-PSDWizard {
    <#
    .SYNOPSIS
        Builds XAML UI dynamically from definition and theme files
    .DESCRIPTION
        Generates complete WPF XAML from language definitions and theme templates.
        Processes conditions, replaces placeholders, and merges all UI components.
    .PARAMETER ResourcePath
        Path to wizard resources folder
    .PARAMETER LangDefinition
        XML language definition document
    .PARAMETER ThemeDefinition
        XML theme definition document
    .PARAMETER TSEnvSettings
        Hashtable of TSEnvironment settings (optional for condition evaluation)
    .PARAMETER OrgName
        Organization name for branding
    .PARAMETER Passthru
        Return XAML as string instead of XML object
    .OUTPUTS
        [xml] or [string] Complete XAML UI
    .EXAMPLE
        $langXml = [xml](Get-Content "$path\PSDWizard_Definitions_en-US.xml")
        $themeXml = [xml](Get-Content "$path\Themes\Classic_Theme_Definitions_en-US.xml")
        $xaml = Format-PSDWizard -ResourcePath $path -LangDefinition $langXml -ThemeDefinition $themeXml
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePath,

        [Parameter(Mandatory=$true)]
        [xml]$LangDefinition,

        [Parameter(Mandatory=$true)]
        [xml]$ThemeDefinition,

        [Parameter(Mandatory=$false)]
        [hashtable]$TSEnvSettings = @{},

        [Parameter(Mandatory=$false)]
        [string]$OrgName = "Organization",

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Building wizard UI from definitions..." -Component $FunctionName

    try {
        # Build resource paths
        $themePath = Join-Path $ResourcePath 'Themes'
        $resourceFiles = Join-Path $ResourcePath 'Resources'

        # Get theme files
        $templateFile = Get-PSDWizardThemeDefinition -Xml $ThemeDefinition -Section 'ThemeTemplate'
        $welcomeFile = Get-PSDWizardThemeDefinition -Xml $ThemeDefinition -Section 'WelcomeWizard'
        $paneTemplate = Get-PSDWizardThemeDefinition -Xml $ThemeDefinition -Section 'PanesTemplate'

        # Build full paths for the theme files
        $templatePath = Join-Path $themePath $templateFile
        $welcomePath = Join-Path $themePath $welcomeFile

        if (-not (Test-Path $templatePath)) {
            throw "Template file not found: $templatePath"
        }

        Write-PSDWizardLog -Message "Loading template: $templateFile" -Component $FunctionName

        # Load main template
        # Read the XAML content from the template file into a string variable
        $xamlContent = Get-Content $templatePath -Raw
        $xamlContent = $xamlContent -replace 'mc:Ignorable="d"', '' -replace 'x:N', 'N' -replace '^<Win.*', '<Window'

        # Process Welcome Wizard
        $welcomeElement = Get-PSDWizardDefinitions -Xml $LangDefinition -Section 'WelcomeWizard'
        $startPageContent = ''

        # Check if the welcome element exists and the welcome page file is available before processing it
        if ($welcomeElement -and (Test-Path $welcomePath)) {
            $skipSettings = $TSEnvSettings.Keys | Where-Object { $_ -like 'Skip*' }
            $condition = $welcomeElement.Condition.'#cdata-section'

            # Evaluate the condition to determine if the welcome page should be displayed
            if (Get-PSDWizardCondition -Condition $condition -TSEnvSettings $TSEnvSettings) {
                Write-PSDWizardLog -Message "Loading welcome page" -Component $FunctionName
                $startPageContent = Get-Content $welcomePath -Raw

                # Extract the main title and subtitle from the welcome element and replace placeholders in the start page content
                $mainTitle = ($welcomeElement.MainTitle.'#cdata-section' -replace '"', '').Trim()
                $subTitle = ($welcomeElement.SubTitle.'#cdata-section' -replace '"', '').Trim()

                $startPageContent = $startPageContent -replace '@MainTitle', $mainTitle
                $startPageContent = $startPageContent -replace '@SubTitle', $subTitle
                $startPageContent = $startPageContent -replace '@ORG', $OrgName
            }
            else {
                Write-PSDWizardLog -Message "Welcome page skipped by condition" -Component $FunctionName
            }
        }

        # Replace the start page placeholder in the main XAML content with the actual start page content
        $xamlContent = $xamlContent -replace '@StartPage', $startPageContent

        # Update resource paths in the XAML content to point to the correct files
        [xml]$xmlTemp = $xamlContent
        $mergedDictionaries = $xmlTemp.Window.'Window.Resources'.ResourceDictionary.'ResourceDictionary.MergedDictionaries'.ResourceDictionary.Source

        # Check if there are any merged dictionaries to process
        if ($mergedDictionaries) {
            $resources = Get-ChildItem $resourceFiles -Filter *.xaml -ErrorAction SilentlyContinue

            # iterate through each merged dictionary and map it to the corresponding resource file if available
            foreach ($source in $mergedDictionaries) {
                $fileName = Split-Path $source -Leaf
                $resourceFile = $resources | Where-Object { $_.Name -eq $fileName } | Select-Object -First 1
                # If a corresponding resource file is found, update the XAML content to reference its full path
                if ($resourceFile) {
                    $xamlContent = $xamlContent -replace [regex]::Escape($source), $resourceFile.FullName
                    Write-PSDWizardLog -Message "Mapped resource: $fileName" -Component $FunctionName
                }
            }
        }

        # Process Panes (Tabs)
        $paneElements = Get-PSDWizardDefinitions -Xml $LangDefinition -Section 'Pane'
        $tabItems = ''
        $tabCount = 0
        $deferredPaneIds = @()
        $taskSequenceSeen = $false
        $interactiveTaskSequence = [string]$TSEnvSettings['SkipTaskSequence'] -ine 'YES'

        # Initialize tab items and count before processing each pane
        foreach ($pane in $paneElements) {
            if ([string]$pane.id -eq 'TaskSequence') {
                $taskSequenceSeen = $true
            }

            # Keep later panes available for condition reevaluation after an interactive TS choice.
            $deferConditions = $taskSequenceSeen -and ([string]$pane.id -ne 'TaskSequence') -and $interactiveTaskSequence
            $include = $true
            if (-not $deferConditions) {
                foreach ($condition in ($pane.Condition.'#cdata-section' | Where-Object { $_ })) {
                    if (-not (Get-PSDWizardCondition -Condition $condition -TSEnvSettings $TSEnvSettings)) {
                        $include = $false
                        Write-PSDWizardLog -Message "Pane '$($pane.Title)' excluded by condition" -Component $FunctionName
                        break
                    }
                }
            }

            if (-not $include) { continue }

            # Get pane definition
            $paneTheme = Get-PSDWizardThemeDefinition -Xml $ThemeDefinition -Section 'Pane' | Where-Object { $_.id -eq $pane.id }

            if (-not $paneTheme -or -not $paneTheme.reference) {
                Write-PSDWizardLog -Message "No theme definition for pane: $($pane.id)" -LogLevel 2 -Component $FunctionName
                continue
            }
            # Construct the full path to the pane file based on the theme reference
            $panePath = Join-Path $themePath $paneTheme.reference

            if (-not (Test-Path $panePath)) {
                Write-PSDWizardLog -Message "Pane file not found: $panePath" -LogLevel 2 -Component $FunctionName
                continue
            }

            # Increment the tab count and log the loading of the pane
            $tabCount++
            Write-PSDWizardLog -Message "Loading pane $tabCount : $($pane.Title)" -Component $FunctionName

            # Load pane content
            $paneContent = Get-Content $panePath -Raw

            # Merge with template
            $tabContent = $paneTemplate -replace '@TabItemContent', $paneContent

            # Replace placeholders
            # Extract titles, context, and help information from the pane and replace placeholders in the tab content
            $tabTitle = $pane.Title
            $mainTitle = ($pane.MainTitle.'#cdata-section' -replace '@ORG', $OrgName -replace '"', '').Trim()
            $subTitle = ($pane.SubTitle.'#cdata-section' -replace '@ORG', $OrgName -replace '"', '').Trim()
            $context = ($pane.Context.'#cdata-section' -replace '"', '').Trim()
            $help = ($pane.Help.'#cdata-section' -replace '"', '').Trim()

            # Replace placeholders in the tab content with the extracted information
            $tabContent = $tabContent -replace '@TabTitle', $tabTitle
            $tabContent = $tabContent -replace '@MainTitle', $mainTitle
            $tabContent = $tabContent -replace '@SubTitle', $subTitle
            $tabContent = $tabContent -replace '@Context', $context
            $tabContent = $tabContent -replace '@Help', $help
            $tabContent = $tabContent -replace '@ORG', $OrgName

            # Apply theme properties for the first tab, such as the starting margin
            if ($tabCount -eq 1) {
                $startMargin = Get-PSDWizardThemeDefinition -Xml $ThemeDefinition -Section 'PaneStartingMargin'
                if ($startMargin) {
                    $tabContent = $tabContent -replace '@margin', $startMargin
                }
            }

            # Replace any remaining theme properties
            $pattern = [regex]'@\w+'
            $matches = $pattern.Matches($tabContent)

            # Iterate through all matches of theme property placeholders in the tab content
            foreach ($match in $matches) {
                $property = $match.Value.TrimStart('@')
                $value = $paneTheme.$property

                # If a value for the theme property is found, replace the placeholder in the tab content
                if ($value) {
                    $tabContent = $tabContent -replace $match.Value, $value
                }
            }

            if ($deferConditions) {
                $deferredPaneIds += [string]$pane.id
            }

            # Append the processed tab content to the collection of tab items
            $tabItems += $tabContent
        }

        Write-PSDWizardLog -Message "Generated $tabCount panes" -Component $FunctionName

        # Insert tabs into template
        $xamlContent = $xamlContent -replace '@TabItems', $tabItems

        # Clean up XAML
        $xamlContent = $xamlContent -replace 'x:N', 'N' -replace '^<Win.*', '<Window'
        $xamlContent = $xamlContent -replace 'Click="[^"]*"', ''
        $xamlContent = $xamlContent -replace 'x:Class="[^"]*"', ''

        # Convert to XML
        [xml]$xamlUI = $xamlContent
        if ($deferredPaneIds.Count -gt 0) {
            $xamlNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml'
            foreach ($paneId in $deferredPaneIds) {
                foreach ($tabNode in $xamlUI.GetElementsByTagName('TabItem')) {
                    if ($tabNode.GetAttribute('Name') -eq "_wiz$paneId") {
                        $tabNode.SetAttribute('Visibility', 'Collapsed')
                        break
                    }
                }
            }
        }

        Write-PSDWizardLog -Message "XAML generation complete" -Component $FunctionName

        if ($Passthru) {
            return $xamlUI.OuterXml
        }
        else {
            return $xamlUI
        }
    }
    catch {
        Write-PSDWizardLog -Message "Error building XAML: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        throw
    }
}

Function Get-PSDWizardVisibleTabIndices {
    <#
    .SYNOPSIS
        Returns the indexes of panes that are currently visible.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TabControl]$TabControl
    )

    $visibleIndices = @()
    for ($index = 0; $index -lt $TabControl.Items.Count; $index++) {
        if ($TabControl.Items[$index].Visibility -ne [System.Windows.Visibility]::Collapsed) {
            $visibleIndices += $index
        }
    }

    return [int[]]$visibleIndices
}

Function Update-PSDWizardNavigationState {
    <#
    .SYNOPSIS
        Updates Back, Next, and Finish state for the visible wizard panes.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TabControl]$TabControl
    )

    $visibleTabIndices = @(Get-PSDWizardVisibleTabIndices -TabControl $TabControl)
    $currentVisiblePosition = [array]::IndexOf([int[]]$visibleTabIndices, [int]$TabControl.SelectedIndex)
    $isLastVisibleTab = ($visibleTabIndices.Count -gt 0) -and ($currentVisiblePosition -eq ($visibleTabIndices.Count - 1))
    $nextButton = $Window.FindName('_wizNext')
    $finishButton = $Window.FindName('_wizFinish')
    $backButton = $Window.FindName('_wizBack')

    if ($backButton) {
        $backButton.Visibility = if ($currentVisiblePosition -le 0) { 'Hidden' } else { 'Visible' }
    }

    if ($isLastVisibleTab) {
        if ($script:useNextAsFinish -and $nextButton) {
            $nextButton.Content = 'Finish'
        }
        elseif ($finishButton) {
            if ($nextButton) { $nextButton.Visibility = 'Collapsed' }
            $finishButton.Visibility = 'Visible'
        }
    }
    else {
        if ($script:useNextAsFinish -and $nextButton) {
            $nextButton.Content = 'Next'
            $nextButton.Visibility = 'Visible'
        }
        if ($finishButton) {
            $finishButton.Visibility = 'Collapsed'
        }
    }
}

Function Test-PSDWizardPageValidation {
    <#
    .SYNOPSIS
        Validates the active wizard page before navigation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.TabItem]$Page,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $pageId = $Page.Name -replace '^_wiz', ''
    $validationMessages = [System.Collections.Generic.List[string]]::new()

    $skipReadinessValidation = $false
    if ($pageId -eq 'Readiness' -and $SyncHash.TSEnvSettings) {
        $skipReadinessValidation = $SyncHash.TSEnvSettings['SkipReadinessCheck'] -ieq 'YES' -or
            $SyncHash.TSEnvSettings['PSDReadinessAllowBypass'] -ieq 'YES' -or
            $SyncHash.TSEnvSettings['PSDReadinessAllowBypass'] -ieq 'True'
    }

    if (-not $skipReadinessValidation -and $SyncHash.PaneValidations -and $SyncHash.PaneValidations.ContainsKey($pageId)) {
        foreach ($condition in $SyncHash.PaneValidations[$pageId]) {
            if (-not (Get-PSDWizardCondition -Condition $condition -TSEnvSettings $SyncHash.TSEnvSettings)) {
                $validationMessages.Add("A validation check failed on the $($Page.Header) page.")
            }
        }
    }

    switch ($pageId) {
        'Readiness' {
            if (-not $skipReadinessValidation -and $SyncHash.ContainsKey('ReadinessChecksPassed') -and -not $SyncHash.ReadinessChecksPassed) {
                $validationMessages.Add('One or more readiness checks failed. Review the results before continuing.')
            }
        }
        'TaskSequence' {
            $taskSequenceId = if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey('TaskSequenceID')) {
                [string]$SyncHash.TSEnvSettings['TaskSequenceID']
            }
            else {
                ''
            }
            if ([string]::IsNullOrWhiteSpace($taskSequenceId)) {
                $taskSequenceControl = $Window.FindName('TSEnv_TaskSequenceID')
                if ($taskSequenceControl) { $taskSequenceId = [string]$taskSequenceControl.Text }
            }
            if ([string]::IsNullOrWhiteSpace($taskSequenceId)) {
                $validationMessages.Add('You must select a Task Sequence before continuing.')
            }
        }
        'DeviceDetails' {
            $computerNameControl = $Window.FindName('TSEnv_OSDComputerName')
            if ($computerNameControl -and -not (Invoke-PSDWizardFieldValidation -Window $Window -ControlName 'TSEnv_OSDComputerName' -ValidationCanvasName '_detTabValidation_Name')) {
                $validationMessages.Add('Please correct the computer name before continuing.')
            }

            $domainRadio = $Window.FindName('_JoinDomainRadio')
            if ($domainRadio -and $domainRadio.IsChecked -eq $true) {
                if (-not (Confirm-PSDWizardDomainRequirements -Window $Window -ValidationCanvasName '_detTabValidation2_Name')) {
                    $validationMessages.Add('Please complete the domain join details before continuing.')
                }
            }
            else {
                $workgroupControl = $Window.FindName('TSEnv_JoinWorkgroup')
                if ($workgroupControl -and -not (Invoke-PSDWizardFieldValidation -Window $Window -ControlName 'TSEnv_JoinWorkgroup' -ValidationCanvasName '_detTabValidation2_Name')) {
                    $validationMessages.Add('Please correct the workgroup name before continuing.')
                }
            }
        }
        'AdminAccount' {
            $adminPasswordControl = $Window.FindName('TSEnv_AdminPassword')
            $confirmPasswordControl = $Window.FindName('_ConfirmAdminPassword')
            $passwordValidationOutput = $Window.FindName('_admTabValidation_Name')
            if ($adminPasswordControl -and $confirmPasswordControl -and $passwordValidationOutput -and -not (Confirm-PSDWizardPassword -PasswordObject $adminPasswordControl -ConfirmedPasswordObject $confirmPasswordControl -OutputObject $passwordValidationOutput -Passthru)) {
                $validationMessages.Add('Please enter and confirm the same administrator password, or leave both fields blank.')
            }
        }
    }

    [pscustomobject]@{
        IsValid = ($validationMessages.Count -eq 0)
        Message = ($validationMessages -join [Environment]::NewLine)
    }
}

Function Invoke-PSDWizard {
    <#
    .SYNOPSIS
        Initializes and runs the PSD Wizard UI in a runspace
    .DESCRIPTION
        Loads XAML UI, wires up event handlers, and manages the wizard interaction loop.
        Runs in STA runspace for proper WPF support.
    .PARAMETER XamlContent
        XAML string or XML document
    .PARAMETER SyncHash
        Synchronized hashtable for cross-thread communication
    .PARAMETER ResourcePath
        Path to wizard resources
    .PARAMETER DevelopmentMode
        Enable development mode features
    .OUTPUTS
        [hashtable] Results from wizard interaction
    .EXAMPLE
        $xaml = Format-PSDWizard -ResourcePath $path -LangDefinition $lang -ThemeDefinition $theme
        $result = Invoke-PSDWizard -XamlContent $xaml -SyncHash $sync -ResourcePath $path
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        $XamlContent,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$false)]
        [string]$ResourcePath,

        [Parameter(Mandatory=$false)]
        [switch]$DevelopmentMode
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Initializing wizard UI..." -Component $FunctionName

    try {
        # Load WPF directly. Add-Type scans the MDT-loaded AppDomain in WinPE and
        # can trigger the unsupported Microsoft.BDD.Core.DeploymentTools initializer.
        foreach ($assemblyName in @('PresentationFramework', 'PresentationCore', 'WindowsBase')) {
            if (-not [System.Reflection.Assembly]::LoadWithPartialName($assemblyName)) {
                throw "Required WPF assembly could not be loaded: $assemblyName"
            }
        }

        # Convert to string if needed
        if ($XamlContent -is [xml]) {
            $xamlString = $XamlContent.OuterXml
        }
        else {
            $xamlString = $XamlContent
        }

        # Load XAML
        $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlString)
        $window = [Windows.Markup.XamlReader]::Load($reader)

        if (-not $window) {
            throw "Failed to load XAML into window"
        }

        Write-PSDWizardLog -Message "XAML loaded successfully" -Component $FunctionName

        # Store window in sync hash
        $SyncHash.Window = $window
        $SyncHash.UIElements = @{}
        $SyncHash.IsDevelopment = $DevelopmentMode.IsPresent

        # Find all named elements
        $xamlDoc = [xml]$xamlString
        $namedElements = $xamlDoc.SelectNodes("//*[@Name]")

        Write-PSDWizardLog -Message "Found $($namedElements.Count) named UI elements" -Component $FunctionName

        foreach ($element in $namedElements) {
            $elementName = $element.Name
            $uiElement = $window.FindName($elementName)

            if ($uiElement) {
                $SyncHash.UIElements[$elementName] = $uiElement
            }
        }

        # Set window properties
        $window.Title = "PSD Wizard v$($script:ModuleVersion)"

        # Make wizard topmost during launch
        $window.Topmost = $true

        # Find specific elements
        $versionLabel = $window.FindName('_wizVersion')
        if ($versionLabel) {
            $versionLabel.Content = "v$($script:ModuleVersion)"
        }

        # Add the debug console button when debug is on
        Initialize-PSDWizardDebugButton -Window $window -SyncHash $SyncHash

        # Add window drag support if borderless
        if ($window.WindowStyle -eq 'None') {
            $window.Add_MouseLeftButtonDown({
                $this.DragMove()
            })
        }

        # Set Topmost to false after window loads
        $window.Add_Loaded({
            # Delay briefly then remove topmost
            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromMilliseconds(500)
            $timer.Add_Tick({
                $window.Topmost = $false
                $this.Stop()
            })
            $timer.Start()
        })

        # Wire up basic navigation
        $backButton = $window.FindName('_wizBack')
        $nextButton = $window.FindName('_wizNext')
        $cancelButton = $window.FindName('_wizCancel')
        $finishButton = $window.FindName('_wizFinish')
        $tabControl = $window.FindName('_wizTabControl')

        # Welcome page elements
        $startButton = $window.FindName('_start')
        $startPage = $window.FindName('_startPage')
        $openPSButton = $window.FindName('_startPageOpenPS')

        if ($backButton) {
            $backButton.Visibility = 'Hidden'
        }

        # If finish button doesn't exist, we'll use Next button as finish on last page
        $useNextAsFinish = ($null -eq $finishButton)
        if ($useNextAsFinish) {
            Write-PSDWizardLog -Message "No _wizFinish button found, will use _wizNext as finish" -Component $FunctionName
        }
        else {
            $finishButton.Visibility = 'Collapsed'
        }

        # Handle welcome page "Let's Get Started" button
        if ($startButton -and $startPage -and $tabControl) {
            $startButton.Add_Click({
                param($sender, $e)
                $startPage.Visibility = 'Collapsed'
                $tabControl.IsEnabled = $true
                if ($tabControl.Items.Count -gt 0) {
                    $tabControl.SelectedIndex = 0
                    # Enable first tab
                    $firstTab = $tabControl.Items[0]
                    if ($firstTab) {
                        $firstTab.IsEnabled = $true
                    }
                }
            })
        }

        # Handle "Open PowerShell" debug button (if in dev mode)
        if ($openPSButton) {
            if ($DevelopmentMode) {
                $openPSButton.Add_Click({
                    param($sender, $e)
                    Start-Process powershell.exe
                })
            }
            else {
                $openPSButton.Visibility = 'Collapsed'
            }
        }

        # Setup event handlers
        if ($nextButton -and $tabControl) {
            $script:useNextAsFinish = $useNextAsFinish
            # Handle Next button click event
            $nextButton.Add_Click({
                param($sender, $e)
                $currentIndex = $tabControl.SelectedIndex

                # Get current tab to check for validation requirements
                $currentTab = if ($currentIndex -ge 0 -and $currentIndex -lt $tabControl.Items.Count) {
                    $tabControl.Items[$currentIndex]
                } else {
                    $null
                }

                #region PAGE VALIDATION
                $pageValidation = if ($currentTab) {
                    Test-PSDWizardPageValidation -Window $window -Page $currentTab -SyncHash $SyncHash
                }
                else {
                    [pscustomobject]@{ IsValid = $true; Message = '' }
                }
                $canContinue = [bool]$pageValidation.IsValid
                $validationMessage = [string]$pageValidation.Message

                # Show validation message if page cannot continue
                if (-not $canContinue) {
                    if ($validationMessage) {
                        [System.Windows.MessageBox]::Show($validationMessage, 'Validation Required', 'OK', 'Warning') | Out-Null
                    }
                    return  # Stop navigation
                }
                #endregion PAGE VALIDATION

                $visibleTabIndices = @(Get-PSDWizardVisibleTabIndices -TabControl $tabControl)

                # Finish on the last visible page, not the last generated TabItem.
                if ($visibleTabIndices.Count -gt 0 -and $currentIndex -eq $visibleTabIndices[-1]) {
                    $SyncHash.Result = 'Finished'

                    # Export wizard results
                    if ($SyncHash.IsDevelopment) {
                        Write-PSDWizardLog -Message "=== DEVELOPMENT MODE: Export Preview ===" -Component 'Invoke-PSDWizard'
                        Write-PSDWizardLog -Message "This is what would be exported to TSEnv in production mode:" -Component 'Invoke-PSDWizard'

                        # Collect all TSEnv properties that would be exported
                        $exportResults = @()

                        # Get all TSEnv_* controls
                        if ($SyncHash.UIElements) {
                            # Filter out all UI elements that are TSEnv_* controls
                            $tsenvControls = $SyncHash.UIElements.GetEnumerator() | Where-Object { $_.Key -like 'TSEnv_*' }

                            # Iterate through each TSEnv_* control and collect its value for export
                            foreach ($item in $tsenvControls) {
                                $control = $item.Value
                                $propertyName = $item.Key -replace '^TSEnv_', ''
                                $value = $null

                                # Get value based on control type
                                switch ($control.GetType().Name) {
                                    'TextBox' {
                                        $value = $control.Text
                                    }
                                    'PasswordBox' {
                                        $value = '<password hidden>'
                                    }
                                    'ComboBox' {
                                        if ($control.SelectedItem) {
                                            if ($control.SelectedItem -is [string]) {
                                                $value = $control.SelectedItem
                                            }
                                            else {
                                                $value = $control.SelectedItem.ToString()
                                            }
                                        }
                                        else {
                                            $value = $control.Text
                                        }
                                    }
                                    'CheckBox' {
                                        # Get the value for the checkbox control
                                        $value = if ($control.IsChecked -eq $true) { 'YES' } else { 'NO' }
                                    }
                                    default {
                                        # Handle default case for controls that don't match known types
                                        if ($control.PSObject.Properties['Text']) {
                                            $value = $control.Text
                                        }
                                        elseif ($control.PSObject.Properties['Content']) {
                                            $value = $control.Content
                                        }
                                    }
                                }

                                # Only include properties with values
                                if (-not [string]::IsNullOrWhiteSpace($value)) {
                                    # Add the property to the export results
                                    $exportResults += [PSCustomObject]@{
                                        Property = $propertyName
                                        Value = $value
                                        ControlType = $control.GetType().Name
                                    }

                                    Write-PSDWizardLog -Message "  $propertyName = $value" -Component 'Invoke-PSDWizard'
                                }
                            }
                        }

                        # Also add properties from TSEnvSettings that aren't controls (like Applications###)
                        if ($SyncHash.TSEnvSettings) {
                            foreach ($key in $SyncHash.TSEnvSettings.Keys) {
                                # Skip if already added from UI control
                                if ($exportResults | Where-Object { $_.Property -eq $key }) {
                                    continue
                                }

                                $value = $SyncHash.TSEnvSettings[$key]

                                # Handle arrays (like IPAddress, DefaultGateway)
                                if ($value -is [array]) {
                                    $value = $value -join ', '
                                }

                                # Never expose password or credential values in summaries or export previews.
                                if ([string]$key -match '(?i)(password|passwd|secret|credential)') {
                                    $value = '********'
                                }

                                # Only include properties with values
                                if (-not [string]::IsNullOrWhiteSpace($value)) {
                                    # Special handling for Applications - show names instead of GUIDs
                                    if ($key -match '^(Applications|MandatoryApplications)\d{3}$' -and $SyncHash.Applications) {
                                        $appGuid = $value
                                        $app = $SyncHash.Applications | Where-Object { $_.guid -eq $appGuid } | Select-Object -First 1
                                        if ($app) {
                                            $value = "$($app.Name) [$appGuid]"
                                        }
                                    }
                                    # Add the property to the export results
                                    $exportResults += [PSCustomObject]@{
                                        Property = $key
                                        Value = $value
                                        ControlType = 'TSEnvSettings'
                                    }

                                    Write-PSDWizardLog -Message "  $key = $value" -Component 'Invoke-PSDWizard'
                                }
                            }
                        }

                        # Display summary
                        Write-PSDWizardLog -Message "=== Total: $($exportResults.Count) properties would be exported ===" -Component 'Invoke-PSDWizard'

                        # Store results in SyncHash for viewing
                        $SyncHash.ExportResults = $exportResults

                        # Display in console
                        Write-Host "`n" -NoNewline
                        Write-Host "=" -ForegroundColor Cyan -NoNewline
                        Write-Host "=" * 59 -ForegroundColor Cyan
                        Write-Host "DEVELOPMENT MODE - Export Preview" -ForegroundColor Yellow
                        Write-Host "=" -ForegroundColor Cyan -NoNewline
                        Write-Host "=" * 59 -ForegroundColor Cyan
                        Write-Host "The following properties would be exported to TSEnv:" -ForegroundColor White
                        Write-Host ""

                        foreach ($result in ($exportResults | Sort-Object Property)) {
                            Write-Host "  $($result.Property)" -ForegroundColor Green -NoNewline
                            Write-Host " = " -NoNewline
                            Write-Host "$($result.Value)" -ForegroundColor Gray
                        }

                        Write-Host ""
                        Write-Host "=" -ForegroundColor Cyan -NoNewline
                        Write-Host "=" * 59 -ForegroundColor Cyan
                        Write-Host "Total: $($exportResults.Count) properties" -ForegroundColor Yellow
                        Write-Host "Check the log file for complete details." -ForegroundColor Gray
                        Write-Host "=" -ForegroundColor Cyan -NoNewline
                        Write-Host "=" * 59 -ForegroundColor Cyan
                        Write-Host ""
                    }
                    else {
                        # Production mode - actually export to TSEnv
                        # TODO: Implement actual TSEnv export
                        Write-PSDWizardLog -Message "Exporting wizard results to TSEnv..." -Component 'Invoke-PSDWizard'
                    }

                    $window.Close()
                    return
                }

                # Navigate to the next visible page.
                $nextVisibleIndex = @($visibleTabIndices | Where-Object { $_ -gt $currentIndex } | Select-Object -First 1)
                if ($nextVisibleIndex.Count -gt 0) {
                    $tabControl.SelectedIndex = [int]$nextVisibleIndex[0]

                    # Enable the new tab
                    $newTab = $tabControl.Items[$tabControl.SelectedIndex]
                    if ($newTab) {
                        $newTab.IsEnabled = $true
                    }

                    # Track visited tab
                    if ($tabControl.SelectedIndex -notin $script:VisitedTabs) {
                        $script:VisitedTabs += $tabControl.SelectedIndex
                    }
                }

                # Button text is now updated in TabControl.SelectionChanged handler
                # (removed duplicate logic here to prevent conflicts)
            })
        }

        if ($backButton -and $tabControl) {
            $backButton.Add_Click({
                param($sender, $e)
                $currentIndex = $tabControl.SelectedIndex
                $visibleTabIndices = @(Get-PSDWizardVisibleTabIndices -TabControl $tabControl)
                # Determine the previous visible tab index.
                $previousVisibleIndex = @($visibleTabIndices | Where-Object { $_ -lt $currentIndex } | Select-Object -Last 1)
                # Navigate to the previous visible page if it exists
                if ($previousVisibleIndex.Count -gt 0) {
                    $tabControl.SelectedIndex = [int]$previousVisibleIndex[0]
                }

                # Button text is now updated in TabControl.SelectionChanged handler
                # (removed duplicate logic here to prevent conflicts)
            })
        }

        if ($cancelButton) {
            # Add click event handler for the Cancel button
            $cancelButton.Add_Click({
                param($sender, $e)
                $SyncHash.Result = 'Cancelled'
                $window.Close()
            })
        }

        if ($finishButton) {
            # Add click event handler for the Finish button
            $finishButton.Add_Click({
                param($sender, $e)
                $SyncHash.Result = 'Finished'

                # Export wizard results
                if ($SyncHash.IsDevelopment) {
                    Write-PSDWizardLog -Message "=== DEVELOPMENT MODE: Export Preview ===" -Component 'Invoke-PSDWizard'
                    Write-PSDWizardLog -Message "This is what would be exported to TSEnv in production mode:" -Component 'Invoke-PSDWizard'

                    # Collect all TSEnv properties that would be exported
                    $exportResults = @()

                    # Get all TSEnv_* controls
                    if ($SyncHash.UIElements) {
                        $tsenvControls = $SyncHash.UIElements.GetEnumerator() | Where-Object { $_.Key -like 'TSEnv_*' }

                        # Iterate through each TSEnv control and collect its value for export
                        foreach ($item in $tsenvControls) {
                            # Get the control and property name for this TSEnv item
                            $control = $item.Value
                            $propertyName = $item.Key -replace '^TSEnv_', ''
                            $value = $null

                            # Get value based on control type
                            switch ($control.GetType().Name) {
                                'TextBox' {
                                    $value = $control.Text
                                }
                                'PasswordBox' {
                                    $value = '<password hidden>'
                                }
                                'ComboBox' {
                                    # Get the value based on the selected item or text
                                    if ($control.SelectedItem) {
                                        if ($control.SelectedItem -is [string]) {
                                            $value = $control.SelectedItem
                                        }
                                        else {
                                            $value = $control.SelectedItem.ToString()
                                        }
                                    }
                                    else {
                                        $value = $control.Text
                                    }
                                }
                                'CheckBox' {
                                    # Get the value based on whether the checkbox is checked
                                    $value = if ($control.IsChecked -eq $true) { 'YES' } else { 'NO' }
                                }
                                default {
                                    # For any other control types, try to get the Text or Content property if available
                                    if ($control.PSObject.Properties['Text']) {
                                        $value = $control.Text
                                    }
                                    elseif ($control.PSObject.Properties['Content']) {
                                        $value = $control.Content
                                    }
                                }
                            }

                            # Only include properties with values
                            if (-not [string]::IsNullOrWhiteSpace($value)) {
                                # Add the property to the export results
                                $exportResults += [PSCustomObject]@{
                                    Property = $propertyName
                                    Value = $value
                                    ControlType = $control.GetType().Name
                                }

                                Write-PSDWizardLog -Message "  $propertyName = $value" -Component 'Invoke-PSDWizard'
                            }
                        }
                    }

                    # Also add properties from TSEnvSettings that aren't controls (like Applications###)
                    if ($SyncHash.TSEnvSettings) {
                        foreach ($key in $SyncHash.TSEnvSettings.Keys) {
                            # Skip if already added from UI control
                            if ($exportResults | Where-Object { $_.Property -eq $key }) {
                                continue
                            }
                            # Get the value from TSEnvSettings for this key
                            $value = $SyncHash.TSEnvSettings[$key]

                            # Handle arrays (like IPAddress, DefaultGateway)
                            if ($value -is [array]) {
                                $value = $value -join ', '
                            }

                            # Never expose password or credential values in summaries or export previews.
                            if ([string]$key -match '(?i)(password|passwd|secret|credential)') {
                                $value = '********'
                            }

                            # Only include properties with values
                            if (-not [string]::IsNullOrWhiteSpace($value)) {
                                # Special handling for Applications - show names instead of GUIDs
                                if ($key -match '^(Applications|MandatoryApplications)\d{3}$' -and $SyncHash.Applications) {
                                    $appGuid = $value
                                    $app = $SyncHash.Applications | Where-Object { $_.guid -eq $appGuid } | Select-Object -First 1
                                    if ($app) {
                                        $value = "$($app.Name) [$appGuid]"
                                    }
                                }
                                # Add the property to the export results
                                $exportResults += [PSCustomObject]@{
                                    Property = $key
                                    Value = $value
                                    ControlType = 'TSEnvSettings'
                                }

                                Write-PSDWizardLog -Message "  $key = $value" -Component 'Invoke-PSDWizard'
                            }
                        }
                    }

                    # Display summary
                    Write-PSDWizardLog -Message "=== Total: $($exportResults.Count) properties would be exported ===" -Component 'Invoke-PSDWizard'

                    # Store results in SyncHash for viewing
                    $SyncHash.ExportResults = $exportResults

                    # Display in console
                    Write-Host "`n" -NoNewline
                    Write-Host "=" -ForegroundColor Cyan -NoNewline
                    Write-Host "=" * 59 -ForegroundColor Cyan
                    Write-Host "DEVELOPMENT MODE - Export Preview" -ForegroundColor Yellow
                    Write-Host "=" -ForegroundColor Cyan -NoNewline
                    Write-Host "=" * 59 -ForegroundColor Cyan
                    Write-Host "The following properties would be exported to TSEnv:" -ForegroundColor White
                    Write-Host ""

                    foreach ($result in ($exportResults | Sort-Object Property)) {
                        Write-Host "  $($result.Property)" -ForegroundColor Green -NoNewline
                        Write-Host " = " -NoNewline
                        Write-Host "$($result.Value)" -ForegroundColor Gray
                    }

                    Write-Host ""
                    Write-Host "=" -ForegroundColor Cyan -NoNewline
                    Write-Host "=" * 59 -ForegroundColor Cyan
                    Write-Host "Total: $($exportResults.Count) properties" -ForegroundColor Yellow
                    Write-Host "Check the log file for complete details." -ForegroundColor Gray
                    Write-Host "=" -ForegroundColor Cyan -NoNewline
                    Write-Host "=" * 59 -ForegroundColor Cyan
                    Write-Host ""
                }
                else {
                    # Production mode - actually export to TSEnv
                    # TODO: Implement actual TSEnv export
                    Write-PSDWizardLog -Message "Exporting wizard results to TSEnv..." -Component 'Invoke-PSDWizard'
                }

                $window.Close()
            })
        }

        # Track visited tabs to allow backward navigation
        $script:VisitedTabs = @(0)  # Start page is always visited
        $script:PreviousTabIndex = 0

        # Add TabControl SelectionChanged handler to refresh TSEnv summary on Ready page
        if ($tabControl) {
            $tabControl.Add_SelectionChanged({
                param($sender, $e)

                $currentTabIndex = $sender.SelectedIndex
                Update-PSDWizardNavigationState -Window $window -TabControl $sender
                $btnNext = $window.FindName('_wizNext')

                # Track this tab as visited (allow going back to it later)
                if ($currentTabIndex -notin $script:VisitedTabs) {
                    $script:VisitedTabs += $currentTabIndex
                }

                # Prevent navigating forward to unvisited tabs (user clicked a tab they shouldn't access yet)
                # Allow backward navigation to any visited tab
                if ($currentTabIndex -gt $script:PreviousTabIndex) {
                    # User is trying to go forward
                    # Check if the tab was already visited OR if the Next button is enabled
                    if ($currentTabIndex -notin $script:VisitedTabs -and $btnNext -and -not $btnNext.IsEnabled) {
                        # Block forward navigation - validation hasn't passed yet
                        Write-PSDWizardLog -Message "Blocked forward tab navigation: validation not passed for previous page" -LogLevel 2 -Component 'Invoke-PSDWizard'

                        # Revert to previous tab
                        $sender.SelectedIndex = $script:PreviousTabIndex
                        return
                    }
                }

                $script:PreviousTabIndex = $currentTabIndex

                # Check if the selected tab is the Ready/Summary page
                $selectedTab = $sender.SelectedItem
                if ($selectedTab -and $selectedTab.Name -match '_wizReady|_wizSummary') {
                    Write-PSDWizardLog -Message "Ready/Summary page selected, refreshing TSEnv ListView" -Component 'Invoke-PSDWizard'

                    # Find the TSEnv ListView
                    $tsenvListView = $window.FindName('TSEnv')
                    if ($tsenvListView) {
                        # Clear existing items (just set ItemsSource to null, don't call .Items.Clear())
                        $tsenvListView.ItemsSource = $null

                        # Collect TSEnv properties from UI controls only (not entire TSEnv)
                        # This matches the old behavior: only show what user set in the wizard
                        $tsenvSummaryData = @()

                        try {
                            # Find all TSEnv_* controls from SyncHash.UIElements
                            if ($SyncHash.UIElements) {
                                $tsenvControls = $SyncHash.UIElements.GetEnumerator() | Where-Object { $_.Key -like 'TSEnv_*' }

                                foreach ($item in $tsenvControls) {
                                    $control = $item.Value
                                    $propertyName = $item.Key -replace '^TSEnv_', ''
                                    $value = $null

                                    # Get value based on control type
                                    switch ($control.GetType().Name) {
                                        'TextBox' {
                                            $value = $control.Text
                                        }
                                        'PasswordBox' {
                                            $value = '********'  # Don't show actual password
                                        }
                                        'ComboBox' {
                                            if ($control.SelectedItem) {
                                                # If object, try to get a string representation
                                                if ($control.SelectedItem -is [string]) {
                                                    $value = $control.SelectedItem
                                                }
                                                elseif ($control.SelectedItem.PSObject.Properties['DisplayText']) {
                                                    $value = $control.SelectedItem.DisplayText
                                                }
                                                elseif ($control.SelectedItem.PSObject.Properties['Name']) {
                                                    $value = $control.SelectedItem.Name
                                                }
                                                else {
                                                    $value = $control.SelectedItem.ToString()
                                                }
                                            }
                                            else {
                                                $value = $control.Text
                                            }
                                        }
                                        'CheckBox' {
                                            $value = if ($control.IsChecked -eq $true) { 'YES' } else { 'NO' }
                                        }
                                        'Label' {
                                            $value = $control.Content
                                        }
                                        'TextBlock' {
                                            $value = $control.Text
                                        }
                                        default {
                                            # Try to get a value anyway
                                            if ($control.PSObject.Properties['Text']) {
                                                $value = $control.Text
                                            }
                                            elseif ($control.PSObject.Properties['Content']) {
                                                $value = $control.Content
                                            }
                                        }
                                    }

                                    # Only add if value is not null or empty
                                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                                        # Special handling for Applications - show names instead of GUIDs
                                        if ($propertyName -match '^(Applications|MandatoryApplications)\d{3}$' -and $SyncHash.Applications) {
                                            # Look up the application name from GUID
                                            $appGuid = $value
                                            $app = $SyncHash.Applications | Where-Object { $_.guid -eq $appGuid } | Select-Object -First 1
                                            if ($app) {
                                                $value = "$($app.Name) [$appGuid]"
                                            }
                                        }

                                        $tsenvSummaryData += [PSCustomObject]@{
                                            Name = $propertyName
                                            Value = $value
                                        }
                                    }
                                }
                            }
                            else {
                                Write-PSDWizardLog -Message "SyncHash.UIElements not available, cannot populate summary" -LogLevel 2 -Component 'Invoke-PSDWizard'
                            }

                            # Also add properties from TSEnvSettings that aren't controls (like Applications###)
                            if ($SyncHash.TSEnvSettings) {
                                foreach ($key in $SyncHash.TSEnvSettings.Keys) {
                                    # Skip if already added from UI control
                                    if ($tsenvSummaryData | Where-Object { $_.Name -eq $key }) {
                                        continue
                                    }

                                    $value = $SyncHash.TSEnvSettings[$key]

                                    # Handle arrays (like IPAddress, DefaultGateway)
                                    if ($value -is [array]) {
                                        $value = $value -join ', '
                                    }

                                    # Never expose password or credential values in the Summary ListView.
                                    if ([string]$key -match '(?i)(password|passwd|secret|credential)') {
                                        $value = '********'
                                    }

                                    # Only add if value is not null or empty
                                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                                        # Special handling for Applications - show names instead of GUIDs
                                        if ($key -match '^(Applications|MandatoryApplications)\d{3}$' -and $SyncHash.Applications) {
                                            # Look up the application name from GUID
                                            $appGuid = $value
                                            $app = $SyncHash.Applications | Where-Object { $_.guid -eq $appGuid } | Select-Object -First 1
                                            if ($app) {
                                                $value = "$($app.Name) [$appGuid]"
                                            }
                                        }

                                        $tsenvSummaryData += [PSCustomObject]@{
                                            Name = $key
                                            Value = $value
                                        }
                                    }
                                }
                            }

                            # Sort by property name
                            $tsenvSummaryData = $tsenvSummaryData | Sort-Object Name

                            # Populate the ListView
                            $tsenvListView.ItemsSource = $tsenvSummaryData
                            Write-PSDWizardLog -Message "Refreshed TSEnv ListView with $($tsenvSummaryData.Count) properties from UI controls" -Component 'Invoke-PSDWizard'
                        }
                        catch {
                            Write-PSDWizardLog -Message "Error refreshing TSEnv ListView: $($_.Exception.Message)" -LogLevel 2 -Component 'Invoke-PSDWizard'
                        }
                    }
                }

                #region PAGE VALIDATION ON TAB CHANGE
                # Validate the current page and enable/disable Next button accordingly
                $btnNext = $window.FindName('_wizNext')
                if ($selectedTab -and $btnNext) {
                    $pageValidation = Test-PSDWizardPageValidation -Window $window -Page $selectedTab -SyncHash $SyncHash
                    $btnNext.IsEnabled = [bool]$pageValidation.IsValid
                }
                #endregion PAGE VALIDATION ON TAB CHANGE
            })

            Write-PSDWizardLog -Message "Added TabControl SelectionChanged handler for TSEnv summary refresh" -Component $FunctionName
        }

        Write-PSDWizardLog -Message "Event handlers wired" -Component $FunctionName

        # Populate data into UI controls
        Initialize-PSDWizardData -Window $window -SyncHash $SyncHash -DevelopmentMode:$DevelopmentMode

        # Show window
        $SyncHash.Result = $null

        # Build the busy spinner thread in the background so the first task sequence selection does not wait for it
        $SyncHash.BusySpinner = Start-PSDWizardSpinner -NoWait
        $dialogResult = $window.ShowDialog()

        Write-PSDWizardLog -Message "Wizard closed. Result: $($SyncHash.Result)" -Component $FunctionName

        return $SyncHash
    }
    catch {
        Write-PSDWizardLog -Message "Error in wizard UI: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        throw
    }
    finally {
        Close-PSDWizardSpinner -SyncHash $SyncHash
    }
}

Function Initialize-PSDWizardData {
    <#
    .SYNOPSIS
        Populates UI controls with loaded data
    .DESCRIPTION
        Takes data from syncHash and populates it into wizard UI controls like
        task sequence lists, application grids, and OS selectors
    .PARAMETER Window
        WPF window object
    .PARAMETER SyncHash
        Synchronized hashtable with loaded data
    .PARAMETER DevelopmentMode
        Whether running in development mode
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$false)]
        [switch]$DevelopmentMode
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Initializing wizard data into UI controls" -Component $FunctionName

    try {
        # Debug output in DevelopmentMode
        if ($DevelopmentMode -and $SyncHash.TSEnvSettings) {
            Write-Host "`n===== TSEnvSettings Contents (DevelopmentMode Debug) =====" -ForegroundColor Cyan
            $SyncHash.TSEnvSettings.GetEnumerator() | Sort-Object Name | ForEach-Object {
                $value = if ($_.Value -is [array]) { "[$($_.Value -join ', ')]" } else { $_.Value }
                Write-Host "  $($_.Key) = $value" -ForegroundColor Gray
            }
            Write-Host "===== Total: $($SyncHash.TSEnvSettings.Count) properties =====`n" -ForegroundColor Cyan

            # Show TSEnvLists if available
            if ($SyncHash.TSEnvLists) {
                Write-Host "===== TSEnvLists Contents (list-based properties) =====" -ForegroundColor Cyan
                $SyncHash.TSEnvLists.GetEnumerator() | Sort-Object Name | ForEach-Object {
                    Write-Host "  $($_.Key): $($_.Value.Count) items" -ForegroundColor Gray
                    $_.Value | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
                }
                Write-Host "=================================================`n" -ForegroundColor Cyan
            }
        }

        # Populate discovered TSEnv_ controls from the parent runspace's TSEnv snapshot.
        if ($SyncHash.TSEnvSettings) {
            Write-PSDWizardLog -Message "Populating TSEnv_ fields from TSEnvSettings hashtable" -Component $FunctionName
            $populatedCount = 0

            $tsEnvControls = @($SyncHash.UIElements.GetEnumerator() | Where-Object { $_.Key -like 'TSEnv_*' })
            foreach ($entry in $tsEnvControls) {
                $controlName = [string]$entry.Key
                $key = $controlName.Substring('TSEnv_'.Length)

                if ($SyncHash.TSEnvSettings.ContainsKey($key)) {
                    $control = $entry.Value
                    $value = $SyncHash.TSEnvSettings[$key]

                    # Handle arrays (like IPAddress, DefaultGateway)
                    if ($value -is [array]) {
                        $value = $value -join ', '
                    }

                    # Expand variables in OSDComputerName (supports %SERIAL%, %RAND:n%, %MACADDRESS%, etc.)
                    if ($key -eq 'OSDComputerName' -and $value -match '%') {
                        $expandedValue = Expand-PSDWizardString -InputString $value
                        Write-PSDWizardLog -Message "Expanded OSDComputerName from '$value' to '$expandedValue'" -Component $FunctionName
                        $value = $expandedValue
                    }

                    # Set value based on control type
                    if ($control.GetType().Name -eq 'TextBox' -or $control.GetType().Name -eq 'TextBlock') {
                        $control.Text = $value
                        $populatedCount++
                        Write-PSDWizardLog -Message "Set $controlName = $value" -Component $FunctionName
                    }
                    elseif ($control.GetType().Name -eq 'Label') {
                        $control.Content = $value
                        $populatedCount++
                        Write-PSDWizardLog -Message "Set $controlName = $value" -Component $FunctionName
                    }
                    elseif ($control.GetType().Name -eq 'ComboBox') {
                        $control.Text = $value
                        $populatedCount++
                        Write-PSDWizardLog -Message "Set $controlName = $value" -Component $FunctionName
                    }
                    elseif ($control.GetType().Name -eq 'PasswordBox') {
                        $control.Password = $value
                        $populatedCount++
                        Write-PSDWizardLog -Message "Set $controlName = ********" -Component $FunctionName

                        # A password supplied by CustomSettings/TSEnv is already confirmed (MDT has no confirm box)
                        if ($controlName -eq 'TSEnv_AdminPassword') {
                            $adminConfirmBox = $Window.FindName('_ConfirmAdminPassword')
                            if ($adminConfirmBox) {
                                $adminConfirmBox.Password = $value
                                Write-PSDWizardLog -Message "Pre-filled _ConfirmAdminPassword from TSEnvSettings" -Component $FunctionName
                            }
                        }
                        elseif ($controlName -eq 'TSEnv_DomainAdminPassword') {
                            $domainConfirmBox = $Window.FindName('_DomainAdminConfirmPassword')
                            if ($domainConfirmBox) {
                                $domainConfirmBox.Password = $value
                                Write-PSDWizardLog -Message "Pre-filled _DomainAdminConfirmPassword from TSEnvSettings" -Component $FunctionName
                            }
                        }
                    }
                }
            }

            Write-PSDWizardLog -Message "Populated $populatedCount TSEnv_ fields from TSEnvSettings" -Component $FunctionName
        }
        else {
            Write-PSDWizardLog -Message "No TSEnvSettings in SyncHash" -LogLevel 1 -Component $FunctionName
        }

        # Add TextChanged event handlers to all TSEnv_ fields to sync changes back to TSEnvSettings
        if ($SyncHash.TSEnvSettings) {
            $tsenvFieldCount = 0

            # Get all controls with names starting with TSEnv_
            $allControls = $Window | Get-Member -MemberType Property | Where-Object { $_.Name -match '^TSEnv_' }

            foreach ($controlProperty in $allControls) {
                $controlName = $controlProperty.Name
                $control = $Window.$controlName

                if ($control -and $control.GetType().Name -eq 'TextBox') {
                    # Add TextChanged event to sync back to TSEnvSettings
                    $control.Add_TextChanged({
                        param($sender, $e)
                        $fieldName = $sender.Name -replace '^TSEnv_', ''
                        $newValue = $sender.Text

                        # Update SyncHash for development mode
                        if ($SyncHash.TSEnvSettings) {
                            $SyncHash.TSEnvSettings[$fieldName] = $newValue
                        }

                        # Also update actual TSEnv in production mode
                        try {
                            Set-PSDWizardTSEnvProperty -Name $fieldName -Value $newValue
                        }
                        catch {
                            # Silently continue if TSEnv not available (development mode)
                        }
                    })

                    $tsenvFieldCount++
                }
            }

            Write-PSDWizardLog -Message "Added TextChanged handlers to $tsenvFieldCount TSEnv_ TextBox fields" -Component $FunctionName
        }

        # Add validation handlers for specific Device Details fields
        Write-PSDWizardLog -Message "Adding validation handlers for Device Details fields" -Component $FunctionName

        # Define validation field mappings
        $validationFields = @(
            @{
                ControlName = 'TSEnv_OSDComputerName'
                ValidationCanvas = '_detTabValidation_Name'
                UpdateNextButton = $true
            }
            @{
                ControlName = 'TSEnv_JoinDomain'
                ValidationCanvas = '_detTabValidation2_Name'
                UpdateNextButton = $true
            }
            @{
                ControlName = 'TSEnv_JoinWorkgroup'
                ValidationCanvas = '_detTabValidation2_Name'
                UpdateNextButton = $true
            }
            @{
                ControlName = 'TSEnv_DomainAdmin'
                ValidationCanvas = '_detTabValidation2_Name'
                UpdateNextButton = $false  # Username doesn't block navigation by itself
            }
            @{
                ControlName = 'TSEnv_DomainAdminDomain'
                ValidationCanvas = '_detTabValidation2_Name'
                UpdateNextButton = $false  # Domain field validation, comprehensive check handles Next button
            }
            @{
                ControlName = 'TSEnv_OSDAddAdmin'
                ValidationCanvas = '_admTabValidation_Name'
                UpdateNextButton = $false  # Admin accounts validation doesn't block navigation
            }
        )

        # Wire up unified validation for each field using TextChanged + GotFocus (v2.3.6 approach)
        foreach ($field in $validationFields) {
            $control = $Window.FindName($field.ControlName)
            if ($control) {
                # Store field info in control's Tag for use in event handlers
                $control.Tag = @{
                    ValidationCanvas = $field.ValidationCanvas
                    UpdateNextButton = $field.UpdateNextButton
                }

                # GotFocus - validate when user enters the field
                $control.Add_GotFocus({
                    param($sender, $e)
                    $wnd = [System.Windows.Window]::GetWindow($sender)
                    $fieldInfo = $sender.Tag

                    if ($fieldInfo -and $wnd) {
                        if ($fieldInfo.UpdateNextButton) {
                            Invoke-PSDWizardFieldValidation -Window $wnd -ControlName $sender.Name -ValidationCanvasName $fieldInfo.ValidationCanvas -UpdateNextButton
                        }
                        else {
                            Invoke-PSDWizardFieldValidation -Window $wnd -ControlName $sender.Name -ValidationCanvasName $fieldInfo.ValidationCanvas
                        }

                        # For domain-related fields, also trigger comprehensive domain validation
                        if ($sender.Name -match 'TSEnv_JoinDomain|TSEnv_DomainAdmin|TSEnv_DomainAdminDomain') {
                            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeAsync([Action]{
                                Confirm-PSDWizardDomainRequirements -Window $wnd -UpdateNextButton
                            }, [System.Windows.Threading.DispatcherPriority]::Background)
                        }

                    }
                })

                # Register once so validation also runs on preloaded values and before focus changes.
                if ($control.Name -match 'TSEnv_JoinDomain|TSEnv_DomainAdmin|TSEnv_DomainAdminDomain') {
                    $control.AddHandler(
                        [System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                        [System.Windows.RoutedEventHandler] {
                            param($sender, $e)
                            $wnd = [System.Windows.Window]::GetWindow($sender)
                            $fieldInfo = $sender.Tag
                            if (-not $fieldInfo -or -not $wnd) { return }

                            if ($fieldInfo.UpdateNextButton) {
                                Invoke-PSDWizardFieldValidation -Window $wnd -ControlName $sender.Name -ValidationCanvasName $fieldInfo.ValidationCanvas -UpdateNextButton
                            }
                            else {
                                Invoke-PSDWizardFieldValidation -Window $wnd -ControlName $sender.Name -ValidationCanvasName $fieldInfo.ValidationCanvas
                            }

                            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeAsync([Action]{
                                Confirm-PSDWizardDomainRequirements -Window $wnd -UpdateNextButton
                            }, [System.Windows.Threading.DispatcherPriority]::Background)
                        }
                    )
                }

                Write-PSDWizardLog -Message "Added GotFocus/TextChanged validation handler for $($field.ControlName)" -Component $FunctionName
            }
        }

        # Initialize validation canvases to hidden state
        $validationCanvases = @('_detTabValidation', '_detTabValidation2', '_tsTabValidation', '_admTabValidation')
        foreach ($canvasName in $validationCanvases) {
            $canvas = $Window.FindName($canvasName)
            if ($canvas) {
                $canvas.Visibility = "Hidden"
                Write-PSDWizardLog -Message "Initialized $canvasName to hidden" -Component $FunctionName
            }
        }

        # Run initial validation for pre-populated fields (KeyUp won't fire for existing data)
        Write-PSDWizardLog -Message "Running initial validation for pre-populated fields" -Component $FunctionName
        foreach ($field in $validationFields) {
            $control = $Window.FindName($field.ControlName)
            if ($control -and -not [string]::IsNullOrWhiteSpace($control.Text)) {
                Write-PSDWizardLog -Message "Validating pre-populated field: $($field.ControlName)" -Component $FunctionName

                # Run validation
                if ($field.UpdateNextButton) {
                    Invoke-PSDWizardFieldValidation -Window $Window -ControlName $field.ControlName -ValidationCanvasName $field.ValidationCanvas -UpdateNextButton
                }
                else {
                    Invoke-PSDWizardFieldValidation -Window $Window -ControlName $field.ControlName -ValidationCanvasName $field.ValidationCanvas
                }
            }
        }

        # Add OSDAddAdmin field validation
        $osdAddAdminControl = $Window.FindName('TSEnv_OSDAddAdmin')
        if ($osdAddAdminControl) {
            # Enable the control (was disabled in XAML)
            $osdAddAdminControl.IsEnabled = $true
            Write-PSDWizardLog -Message "Enabled TSEnv_OSDAddAdmin field for input" -Component $FunctionName
        }

        # Add password matching validation for Admin Credentials page
        Write-PSDWizardLog -Message "Adding password matching validation handlers" -Component $FunctionName
        $passwordControl = $Window.FindName('TSEnv_AdminPassword')
        $confirmPasswordControl = $Window.FindName('_ConfirmAdminPassword')
        $validationOutput = $Window.FindName('_admTabValidation_Name')

        if ($passwordControl -and $confirmPasswordControl -and $validationOutput) {
            # Create a scriptblock for password validation
            $passwordValidationHandler = {
                param($sender, $e)
                try {
                    $wnd = [System.Windows.Window]::GetWindow($sender)
                    if ($wnd) {
                        $adminPasswordBox = $wnd.FindName('TSEnv_AdminPassword')
                        $confirmAdminPasswordBox = $wnd.FindName('_ConfirmAdminPassword')
                        $output = $wnd.FindName('_admTabValidation_Name')

                        if ($adminPasswordBox -and $confirmAdminPasswordBox -and $output) {
                            Confirm-PSDWizardPassword -PasswordObject $adminPasswordBox -ConfirmedPasswordObject $confirmAdminPasswordBox -OutputObject $output -UpdateNextButton
                        }
                    }
                }
                catch {
                    Write-PSDWizardLog -Message "Password validation event failed: $($_.Exception.Message)" -LogLevel 2 -Component 'AdminPassword_Event'
                }
            }

            # Wire up PasswordChanged event for both password fields
            $passwordControl.Add_PasswordChanged($passwordValidationHandler)
            $confirmPasswordControl.Add_PasswordChanged($passwordValidationHandler)

            # Keep Enter in password fields from activating a wizard navigation button.
            $consumePasswordEnter = {
                param($sender, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
                    $e.Handled = $true
                }
            }
            $passwordControl.Add_PreviewKeyDown($consumePasswordEnter)
            $confirmPasswordControl.Add_PreviewKeyDown($consumePasswordEnter)

            Write-PSDWizardLog -Message "Added password matching validation for TSEnv_AdminPassword and _ConfirmAdminPassword" -Component $FunctionName
        }
        else {
            Write-PSDWizardLog -Message "Password controls not found - skipping password validation setup" -Component $FunctionName -loglevel 2
        }

        # Find and populate Task Sequence control
        $tsControlNames = @('_tsTabTree', '_tsTabList', 'TSEnv_TaskSequence', '_lstTaskSequence')
        foreach ($controlName in $tsControlNames) {
            $tsControl = $Window.FindName($controlName)
            if ($tsControl -and $SyncHash.TaskSequences) {
                Write-PSDWizardLog -Message "Found TS control: $controlName (Type: $($tsControl.GetType().Name))" -Component $FunctionName

                # Populate based on control type
                if ($tsControl.GetType().Name -eq 'TreeView') {
                    $tsControl.ItemsSource = $null
                    $tsControl.Items.Clear()

                    # Build hierarchical structure if groups exist
                    if ($SyncHash.TaskSequenceGroups) {
                        # Get enabled groups (exclude hidden folder)
                        $visibleGroups = @($SyncHash.TaskSequenceGroups | Where-Object {
                            $isEnabled = ($_.enable -eq 'True') -or ([string]::IsNullOrEmpty($_.enable))
                            $isNotHidden = $_.Name -ne 'hidden'
                            $isEnabled -and $isNotHidden
                        })

                        foreach ($group in $visibleGroups) {
                            $groupMembers = @($group.Member) | Where-Object { $_ }

                            # Add task sequences that belong to this group
                            foreach ($ts in $SyncHash.TaskSequences) {
                                if ($ts.guid -in $groupMembers) {
                                    # If group is "default", add items to root level
                                    if ($group.Name -eq 'default') {
                                        $tsItem = New-Object System.Windows.Controls.TreeViewItem
                                        $tsItem.Header = "$($ts.Name) ($($ts.ID))"
                                        $tsItem.Tag = $ts
                                        $tsControl.Items.Add($tsItem) | Out-Null
                                    }
                                    else {
                                        # Create folder node if it doesn't exist
                                        $existingFolder = $tsControl.Items | Where-Object { $_.Header -eq $group.Name }
                                        if (-not $existingFolder) {
                                            $folderItem = New-Object System.Windows.Controls.TreeViewItem
                                            $folderItem.Header = $group.Name
                                            $folderItem.Tag = $group
                                            $tsControl.Items.Add($folderItem) | Out-Null
                                            $existingFolder = $folderItem
                                        }

                                        # Add TS to folder
                                        $tsItem = New-Object System.Windows.Controls.TreeViewItem
                                        $tsItem.Header = "$($ts.Name) ($($ts.ID))"
                                        $tsItem.Tag = $ts
                                        $existingFolder.Items.Add($tsItem) | Out-Null
                                    }
                                }
                            }
                        }
                    }
                    else {
                        # Flat list if no groups
                        foreach ($ts in $SyncHash.TaskSequences) {
                            $treeItem = New-Object System.Windows.Controls.TreeViewItem
                            $treeItem.Header = "$($ts.Name) ($($ts.ID))"
                            $treeItem.Tag = $ts
                            $tsControl.Items.Add($treeItem) | Out-Null
                        }
                    }

                    Write-PSDWizardLog -Message "Populated $($tsControl.Items.Count) task sequence groups/items into TreeView $controlName" -Component $FunctionName

                    # Wire up selection changed event to update TSEnv_TaskSequenceID
                    $tsControl.Add_SelectedItemChanged({
                        param($s, $ev)
                        try {
                            $selectedItem = $s.SelectedItem
                            if ($selectedItem -and $selectedItem.Tag -and $selectedItem.Tag.ID) {
                                # Find the control in the same window
                                $win = [System.Windows.Window]::GetWindow($s)
                                if ($win) {
                                    $tsIdBox = $win.FindName('TSEnv_TaskSequenceID')
                                    $btnNext = $win.FindName('_wizNext')
                                    $tsValidation = $win.FindName('_tsTabValidation')

                                    if ($tsIdBox) {
                                        $tsId = $selectedItem.Tag.ID
                                        $tsIdBox.Text = $tsId

                                        Update-PSDWizardTaskSequenceRules -TaskSequenceID $tsId -Window $win -SyncHash $SyncHash

                                        Write-PSDWizardLog -Message "Selected TS: $tsId" -Component 'Initialize-PSDWizardData'

                                        # Validate that the TS's assigned OS still exists
                                        $osGuid = Get-PSDWizardTSOSGUID -TaskSequenceID $tsId
                                        $isValid = $true

                                        if (-not [string]::IsNullOrWhiteSpace($osGuid)) {
                                            # Check if OS exists in OperatingSystems list
                                            if ($SyncHash.OperatingSystems) {
                                                $osExists = $SyncHash.OperatingSystems | Where-Object { $_.guid -eq $osGuid } | Select-Object -First 1

                                                if (-not $osExists) {
                                                    $isValid = $false
                                                    Write-PSDWizardLog -Message "TS '$tsId' references OS GUID '$osGuid' which was not found in OperatingSystems" -LogLevel 1 -Component 'Initialize-PSDWizardData'

                                                    # Show validation error
                                                    if ($tsValidation) {
                                                        $tsValidation.Visibility = [System.Windows.Visibility]::Visible
                                                        $validationText = $tsValidation.FindName('_tsTabValidation_Name')
                                                        if ($validationText) {
                                                            $validationText.Text = 'Invalid TS: No OS found!'
                                                        }
                                                        $validationAlert = $tsValidation.FindName('_tsTabValidation_Alert')
                                                        if ($validationAlert) {
                                                            $validationAlert.Visibility = [System.Windows.Visibility]::Visible
                                                        }
                                                    }
                                                }
                                                else {
                                                    Write-PSDWizardLog -Message \"TS '$tsId' has valid OS: $($osExists.Name) [$osGuid]\" -Component 'Initialize-PSDWizardData'

                                                    # Hide validation error
                                                    if ($tsValidation) {
                                                        $tsValidation.Visibility = [System.Windows.Visibility]::Hidden
                                                    }
                                                }
                                            }
                                        }

                                        # Enable/disable Next button based on validation
                                        if ($btnNext) {
                                            $btnNext.IsEnabled = $isValid
                                            if ($isValid) {
                                                Write-PSDWizardLog -Message \"Next button enabled (Task Sequence selected and valid)\" -Component 'Initialize-PSDWizardData'
                                            }
                                            else {
                                                Write-PSDWizardLog -Message \"Next button disabled (Task Sequence OS not found)\" -Component 'Initialize-PSDWizardData'
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        catch {
                            Write-PSDWizardLog -Message \"Error in TS selection: $($_.Exception.Message)\" -LogLevel 2 -Component 'Initialize-PSDWizardData'
                        }
                    })
                    Write-PSDWizardLog -Message "Wired TSEnv_TaskSequenceID update event" -Component $FunctionName

                    # Expand all folders by default
                    foreach ($item in $tsControl.Items) {
                        if ($item.Items.Count -gt 0) {
                            $item.IsExpanded = $true
                        }
                    }

                    # Preselect TaskSequence based on TaskSequenceID from TSEnvSettings
                    if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey('TaskSequenceID')) {
                        $preselectedTSID = $SyncHash.TSEnvSettings['TaskSequenceID']

                        if (-not [string]::IsNullOrWhiteSpace($preselectedTSID)) {
                            Write-PSDWizardLog -Message "Attempting to preselect TaskSequence: $preselectedTSID" -Component $FunctionName

                            # Search for the task sequence in the tree
                            $found = $false
                            foreach ($item in $tsControl.Items) {
                                if ($item.Tag -and $item.Tag.ID -eq $preselectedTSID) {
                                    $item.IsSelected = $true
                                    $item.BringIntoView()
                                    $found = $true
                                    Write-PSDWizardLog -Message "Preselected TaskSequence '$preselectedTSID' in TreeView (root level)" -Component $FunctionName
                                    break
                                }
                                elseif ($item.Items.Count -gt 0) {
                                    # Search in child items (folders)
                                    foreach ($childItem in $item.Items) {
                                        if ($childItem.Tag -and $childItem.Tag.ID -eq $preselectedTSID) {
                                            $childItem.IsSelected = $true
                                            $childItem.BringIntoView()
                                            $found = $true
                                            Write-PSDWizardLog -Message "Preselected TaskSequence '$preselectedTSID' in TreeView (folder: $($item.Header))" -Component $FunctionName
                                            break
                                        }
                                    }
                                    if ($found) { break }
                                }
                            }

                            if (-not $found) {
                                Write-PSDWizardLog -Message "Could not find TaskSequence '$preselectedTSID' in TreeView for preselection" -LogLevel 1 -Component $FunctionName
                            }
                        }
                    }
                }
                elseif ($tsControl.GetType().Name -eq 'ListBox') {
                    $tsControl.ItemsSource = $null
                    $tsControl.Items.Clear()

                    foreach ($ts in $SyncHash.TaskSequences) {
                        $item = New-Object PSObject -Property @{
                            ID = $ts.ID
                            Name = $ts.Name
                            Description = if ($ts.Comments) { $ts.Comments } else { '' }
                        }
                        $tsControl.Items.Add($item) | Out-Null
                    }

                    Write-PSDWizardLog -Message "Populated $($tsControl.Items.Count) task sequences into ListBox $controlName" -Component $FunctionName

                    # Preselect TaskSequence based on TaskSequenceID from TSEnvSettings
                    if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey('TaskSequenceID')) {
                        $preselectedTSID = $SyncHash.TSEnvSettings['TaskSequenceID']

                        if (-not [string]::IsNullOrWhiteSpace($preselectedTSID)) {
                            # Find and select the matching item
                            $matchingTS = $tsControl.Items | Where-Object { $_.ID -eq $preselectedTSID }

                            if ($matchingTS) {
                                $tsControl.SelectedItem = $matchingTS
                                Write-PSDWizardLog -Message "Preselected TaskSequence '$preselectedTSID' in ListBox" -Component $FunctionName

                                # Also update the TSEnv_TaskSequenceID field directly
                                $tsIdField = $Window.FindName('TSEnv_TaskSequenceID')
                                if ($tsIdField) {
                                    $tsIdField.Text = $preselectedTSID
                                }
                            }
                            else {
                                Write-PSDWizardLog -Message "Could not find TaskSequence '$preselectedTSID' in ListBox for preselection" -LogLevel 1 -Component $FunctionName
                            }
                        }
                    }

                    # Wire up selection changed event for ListBox
                    $tsControl.Add_SelectionChanged({
                        param($s, $ev)
                        try {
                            $selectedItem = $s.
SelectedItem
                            if ($selectedItem -and $selectedItem.ID) {
                                $win = [System.Windows.Window]::GetWindow($s)
                                if ($win) {
                                    $tsIdBox = $win.FindName('TSEnv_TaskSequenceID')
                                    $btnNext = $win.FindName('_wizNext')
                                    $tsValidation = $win.FindName('_tsTabValidation')

                                    if ($tsIdBox) {
                                        $tsId = $selectedItem.ID
                                        $tsIdBox.Text = $tsId

                                        Update-PSDWizardTaskSequenceRules -TaskSequenceID $tsId -Window $win -SyncHash $SyncHash

                                        Write-PSDWizardLog -Message "Selected TS: $tsId" -Component 'Initialize-PSDWizardData'

                                        # Validate that the TS's assigned OS still exists
                                        $osGuid = Get-PSDWizardTSOSGUID -TaskSequenceID $tsId
                                        $isValid = $true

                                        if (-not [string]::IsNullOrWhiteSpace($osGuid)) {
                                            if ($SyncHash.OperatingSystems) {
                                                $osExists = $SyncHash.OperatingSystems | Where-Object { $_.guid -eq $osGuid } | Select-Object -First 1

                                                if (-not $osExists) {
                                                    $isValid = $false
                                                    Write-PSDWizardLog -Message "TS '$tsId' references OS GUID '$osGuid' which was not found" -LogLevel 1 -Component 'Initialize-PSDWizardData'

                                                    if ($tsValidation) {
                                                        $tsValidation.Visibility = [System.Windows.Visibility]::Visible
                                                        $validationText = $tsValidation.FindName('_tsTabValidation_Name')
                                                        if ($validationText) { $validationText.Text = 'Invalid TS: No OS found!' }
                                                        $validationAlert = $tsValidation.FindName('_tsTabValidation_Alert')
                                                        if ($validationAlert) { $validationAlert.Visibility = [System.Windows.Visibility]::Visible }
                                                    }
                                                }
                                                else {
                                                    Write-PSDWizardLog -Message "TS '$tsId' has valid OS: $($osExists.Name)" -Component 'Initialize-PSDWizardData'
                                                    if ($tsValidation) { $tsValidation.Visibility = [System.Windows.Visibility]::Hidden }
                                                }
                                            }
                                        }

                                        # Enable/disable Next button
                                        if ($btnNext) {
                                            $btnNext.IsEnabled = $isValid
                                            Write-PSDWizardLog -Message "Next button $(if($isValid){'enabled'}else{'disabled'}) (TS validation: $isValid)" -Component 'Initialize-PSDWizardData'
                                        }
                                    }
                                }
                            }
                        }
                        catch {
                            Write-PSDWizardLog -Message "Error in ListBox TS selection: $($_.Exception.Message)" -LogLevel 2 -Component 'Initialize-PSDWizardData'
                        }
                    })
                    Write-PSDWizardLog -Message "Wired ListBox TSEnv_TaskSequenceID update event" -Component $FunctionName
                }
                elseif ($tsControl.GetType().Name -eq 'DataGrid') {
                    $tsData = foreach ($ts in $SyncHash.TaskSequences) {
                        [PSCustomObject]@{
                            ID = $ts.ID
                            Name = $ts.Name
                            Description = if ($ts.Comments) { $ts.Comments } else { '' }
                        }
                    }
                    $tsControl.ItemsSource = $tsData
                    Write-PSDWizardLog -Message "Populated $($tsData.Count) task sequences into DataGrid $controlName" -Component $FunctionName

                    # Preselect TaskSequence based on TaskSequenceID from TSEnvSettings
                    if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey('TaskSequenceID')) {
                        $preselectedTSID = $SyncHash.TSEnvSettings['TaskSequenceID']

                        if (-not [string]::IsNullOrWhiteSpace($preselectedTSID)) {
                            # Find and select the matching item
                            $matchingTS = $tsData | Where-Object { $_.ID -eq $preselectedTSID }

                            if ($matchingTS) {
                                $tsControl.SelectedItem = $matchingTS
                                Write-PSDWizardLog -Message "Preselected TaskSequence '$preselectedTSID' in DataGrid" -Component $FunctionName

                                # Also update the TSEnv_TaskSequenceID field directly
                                $tsIdField = $Window.FindName('TSEnv_TaskSequenceID')
                                if ($tsIdField) {
                                    $tsIdField.Text = $preselectedTSID
                                }
                            }
                            else {
                                Write-PSDWizardLog -Message "Could not find TaskSequence '$preselectedTSID' in DataGrid for preselection" -LogLevel 1 -Component $FunctionName
                            }
                        }
                    }

                    # Wire up selection changed event for DataGrid
                    $tsControl.Add_SelectionChanged({
                        param($s, $ev)
                        try {
                            $selectedItem = $s.SelectedItem
                            if ($selectedItem -and $selectedItem.ID) {
                                $win = [System.Windows.Window]::GetWindow($s)
                                if ($win) {
                                    $tsIdBox = $win.FindName('TSEnv_TaskSequenceID')
                                    $btnNext = $win.FindName('_wizNext')
                                    $tsValidation = $win.FindName('_tsTabValidation')

                                    if ($tsIdBox) {
                                        $tsId = $selectedItem.ID
                                        $tsIdBox.Text = $tsId

                                        Update-PSDWizardTaskSequenceRules -TaskSequenceID $tsId -Window $win -SyncHash $SyncHash

                                        Write-PSDWizardLog -Message "Selected TS: $tsId" -Component 'Initialize-PSDWizardData'

                                        # Validate that the TS's assigned OS still exists
                                        $osGuid = Get-PSDWizardTSOSGUID -TaskSequenceID $tsId
                                        $isValid = $true

                                        if (-not [string]::IsNullOrWhiteSpace($osGuid)) {
                                            if ($SyncHash.OperatingSystems) {
                                                $osExists = $SyncHash.OperatingSystems | Where-Object { $_.guid -eq $osGuid } | Select-Object -First 1

                                                if (-not $osExists) {
                                                    $isValid = $false
                                                    Write-PSDWizardLog -Message "TS '$tsId' references OS GUID '$osGuid' which was not found" -LogLevel 1 -Component 'Initialize-PSDWizardData'

                                                    if ($tsValidation) {
                                                        $tsValidation.Visibility = [System.Windows.Visibility]::Visible
                                                        $validationText = $tsValidation.FindName('_tsTabValidation_Name')
                                                        if ($validationText) { $validationText.Text = 'Invalid TS: No OS found!' }
                                                        $validationAlert = $tsValidation.FindName('_tsTabValidation_Alert')
                                                        if ($validationAlert) { $validationAlert.Visibility = [System.Windows.Visibility]::Visible }
                                                    }
                                                }
                                                else {
                                                    Write-PSDWizardLog -Message "TS '$tsId' has valid OS: $($osExists.Name)" -Component 'Initialize-PSDWizardData'
                                                    if ($tsValidation) { $tsValidation.Visibility = [System.Windows.Visibility]::Hidden }
                                                }
                                            }
                                        }

                                        # Enable/disable Next button
                                        if ($btnNext) {
                                            $btnNext.IsEnabled = $isValid
                                            Write-PSDWizardLog -Message "Next button $(if($isValid){'enabled'}else{'disabled'}) (TS validation: $isValid)" -Component 'Initialize-PSDWizardData'
                                        }
                                    }
                                }
                            }
                        }
                        catch {
                            Write-PSDWizardLog -Message "Error in DataGrid TS selection: $($_.Exception.Message)" -LogLevel 2 -Component 'Initialize-PSDWizardData'
                        }
                    })
                    Write-PSDWizardLog -Message "Wired DataGrid TSEnv_TaskSequenceID update event" -Component $FunctionName
                }

                break
            }
        }

        # Find and populate Applications control
        $appControlNames = @('_appTabList', '_appTabDatagrid', '_lstApplications', 'TSEnv_Applications', '_dgApplications')
        foreach ($controlName in $appControlNames) {
            $appControl = $Window.FindName($controlName)
            if ($appControl -and $SyncHash.Applications) {
                Write-PSDWizardLog -Message "Found app control: $controlName (Type: $($appControl.GetType().Name))" -Component $FunctionName

                if ($appControl.GetType().Name -eq 'DataGrid') {
                    $appData = foreach ($app in $SyncHash.Applications) {
                        [PSCustomObject]@{
                            guid = $app.guid
                            Name = $app.Name
                            ShortName = if ($app.ShortName) { $app.ShortName } else { $app.Name }
                            Version = if ($app.Version) { $app.Version } else { '' }
                            Publisher = if ($app.Publisher) { $app.Publisher } else { '' }
                        }
                    }
                    $appControl.ItemsSource = $appData
                    Write-PSDWizardLog -Message "Populated $($appData.Count) applications into DataGrid $controlName" -Component $FunctionName

                    # Preselect applications based on Applications### from TSEnvSettings
                    if ($SyncHash.TSEnvSettings) {
                        $selectedAppGuids = @()
                        $mandatoryAppGuids = @()

                        # Get Applications### values (Applications001, Applications002, etc.)
                        $appKeys = $SyncHash.TSEnvSettings.Keys | Where-Object { $_ -match '^Applications\d{3}$' } | Sort-Object
                        foreach ($key in $appKeys) {
                            $guid = $SyncHash.TSEnvSettings[$key]
                            if (-not [string]::IsNullOrWhiteSpace($guid)) {
                                $selectedAppGuids += $guid
                            }
                        }

                        # Get MandatoryApplications### values
                        $mandatoryKeys = $SyncHash.TSEnvSettings.Keys | Where-Object { $_ -match '^MandatoryApplications\d{3}$' } | Sort-Object
                        foreach ($key in $mandatoryKeys) {
                            $guid = $SyncHash.TSEnvSettings[$key]
                            if (-not [string]::IsNullOrWhiteSpace($guid)) {
                                $mandatoryAppGuids += $guid
                                if ($guid -notin $selectedAppGuids) {
                                    $selectedAppGuids += $guid
                                }
                            }
                        }

                        # Preselect applications in the DataGrid
                        if ($selectedAppGuids.Count -gt 0) {
                            $preselectedCount = 0

                            foreach ($item in $appData) {
                                if ($item.guid -in $selectedAppGuids) {
                                    $appControl.SelectedItems.Add($item) | Out-Null
                                    $preselectedCount++

                                    # Mark as mandatory if in mandatory list
                                    if ($item.guid -in $mandatoryAppGuids) {
                                        Add-Member -InputObject $item -NotePropertyName 'IsMandatory' -NotePropertyValue $true -Force
                                    }

                                    Write-PSDWizardLog -Message "Preselected application: $($item.Name) (GUID: $($item.guid))" -Component $FunctionName
                                }
                            }

                            Write-PSDWizardLog -Message "Preselected $preselectedCount applications (including $($mandatoryAppGuids.Count) mandatory)" -Component $FunctionName
                        }

                        # Add event handler to prevent deselection of mandatory applications
                        if ($mandatoryAppGuids.Count -gt 0) {
                            $appControl.Add_SelectionChanged({
                                param($sender, $e)

                                # Check if any mandatory apps were deselected
                                $currentSelectedGuids = @($sender.SelectedItems | Select-Object -ExpandProperty guid)

                                foreach ($item in $sender.ItemsSource) {
                                    # Check if item has IsMandatory property
                                    $isMandatory = $false
                                    if ($item.PSObject.Properties.Name -contains 'IsMandatory') {
                                        $isMandatory = $item.IsMandatory
                                    }

                                    if ($isMandatory -and $item.guid -notin $currentSelectedGuids) {
                                        # Re-select the mandatory application
                                        $sender.SelectedItems.Add($item) | Out-Null
                                        Write-PSDWizardLog -Message "Prevented deselection of mandatory application: $($item.Name)" -Component 'Initialize-PSDWizardData'
                                    }
                                }
                            })

                            Write-PSDWizardLog -Message "Added mandatory application protection for $($mandatoryAppGuids.Count) apps" -Component $FunctionName
                        }

                        $appControl.Add_SelectionChanged({
                            param($sender, $e)
                            if ($SyncHash.IsRefreshingTaskSequenceRules -or $SyncHash.IsRefreshingApplicationBundle) {
                                return
                            }
                            # Rewrite Applications### from current UI state so deselected CustomSettings defaults do not persist.
                            $selectedGuids = @($sender.SelectedItems | Select-Object -ExpandProperty guid)
                            $selectedGuids += @($SyncHash.SelectedApplicationBundleGuids)
                            Export-PSDWizardApplication -SelectedApplications $selectedGuids | Out-Null
                        })
                    }
                }
                elseif ($appControl.GetType().Name -eq 'ListBox') {
                    $appControl.ItemsSource = $null
                    $appControl.Items.Clear()

                    $selectedAppGuids = @($SyncHash.TSEnvSettings.Keys | Where-Object { $_ -match '^Applications\d{3}$' } | ForEach-Object { [string]$SyncHash.TSEnvSettings[$_] } | Where-Object { $_ })
                    $mandatoryAppGuids = @($SyncHash.TSEnvSettings.Keys | Where-Object { $_ -match '^MandatoryApplications\d{3}$' } | ForEach-Object { [string]$SyncHash.TSEnvSettings[$_] } | Where-Object { $_ })
                    $SyncHash.SelectedApplicationBundleGuids = @($selectedAppGuids | ForEach-Object {
                        $guid = [string]$_
                        $application = @($SyncHash.ApplicationCatalog | Where-Object { [string]$_.guid -ieq $guid }) | Select-Object -First 1
                        if ($application -and @($application.SelectNodes('./Dependency')).Count -gt 0) { $guid }
                    })
                    $appDisplayItems = @(Get-PSDWizardApplicationDisplayItems -SyncHash $SyncHash -SelectedGuids $selectedAppGuids -MandatoryGuids $mandatoryAppGuids)

                    foreach ($item in $appDisplayItems) {
                        $appControl.Items.Add($item) | Out-Null
                    }

                    Write-PSDWizardLog -Message "Populated $($appControl.Items.Count) applications into ListBox $controlName" -Component $FunctionName

                    # Preselect applications based on Applications### from TSEnvSettings
                    if ($SyncHash.TSEnvSettings) {
                        $selectedAppGuids = @()
                        $mandatoryAppGuids = @()

                        # Get Applications### values (Applications001, Applications002, etc.)
                        $appKeys = $SyncHash.TSEnvSettings.Keys | Where-Object { $_ -match '^Applications\d{3}$' } | Sort-Object
                        foreach ($key in $appKeys) {
                            $guid = $SyncHash.TSEnvSettings[$key]
                            if (-not [string]::IsNullOrWhiteSpace($guid)) {
                                $selectedAppGuids += $guid
                            }
                        }

                        # Get MandatoryApplications### values (MandatoryApplications001, MandatoryApplications002, etc.)
                        $mandatoryKeys = $SyncHash.TSEnvSettings.Keys | Where-Object { $_ -match '^MandatoryApplications\d{3}$' } | Sort-Object
                        foreach ($key in $mandatoryKeys) {
                            $guid = $SyncHash.TSEnvSettings[$key]
                            if (-not [string]::IsNullOrWhiteSpace($guid)) {
                                $mandatoryAppGuids += $guid
                                # Also add to selected apps if not already there
                                if ($guid -notin $selectedAppGuids) {
                                    $selectedAppGuids += $guid
                                }
                            }
                        }

                        $selectedAppGuids = @($selectedAppGuids + @($appDisplayItems | Where-Object { $_.Selected } | ForEach-Object { $_.guid }) | Select-Object -Unique)

                        # Preselect applications in the ListBox
                        if ($selectedAppGuids.Count -gt 0) {
                            $preselectedCount = 0

                            foreach ($item in $appControl.Items) {
                                if ($item.guid -in $selectedAppGuids) {
                                    $appControl.SelectedItems.Add($item) | Out-Null
                                    $item.Selected = $true
                                    $preselectedCount++

                                    # Mark as mandatory if in mandatory list
                                    if ($item.guid -in $mandatoryAppGuids) {
                                        # Store mandatory status in the item
                                        Add-Member -InputObject $item -NotePropertyName 'IsMandatory' -NotePropertyValue $true -Force
                                    }

                                    Write-PSDWizardLog -Message "Preselected application: $($item.Name) (GUID: $($item.guid))" -Component $FunctionName
                                }
                            }

                            Write-PSDWizardLog -Message "Preselected $preselectedCount applications (including $($mandatoryAppGuids.Count) mandatory)" -Component $FunctionName
                        }

                        # Add event handler to prevent deselection of mandatory applications
                        if ($mandatoryAppGuids.Count -gt 0) {
                            $appControl.Add_SelectionChanged({
                                param($sender, $e)

                                # Check if any mandatory apps were deselected
                                $currentSelectedGuids = @($sender.SelectedItems | Select-Object -ExpandProperty guid)

                                foreach ($item in $sender.Items) {
                                    # Check if item has IsMandatory property
                                    $isMandatory = $false
                                    if ($item.PSObject.Properties.Name -contains 'IsMandatory') {
                                        $isMandatory = $item.IsMandatory
                                    }

                                    if ($isMandatory -and $item.guid -notin $currentSelectedGuids) {
                                        # Re-select the mandatory application
                                        $sender.SelectedItems.Add($item) | Out-Null
                                        Write-PSDWizardLog -Message "Prevented deselection of mandatory application: $($item.Name)" -Component 'Initialize-PSDWizardData'
                                    }
                                }
                            })

                            Write-PSDWizardLog -Message "Added mandatory application protection for $($mandatoryAppGuids.Count) apps" -Component $FunctionName
                        }

                        $appControl.Add_SelectionChanged({
                            param($sender, $e)
                            if ($SyncHash.IsRefreshingTaskSequenceRules -or $SyncHash.IsRefreshingApplicationBundle) {
                                return
                            }
                            # Rewrite Applications### from current UI state so deselected CustomSettings defaults do not persist.
                            $selectedGuids = @($sender.SelectedItems | Select-Object -ExpandProperty guid)
                            $selectedGuids += @($SyncHash.SelectedApplicationBundleGuids)
                            Export-PSDWizardApplication -SelectedApplications $selectedGuids | Out-Null
                        })
                    }
                }

                $appControl.Add_SelectionChanged({
                    param($sender, $e)
                    if ($SyncHash.IsRefreshingTaskSequenceRules -or $SyncHash.IsRefreshingApplicationBundle) {
                        return
                    }

                    $selectedGuids = @($sender.SelectedItems | Select-Object -ExpandProperty guid)
                    foreach ($item in $sender.Items) {
                        if ($item.guid -in @($SyncHash.MandatoryApplicationGuids) -and $item.guid -notin $selectedGuids) {
                            $sender.SelectedItems.Add($item) | Out-Null
                        }
                    }
                })

                break
            }
        }

        # Dynamically populate all TSEnvList_* controls from TSEnvLists
        # This handles DeviceRole, IntuneGroup, DomainOUs, and any other list-based properties
        if ($SyncHash.TSEnvLists) {
            Write-PSDWizardLog -Message "Scanning for TSEnvList_* controls to populate dynamically..." -Component $FunctionName

            # Get all named elements from the window
            $allControls = @()
            $allControls += $Window | Get-Member -MemberType Property | Where-Object { $_.Name -notmatch '^_' -and $_.Name -ne 'Resources' }

            # Also scan FindName for controls matching pattern
            foreach ($listKey in $SyncHash.TSEnvLists.Keys) {
                $control = Get-PSDWizardListControl -Window $Window -SyncHash $SyncHash -ListName $listKey
                $controlName = if ($control) { $control.Name } else { "TSEnvList_$listKey" }

                if ($control) {
                    $controlType = $control.GetType().Name
                    Write-PSDWizardLog -Message "Found control: $controlName (Type: $controlType)" -Component $FunctionName

                    if ($controlType -eq 'ComboBox' -or $controlType -eq 'ListBox') {
                        $control.ItemsSource = $null
                        $control.Items.Clear()

                        foreach ($item in $SyncHash.TSEnvLists[$listKey]) {
                            $control.Items.Add($item) | Out-Null
                        }

                        Write-PSDWizardLog -Message "Populated $($control.Items.Count) items into $controlType $controlName from TSEnvLists['$listKey']" -Component $FunctionName

                        # Add event handler to sync selection with TSEnv_ field
                        # The text field is named after the control, not after the (upper case) list name
                        $tsenvFieldName = $control.Name -replace '^TSEnvList_', 'TSEnv_'
                        $tsenvField = $Window.FindName($tsenvFieldName)

                        if ($controlType -eq 'ComboBox') {
                            $control.Add_SelectionChanged({
                                param($sender, $e)
                                $selectedValue = $sender.SelectedItem
                                $fieldName = $sender.Name -replace '^TSEnvList_', ''
                                $tsenvFieldName = "TSEnv_$fieldName"
                                $targetField = [System.Windows.Window]::GetWindow($sender).FindName($tsenvFieldName)

                                if ($targetField -and $selectedValue) {
                                    $targetField.Text = $selectedValue.ToString()

                                    # Also update SyncHash.TSEnvSettings
                                    if ($SyncHash.TSEnvSettings) {
                                        $SyncHash.TSEnvSettings[$fieldName] = $selectedValue.ToString()
                                    }

                                    Write-PSDWizardLog -Message "Synced $tsenvFieldName = $selectedValue" -Component 'Initialize-PSDWizardData'
                                }
                            })
                            Write-PSDWizardLog -Message "Added SelectionChanged handler for $controlName -> $tsenvFieldName" -Component $FunctionName
                        }
                        elseif ($controlType -eq 'ListBox') {
                            $control.Add_SelectionChanged({
                                param($sender, $e)
                                $selectedValue = $sender.SelectedItem
                                $fieldName = $sender.Name -replace '^TSEnvList_', ''
                                $tsenvFieldName = "TSEnv_$fieldName"
                                $targetField = [System.Windows.Window]::GetWindow($sender).FindName($tsenvFieldName)

                                if ($targetField -and $selectedValue) {
                                    $targetField.Text = $selectedValue.ToString()

                                    # Also update SyncHash.TSEnvSettings
                                    if ($SyncHash.TSEnvSettings) {
                                        $SyncHash.TSEnvSettings[$fieldName] = $selectedValue.ToString()
                                    }

                                    Write-PSDWizardLog -Message "Synced $tsenvFieldName = $selectedValue" -Component 'Initialize-PSDWizardData'
                                }
                            })
                            Write-PSDWizardLog -Message "Added SelectionChanged handler for $controlName -> $tsenvFieldName" -Component $FunctionName
                        }

                        # Preselect item if value exists in TSEnvSettings
                        if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey($listKey)) {
                            $preselectedValue = $SyncHash.TSEnvSettings[$listKey]

                            if (-not [string]::IsNullOrWhiteSpace($preselectedValue)) {
                                # Find and select the matching item
                                $matchingItem = $control.Items | Where-Object { $_.ToString() -eq $preselectedValue }

                                if ($matchingItem) {
                                    $control.SelectedItem = $matchingItem
                                    Write-PSDWizardLog -Message "Preselected '$preselectedValue' in $controlName from TSEnvSettings" -Component $FunctionName

                                    # Also update the TSEnv_ field directly
                                    if ($tsenvField) {
                                        $tsenvField.Text = $preselectedValue
                                    }
                                }
                                else {
                                    Write-PSDWizardLog -Message "Could not find '$preselectedValue' in $controlName items for preselection" -LogLevel 1 -Component $FunctionName
                                }
                            }
                        }
                    }
                    elseif ($controlType -eq 'DataGrid') {
                        $gridData = @()
                        foreach ($item in $SyncHash.TSEnvLists[$listKey]) {
                            $gridData += [PSCustomObject]@{ Value = $item }
                        }
                        $control.ItemsSource = $gridData
                        Write-PSDWizardLog -Message "Populated $($gridData.Count) items into DataGrid $controlName from TSEnvLists['$listKey']" -Component $FunctionName
                    }

                    # Special handling for DomainOUs: Show dropdown if multiple, show textbox if 0 or 1
                    if ($listKey -eq 'DomainOUs') {
                        $ouTextBox = $Window.FindName('TSEnv_MachineObjectOU')
                        $ouCount = $control.Items.Count

                        if ($ouCount -gt 1) {
                            # Multiple OUs: Show dropdown, hide textbox
                            $control.Visibility = [System.Windows.Visibility]::Visible
                            if ($ouTextBox) {
                                $ouTextBox.Visibility = [System.Windows.Visibility]::Hidden
                            }
                            Write-PSDWizardLog -Message "Multiple OUs ($ouCount) found - showing dropdown, hiding textbox" -Component $FunctionName

                            # Add blank/empty option at the beginning (OU is optional)
                            $control.Items.Insert(0, "<Not specified>")
                            $control.SelectedIndex = 0

                            # Update event handler to handle blank selection
                            $control.Add_SelectionChanged({
                                param($sender, $e)
                                $selectedValue = $sender.SelectedItem

                                if ($selectedValue -and $selectedValue -ne "<Not specified>") {
                                    $targetField = [System.Windows.Window]::GetWindow($sender).FindName('TSEnv_MachineObjectOU')
                                    if ($targetField) {
                                        $targetField.Text = $selectedValue.ToString()
                                    }

                                    # Update SyncHash
                                    if ($script:PSDWizardSyncHash.TSEnvSettings) {
                                        $script:PSDWizardSyncHash.TSEnvSettings['MachineObjectOU'] = $selectedValue.ToString()
                                    }
                                    Set-PSDWizardTSEnvProperty -Name 'MachineObjectOU' -Value $selectedValue.ToString()
                                    Write-PSDWizardLog -Message "Selected OU: $selectedValue" -Component 'Initialize-PSDWizardData'
                                }
                                else {
                                    # Blank selected - clear OU
                                    $targetField = [System.Windows.Window]::GetWindow($sender).FindName('TSEnv_MachineObjectOU')
                                    if ($targetField) {
                                        $targetField.Text = ''
                                    }
                                    if ($script:PSDWizardSyncHash.TSEnvSettings) {
                                        $script:PSDWizardSyncHash.TSEnvSettings['MachineObjectOU'] = ''
                                    }
                                    Set-PSDWizardTSEnvProperty -Name 'MachineObjectOU' -Value ''
                                    Write-PSDWizardLog -Message "Cleared OU selection (optional)" -Component 'Initialize-PSDWizardData'
                                }
                            })
                        }
                        else {
                            # 0 or 1 OU: Hide dropdown, show textbox
                            $control.Visibility = [System.Windows.Visibility]::Hidden
                            if ($ouTextBox) {
                                $ouTextBox.Visibility = [System.Windows.Visibility]::Visible

                                # Pre-populate textbox if exactly 1 OU exists
                                if ($ouCount -eq 1) {
                                    $ouTextBox.Text = $control.Items[0].ToString()
                                    Write-PSDWizardLog -Message "Single OU found - pre-populated textbox with: $($control.Items[0])" -Component $FunctionName
                                }
                            }
                            Write-PSDWizardLog -Message "$ouCount OU(s) found - showing textbox, hiding dropdown" -Component $FunctionName
                        }
                    }
                }
            }
        }

        # Dynamically populate locale and timezone controls (special case with object properties)
        # Supports both old naming (_locTabSystemLocale) and new dynamic naming (Locales_SystemLocale)
        if ($SyncHash.Locales) {
            # First, try to find controls with new dynamic naming pattern: Locales_*
            $localeControlsFound = @()

            # Scan all controls for Locales_* pattern
            $allControlNames = $Window | Get-Member -MemberType Property | Where-Object { $_.Name -match '^Locales_' } | Select-Object -ExpandProperty Name
            foreach ($controlName in $allControlNames) {
                $localeControlsFound += @{
                    ControlName = $controlName
                    PropertyName = $controlName -replace '^Locales_', ''
                }
            }

            # Fall back to old hardcoded names if no dynamic controls found
            if ($localeControlsFound.Count -eq 0) {
                $localeControlsFound = @(
                    @{ ControlName = '_locTabSystemLocale'; PropertyName = 'SystemLocale' }
                    @{ ControlName = '_locTabKeyboardLocale'; PropertyName = 'KeyboardLocale' }
                    @{ ControlName = '_locTabLanguage'; PropertyName = 'UILanguage' }
                )
            }

            Write-PSDWizardLog -Message "Found $($localeControlsFound.Count) locale controls to populate" -Component $FunctionName

            foreach ($controlInfo in $localeControlsFound) {
                $controlName = $controlInfo.ControlName
                $propertyName = $controlInfo.PropertyName
                $localeControl = $Window.FindName($controlName)

                if ($localeControl -and $localeControl.GetType().Name -eq 'ComboBox') {
                    $localeControl.ItemsSource = $null
                    $localeControl.Items.Clear()

                    foreach ($locale in $SyncHash.Locales) {
                        $item = New-Object PSObject -Property @{
                            ID = $locale.ID
                            Name = $locale.Name
                            Language = $locale.Language
                            Culture = $locale.Culture
                            KeyboardID = $locale.KeyboardID
                            KeyboardLayout = $locale.KeyboardLayout
                            DisplayText = $locale.Name
                        }
                        $localeControl.Items.Add($item) | Out-Null
                    }

                    $localeControl.DisplayMemberPath = 'DisplayText'
                    $localeControl.SelectedValuePath = 'KeyboardLayout'

                    Write-PSDWizardLog -Message "Populated $($localeControl.Items.Count) locales into ComboBox $controlName" -Component $FunctionName

                    # Add SelectionChanged event handler to sync back to TSEnv
                    $localeControl.Add_SelectionChanged({
                        param($sender, $e)

                        $selectedLocale = $sender.SelectedItem
                        if ($selectedLocale) {
                            $controlName = $sender.Name

                            # Extract property name from control name dynamically
                            $tsenvPropertyName = if ($controlName -match '^Locales_(.+)$') {
                                $matches[1]
                            }
                            elseif ($controlName -match '^_locTab(.+)$') {
                                # Old naming convention mapping
                                switch ($matches[1]) {
                                    'SystemLocale' { 'SystemLocale' }
                                    'KeyboardLocale' { 'KeyboardLocale' }
                                    'Language' { 'UILanguage' }
                                    default { $matches[1] }
                                }
                            }
                            else {
                                $null
                            }

                            if ($tsenvPropertyName) {
                                # Determine which value property to use based on the TSEnv property name
                                $valueToStore = switch ($tsenvPropertyName) {
                                    'SystemLocale' { $selectedLocale.Culture }
                                    'KeyboardLocale' { $selectedLocale.KeyboardLayout }
                                    'UILanguage' { $selectedLocale.Culture }
                                    default { $selectedLocale.Culture }
                                }

                                # Update the corresponding TSEnv_ TextBox field
                                $win = [System.Windows.Window]::GetWindow($sender)
                                if ($win) {
                                    $tsenvField = $win.FindName("TSEnv_$tsenvPropertyName")
                                    if ($tsenvField) {
                                        $tsenvField.Text = $valueToStore
                                    }
                                }

                                # Update SyncHash for development mode
                                if ($SyncHash.TSEnvSettings) {
                                    $SyncHash.TSEnvSettings[$tsenvPropertyName] = $valueToStore
                                }

                                # Update actual TSEnv in production mode
                                try {
                                    Set-PSDWizardTSEnvProperty -Name $tsenvPropertyName -Value $valueToStore
                                    Write-PSDWizardLog -Message "Updated $tsenvPropertyName = $valueToStore" -Component 'Initialize-PSDWizardData'
                                }
                                catch {
                                    # Silently continue if TSEnv not available (development mode)
                                }
                            }
                        }
                    })

                    # Preselect based on TSEnv value
                    if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey($propertyName)) {
                        $preselectedValue = $SyncHash.TSEnvSettings[$propertyName]

                        if (-not [string]::IsNullOrWhiteSpace($preselectedValue)) {
                            # Find matching item based on property type
                            $matchingItem = $null

                            switch ($propertyName) {
                                'SystemLocale' {
                                    $matchingItem = $localeControl.Items | Where-Object {
                                        $_.Culture -ieq $preselectedValue -or $_.Name -ieq $preselectedValue
                                    } | Select-Object -First 1
                                }
                                'KeyboardLocale' {
                                    $matchingItem = $localeControl.Items | Where-Object {
                                        $_.KeyboardLayout -ieq $preselectedValue
                                    } | Select-Object -First 1
                                    if (-not $matchingItem) {
                                        # CustomSettings may use the documented culture alias instead of the layout ID.
                                        $matchingItem = $localeControl.Items | Where-Object {
                                            $_.Culture -ieq $preselectedValue -or $_.Name -ieq $preselectedValue -or
                                            $_.ID -ieq $preselectedValue -or $_.KeyboardID -ieq $preselectedValue
                                        } | Select-Object -First 1
                                    }
                                }
                                { $_ -in 'UILanguage', 'Language' } {
                                    $matchingItem = $localeControl.Items | Where-Object {
                                        $_.Culture -ieq $preselectedValue -or $_.Language -ieq $preselectedValue
                                    } | Select-Object -First 1
                                }
                                default {
                                    $matchingItem = $localeControl.Items | Where-Object {
                                        $_.Culture -ieq $preselectedValue
                                    } | Select-Object -First 1
                                }
                            }

                            if ($matchingItem) {
                                $localeControl.SelectedItem = $matchingItem
                                $normalizedValue = switch ($propertyName) {
                                    'KeyboardLocale' { [string]$matchingItem.KeyboardLayout }
                                    { $_ -in 'SystemLocale', 'UILanguage', 'Language' } { [string]$matchingItem.Culture }
                                    default { [string]$preselectedValue }
                                }
                                Write-PSDWizardLog -Message "Preselected locale '$preselectedValue' as '$normalizedValue' in $controlName" -Component $FunctionName

                                # Keep both the UI mirror and PSD's processed environment in canonical form.
                                $tsenvField = $Window.FindName("TSEnv_$propertyName")
                                if ($tsenvField) {
                                    $tsenvField.Text = $normalizedValue
                                }
                                if ($SyncHash.TSEnvSettings) {
                                    $SyncHash.TSEnvSettings[$propertyName] = $normalizedValue
                                }
                                try {
                                    Set-PSDWizardTSEnvProperty -Name $propertyName -Value $normalizedValue
                                }
                                catch {
                                    Write-PSDWizardLog -Message "Unable to normalize $propertyName in TSEnv: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
                                }
                            }
                            else {
                                Write-PSDWizardLog -Message "Could not find locale matching '$preselectedValue' in $controlName" -LogLevel 1 -Component $FunctionName
                            }
                        }
                    }
                }
            }
        }

        # Dynamically populate timezone controls (special case with object properties)
        # Supports both old naming (_locTabTimeZoneName) and new dynamic naming (TimeZoneIndex_TimeZoneName)
        if ($SyncHash.TimeZones) {
            # First, try to find controls with new dynamic naming pattern: TimeZoneIndex_*
            $timezoneControlsFound = @()

            # Scan all controls for TimeZoneIndex_* pattern
            $allControlNames = $Window | Get-Member -MemberType Property | Where-Object { $_.Name -match '^TimeZoneIndex_' } | Select-Object -ExpandProperty Name
            foreach ($controlName in $allControlNames) {
                $timezoneControlsFound += @{
                    ControlName = $controlName
                    PropertyName = $controlName -replace '^TimeZoneIndex_', ''
                }
            }

            # Fall back to old hardcoded names if no dynamic controls found
            if ($timezoneControlsFound.Count -eq 0) {
                $timezoneControlsFound = @(
                    @{ ControlName = '_locTabTimeZoneName'; PropertyName = 'TimeZoneName' }
                    @{ ControlName = '_locTabTimeZone'; PropertyName = 'TimeZone' }
                )
            }

            Write-PSDWizardLog -Message "Found $($timezoneControlsFound.Count) timezone controls to populate" -Component $FunctionName

            foreach ($controlInfo in $timezoneControlsFound) {
                $controlName = $controlInfo.ControlName
                $propertyName = $controlInfo.PropertyName
                $timezoneControl = $Window.FindName($controlName)

                if ($timezoneControl -and $timezoneControl.GetType().Name -eq 'ComboBox') {
                    $timezoneControl.ItemsSource = $null
                    $timezoneControl.Items.Clear()

                    foreach ($tz in $SyncHash.TimeZones) {
                        $item = New-Object PSObject -Property @{
                            id = $tz.id
                            TimeZone = $tz.TimeZone
                            DisplayName = $tz.DisplayName
                            Name = $tz.Name
                            UTC = $tz.UTC
                            DisplayText = $tz.TimeZone
                        }
                        $timezoneControl.Items.Add($item) | Out-Null
                    }

                    $timezoneControl.DisplayMemberPath = 'DisplayText'
                    $timezoneControl.SelectedValuePath = 'id'

                    Write-PSDWizardLog -Message "Populated $($timezoneControl.Items.Count) timezones into ComboBox $controlName" -Component $FunctionName

                    # Add SelectionChanged event handler to sync back to TSEnv
                    $timezoneControl.Add_SelectionChanged({
                        param($sender, $e)

                        $selectedTimezone = $sender.SelectedItem
                        if ($selectedTimezone) {
                            $controlName = $sender.Name

                            # Extract property name from control name dynamically
                            $tsenvPropertyName = if ($controlName -match '^TimeZoneIndex_(.+)$') {
                                $matches[1]
                            }
                            elseif ($controlName -match '^_locTab(.+)$') {
                                # Old naming convention - already formatted correctly
                                $matches[1]
                            }
                            else {
                                'TimeZoneName'  # Default fallback
                            }

                            # TimeZoneName property stores the timezone display name
                            $valueToStore = $selectedTimezone.TimeZone

                            # Update the corresponding TSEnv_ TextBox field
                            $win = [System.Windows.Window]::GetWindow($sender)
                            if ($win) {
                                $tsenvField = $win.FindName("TSEnv_$tsenvPropertyName")
                                if ($tsenvField) {
                                    $tsenvField.Text = $valueToStore
                                }
                            }

                            # Update SyncHash for development mode
                            if ($SyncHash.TSEnvSettings) {
                                $SyncHash.TSEnvSettings[$tsenvPropertyName] = $valueToStore
                            }

                            # Update actual TSEnv in production mode
                            try {
                                Set-PSDWizardTSEnvProperty -Name $tsenvPropertyName -Value $valueToStore
                                Write-PSDWizardLog -Message "Updated $tsenvPropertyName = $valueToStore" -Component 'Initialize-PSDWizardData'
                            }
                            catch {
                                # Silently continue if TSEnv not available (development mode)
                            }
                        }
                    })

                    # Preselect based on TSEnv value
                    if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey($propertyName)) {
                        $preselectedValue = $SyncHash.TSEnvSettings[$propertyName]

                        if (-not [string]::IsNullOrWhiteSpace($preselectedValue)) {
                            # Find matching timezone by TimeZone or DisplayName
                            $matchingTimezone = $timezoneControl.Items | Where-Object {
                                $_.TimeZone -eq $preselectedValue -or $_.DisplayName -eq $preselectedValue -or $_.Name -eq $preselectedValue
                            } | Select-Object -First 1

                            if ($matchingTimezone) {
                                $timezoneControl.SelectedItem = $matchingTimezone
                                Write-PSDWizardLog -Message "Preselected timezone '$preselectedValue' in $controlName" -Component $FunctionName

                                # Also update the TSEnv_ TextBox field
                                $tsenvField = $Window.FindName("TSEnv_$propertyName")
                                if ($tsenvField) {
                                    $tsenvField.Text = $preselectedValue
                                }
                            }
                            else {
                                Write-PSDWizardLog -Message "Could not find timezone matching '$preselectedValue' in $controlName" -LogLevel 1 -Component $FunctionName
                            }
                        }
                    }
                }
            }
        }

        #region TargetDisk Page Population
        # Check if TargetDisk page exists
        $diskControls = @('_lstDisks', '_lstVolumes', '_cmbTargetDisk', 'TSEnv_OSDDiskIndex')
        $hasTargetDiskPage = $false
        foreach ($controlName in $diskControls) {
            if ($Window.FindName($controlName)) {
                $hasTargetDiskPage = $true
                break
            }
        }

        if ($hasTargetDiskPage) {
            Write-PSDWizardLog -Message "Initializing TargetDisk page controls..." -Component $FunctionName

            # Collect disk information
            # Each collection uses its own try/catch so a failure enumerating partitions/volumes
            # (e.g. an unpartitioned/raw target disk, which is common before OS deployment) does
            # not wipe out the disk list that was already retrieved successfully.
            $SyncHash.Disks = @()
            $SyncHash.PhysicalDisks = @()
            $SyncHash.Partitions = @()
            $SyncHash.Volumes = @()

            try {
                $SyncHash.Disks = @(Get-Disk -ErrorAction Stop | Sort-Object Number)
            }
            catch {
                Write-PSDWizardLog -Message "Error collecting disks: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
            }

            try {
                $SyncHash.PhysicalDisks = @(Get-PhysicalDisk -ErrorAction Stop)
            }
            catch {
                Write-PSDWizardLog -Message "Error collecting physical disks: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
            }

            try {
                $SyncHash.Partitions = @($SyncHash.Disks | Get-Partition -ErrorAction SilentlyContinue)
            }
            catch {
                Write-PSDWizardLog -Message "Error collecting partitions: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
            }

            try {
                $SyncHash.Volumes = @($SyncHash.Partitions | Get-Volume -ErrorAction SilentlyContinue)
            }
            catch {
                Write-PSDWizardLog -Message "Error collecting volumes: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
            }

            Write-PSDWizardLog -Message "Found $($SyncHash.Disks.Count) disks, $($SyncHash.Volumes.Count) volumes" -Component $FunctionName

            # Populate _lstDisks ListView
            $lstDisks = $Window.FindName('_lstDisks')
            if ($lstDisks -and $SyncHash.Disks) {
                try {
                    $diskData = @($SyncHash.Disks | Select-Object Number, FriendlyName, PartitionStyle,
                        @{Name="Model"; Expression={
                            ($SyncHash.PhysicalDisks | Where-Object DeviceID -eq $_.Number).Model
                        }},
                        @{Name="Bus"; Expression={
                            ($SyncHash.PhysicalDisks | Where-Object DeviceID -eq $_.Number).BusType
                        }},
                        @{Name="Media"; Expression={
                            ($SyncHash.PhysicalDisks | Where-Object DeviceID -eq $_.Number).MediaType
                        }},
                        @{Name="Size"; Expression={
                            ([math]::round($_.Size / 1GB, 2)).ToString() + ' GB'
                        }})

                    $lstDisks.ItemsSource = $diskData
                    Write-PSDWizardLog -Message "Populated _lstDisks with $($diskData.Count) disks" -Component $FunctionName
                }
                catch {
                    Write-PSDWizardLog -Message "Error populating _lstDisks: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
                }
            }

            # Populate _lstVolumes ListView
            $lstVolumes = $Window.FindName('_lstVolumes')
            if ($lstVolumes -and $SyncHash.Volumes) {
                try {
                    $volumeData = @($SyncHash.Volumes | Sort-Object DriveLetter |
                        Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType,
                            @{Name="Disk"; Expression={
                                $volDriveLetter = $_.DriveLetter
                                ($SyncHash.Partitions | Where-Object { $_.AccessPaths -contains "$($volDriveLetter):\" }).DiskNumber
                            }},
                            @{Name="Size"; Expression={
                                ([math]::round($_.Size / 1GB, 2)).ToString() + ' GB'
                            }},
                            @{Name="SizeRemaining"; Expression={
                                ([math]::round($_.SizeRemaining / 1GB, 2)).ToString() + ' GB'
                                }})

                    $lstVolumes.ItemsSource = $volumeData
                    Write-PSDWizardLog -Message "Populated _lstVolumes with $($volumeData.Count) volumes" -Component $FunctionName
                }
                catch {
                    Write-PSDWizardLog -Message "Error populating _lstVolumes: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
                }
            }

            # Populate _cmbTargetDisk ComboBox
            $cmbTargetDisk = $Window.FindName('_cmbTargetDisk')
            if ($cmbTargetDisk -and $SyncHash.Disks) {
                try {
                    # Clear existing items
                    $cmbTargetDisk.Items.Clear()

                    # Add disk numbers to ComboBox
                    foreach ($disk in $SyncHash.Disks) {
                        $cmbTargetDisk.Items.Add($disk.Number) | Out-Null
                    }

                    Write-PSDWizardLog -Message "Populated _cmbTargetDisk with $($cmbTargetDisk.Items.Count) disk indices" -Component $FunctionName

                    # Preselect based on TSEnvSettings OSDDiskIndex
                    if ($SyncHash.TSEnvSettings -and $SyncHash.TSEnvSettings.ContainsKey('OSDDiskIndex')) {
                        $preselectedDiskIndex = $SyncHash.TSEnvSettings['OSDDiskIndex']

                        if (-not [string]::IsNullOrWhiteSpace($preselectedDiskIndex)) {
                            # Convert to int
                            try {
                                $diskIndex = [int]$preselectedDiskIndex

                                if ($diskIndex -in $SyncHash.Disks.Number) {
                                    $cmbTargetDisk.SelectedItem = $diskIndex
                                    Write-PSDWizardLog -Message "Preselected disk index $diskIndex in _cmbTargetDisk" -Component $FunctionName
                                }
                                else {
                                    Write-PSDWizardLog -Message "OSDDiskIndex $diskIndex not found in available disks, defaulting to first disk" -LogLevel 1 -Component $FunctionName
                                    $cmbTargetDisk.SelectedIndex = 0
                                }
                            }
                            catch {
                                Write-PSDWizardLog -Message "Invalid OSDDiskIndex format: $preselectedDiskIndex, defaulting to first disk" -LogLevel 1 -Component $FunctionName
                                $cmbTargetDisk.SelectedIndex = 0
                            }
                        }
                        else {
                            # Default to first disk
                            $cmbTargetDisk.SelectedIndex = 0
                            Write-PSDWizardLog -Message "No OSDDiskIndex specified, defaulting to first disk" -Component $FunctionName
                        }
                    }
                    else {
                        # Default to first disk
                        $cmbTargetDisk.SelectedIndex = 0
                        Write-PSDWizardLog -Message "No TSEnvSettings OSDDiskIndex, defaulting to first disk" -Component $FunctionName
                    }
                }
                catch {
                    Write-PSDWizardLog -Message "Error populating _cmbTargetDisk: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
                }
            }

            # Add event handlers

            # _cmbTargetDisk SelectionChanged event
            if ($cmbTargetDisk) {
                $cmbTargetDisk.Add_SelectionChanged({
                    param($sender, $e)

                    $selectedDiskIndex = $sender.SelectedItem

                    if ($null -ne $selectedDiskIndex) {
                        # Get Window reference
                        $win = [System.Windows.Window]::GetWindow($sender)

                        # Update TSEnv_OSDDiskIndex TextBox
                        $tsOSDDiskIndex = $win.FindName('TSEnv_OSDDiskIndex')
                        if ($tsOSDDiskIndex) {
                            $tsOSDDiskIndex.Text = $selectedDiskIndex.ToString()
                        }

                        # Update SyncHash.TSEnvSettings
                        if ($SyncHash.TSEnvSettings) {
                            $SyncHash.TSEnvSettings['OSDDiskIndex'] = $selectedDiskIndex.ToString()
                        }

                        Write-PSDWizardLog -Message "Selected disk index: $selectedDiskIndex" -Component 'TargetDisk_Event'
                    }
                })

                Write-PSDWizardLog -Message "Added SelectionChanged event handler to _cmbTargetDisk" -Component $FunctionName
            }

            # _lstDisks SelectionChanged event
            if ($lstDisks) {
                $lstDisks.Add_SelectionChanged({
                    param($sender, $e)

                    if ($sender.SelectedItem) {
                        $selectedDisk = $sender.SelectedItem
                        $diskNumber = $selectedDisk.Number

                        # Get Window reference
                        $win = [System.Windows.Window]::GetWindow($sender)

                        # Update ComboBox
                        $cmbTargetDisk = $win.FindName('_cmbTargetDisk')
                        if ($cmbTargetDisk) {
                            $cmbTargetDisk.SelectedItem = $diskNumber
                        }

                        # Update TSEnv_OSDDiskIndex TextBox
                        $tsOSDDiskIndex = $win.FindName('TSEnv_OSDDiskIndex')
                        if ($tsOSDDiskIndex) {
                            $tsOSDDiskIndex.Text = $diskNumber.ToString()
                        }

                        # Clear volume selection
                        $lstVolumes = $win.FindName('_lstVolumes')
                        if ($lstVolumes) {
                            $lstVolumes.SelectedItem = $null
                        }

                        # Clear pie chart
                        $imgPieChart = $win.FindName('_imgPieChart')
                        if ($imgPieChart) {
                            $imgPieChart.Source = $null
                        }

                        Write-PSDWizardLog -Message "Disk $diskNumber selected from ListView" -Component 'TargetDisk_Event'
                    }
                })

                Write-PSDWizardLog -Message "Added SelectionChanged event handler to _lstDisks" -Component $FunctionName
            }

            # _lstVolumes SelectionChanged event (with pie chart generation)
            if ($lstVolumes) {
                $lstVolumes.Add_SelectionChanged({
                    param($sender, $e)

                    if ($sender.SelectedItem) {
                        $selectedVolume = $sender.SelectedItem
                        $driveLetter = $selectedVolume.DriveLetter

                        Write-PSDWizardLog -Message "Volume $driveLetter selected from ListView" -Component 'TargetDisk_Event'

                        # Get volume details for pie chart
                        try {
                            $vol = $SyncHash.Volumes | Where-Object { $_.DriveLetter -eq $driveLetter } | Select-Object -First 1

                            if ($vol) {
                                # Ensure numeric values (handle potential arrays)
                                $volSize = if ($vol.Size -is [array]) { $vol.Size[0] } else { $vol.Size }
                                $volSizeRemaining = if ($vol.SizeRemaining -is [array]) { $vol.SizeRemaining[0] } else { $vol.SizeRemaining }

                                # Validate we have valid numbers
                                if ($null -ne $volSize -and $null -ne $volSizeRemaining -and $volSize -gt 0) {
                                    # Create hash table for volume data
                                    $volDataSet = @{
                                        FreeVol = @{
                                            Header = "Free Space"
                                            Value = [math]::Round(($volSizeRemaining / 1GB), 2)
                                        }
                                        UsedVol = @{
                                            Header = "Used Space"
                                            Value = [math]::Round((($volSize - $volSizeRemaining) / 1GB), 2)
                                        }
                                    }

                                    # Generate pie chart
                                    Add-Type -AssemblyName System.Windows.Forms, System.Windows.Forms.DataVisualization

                                $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
                                $chart.Width = 200
                                $chart.Height = 160
                                $chart.Left = 0
                                $chart.Top = 0

                                $chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
                                $chart.ChartAreas.Add($chartArea)
                                [void]$chart.Series.Add("Data")

                                # Add data points
                                $volDataSet.GetEnumerator() | ForEach-Object {
                                    $datapoint = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint(0, $_.Value.Value)
                                    $datapoint.AxisLabel = "$($_.Value.Header) ($($_.Value.Value) GB)"
                                    $chart.Series["Data"].Points.Add($datapoint)
                                }

                                $chart.Series["Data"].ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Pie
                                $chart.Series["Data"]["PieLabelStyle"] = "Outside"
                                $chart.Series["Data"]["PieLineColor"] = "Black"
                                $chart.Series["Data"]["PieDrawingStyle"] = "Concave"
                                ($chart.Series["Data"].Points.FindMaxByValue())["Exploded"] = $true

                                # Set title
                                $title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
                                $chart.Titles.Add($title)
                                $chart.Titles[0].Text = "Volume Usage for: $driveLetter"

                                # Save chart as image
                                $chartFile = Join-Path $env:Temp "${driveLetter}_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
                                $chart.SaveImage($chartFile, "PNG")

                                # Display in UI
                                $win = [System.Windows.Window]::GetWindow($sender)
                                $imgPieChart = $win.FindName('_imgPieChart')
                                if ($imgPieChart) {
                                    $imgPieChart.Source = $chartFile
                                }

                                $chart.Dispose()

                                Write-PSDWizardLog -Message "Generated pie chart for volume $driveLetter at: $chartFile" -Component 'TargetDisk_Event'
                                }
                                else {
                                    Write-PSDWizardLog -Message "Invalid volume data for $driveLetter (Size: $volSize, Remaining: $volSizeRemaining)" -LogLevel 1 -Component 'TargetDisk_Event'
                                }
                            }
                            else {
                                Write-PSDWizardLog -Message "Volume $driveLetter not found in SyncHash.Volumes" -LogLevel 1 -Component 'TargetDisk_Event'
                            }
                        }
                        catch {
                            Write-PSDWizardLog -Message "Error generating pie chart: $($_.Exception.Message)" -LogLevel 2 -Component 'TargetDisk_Event'
                        }
                    }
                })

                Write-PSDWizardLog -Message "Added SelectionChanged event handler to _lstVolumes (with pie chart)" -Component $FunctionName
            }

            # TSEnv_OSDDiskIndex TextChanged event
            $tsOSDDiskIndex = $Window.FindName('TSEnv_OSDDiskIndex')
            if ($tsOSDDiskIndex) {
                $tsOSDDiskIndex.Add_TextChanged({
                    param($sender, $e)

                    # Get Window reference
                    $win = [System.Windows.Window]::GetWindow($sender)
                    $wizNext = $win.FindName('_wizNext')

                    if ($wizNext) {
                        $diskIndexText = $sender.Text

                        if (-not [string]::IsNullOrWhiteSpace($diskIndexText)) {
                            try {
                                $diskIndex = [int]$diskIndexText

                                if ($diskIndex -in $SyncHash.Disks.Number) {
                                    $wizNext.IsEnabled = $true
                                    Write-PSDWizardLog -Message "Valid disk index $diskIndex entered, Next button enabled" -Component 'TargetDisk_Event'
                                }
                                else {
                                    $wizNext.IsEnabled = $false
                                    Write-PSDWizardLog -Message "Invalid disk index $diskIndex entered, Next button disabled" -LogLevel 1 -Component 'TargetDisk_Event'
                                }
                            }
                            catch {
                                $wizNext.IsEnabled = $false
                                Write-PSDWizardLog -Message "Invalid disk index format: $diskIndexText" -LogLevel 1 -Component 'TargetDisk_Event'
                            }
                        }
                        else {
                            $wizNext.IsEnabled = $false
                        }
                    }
                })

                Write-PSDWizardLog -Message "Added TextChanged event handler to TSEnv_OSDDiskIndex" -Component $FunctionName
            }
        }
        #endregion TargetDisk Page Population

        # Dynamically populate TSEnv ListView on Ready/Summary page with all TSEnv properties
        $tsenvListView = $Window.FindName('TSEnv')
        if ($tsenvListView) {
            Write-PSDWizardLog -Message "Found TSEnv ListView control for Summary page" -Component $FunctionName

            # Clear any existing items (just set ItemsSource to null, don't call .Items.Clear())
            $tsenvListView.ItemsSource = $null

            # Collect all TSEnv properties
            $tsenvSummaryData = @()

            if ($SyncHash.TSEnvSettings) {
                # Get all TSEnv properties and sort by name
                $sortedProperties = $SyncHash.TSEnvSettings.GetEnumerator() | Sort-Object Name

                foreach ($property in $sortedProperties) {
                    $name = $property.Key
                    $value = $property.Value

                    # Format array values nicely
                    if ($value -is [array]) {
                        $value = $value -join ', '
                    }

                    # Handle null/empty values
                    if ([string]::IsNullOrWhiteSpace($value)) {
                        $value = '<empty>'
                    }

                    # Never expose password or credential values in the Summary ListView.
                    if ([string]$name -match '(?i)(password|passwd|secret|credential)') {
                        $value = '********'
                    }

                    # Special handling for Applications - show names instead of GUIDs
                    if ($name -match '^(Applications|MandatoryApplications)\d{3}$' -and $SyncHash.Applications) {
                        # Look up the application name from GUID
                        $appGuid = $value
                        $app = $SyncHash.Applications | Where-Object { $_.guid -eq $appGuid } | Select-Object -First 1
                        if ($app) {
                            $value = "$($app.Name) [$appGuid]"
                        }
                    }

                    # Add to summary data
                    $tsenvSummaryData += [PSCustomObject]@{
                        Name = $name
                        Value = $value
                    }
                }

                # Set the ItemsSource to populate the ListView
                $tsenvListView.ItemsSource = $tsenvSummaryData

                Write-PSDWizardLog -Message "Populated $($tsenvSummaryData.Count) TSEnv properties into Summary ListView" -Component $FunctionName
            }
            else {
                Write-PSDWizardLog -Message "No TSEnvSettings available to populate Summary ListView" -LogLevel 1 -Component $FunctionName
            }
        }
        else {
            Write-PSDWizardLog -Message "TSEnv ListView not found (Summary page may not be included in this theme)" -LogLevel 1 -Component $FunctionName
        }

        #region RADIO BUTTON HANDLERS (Domain/Workgroup Selection)

        # Check if Domain/Workgroup radio buttons exist in the current theme
        $radJoinDomain = $Window.FindName('_JoinDomainRadio')
        $radJoinWorkgroup = $Window.FindName('_JoinWorkgroupRadio')

        if ($radJoinDomain -and $radJoinWorkgroup) {
            Write-PSDWizardLog -Message "Setting up Domain/Workgroup radio button handlers" -Component $FunctionName

            # Save original values from TSEnv (these will be restored when switching between options)
            $script:SavedJoinDomain = Get-PSDWizardTSEnvProperty 'JoinDomain' -ValueOnly
            $script:SavedJoinWorkgroup = Get-PSDWizardTSEnvProperty 'JoinWorkgroup' -ValueOnly

            Write-PSDWizardLog -Message "Saved original Domain: [$script:SavedJoinDomain], Workgroup: [$script:SavedJoinWorkgroup]" -Component $FunctionName

            # Find the grid containers that show/hide domain vs workgroup fields
            $grdJoinDomain = $Window.FindName('_grdJoinDomain')
            $grdJoinWorkgroup = $Window.FindName('_grdJoinWorkgroup')

            # Find the textbox controls for domain and workgroup
            $txtJoinDomain = $Window.FindName('TSEnv_JoinDomain')
            $txtJoinWorkgroup = $Window.FindName('TSEnv_JoinWorkgroup')

            # Set initial visibility: Hide both grids first (they'll be shown by event handlers)
            if ($grdJoinDomain) {
                $grdJoinDomain.Visibility = [System.Windows.Visibility]::Collapsed
                Write-PSDWizardLog -Message "Initially collapsed Domain grid" -Component $FunctionName
            }
            if ($grdJoinWorkgroup) {
                $grdJoinWorkgroup.Visibility = [System.Windows.Visibility]::Collapsed
                Write-PSDWizardLog -Message "Initially collapsed Workgroup grid" -Component $FunctionName
            }

            # Find the Next button (may be null if not available yet, but we can try)
            $btnNext = $Window.FindName('_wizNext')

            # Event handler: When Domain radio is checked
            $radJoinDomain.Add_Checked({
                Write-PSDWizardLog -Message "Domain radio checked - switching to domain join mode" -Component 'Initialize-PSDWizardData'

                # Find controls inside scriptblock (closure scope issue)
                $wnd = $script:PSDWizardSyncHash.Window
                $txtDomain = $wnd.FindName('TSEnv_JoinDomain')
                $txtWG = $wnd.FindName('TSEnv_JoinWorkgroup')
                $grdDomain = $wnd.FindName('_grdJoinDomain')
                $grdWG = $wnd.FindName('_grdJoinWorkgroup')

                # Clear workgroup value
                if ($txtWG) {
                    $txtWG.Text = $null
                    Set-PSDWizardTSEnvProperty -Name 'JoinWorkgroup' -Value $null
                }

                # Clear validation canvas (since we're switching modes)
                $validationCanvas = $wnd.FindName('_detTabValidation2')
                if ($validationCanvas) {
                    $validationCanvas.Visibility = "Hidden"
                }

                # Restore saved domain value
                if ($txtDomain -and -not [string]::IsNullOrWhiteSpace($script:SavedJoinDomain)) {
                    $txtDomain.Text = $script:SavedJoinDomain
                    Set-PSDWizardTSEnvProperty -Name 'JoinDomain' -Value $script:SavedJoinDomain
                }

                # Show domain grid, hide workgroup grid
                if ($grdDomain) {
                    $grdDomain.Visibility = [System.Windows.Visibility]::Visible
                    Write-PSDWizardLog -Message "Domain grid set to Visible" -Component 'Initialize-PSDWizardData'
                }
                if ($grdWG) {
                    $grdWG.Visibility = [System.Windows.Visibility]::Collapsed
                    Write-PSDWizardLog -Message "Workgroup grid set to Collapsed" -Component 'Initialize-PSDWizardData'
                }

                # Trigger validation for domain field if it has content (shows per-field validation message)
                if ($txtDomain -and -not [string]::IsNullOrWhiteSpace($txtDomain.Text)) {
                    Invoke-PSDWizardFieldValidation -Window $wnd -ControlName 'TSEnv_JoinDomain' -ValidationCanvasName '_detTabValidation2_Name'
                }

                # Trigger comprehensive domain requirements validation (controls Next button)
                Confirm-PSDWizardDomainRequirements -Window $wnd -UpdateNextButton
            })

            # Event handler: When Workgroup radio is checked
            $radJoinWorkgroup.Add_Checked({
                Write-PSDWizardLog -Message "Workgroup radio checked - switching to workgroup mode" -Component 'Initialize-PSDWizardData'

                # Find controls inside scriptblock (closure scope issue)
                $wnd = $script:PSDWizardSyncHash.Window
                $txtDomain = $wnd.FindName('TSEnv_JoinDomain')
                $txtWG = $wnd.FindName('TSEnv_JoinWorkgroup')
                $grdDomain = $wnd.FindName('_grdJoinDomain')
                $grdWG = $wnd.FindName('_grdJoinWorkgroup')

                # Clear domain value
                if ($txtDomain) {
                    $txtDomain.Text = $null
                    Set-PSDWizardTSEnvProperty -Name 'JoinDomain' -Value $null
                }

                # Clear validation canvas (since we're switching modes)
                $validationCanvas = $wnd.FindName('_detTabValidation2')
                if ($validationCanvas) {
                    $validationCanvas.Visibility = "Hidden"
                }

                # Restore saved workgroup value
                if ($txtWG -and -not [string]::IsNullOrWhiteSpace($script:SavedJoinWorkgroup)) {
                    $txtWG.Text = $script:SavedJoinWorkgroup
                    Set-PSDWizardTSEnvProperty -Name 'JoinWorkgroup' -Value $script:SavedJoinWorkgroup
                }

                # Hide domain grid, show workgroup grid
                if ($grdDomain) {
                    $grdDomain.Visibility = [System.Windows.Visibility]::Collapsed
                    Write-PSDWizardLog -Message "Domain grid set to Collapsed" -Component 'Initialize-PSDWizardData'
                }
                if ($grdWG) {
                    $grdWG.Visibility = [System.Windows.Visibility]::Visible
                    Write-PSDWizardLog -Message "Workgroup grid set to Visible" -Component 'Initialize-PSDWizardData'
                }

                # Re-enable Next button (domain validation may have disabled it)
                # Workgroup validation will control it from here
                $nextButton = $wnd.FindName('_wizNext')
                if ($nextButton) {
                    $nextButton.IsEnabled = $true
                }

                # Trigger validation for workgroup field if it has content
                if ($txtWG -and -not [string]::IsNullOrWhiteSpace($txtWG.Text)) {
                    Invoke-PSDWizardFieldValidation -Window $wnd -ControlName 'TSEnv_JoinWorkgroup' -ValidationCanvasName '_detTabValidation2_Name' -UpdateNextButton
                }
            })

            # Determine initial state: Pre-select the appropriate radio button
            # Priority: Domain takes precedence over Workgroup if both are set
            if (-not [string]::IsNullOrWhiteSpace($script:SavedJoinDomain)) {
                Write-PSDWizardLog -Message "Pre-selecting Domain radio (JoinDomain='$script:SavedJoinDomain')" -Component $FunctionName

                # Manually trigger visibility update (event handler may not fire when setting programmatically)
                if ($txtJoinDomain) {
                    $txtJoinDomain.Text = $script:SavedJoinDomain
                    Set-PSDWizardTSEnvProperty -Name 'JoinDomain' -Value $script:SavedJoinDomain
                    Write-PSDWizardLog -Message "Set domain textbox to: $($script:SavedJoinDomain)" -Component $FunctionName
                }
                if ($grdJoinDomain) {
                    $grdJoinDomain.Visibility = [System.Windows.Visibility]::Visible
                    Write-PSDWizardLog -Message "Manually set Domain grid to Visible (IsVisible=$($grdJoinDomain.IsVisible))" -Component $FunctionName
                }
                if ($grdJoinWorkgroup) {
                    $grdJoinWorkgroup.Visibility = [System.Windows.Visibility]::Collapsed
                    Write-PSDWizardLog -Message "Manually set Workgroup grid to Collapsed" -Component $FunctionName
                }

                $radJoinDomain.IsChecked = $true
            }
            elseif (-not [string]::IsNullOrWhiteSpace($script:SavedJoinWorkgroup)) {
                Write-PSDWizardLog -Message "Pre-selecting Workgroup radio (JoinWorkgroup='$script:SavedJoinWorkgroup')" -Component $FunctionName

                # Manually trigger visibility update
                if ($txtJoinWorkgroup) {
                    $txtJoinWorkgroup.Text = $script:SavedJoinWorkgroup
                    Set-PSDWizardTSEnvProperty -Name 'JoinWorkgroup' -Value $script:SavedJoinWorkgroup
                    Write-PSDWizardLog -Message "Set workgroup textbox to: $($script:SavedJoinWorkgroup)" -Component $FunctionName
                }
                if ($grdJoinWorkgroup) {
                    $grdJoinWorkgroup.Visibility = [System.Windows.Visibility]::Visible
                    Write-PSDWizardLog -Message "Manually set Workgroup grid to Visible (IsVisible=$($grdJoinWorkgroup.IsVisible))" -Component $FunctionName
                }
                if ($grdJoinDomain) {
                    $grdJoinDomain.Visibility = [System.Windows.Visibility]::Collapsed
                    Write-PSDWizardLog -Message "Manually set Domain grid to Collapsed" -Component $FunctionName
                }

                $radJoinWorkgroup.IsChecked = $true
            }
            else {
                # Neither is set - default to Domain
                Write-PSDWizardLog -Message "No Domain or Workgroup value found - defaulting to Domain radio" -Component $FunctionName

                # Manually show domain grid
                if ($grdJoinDomain) {
                    $grdJoinDomain.Visibility = [System.Windows.Visibility]::Visible
                    Write-PSDWizardLog -Message "Manually set Domain grid to Visible (default) (IsVisible=$($grdJoinDomain.IsVisible))" -Component $FunctionName
                }
                if ($grdJoinWorkgroup) {
                    $grdJoinWorkgroup.Visibility = [System.Windows.Visibility]::Collapsed
                    Write-PSDWizardLog -Message "Manually set Workgroup grid to Collapsed (default)" -Component $FunctionName
                }

                $radJoinDomain.IsChecked = $true
            }

            # Trigger initial validation based on which radio is selected
            # This ensures Next button is properly disabled if required fields are empty
            if ($radJoinDomain.IsChecked -eq $true) {
                Write-PSDWizardLog -Message "Running initial domain validation to set Next button state" -Component $FunctionName
                Confirm-PSDWizardDomainRequirements -Window $Window -ValidationCanvasName '_detTabValidation2_Name' -UpdateNextButton
            }

            Write-PSDWizardLog -Message "Domain/Workgroup radio button handlers configured successfully" -Component $FunctionName
        }
        else {
            Write-PSDWizardLog -Message "Domain/Workgroup radio buttons not found (DeviceDetails page may not be included in this theme)" -LogLevel 1 -Component $FunctionName
        }

        #endregion

        #region DOMAIN FIELDS COMPREHENSIVE VALIDATION

        # Add validation handlers for domain join account password and domain fields
        # These trigger comprehensive domain validation to ensure all required fields are filled
        $domainPasswordField = $Window.FindName('TSEnv_DomainAdminPassword')
        $domainConfirmPasswordField = $Window.FindName('_DomainAdminConfirmPassword')
        $domainAdminDomainField = $Window.FindName('TSEnv_DomainAdminDomain')

        if ($domainPasswordField -and $domainConfirmPasswordField) {
            Write-PSDWizardLog -Message "Adding domain password validation handlers" -Component $FunctionName

            # Create handler that triggers comprehensive domain validation
            $domainPasswordValidationHandler = {
                param($sender, $e)
                $wnd = [System.Windows.Window]::GetWindow($sender)
                if ($wnd) {
                    Confirm-PSDWizardDomainRequirements -Window $wnd -ValidationCanvasName '_detTabValidation2_Name' -UpdateNextButton
                }
            }

            # Wire up to both password fields
            $domainPasswordField.Add_PasswordChanged($domainPasswordValidationHandler)
            $domainConfirmPasswordField.Add_PasswordChanged($domainPasswordValidationHandler)

            Write-PSDWizardLog -Message "Added PasswordChanged handlers for domain join account passwords" -Component $FunctionName
        }

        if ($domainAdminDomainField) {
            Write-PSDWizardLog -Message "Adding domain admin domain validation handler" -Component $FunctionName

            # GotFocus - validate when user enters field
            $domainAdminDomainField.Add_GotFocus({
                param($sender, $e)
                $wnd = [System.Windows.Window]::GetWindow($sender)
                if ($wnd) {
                    Confirm-PSDWizardDomainRequirements -Window $wnd -ValidationCanvasName '_detTabValidation2_Name' -UpdateNextButton
                }
            })

            # TextChanged - validate as user types
            $domainAdminDomainField.Add_TextChanged({
                param($sender, $e)
                $wnd = [System.Windows.Window]::GetWindow($sender)
                if ($wnd) {
                    Confirm-PSDWizardDomainRequirements -Window $wnd -ValidationCanvasName '_detTabValidation2_Name' -UpdateNextButton
                }
            })

            Write-PSDWizardLog -Message "Added validation handlers for TSEnv_DomainAdminDomain" -Component $FunctionName
        }

        #endregion

        # The generated page controls whether readiness scripts are eligible to run.
        $readinessPage = $Window.FindName('_wizReadiness')
        if (-not $readinessPage) {
            Write-PSDWizardLog -Message "Deployment Readiness page is not present - skipping readiness checks" -Component $FunctionName
        }
        elseif ($SyncHash.ResourcePath) {
            Write-PSDWizardLog -Message "Invoking deployment readiness checks..." -Component $FunctionName
            try {
                $SyncHash.ReadinessChecksPassed = Invoke-PSDWizardReadinessChecks -Window $Window -ResourcePath $SyncHash.ResourcePath -TSEnvSettings $SyncHash.TSEnvSettings
            }
            catch {
                $SyncHash.ReadinessChecksPassed = $false
                Write-PSDWizardLog -Message "Error during readiness checks: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
            }
        }
        else {
            Write-PSDWizardLog -Message "ResourcePath not found in SyncHash - skipping readiness checks" -LogLevel 1 -Component $FunctionName
        }
        # Update the visibility of all pages based on the current state
        Update-PSDWizardPageVisibility -Window $Window -SyncHash $SyncHash
        # Initialize the role feature list based on the current state
        Initialize-PSDWizardRoleFeatureList -Window $Window -SyncHash $SyncHash

        Write-PSDWizardLog -Message "Data initialization complete" -Component $FunctionName

        # Wire up page-specific event handlers
        Initialize-PSDWizardPageHandlers -Window $Window -SyncHash $SyncHash
    }
    catch {
        Write-PSDWizardLog -Message "Error initializing data: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

Function Initialize-PSDWizardPageHandlers {
    <#
    .SYNOPSIS
        Coordinator function that wires up all page-specific event handlers
    .DESCRIPTION
        Detects which pages exist in the wizard and calls the appropriate
        registration function for each page to wire up its event handlers
    .PARAMETER Window
        WPF window object
    .PARAMETER SyncHash
        Synchronized hashtable with loaded data
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Registering page-specific event handlers..." -Component $FunctionName

    try {
        # Task Sequence page
        if ($Window.FindName('_wizTaskSequence')) {
            Write-PSDWizardLog -Message "Registering Task Sequence page handlers" -Component $FunctionName
            Register-PSDWizardTaskSequenceHandlers -Window $Window -SyncHash $SyncHash
        }

        # Applications page
        if ($Window.FindName('_wizApplications')) {
            Write-PSDWizardLog -Message "Registering Applications page handlers" -Component $FunctionName
            Register-PSDWizardApplicationHandlers -Window $Window -SyncHash $SyncHash
        }

        # Target Disk page
        $diskControls = @('_lstDisks', '_lstVolumes', '_cmbTargetDisk')
        $hasTargetDiskPage = $false
        foreach ($controlName in $diskControls) {
            if ($Window.FindName($controlName)) {
                $hasTargetDiskPage = $true
                break
            }
        }

        if ($hasTargetDiskPage) {
            Write-PSDWizardLog -Message "Registering Target Disk page handlers" -Component $FunctionName
            Register-PSDWizardTargetDiskHandlers -Window $Window -SyncHash $SyncHash
        }

        Write-PSDWizardLog -Message "Page handler registration complete" -Component $FunctionName
    }
    catch {
        Write-PSDWizardLog -Message "Error registering page handlers: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

Function Register-PSDWizardTaskSequenceHandlers {
    <#
    .SYNOPSIS
        Registers all event handlers for the Task Sequence selection page
    .DESCRIPTION
        Wires up Search, Clear, Expand All, Collapse All buttons and search textbox
        placeholder behavior for the Task Sequence page
    .PARAMETER Window
        WPF window object
    .PARAMETER SyncHash
        Synchronized hashtable with loaded data
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Wiring up Task Sequence page handlers..." -Component $FunctionName

    try {
        # Find the TS control (TreeView, ListBox, or DataGrid)
        $tsControlNames = @('_tsTabTree', '_tsTabList', 'TSEnv_TaskSequence', '_lstTaskSequence')
        $tsTreeControl = $null
        foreach ($controlName in $tsControlNames) {
            $tsTreeControl = $Window.FindName($controlName)
            if ($tsTreeControl) {
                break
            }
        }

        if (-not $tsTreeControl) {
            Write-PSDWizardLog -Message "No Task Sequence control found - skipping handler registration" -LogLevel 1 -Component $FunctionName
            return
        }

        # Find button controls
        $searchButton = $Window.FindName('_tsTabSearchEnter')
        $clearButton = $Window.FindName('_tsTabSearchClear')
        $expandButton = $Window.FindName('_tsTabExpand')
        $collapseButton = $Window.FindName('_tsTabCollapse')
        $searchTextBox = $Window.FindName('_tsTabSearch')

        # Wire up Search textbox placeholder behavior
        if ($searchTextBox) {
            # Initially disable search buttons
            if ($searchButton) { $searchButton.IsEnabled = $false }
            if ($clearButton) { $clearButton.IsEnabled = $false }

            # Add placeholder text behavior (clear on focus, restore on blur)
            $searchTextBox.Add_GotFocus({
                param($sender, $e)
                if ($sender.Text -eq 'Search...') {
                    $sender.Text = ''
                    $sender.Foreground = 'Black'
                }
            })

            $searchTextBox.Add_LostFocus({
                param($sender, $e)
                if ([string]::IsNullOrWhiteSpace($sender.Text)) {
                    $sender.Text = 'Search...'
                    $sender.Foreground = 'Gray'
                }
            })

            # Enable search buttons when text is entered
            $searchTextBox.Add_TextChanged({
                param($sender, $e)
                $win = [System.Windows.Window]::GetWindow($sender)
                if ($win) {
                    $btnSearch = $win.FindName('_tsTabSearchEnter')
                    $btnClear = $win.FindName('_tsTabSearchClear')
                    $hasText = -not [string]::IsNullOrWhiteSpace($sender.Text) -and $sender.Text -ne 'Search...'

                    if ($btnSearch) { $btnSearch.IsEnabled = $hasText }
                    if ($btnClear) { $btnClear.IsEnabled = $hasText }
                }
            })

            Write-PSDWizardLog -Message "Registered search textbox handlers" -Component $FunctionName
        }

        # Wire up Search button
        if ($searchButton) {
            $searchButton.Add_Click({
                param($sender, $e)
                $win = [System.Windows.Window]::GetWindow($sender)
                if ($win) {
                    $searchBox = $win.FindName('_tsTabSearch')
                    $tsCtrl = $null
                    foreach ($name in @('_tsTabTree', '_tsTabList', 'TSEnv_TaskSequence', '_lstTaskSequence')) {
                        $tsCtrl = $win.FindName($name)
                        if ($tsCtrl) { break }
                    }

                    if ($tsCtrl -and $searchBox -and -not [string]::IsNullOrWhiteSpace($searchBox.Text)) {
                        $filter = $searchBox.Text
                        Write-PSDWizardLog -Message "Searching task sequences for: $filter" -Component 'TaskSequence_Handler'

                        # Filter items based on control type
                        if ($tsCtrl.GetType().Name -eq 'TreeView') {
                            # Collapse all first to hide non-matching items
                            foreach ($item in $tsCtrl.Items) {
                                $item.IsExpanded = $false
                            }

                            # Search and expand matching items
                            foreach ($item in $tsCtrl.Items) {
                                $matchFound = $false

                                # Check folder name
                                if ($item.Header -match $filter) {
                                    $matchFound = $true
                                }

                                # Check children
                                if ($item.Items.Count -gt 0) {
                                    foreach ($child in $item.Items) {
                                        if ($child.Header -match $filter -or ($child.Tag -and $child.Tag.Name -match $filter)) {
                                            $matchFound = $true
                                            $item.IsExpanded = $true
                                            break
                                        }
                                    }
                                }

                                # Show folder if it or its children match
                                if ($matchFound) {
                                    $item.Visibility = [System.Windows.Visibility]::Visible
                                    $item.IsExpanded = $true
                                } else {
                                    $item.Visibility = [System.Windows.Visibility]::Collapsed
                                }
                            }
                        }
                    }
                }
            })
            Write-PSDWizardLog -Message "Registered Search button handler" -Component $FunctionName
        }

        # Wire up Clear button
        if ($clearButton) {
            $clearButton.Add_Click({
                param($sender, $e)
                $win = [System.Windows.Window]::GetWindow($sender)
                if ($win) {
                    $searchBox = $win.FindName('_tsTabSearch')
                    $btnSearch = $win.FindName('_tsTabSearchEnter')
                    $btnClear = $win.FindName('_tsTabSearchClear')
                    $tsCtrl = $null
                    foreach ($name in @('_tsTabTree', '_tsTabList', 'TSEnv_TaskSequence', '_lstTaskSequence')) {
                        $tsCtrl = $win.FindName($name)
                        if ($tsCtrl) { break }
                    }

                    if ($searchBox) {
                        $searchBox.Text = ''
                        if ($btnSearch) { $btnSearch.IsEnabled = $false }
                        if ($btnClear) { $btnClear.IsEnabled = $false }
                    }

                    # Restore visibility of all items
                    if ($tsCtrl -and $tsCtrl.GetType().Name -eq 'TreeView') {
                        foreach ($item in $tsCtrl.Items) {
                            $item.Visibility = [System.Windows.Visibility]::Visible
                            $item.IsExpanded = $true
                        }
                    }

                    Write-PSDWizardLog -Message "Cleared task sequence search filter" -Component 'TaskSequence_Handler'
                }
            })
            Write-PSDWizardLog -Message "Registered Clear button handler" -Component $FunctionName
        }

        # Wire up Expand All button (TreeView only)
        if ($expandButton -and $tsTreeControl.GetType().Name -eq 'TreeView') {
            $expandButton.Add_Click({
                param($sender, $e)
                $win = [System.Windows.Window]::GetWindow($sender)
                if ($win) {
                    $tsCtrl = $null
                    foreach ($name in @('_tsTabTree', '_tsTabList', 'TSEnv_TaskSequence', '_lstTaskSequence')) {
                        $tsCtrl = $win.FindName($name)
                        if ($tsCtrl -and $tsCtrl.GetType().Name -eq 'TreeView') { break }
                    }

                    if ($tsCtrl) {
                        foreach ($item in $tsCtrl.Items) {
                            if ($item.Items.Count -gt 0) {
                                $item.IsExpanded = $true
                            }
                        }
                        Write-PSDWizardLog -Message "Expanded all task sequence folders" -Component 'TaskSequence_Handler'
                    }
                }
            })
            Write-PSDWizardLog -Message "Registered Expand All button handler" -Component $FunctionName
        }

        # Wire up Collapse All button (TreeView only)
        if ($collapseButton -and $tsTreeControl.GetType().Name -eq 'TreeView') {
            $collapseButton.Add_Click({
                param($sender, $e)
                $win = [System.Windows.Window]::GetWindow($sender)
                if ($win) {
                    $tsCtrl = $null
                    foreach ($name in @('_tsTabTree', '_tsTabList', 'TSEnv_TaskSequence', '_lstTaskSequence')) {
                        $tsCtrl = $win.FindName($name)
                        if ($tsCtrl -and $tsCtrl.GetType().Name -eq 'TreeView') { break }
                    }

                    if ($tsCtrl) {
                        foreach ($item in $tsCtrl.Items) {
                            if ($item.Items.Count -gt 0) {
                                $item.IsExpanded = $false
                            }
                        }
                        Write-PSDWizardLog -Message "Collapsed all task sequence folders" -Component 'TaskSequence_Handler'
                    }
                }
            })
            Write-PSDWizardLog -Message "Registered Collapse All button handler" -Component $FunctionName
        }

        Write-PSDWizardLog -Message "Task Sequence page handlers registered successfully" -Component $FunctionName
    }
    catch {
        Write-PSDWizardLog -Message "Error registering Task Sequence handlers: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

Function Get-PSDWizardApplicationBundles {
    <#
    .SYNOPSIS
        Returns enabled applications that contain dependency entries.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [object[]]$Applications = @()
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Scanning $(@($Applications).Count) application catalog entries for dependency bundles" -Component $FunctionName
    $bundleCount = 0
    foreach ($application in @($Applications)) {
        $dependencyNodes = @($application.SelectNodes('./Dependency'))
        if ($dependencyNodes.Count -gt 0) {
            $bundleCount++
            Write-PSDWizardLog -Message "Found bundle '$($application.Name)' [$($application.guid)] with $($dependencyNodes.Count) direct dependencies" -Component $FunctionName
            [PSCustomObject]@{
                guid = [string]$application.guid
                DisplayName = if ($application.DisplayName) { [string]$application.DisplayName } else { [string]$application.Name }
                Name = [string]$application.Name
                DependencyCount = $dependencyNodes.Count
            }
        }
    }
    Write-PSDWizardLog -Message "Application bundle scan complete: $bundleCount bundles found" -Component $FunctionName
}

Function Set-PSDWizardApplicationBundleSelection {
    <#
    .SYNOPSIS
        Selects a bundle and its dependency GUIDs in the application list.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory=$true)]
        [string]$BundleGuid,

        [Parameter(Mandatory=$false)]
        [scriptblock]$DependencyResolver,

        [Parameter(Mandatory=$false)]
        [scriptblock]$DisplayBuilder,

        [Parameter(Mandatory=$false)]
        [scriptblock]$ApplicationExporter
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Applying application bundle '$BundleGuid'" -Component $FunctionName
    $applicationControl = @('_appTabList', '_appTabDatagrid', '_lstApplications', '_dgApplications') | ForEach-Object {
        $Window.FindName($_)
    } | Where-Object { $_ } | Select-Object -First 1
    if (-not $applicationControl -or $applicationControl.GetType().Name -ne 'ListBox') {
        Write-PSDWizardLog -Message "Cannot apply bundle '$BundleGuid': application ListBox was not found" -LogLevel 2 -Component $FunctionName
        return
    }

    $selectedGuids = @($applicationControl.Items | Where-Object { $_.Selected } | ForEach-Object { [string]$_.guid })
    $mandatoryGuids = @($SyncHash.MandatoryApplicationGuids)
    if ($SyncHash.TSEnvSettings) {
        $mandatoryGuids += @($SyncHash.TSEnvSettings.Keys | Where-Object { $_ -match '^MandatoryApplications\d{3}$' } | ForEach-Object { [string]$SyncHash.TSEnvSettings[$_] })
    }

    $selectedGuids += [string]$BundleGuid
    $SyncHash.SelectedApplicationBundleGuids = @([string]$BundleGuid)
    $dependencies = if ($DependencyResolver) {
        & $DependencyResolver -ApplicationGuid $BundleGuid -Applications $SyncHash.ApplicationCatalog
    }
    else {
        Get-PSDWizardApplicationDependencies -ApplicationGuid $BundleGuid -Applications $SyncHash.ApplicationCatalog
    }
    $selectedGuids += @($dependencies)
    $selectedGuids = @($selectedGuids + $mandatoryGuids | Where-Object { $_ } | Select-Object -Unique)
    Write-PSDWizardLog -Message "Bundle '$BundleGuid' resolved $(@($dependencies).Count) dependencies; total selected GUIDs including mandatory=$($selectedGuids.Count)" -Component $FunctionName
    $displayItems = if ($DisplayBuilder) {
        @(& $DisplayBuilder -SyncHash $SyncHash -SelectedGuids $selectedGuids -MandatoryGuids $mandatoryGuids -DependencyResolver $DependencyResolver)
    }
    else {
        @(Get-PSDWizardApplicationDisplayItems -SyncHash $SyncHash -SelectedGuids $selectedGuids -MandatoryGuids $mandatoryGuids -DependencyResolver $DependencyResolver)
    }

    $SyncHash.IsRefreshingApplicationBundle = $true
    try {
        $applicationControl.Items.Clear()
        foreach ($item in $displayItems) {
            $applicationControl.Items.Add($item) | Out-Null
            if ($item.Selected) { $applicationControl.SelectedItems.Add($item) | Out-Null }
        }
        $exportedGuids = @($selectedGuids | Select-Object -Unique)
        if ($ApplicationExporter) {
            & $ApplicationExporter -SelectedApplications $exportedGuids | Out-Null
        }
        else {
            Export-PSDWizardApplication -SelectedApplications $exportedGuids | Out-Null
        }
        $selectedRows = @($displayItems | Where-Object { $_.Selected })
        $hiddenRows = @($selectedRows | Where-Object { $_.IsRequiredDependency })
        Write-PSDWizardLog -Message "Selected application bundle '$BundleGuid' with $($selectedRows.Count) application rows ($($hiddenRows.Count) hidden dependencies); exported $($exportedGuids.Count) GUIDs" -Component $FunctionName
    }
    finally {
        $SyncHash.IsRefreshingApplicationBundle = $false
    }
}

Function Register-PSDWizardApplicationHandlers {
    <#
    .SYNOPSIS
        Registers all event handlers for the Applications selection page
    .DESCRIPTION
        Placeholder for future application page-specific handlers
        (search, select all, select none, etc.)
    .PARAMETER Window
        WPF window object
    .PARAMETER SyncHash
        Synchronized hashtable with loaded data
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Wiring up Applications page handlers..." -Component $FunctionName

    try {
        $bundleControl = $Window.FindName('_appBundlesCmb')
        $applicationControl = @('_appTabList', '_appTabDatagrid', '_lstApplications', '_dgApplications') | ForEach-Object {
            $Window.FindName($_)
        } | Where-Object { $_ } | Select-Object -First 1

        if ($bundleControl) {
            $bundleControl.Items.Clear()
            $bundleControl.Items.Add([PSCustomObject]@{ DisplayName = 'Custom selection'; guid = '' }) | Out-Null
            foreach ($bundle in @(Get-PSDWizardApplicationBundles -Applications $SyncHash.ApplicationCatalog)) {
                $bundleControl.Items.Add($bundle) | Out-Null
            }
            $bundleControl.DisplayMemberPath = 'DisplayName'
            $bundleControl.SelectedIndex = 0

            $dependencyResolver = ${function:Get-PSDWizardApplicationDependencies}.GetNewClosure()
            $displayBuilder = ${function:Get-PSDWizardApplicationDisplayItems}.GetNewClosure()
            $applicationExporter = ${function:Export-PSDWizardApplication}.GetNewClosure()
            $bundleSelectionAction = ${function:Set-PSDWizardApplicationBundleSelection}.GetNewClosure()
            $bundleSelectionHandler = {
                param($sender, $e)
                $bundle = $sender.SelectedItem
                if ($bundle -and $bundle.guid -and -not $SyncHash.IsRefreshingApplicationBundle) {
                    & $bundleSelectionAction -Window $Window -SyncHash $SyncHash -BundleGuid ([string]$bundle.guid) -DependencyResolver $dependencyResolver -DisplayBuilder $displayBuilder -ApplicationExporter $applicationExporter
                }
                elseif ($bundle -and -not $bundle.guid) {
                    $SyncHash.SelectedApplicationBundleGuids = @()
                }
            }.GetNewClosure()
            $bundleControl.Add_SelectionChanged($bundleSelectionHandler)
        }

        $selectAllButton = $Window.FindName('_appTabSelectAll')
        $selectNoneButton = $Window.FindName('_appTabSelectNone')
        $applicationExporter = ${function:Export-PSDWizardApplication}.GetNewClosure()

        if ($selectAllButton -and $applicationControl) {
            $selectAllButton.Add_Click({
                param($sender, $e)
                $SyncHash.IsRefreshingApplicationBundle = $true
                try {
                    if ($bundleControl) { $bundleControl.SelectedIndex = 0 }
                    $SyncHash.SelectedApplicationBundleGuids = @()
                    foreach ($item in @($applicationControl.Items)) {
                        if ($item.IsSelectable -eq $false) { continue }
                        $item.Selected = $true
                        if (-not $applicationControl.SelectedItems.Contains($item)) {
                            $applicationControl.SelectedItems.Add($item) | Out-Null
                        }
                    }
                    $selectedGuids = @($applicationControl.SelectedItems | ForEach-Object { [string]$_.guid } | Where-Object { $_ } | Select-Object -Unique)
                    & $applicationExporter -SelectedApplications $selectedGuids | Out-Null
                }
                finally {
                    $SyncHash.IsRefreshingApplicationBundle = $false
                }
                Write-PSDWizardLog -Message "Selected all selectable applications" -Component 'Applications_Handler'
            }.GetNewClosure())
        }

        if ($selectNoneButton -and $applicationControl) {
            $selectNoneButton.Add_Click({
                param($sender, $e)
                $SyncHash.IsRefreshingApplicationBundle = $true
                try {
                    if ($bundleControl) { $bundleControl.SelectedIndex = 0 }
                    $SyncHash.SelectedApplicationBundleGuids = @()
                    foreach ($item in @($applicationControl.Items)) {
                        $isMandatory = [bool]$item.IsMandatory -or [string]$item.guid -in @($SyncHash.MandatoryApplicationGuids)
                        if (-not $isMandatory) {
                            $item.Selected = $false
                            if ($applicationControl.SelectedItems.Contains($item)) {
                                $applicationControl.SelectedItems.Remove($item)
                            }
                        }
                    }
                    $selectedGuids = @($applicationControl.SelectedItems | ForEach-Object { [string]$_.guid } | Where-Object { $_ } | Select-Object -Unique)
                    & $applicationExporter -SelectedApplications $selectedGuids | Out-Null
                }
                finally {
                    $SyncHash.IsRefreshingApplicationBundle = $false
                }
                Write-PSDWizardLog -Message "Cleared all optional application selections" -Component 'Applications_Handler'
            }.GetNewClosure())
        }

        Write-PSDWizardLog -Message "Applications page handlers registered successfully; bundles=$(@(Get-PSDWizardApplicationBundles -Applications $SyncHash.ApplicationCatalog).Count), applicationRows=$(@($applicationControl.Items).Count)" -Component $FunctionName
    }
    catch {
        Write-PSDWizardLog -Message "Error registering Applications handlers: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
    }
}

Function Register-PSDWizardTargetDiskHandlers {
    <#
    .SYNOPSIS
        Registers all event handlers for the Target Disk selection page
    .DESCRIPTION
        Placeholder for Target Disk page handlers
        (handlers are already wired during data population)
    .PARAMETER Window
        WPF window object
    .PARAMETER SyncHash
        Synchronized hashtable with loaded data
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory=$true)]
        [hashtable]$SyncHash
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Target Disk page handlers already registered during data initialization" -Component $FunctionName

    # Note: Target Disk handlers are already wired up in Initialize-PSDWizardData
    # during the TargetDisk Page Population section. This is intentional because
    # those handlers are tightly coupled to the data population logic.
}

#endregion

#region DATA LOADING FUNCTIONS

Function Import-PSDWizardCustomSettings {
    <#
    .SYNOPSIS
        Parses CustomSettings.ini into a hashtable
    .DESCRIPTION
        Reads and parses an MDT-style INI file, returning all sections and properties
        as a nested hashtable structure for use in DevelopmentMode
    .PARAMETER Path
        Path to CustomSettings.ini file
    .OUTPUTS
        [hashtable] with sections as keys, each containing property hashtables
    .EXAMPLE
        $settings = Import-PSDWizardCustomSettings -Path 'E:\PSD\Control\CustomSettings.ini'
        $orgName = $settings['Default']['_SMSTSORGNAME']
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    Param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$Path
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Parsing INI file: $Path" -Component $FunctionName

    $settings = @{}
    $currentSection = 'Default'
    $settings[$currentSection] = @{}

    try {
        $content = Get-Content -Path $Path -ErrorAction Stop

        foreach ($line in $content) {
            # Skip empty lines and comments
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*;') {
                continue
            }

            # Section header [SectionName]
            if ($line -match '^\s*\[(.+)\]\s*$') {
                $currentSection = $matches[1].Trim()
                if (-not $settings.ContainsKey($currentSection)) {
                    $settings[$currentSection] = @{}
                }
                continue
            }

            # Key=Value pair
            if ($line -match '^\s*([^=;]+?)\s*=\s*(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()

                # Remove inline comments
                if ($value -match '^([^;]+);.*$') {
                    $value = $matches[1].Trim()
                }

                $settings[$currentSection][$key] = $value
            }
        }

        Write-PSDWizardLog -Message "Parsed $($settings.Keys.Count) sections with $($settings.Values.Values.Count) total properties" -Component $FunctionName
        return $settings
    }
    catch {
        Write-PSDWizardLog -Message "Error parsing INI file: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName
        return @{ 'Default' = @{} }
    }
}

Function Get-PSDWizardApplicationProfileGuids {
    <#
    .SYNOPSIS
        Resolves eligible application GUIDs for a wizard selection profile.
    #>
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory=$true)]
            [string]$ControlPath,
            [Parameter(Mandatory=$true)]
            [string]$SelectionName,
            [Parameter(Mandatory=$true)]
            [object[]]$Applications,
            [Parameter(Mandatory=$true)]
            [object[]]$ApplicationGroups
        )

        $selectionXmlPath = Join-Path $ControlPath 'SelectionProfiles.xml'
        if (-not (Test-Path $selectionXmlPath)) {
            Write-PSDWizardLog -Message "SelectionProfiles.xml not found at $selectionXmlPath" -LogLevel 2 -Component $MyInvocation.MyCommand.Name
            return @()
        }

        try {
            # Load the selection profile XML document for further processing
            [xml]$selectionDocument = Get-Content $selectionXmlPath -Raw -Encoding UTF8
            $matchedEntry = @($selectionDocument.selectionProfiles.selectionProfile | Where-Object {
                $_.Name -ieq $SelectionName -and $_.enable -ine 'False'
            } | Select-Object -First 1)
            # Check if a matching selection profile was found
            if ($matchedEntry.Count -eq 0) {
                Write-PSDWizardLog -Message "Enabled selection profile '$SelectionName' was not found" -LogLevel 2 -Component $MyInvocation.MyCommand.Name
                return @()
            }

            # Parse the XML definition of the selection profile to extract inclusion and exclusion rules
            # Filter the child nodes of the selection profile to include only 'Include' and 'Exclude' elements with a valid path
            [xml]$definition = [string]$matchedEntry[0].Definition
            $rules = @($definition.SelectionProfile.ChildNodes | Where-Object {
                $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.Name -in @('Include', 'Exclude') -and -not [string]::IsNullOrWhiteSpace($_.path)
            } | ForEach-Object {
                [PSCustomObject]@{
                    Action = $_.Name
                    Path = ([string]$_.path).Replace('/', '\').Trim('\')
                }
            })

            $groupsByGuid = @{}
            # Build a hashtable to quickly look up application groups by their GUID
            foreach ($group in $ApplicationGroups) {
                if ($group.guid -and $group.enable -ine 'False') {
                    $groupsByGuid[[string]$group.guid] = $group
                }
            }

            $applicationsByGuid = @{}
            # Build a hashtable to quickly look up applications by their GUID
            foreach ($application in $Applications) {
                if ($application.guid) {
                    $applicationsByGuid[[string]$application.guid] = $application
                }
            }

            $nestedGroupGuids = @{}
            # Initialize a hashtable to keep track of nested group GUIDs
            foreach ($group in $groupsByGuid.Values) {
                # Iterate through each member of the current group to check if it is a nested group
                foreach ($member in @($group.Member)) {
                    # Convert the member to a string for consistent comparison
                    if ($groupsByGuid.ContainsKey([string]$member)) {
                        $nestedGroupGuids[[string]$member] = $true
                    }
                }
            }
            # Identify the root groups that are not nested within any other group
            $rootGroups = @($groupsByGuid.Values | Where-Object { -not $nestedGroupGuids.ContainsKey([string]$_.guid) })
            if ($rootGroups.Count -eq 0) {
                $rootGroups = @($groupsByGuid.Values)
            }

            # Initialize a hashtable to store the paths associated with each application GUID
            $pathsByApplicationGuid = @{}
            $groupQueue = New-Object System.Collections.Queue
            # Initialize a queue to manage the processing of groups in a breadth-first manner
            foreach ($group in $rootGroups) {
                $rootPath = 'Applications'
                # Construct the root path for the current group based on its name
                if ($group.Name -ine 'default') {
                    $rootPath = Join-Path $rootPath ([string]$group.Name)
                }
                # Enqueue the current group along with its path and ancestors for further processing
                $groupQueue.Enqueue([PSCustomObject]@{
                    Group = $group
                    Path = $rootPath
                    Ancestors = @()
                })
            }

            while ($groupQueue.Count -gt 0) {
                # Dequeue the next group entry from the queue for processing
                $entry = $groupQueue.Dequeue()
                $groupGuid = [string]$entry.Group.guid
                # Get the GUID of the current group for reference
                # Skip processing if the current group is already in the list of ancestors to avoid circular references
                if ($groupGuid -in $entry.Ancestors) {
                    continue
                }

                $ancestors = @($entry.Ancestors) + $groupGuid
                # Iterate through each member of the current group to determine if it is an application or a nested group
                foreach ($member in @($entry.Group.Member)) {
                    $memberGuid = [string]$member
                    # Check if the current member is an application or a nested group
                    if ($applicationsByGuid.ContainsKey($memberGuid)) {
                        $applicationPath = Join-Path $entry.Path ([string]$applicationsByGuid[$memberGuid].Name)
                        # Determine the path for the current application within the group hierarchy
                        if ($pathsByApplicationGuid.ContainsKey($memberGuid)) {
                            $pathsByApplicationGuid[$memberGuid] = @($pathsByApplicationGuid[$memberGuid]) + $applicationPath
                        }
                        else {
                            $pathsByApplicationGuid[$memberGuid] = @($applicationPath)
                        }
                    }
                    elseif ($groupsByGuid.ContainsKey($memberGuid)) {
                        # Enqueue the child group for further processing
                        $childGroup = $groupsByGuid[$memberGuid]
                        $groupQueue.Enqueue([PSCustomObject]@{
                            Group = $childGroup
                            Path = Join-Path $entry.Path ([string]$childGroup.Name)
                            Ancestors = $ancestors
                        })
                    }
                }
            }

            # Ensure that each application has an entry in the pathsByApplicationGuid hashtable
            foreach ($application in $Applications) {
                # Get the GUID of the current application
                $applicationGuid = [string]$application.guid
                # Check if the application already has an entry in the pathsByApplicationGuid hashtable
                if (-not $pathsByApplicationGuid.ContainsKey($applicationGuid)) {
                    $pathsByApplicationGuid[$applicationGuid] = @((Join-Path 'Applications' ([string]$application.Name)))
                }
            }

            $eligibleGuids = @()
            # Initialize the list of eligible application GUIDs
            foreach ($application in $Applications) {
                $isIncluded = $false
                # Iterate through each application path associated with the current application
                foreach ($applicationPath in $pathsByApplicationGuid[[string]$application.guid]) {
                    $winningRule = $null
                    # Initialize the winning rule for the current application path as null
                    foreach ($rule in $rules) {
                        # Check if the current rule matches the application path and if it should be considered the winning rule
                        $matchesPath = $applicationPath -ieq $rule.Path -or $applicationPath.StartsWith($rule.Path + '\', [System.StringComparison]::OrdinalIgnoreCase)
                        if ($matchesPath -and ($null -eq $winningRule -or $rule.Path.Length -ge $winningRule.Path.Length)) {
                            $winningRule = $rule
                        }
                    }
                    # Determine the winning rule for the current application path
                    if ($winningRule -and $winningRule.Action -ieq 'Include') {
                        $isIncluded = $true
                        break
                    }
                }

                # if the application is included based on the resolved rules
                if ($isIncluded) {
                    $eligibleGuids += [string]$application.guid
                }
            }

            return $eligibleGuids
        }
        catch {
            Write-PSDWizardLog -Message "Unable to resolve selection profile '$SelectionName' at $($_.InvocationInfo.PositionMessage): $($_.Exception.Message)" -LogLevel 2 -Component $MyInvocation.MyCommand.Name
            return @()
        }
    }


Function Import-PSDWizardControlData {
    <#
    .SYNOPSIS
        Loads deployment data from Control folder with group hierarchy
    .DESCRIPTION
        Imports applications, task sequences, and operating systems from
        deployment share Control folder XML files for DevelopmentMode testing.
        Filters out disabled (enable="False") and hidden (hide="True") items.
        Builds hierarchical structure from group XML files.
    .PARAMETER ControlPath
        Path to Control folder containing XML files
    .OUTPUTS
        [hashtable] with Applications, TaskSequences, OperatingSystems arrays and Group structures
    .EXAMPLE
        $data = Import-PSDWizardControlData -ControlPath 'E:\PSD\Control'
        Write-Host "Found $($data.Applications.Count) applications"
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    Param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType Container})]
        [string]$ControlPath
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "Loading Control folder data from: $ControlPath" -Component $FunctionName

    # Initialize the data hashtable for storing control folder information
    $data = @{
        Applications = @()
        ApplicationCatalog = @()
        ApplicationGroups = @()
        TaskSequences = @()
        TaskSequenceGroups = @()
        OperatingSystems = @()
    }

    try {
        # build path for ApplicationGroups.xml
        $appGroupsXml = Join-Path $ControlPath 'ApplicationGroups.xml'
        if (Test-Path $appGroupsXml) {
            # Load and parse the ApplicationGroups.xml file
            [xml]$appGroupsDoc = Get-Content $appGroupsXml -Encoding UTF8
            $data.ApplicationGroups = @($appGroupsDoc.groups.group)
            Write-PSDWizardLog -Message "Loaded $($data.ApplicationGroups.Count) application groups" -Component $FunctionName
        }

        # build path for Applications.xml
        $appsXml = Join-Path $ControlPath 'Applications.xml'
        if (Test-Path $appsXml) {
            # Load and parse the Applications.xml file
            [xml]$appsDoc = Get-Content $appsXml -Encoding UTF8
            $allApps = @($appsDoc.applications.application)

            # Get enabled groups
            $enabledGroups = @($data.ApplicationGroups | Where-Object {
                ($_.enable -eq 'True') -or ([string]::IsNullOrEmpty($_.enable))
            })
            # Get all members of the enabled groups
            $enabledGroupMembers = @($enabledGroups | ForEach-Object { $_.Member }) | Where-Object { $_ }

            # Keep enabled applications available for dependency resolution, then hide normal hidden rows from the UI list.
            $data.ApplicationCatalog = @($allApps | Where-Object {
                $isEnabled = ($_.enable -eq 'True') -or ([string]::IsNullOrEmpty($_.enable))
                $inEnabledGroup = ($enabledGroupMembers.Count -eq 0) -or ($_.guid -in $enabledGroupMembers)
                $isEnabled -and $inEnabledGroup
            })
            $data.Applications = @($data.ApplicationCatalog | Where-Object { $_.hide -ne 'True' })

            Write-PSDWizardLog -Message "Loaded $($data.Applications.Count) visible applications and $($data.ApplicationCatalog.Count) catalog applications (filtered from $($allApps.Count) total)" -Component $FunctionName
        }

        # build path for TaskSequenceGroups.xml
        $tsGroupsXml = Join-Path $ControlPath 'TaskSequenceGroups.xml'
        if (Test-Path $tsGroupsXml) {
            # Load and parse the TaskSequenceGroups.xml file
            [xml]$tsGroupsDoc = Get-Content $tsGroupsXml -Encoding UTF8
            $data.TaskSequenceGroups = @($tsGroupsDoc.groups.group)
            Write-PSDWizardLog -Message "Loaded $($data.TaskSequenceGroups.Count) task sequence groups" -Component $FunctionName
        }

        # build path for TaskSequences.xml
        $tsXml = Join-Path $ControlPath 'TaskSequences.xml'
        if (Test-Path $tsXml) {
            # Load and parse the TaskSequences.xml file
            [xml]$tsDoc = Get-Content $tsXml -Encoding UTF8
            $allTS = @($tsDoc.tss.ts)

            # Get enabled groups
            $enabledGroups = @($data.TaskSequenceGroups | Where-Object {
                ($_.enable -eq 'True') -or ([string]::IsNullOrEmpty($_.enable))
            })
            $enabledGroupMembers = @($enabledGroups | ForEach-Object { $_.Member }) | Where-Object { $_ }

            # Filter: enable="True" AND hide != "True" AND in enabled group
            $data.TaskSequences = @($allTS | Where-Object {
                # Determine if the task sequence entry is enabled, visible, and in an enabled group
                $isEnabled = ($_.enable -eq 'True') -or ([string]::IsNullOrEmpty($_.enable))
                $isVisible = ($_.hide -ne 'True')
                # Determine if the task sequence entry is in an enabled group
                $inEnabledGroup = ($enabledGroupMembers.Count -eq 0) -or ($_.guid -in $enabledGroupMembers)
                $isEnabled -and $isVisible -and $inEnabledGroup
            })

            Write-PSDWizardLog -Message "Loaded $($data.TaskSequences.Count) visible task sequences (filtered from $($allTS.Count) total)" -Component $FunctionName
        }

        # Load OperatingSystems.xml
        $osXml = Join-Path $ControlPath 'OperatingSystems.xml'
        if (Test-Path $osXml) {
            # Load and parse the OperatingSystems.xml file
            [xml]$osDoc = Get-Content $osXml -Encoding UTF8
            $allOS = @($osDoc.oss.os)

            # Filter: enable="True" AND hide != "True"
            $data.OperatingSystems = @($allOS | Where-Object {
                # Determine if the operating system entry is enabled and visible
                $isEnabled = ($_.enable -eq 'True') -or ([string]::IsNullOrEmpty($_.enable))
                $isVisible = ($_.hide -ne 'True')
                $isEnabled -and $isVisible
            })

            Write-PSDWizardLog -Message "Loaded $($data.OperatingSystems.Count) visible operating systems (filtered from $($allOS.Count) total)" -Component $FunctionName
        }

        return $data
    }
    catch {
        Write-PSDWizardLog -Message "Error loading Control data: $($_.Exception.Message)" -LogLevel 2 -Component $FunctionName
        return $data
    }
}

#endregion

#region MAIN WIZARD FUNCTIONS

Function Show-PSDWizard {
    <#
    .SYNOPSIS
        Main entry point for PSDWizardNew v3.0.1
    .DESCRIPTION
        Initializes and displays the PSD Wizard with runspace-based UI architecture.
        Supports both WinPE and development mode execution.
    .PARAMETER ResourcePath
        Path to wizard resources (definitions, themes, etc.)
    .PARAMETER Language
        Language code (default: en-US)
    .PARAMETER Theme
        Theme name (default: Classic)
    .PARAMETER Page
        Starting page (optional)
    .PARAMETER ControlPath
        Path to deployment share Control folder (for DevelopmentMode data loading)
    .PARAMETER TSEnvSettings
        Hashtable of TSEnvironment settings (for DevelopmentMode, pre-populated by test script)
    .PARAMETER DevelopmentMode
        Enable development mode for testing outside WinPE
    .PARAMETER NoSplashScreen
        Skip showing the splashscreen
    .PARAMETER Passthru
        Return the wizard state object
    .OUTPUTS
        [hashtable] Wizard state (if -Passthru specified)
    .EXAMPLE
        Show-PSDWizard -ResourcePath 'C:\Deploy\Scripts\PSDWizardNew' -Theme 'Modern'
    .EXAMPLE
        Show-PSDWizard -DevelopmentMode -ControlPath 'E:\PSD\Control' -TSEnvSettings $localInfo -NoSplashScreen
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$ResourcePath = (Join-Path $PSScriptRoot 'PSDWizardNew'),

        [Parameter(Mandatory=$false)]
        [string]$Language = 'en-US',

        [Parameter(Mandatory=$false)]
        [string]$Theme = 'Classic',

        [Parameter(Mandatory=$false)]
        [string]$Page,

        [Parameter(Mandatory=$false)]
        [string]$ControlPath,

        [Parameter(Mandatory=$false)]
        [hashtable]$TSEnvSettings,

        [Parameter(Mandatory=$false)]
        [switch]$DevelopmentMode,

        [Parameter(Mandatory=$false)]
        [switch]$NoSplashScreen,

        [Parameter(Mandatory=$false)]
        [switch]$Passthru
    )

    $FunctionName = $MyInvocation.MyCommand.Name
    Write-PSDWizardLog -Message "===== PSDWizardNew v$($script:ModuleVersion) Starting =====" -Component $FunctionName

    try {
        # Detect the current environment and determine if running in development mode or within a task sequence
        $envInfo = Test-PSDWizardEnvironment
        if ($DevelopmentMode) {
            $envInfo.IsDevelopment = $true
            $script:IsDevelopmentMode = $true
        }
        elseif (-not $envInfo.TSEnvAvailable) {
            throw "PSD TSEnv: drive is unavailable. Ensure PSD initialized the task-sequence environment before launching the wizard. Use -DevelopmentMode only for explicit local testing."
        }

        Write-PSDWizardLog -Message "Environment: WinPE=$($envInfo.IsWinPE), TSEnv=$($envInfo.TSEnvAvailable), Dev=$($envInfo.IsDevelopment)" -Component $FunctionName

        # Initialize the synchronized state hash for the wizard
        $syncHash = Initialize-PSDWizardState -DevelopmentMode:$DevelopmentMode
        $syncHash.ResourcePath = $ResourcePath
        $syncHash.Language = $Language
        $syncHash.Theme = $Theme
        $script:PSDWizardSyncHash = $syncHash

        # Show splashscreen
        $splashScreen = $null
        if (-not $NoSplashScreen) {
            $splashScreen = Show-PSDWizardSplashScreen -Theme $Theme -Language $Language
            Update-PSDWizardProgressBar -Runspace $splashScreen -Status "Initializing..." -PercentComplete 10
        }

        # Load definition files
        Write-PSDWizardLog -Message "Loading definition files..." -Component $FunctionName
        $langFile = Join-Path $ResourcePath "PSDWizard_Definitions_$Language.xml"
        $themeFile = Join-Path $ResourcePath "Themes\${Theme}_Theme_Definitions_$Language.xml"

        if (-not (Test-Path $langFile)) {
            throw "Language definition file not found: $langFile"
        }

        # Verify theme file exists, fallback to Classic if not
        if (-not (Test-Path $themeFile)) {
            Write-PSDWizardLog -Message "Theme file not found: $themeFile, falling back to Classic" -LogLevel 2 -Component $FunctionName
            $themeFile = Join-Path $ResourcePath "Themes\Classic_Theme_Definitions_$Language.xml"
        }

        # Load the theme and language definitions into XML objects
        if ($splashScreen) {
            Update-PSDWizardProgressBar -Runspace $splashScreen -Status "Loading definitions..." -PercentComplete 25
        }

        # Load the XML content of the language and theme definition files into memory
        [xml]$langDefinition = Get-Content $langFile -Encoding UTF8
        [xml]$themeDefinition = Get-Content $themeFile -Encoding UTF8

        # Cache pane validations so navigation can validate the active page.
        $syncHash.PaneValidations = @{}
        $syncHash.DynamicPaneConditions = @{}
        $afterTaskSequence = $false
        foreach ($paneDefinition in @($langDefinition.Wizard.Pane)) {
            if ([string]$paneDefinition.id -eq 'TaskSequence') {
                $afterTaskSequence = $true
            }
            elseif ($afterTaskSequence) {
                $paneConditions = @($paneDefinition.Condition | ForEach-Object { $_.InnerText } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $syncHash.DynamicPaneConditions[[string]$paneDefinition.id] = $paneConditions
            }

            $validationExpressions = @($paneDefinition.Validation | ForEach-Object { $_.InnerText } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($validationExpressions.Count -gt 0) {
                $syncHash.PaneValidations[[string]$paneDefinition.id] = $validationExpressions
            }
        }

        Write-PSDWizardLog -Message "Loaded language: $Language, theme: $Theme" -Component $FunctionName

        # Keep source-specific acquisition separate from shared state initialization.
        $wizardData = @{
            TSEnvSettings = $null
            ControlData = $null
            LocalePath = $null
        }

        # Acquire environment-specific inputs before populating shared wizard state.
        if ($envInfo.IsDevelopment) {
            Write-PSDWizardLog -Message "DevelopmentMode: Simulating TSEnvironment" -Component $FunctionName

            if (-not $TSEnvSettings) {
                Write-PSDWizardLog -Message "No TSEnvSettings provided, creating minimal mock" -LogLevel 1 -Component $FunctionName
                # Supply a small usable baseline for local wizard testing.
                $wizardData.TSEnvSettings = @{
                    'SkipBDDWizard' = 'NO'
                    'SkipComputerName' = 'NO'
                    'SkipDomainMembership' = 'NO'
                    'SkipTaskSequence' = 'NO'
                    'SkipApplications' = 'NO'
                    'SkipLocaleSelection' = 'NO'
                    'SkipReadinessCheck' = 'NO'
                    'OrgName' = 'Development Organization'
                    '_SMSTSOrgName' = 'Development Organization'
                }
            }
            else {
                $wizardData.TSEnvSettings = $TSEnvSettings
                Write-PSDWizardLog -Message "Using TSEnvSettings provided by caller ($($TSEnvSettings.Count) properties)" -Component $FunctionName
            }

            if (-not $ControlPath) {
                # Infer the conventional sibling Control folder from Scripts\PSDWizardNew.
                $scriptsPath = Split-Path -Parent $ResourcePath
                $deploymentRoot = Split-Path -Parent $scriptsPath
                $controlCandidate = Join-Path $deploymentRoot 'Control'
                if (Test-Path -LiteralPath $controlCandidate -PathType Container) {
                    $ControlPath = $controlCandidate
                    Write-PSDWizardLog -Message "Auto-detected Control folder from ResourcePath: $ControlPath" -Component $FunctionName
                }
            }

            # PSDGather evaluates CustomSettings.ini before the wizard starts.
            if ($ControlPath -and (Test-Path $ControlPath)) {
                Write-PSDWizardLog -Message "Loading Control folder data: $ControlPath" -Component $FunctionName
                $wizardData.ControlData = Import-PSDWizardControlData -ControlPath $ControlPath

                # In development, the locale indexes are found beside the wizard's resource folder or the deployment share's Control folder.
                $wizardData.LocalePath = Resolve-PSDWizardLocalePath -ResourcePath $ResourcePath -ControlPath $ControlPath
            }
            else {
                Write-PSDWizardLog -Message "No Control folder specified or found - using mock data only" -Component $FunctionName
            }
        }
        else {
            # Snapshot the processed PSD environment before entering the WPF runspace.
            $wizardData.TSEnvSettings = [hashtable]::Synchronized([hashtable]::new([System.StringComparer]::OrdinalIgnoreCase))
            foreach ($property in @(Get-PSDWizardTSEnvProperty '*' -WildCard)) {
                if ($property.Name) {
                    $wizardData.TSEnvSettings[[string]$property.Name] = $property.Value
                    Write-PSDWizardLog -Message "Loaded TSEnv property: $($property.Name) = $($property.Value)" -Component $FunctionName
                }
            }
            Write-PSDWizardLog -Message "Loaded TSEnv settings: $($wizardData.TSEnvSettings.Count) variables" -Component $FunctionName

            # Control data is optional in production; PSD already supplied the TSEnv snapshot.
            if ($ControlPath -and (Test-Path $ControlPath)) {
                Write-PSDWizardLog -Message "Loading Control folder data: $ControlPath" -Component $FunctionName
                $wizardData.ControlData = Import-PSDWizardControlData -ControlPath $ControlPath
            }
            else {
                Write-PSDWizardLog -Message "Control folder not available: $ControlPath" -LogLevel 2 -Component $FunctionName
            }

            $wizardData.LocalePath = Resolve-PSDWizardLocalePath -ResourcePath $ResourcePath -ControlPath $ControlPath
        }

        # Populate shared state once, regardless of where the inputs came from.
        $tsEnvSettings = $wizardData.TSEnvSettings
        $syncHash.TSEnvSettings = $wizardData.TSEnvSettings

        # The debug console is available with PSDDebug=YES (Bootstrap.ini), -Debug or in development mode
        $syncHash.DebugMode = [bool]($PSBoundParameters['Debug'] -or $DevelopmentMode -or ($Global:PSDDebug -eq $true) -or ([string]$tsEnvSettings['PSDDebug'] -eq 'YES'))
        if ($syncHash.DebugMode) {
            Write-PSDWizardLog -Message "Debug mode is on, the debug console is available" -Component $FunctionName
        }

        if ($wizardData.ControlData) {
            $syncHash.ControlPath = $ControlPath
            $syncHash.Applications = $wizardData.ControlData.Applications
            $syncHash.ApplicationCatalog = if ($wizardData.ControlData.ApplicationCatalog) { $wizardData.ControlData.ApplicationCatalog } else { $wizardData.ControlData.Applications }
            $syncHash.VisibleApplicationCatalog = $wizardData.ControlData.Applications
            $syncHash.ApplicationGroups = $wizardData.ControlData.ApplicationGroups
            $syncHash.TaskSequences = $wizardData.ControlData.TaskSequences
            $syncHash.TaskSequenceGroups = $wizardData.ControlData.TaskSequenceGroups
            $syncHash.OperatingSystems = $wizardData.ControlData.OperatingSystems
            Write-PSDWizardLog -Message "Loaded $($wizardData.ControlData.Applications.Count) apps, $($wizardData.ControlData.TaskSequences.Count) TS, $($wizardData.ControlData.OperatingSystems.Count) OS" -Component $FunctionName
        }

        # Load locale indexes from the environment-appropriate resource folder.
        if ($wizardData.LocalePath) {
            Write-PSDWizardLog -Message "Loading locale and timezone data from $($wizardData.LocalePath)..." -Component $FunctionName
            $syncHash.Locales = Get-PSDWizardLocale -Path $wizardData.LocalePath
            $syncHash.TimeZones = Get-PSDWizardTimeZoneIndex -Path $wizardData.LocalePath
            Write-PSDWizardLog -Message "Loaded $($syncHash.Locales.Count) locales and $($syncHash.TimeZones.Count) timezones" -Component $FunctionName
        }
        # Load list-valued TSEnv settings into the synchronized hashtable.
        $syncHash.TSEnvLists = Get-PSDWizardTSEnvLists -TSEnvSettings $tsEnvSettings
        Write-PSDWizardLog -Message "Loaded $($syncHash.TSEnvLists.Count) list-valued settings from TSEnv" -Component $FunctionName

        # Determine the selection profile name from the TSEnv settings.
        $selectionProfileName = [string]$tsEnvSettings['WizardSelectionProfile']
        if (-not [string]::IsNullOrWhiteSpace($selectionProfileName) -and $syncHash.ApplicationCatalog) {
            # Get the list of eligible and mandatory application GUIDs based on the selection profile and TSEnv settings.
            $eligibleAppGuids = @(Get-PSDWizardApplicationProfileGuids -ControlPath $ControlPath -SelectionName $selectionProfileName -Applications $syncHash.ApplicationCatalog -ApplicationGroups $syncHash.ApplicationGroups)
            $mandatoryAppGuids = @($tsEnvSettings.Keys | Where-Object { $_ -match '^MandatoryApplications\d{3}$' } | ForEach-Object { [string]$tsEnvSettings[$_] })
            $eligibleAppGuids = @($eligibleAppGuids + $mandatoryAppGuids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            $syncHash.Applications = @($syncHash.ApplicationCatalog | Where-Object { $_.guid -in $eligibleAppGuids })
            Write-PSDWizardLog -Message "Filtered wizard applications using selection profile '$selectionProfileName': $($syncHash.Applications.Count) available" -Component $FunctionName
        }

        # Get org name from the TSEnv settings.
        $orgName = $tsEnvSettings['_SMSTSOrgName']
        if (-not $orgName) {
            $orgName = $tsEnvSettings['OrgName']
        }
        # Fallback to a default organization name if none is specified in the TSEnv settings.
        if (-not $orgName) {
            $orgName = "Organization"
        }

        # Update the progress bar to indicate that the UI is being built.
        if ($splashScreen) {
            Update-PSDWizardProgressBar -Runspace $splashScreen -Status "Building UI..." -PercentComplete 50
        }

        # Generate the XAML content for the wizard based on the resource path, language and theme definitions, TSEnv settings, and organization name.
        Write-PSDWizardLog -Message "Generating wizard XAML..." -Component $FunctionName
        $xaml = Format-PSDWizard -ResourcePath $ResourcePath `
                                -LangDefinition $langDefinition `
                                -ThemeDefinition $themeDefinition `
                                -TSEnvSettings $tsEnvSettings `
                                -OrgName $orgName

        if (-not $xaml) {
            throw "Failed to generate wizard XAML"
        }

        Write-PSDWizardLog -Message "XAML generated successfully" -Component $FunctionName

        # Update the progress bar to indicate that the UI has been generated successfully.
        if ($splashScreen) {
            Update-PSDWizardProgressBar -Runspace $splashScreen -Status "Rendering UI..." -PercentComplete 75
        }

        # Close splashscreen before showing wizard
        if ($splashScreen) {
            Start-Sleep -Milliseconds 500
            Close-PSDWizardSplashScreen -Runspace $splashScreen
        }

        # Count the number of TabItem elements in the generated XAML to determine if any wizard panes are available.
        $tabItemCount = @($xaml.GetElementsByTagName('TabItem')).Count
        if ($tabItemCount -eq 0) {
            # If no TabItem elements are found, log a message and mark the wizard as completed without opening an empty wizard.
            Write-PSDWizardLog -Message "All wizard panes were skipped by processed TSEnv settings; continuing without opening an empty wizard" -Component $FunctionName
            $syncHash.Result = 'Completed'
            $syncHash.IsClosed = $true

            if ($Passthru) {
                return $syncHash
            }

            return
        }

        # Show the wizard UI by invoking the PSDWizard with the generated XAML content.
        Write-PSDWizardLog -Message "Launching wizard UI..." -Component $FunctionName
        $result = Invoke-PSDWizard -XamlContent $xaml `
                                  -SyncHash $syncHash `
                                  -ResourcePath $ResourcePath `
                                  -DevelopmentMode:$DevelopmentMode

        Write-PSDWizardLog -Message "Wizard completed with result: $($result.Result)" -Component $FunctionName
        Write-PSDWizardLog -Message "===== PSDWizardNew v$($script:ModuleVersion) Complete =====" -Component $FunctionName

        if ($Passthru) {
            return $syncHash
        }
    }
    catch {
        Write-PSDWizardLog -Message "Critical error in Show-PSDWizard: $($_.Exception.Message)" -LogLevel 3 -Component $FunctionName

        # Ensure that the splash screen is closed in case of a critical error.
        if ($splashScreen) {
            Close-PSDWizardSplashScreen -Runspace $splashScreen
        }

        throw
    }
}

#endregion

#region MODULE EXPORTS

# Export all functions following naming convention
Export-ModuleMember -Function @(
    # Environment
    'Test-PSDWizardEnvironment',
    'Write-PSDWizardLog',

    # State Management
    'Initialize-PSDWizardState',
    'Get-PSDWizardState',
    'Set-PSDWizardState',

    # Runspace Management
    'Start-PSDWizardRunspace',
    'Stop-PSDWizardRunspace',

    # Definitions
    'Get-PSDWizardDefinitions',
    'Get-PSDWizardThemeDefinition',
    'Get-PSDWizardCondition',

    # TSEnv
    'Get-PSDWizardTSEnvProperty',
    'Set-PSDWizardTSEnvProperty',
    'Remove-PSDWizardTSEnvProperty',

    # Validation (FIXED)
    'Confirm-PSDWizardOSDJoinAccount',
    'Confirm-PSDWizardComputerName',
    'Confirm-PSDWizardPassword',

    # Locale and TimeZone
    'Get-PSDWizardLocale',
    'Get-PSDWizardTimeZoneIndex',

    # Test Functions
    'Test-PSDWizardApplicationExist',

    # Applications (FIXED)
    'Export-PSDWizardApplication',
    'Get-PSDWizardSelectedApplications',

    # Task Sequences (FIXED)
    'Export-PSDWizardTaskSequence',

    # Splashscreen
    'Show-PSDWizardSplashScreen',
    'Close-PSDWizardSplashScreen',
    'Update-PSDWizardProgressBar',

    # UI Builder
    'Format-PSDWizard',
    'Invoke-PSDWizard',

    # Main Entry Point
    'Show-PSDWizard'
)

# Export module variables
Export-ModuleMember -Variable @(
    'script:ModuleVersion',
    'script:ModuleDate'
)