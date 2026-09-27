<#
.SYNOPSIS
    Common utility functions shared across PSD modules
.DESCRIPTION
    This module contains shared functions and initialization code used by multiple PSD modules
    to reduce code duplication and improve maintainability.
.LINK
    https://github.com/FriendsOfMDT/PSD
.NOTES
    FileName: PSDCommon.psm1
    Solution: PowerShell Deployment for MDT
    Author: PSD Development Team
    Contact: @PowershellCrack
    Created: 2025-10-31
    Modified: 2025-10-31
    Version: 1.0.1

.EXAMPLE
    Import-Module PSDCommon
    Initialize-PSDDebugMode
    
    # Access state
    $state = Get-PSDState
    $state.SetDataPath("C:\MININT")
    $logPath = $state.GetLogPath()
#>

#region STATE MANAGEMENT CLASS

<#
.SYNOPSIS
    Manages PSD state using a singleton pattern to replace global variables
.DESCRIPTION
    This class provides centralized state management for PSD modules,
    eliminating the need for global variables while maintaining accessibility
#>
class PSDState {
    # Hidden static instance for singleton pattern
    hidden static [PSDState] $Instance
    
    # Properties (private, accessed through methods)
    hidden [string] $DataPath = ""
    hidden [string] $LogPath = ""
    hidden [string] $TranscriptLogPath = ""
    hidden [bool] $DebugEnabled = $false
    hidden [hashtable] $CustomProperties = @{}
    
    # Singleton: Private constructor
    hidden PSDState() {
        $this.DebugEnabled = $false
    }
    
    # Get singleton instance
    static [PSDState] GetInstance() {
        if ($null -eq [PSDState]::Instance) {
            [PSDState]::Instance = [PSDState]::new()
        }
        return [PSDState]::Instance
    }
    
    # Data Path methods
    [string] GetDataPath() {
        return $this.DataPath
    }
    
    [void] SetDataPath([string]$path) {
        $this.DataPath = $path
    }
    
    [bool] HasDataPath() {
        return (-not [string]::IsNullOrEmpty($this.DataPath))
    }
    
    # Log Path methods
    [string] GetLogPath() {
        return $this.LogPath
    }
    
    [void] SetLogPath([string]$path) {
        $this.LogPath = $path
    }
    
    # Transcript Log Path methods
    [string] GetTranscriptLogPath() {
        return $this.TranscriptLogPath
    }
    
    [void] SetTranscriptLogPath([string]$path) {
        $this.TranscriptLogPath = $path
    }
    
    # Debug methods
    [bool] IsDebugEnabled() {
        return $this.DebugEnabled
    }
    
    [void] SetDebugEnabled([bool]$enabled) {
        $this.DebugEnabled = $enabled
        if ($enabled) {
            $script:VerbosePreference = "Continue"
        }
    }
    
    # Custom properties (for extensibility)
    [object] GetProperty([string]$name) {
        if ($this.CustomProperties.ContainsKey($name)) {
            return $this.CustomProperties[$name]
        }
        return $null
    }
    
    [void] SetProperty([string]$name, [object]$value) {
        $this.CustomProperties[$name] = $value
    }
    
    [bool] HasProperty([string]$name) {
        return $this.CustomProperties.ContainsKey($name)
    }
    
    [void] RemoveProperty([string]$name) {
        if ($this.CustomProperties.ContainsKey($name)) {
            $this.CustomProperties.Remove($name)
        }
    }
    
    # Get all custom properties
    [hashtable] GetAllProperties() {
        return $this.CustomProperties.Clone()
    }
    
    # Clear all state (for testing/cleanup)
    [void] Clear() {
        $this.DataPath = ""
        $this.LogPath = ""
        $this.TranscriptLogPath = ""
        $this.DebugEnabled = $false
        $this.CustomProperties.Clear()
    }
}

<#
.SYNOPSIS
    Gets the PSD state singleton instance
.DESCRIPTION
    Returns the singleton instance of PSDState for accessing shared state
.OUTPUTS
    PSDState - The singleton state instance
.EXAMPLE
    $state = Get-PSDState
    $state.SetDataPath("C:\MININT")
#>
function Get-PSDState {
    [CmdletBinding()]
    [OutputType([PSDState])]
    param()
    
    return [PSDState]::GetInstance()
}

#endregion

#region INITIALIZATION FUNCTIONS

<#
.SYNOPSIS
    Initializes PSD debug mode based on environment variables
.DESCRIPTION
    Checks TSEnv:PSDDebug and sets debug state and verbose preference
#>
function Initialize-PSDDebugMode {
    [CmdletBinding()]
    param()
    
    $state = Get-PSDState
    
    # Check for debug in PowerShell and TSEnv
    if ($TSEnv:PSDDebug -eq "YES") {
        $state.SetDebugEnabled($true)
    }
    if ($PSDDebug -eq $true) {
        $state.SetDebugEnabled($true)
    }
    
    # Set verbose preference if debug is enabled
    if ($state.IsDebugEnabled()) {
        $script:VerbosePreference = "Continue"
    }
}

<#
.SYNOPSIS
    Gets the calling script name safely
.DESCRIPTION
    Attempts to get the PowerShell caller script name, returns 'PSD' if unable
.OUTPUTS
    String - The calling script name without extension
#>
function Get-PSDCallerScript {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    
    try {
        $caller = Split-Path -Path $MyInvocation.PSCommandPath -Leaf -ErrorAction Stop
        return $caller
    }
    catch {
        return 'PSD'
    }
}

#endregion

#region BACKWARD COMPATIBILITY HELPERS

<#
.SYNOPSIS
    Gets or sets $Global:PSDDebug for backward compatibility
.DESCRIPTION
    Provides backward compatibility by syncing with PSDState
.PARAMETER Value
    Optional value to set
.OUTPUTS
    Boolean - Current debug state
#>
function Get-PSDDebugState {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$Value
    )
    
    $state = Get-PSDState
    
    if ($PSBoundParameters.ContainsKey('Value')) {
        $state.SetDebugEnabled($Value)
    }
    
    return $state.IsDebugEnabled()
}

<#
.SYNOPSIS
    Gets or sets the PSD data path (replaces $global:psuDataPath)
.DESCRIPTION
    Provides centralized data path management through state class
.PARAMETER Path
    Optional path to set
.OUTPUTS
    String - Current data path
#>
function Get-PSDDataPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    
    $state = Get-PSDState
    
    if ($PSBoundParameters.ContainsKey('Path')) {
        $state.SetDataPath($Path)
    }
    
    return $state.GetDataPath()
}

<#
.SYNOPSIS
    Sets the PSD data path
.DESCRIPTION
    Sets the data path in the state management system
.PARAMETER Path
    The path to set
#>
function Set-PSDDataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $state = Get-PSDState
    $state.SetDataPath($Path)
}

<#
.SYNOPSIS
    Gets or sets the PSD log path (replaces $Global:PSDLogPath)
.DESCRIPTION
    Provides centralized log path management through state class
.PARAMETER Path
    Optional path to set
.OUTPUTS
    String - Current log path
#>
function Get-PSDLogPathFromState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    
    $state = Get-PSDState
    
    if ($PSBoundParameters.ContainsKey('Path')) {
        $state.SetLogPath($Path)
    }
    
    return $state.GetLogPath()
}

<#
.SYNOPSIS
    Sets the PSD log path
.DESCRIPTION
    Sets the log path in the state management system
.PARAMETER Path
    The path to set
#>
function Set-PSDLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $state = Get-PSDState
    $state.SetLogPath($Path)
}

<#
.SYNOPSIS
    Gets or sets the PSD transcript log path (replaces $Global:PSDTranscriptLog)
.DESCRIPTION
    Provides centralized transcript log path management through state class
.PARAMETER Path
    Optional path to set
.OUTPUTS
    String - Current transcript log path
#>
function Get-PSDTranscriptLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    
    $state = Get-PSDState
    
    if ($PSBoundParameters.ContainsKey('Path')) {
        $state.SetTranscriptLogPath($Path)
    }
    
    return $state.GetTranscriptLogPath()
}

<#
.SYNOPSIS
    Sets the PSD transcript log path
.DESCRIPTION
    Sets the transcript log path in the state management system
.PARAMETER Path
    The path to set
#>
function Set-PSDTranscriptLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $state = Get-PSDState
    $state.SetTranscriptLogPath($Path)
}

#endregion

#region WPF/XAML FUNCTIONS

<#
.SYNOPSIS
    Loads required WPF assemblies
.DESCRIPTION
    Loads PresentationFramework and PresentationCore assemblies for WPF UI
#>
function Initialize-PSDWPFAssemblies {
    [CmdletBinding()]
    param()
    
    [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework')
    [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')
    
    Write-Verbose "WPF Assemblies loaded successfully"
}

<#
.SYNOPSIS
    Processes XAML and creates a WPF window
.DESCRIPTION
    Takes XAML string, processes it, and returns a hashtable with Window and named elements
.PARAMETER XamlContent
    The XAML content as a string
.PARAMETER SyncHash
    Optional synchronized hashtable to populate with UI elements
.OUTPUTS
    Hashtable containing Window and named XAML elements
#>
function New-PSDWPFWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$XamlContent,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$SyncHash = @{}
    )
    
    # Load WPF assemblies if not already loaded
    Initialize-PSDWPFAssemblies
    
    # Process XAML
    [xml]$xaml = $XamlContent -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    $SyncHash.Window = [Windows.Markup.XamlReader]::Load($reader)
    
    # Store named elements in hashtable
    $xaml.SelectNodes("//*[@Name]") | ForEach-Object { 
        $SyncHash."$($_.Name)" = $SyncHash.Window.FindName($_.Name)
    }
    
    return $SyncHash
}

#endregion

#region ENVIRONMENT DETECTION FUNCTIONS

<#
.SYNOPSIS
    Checks if running in Windows PE
.DESCRIPTION
    Tests for the MiniNT registry key to determine if running in WinPE
.OUTPUTS
    Boolean - True if running in WinPE, False otherwise
#>
function Test-PSDInWinPE {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    return Test-Path -Path Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlset\Control\MiniNT
}

<#
.SYNOPSIS
    Checks if running in ISE
.DESCRIPTION
    Determines if the script is running in PowerShell ISE
.OUTPUTS
    Boolean - True if running in ISE, False otherwise
#>
function Test-PSDIsISE {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    try {
        return ($null -ne $psISE)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Checks if running in Visual Studio Code
.DESCRIPTION
    Determines if the script is running in VS Code
.OUTPUTS
    Boolean - True if running in VS Code, False otherwise
#>
function Test-PSDIsVSCode {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    if ($env:TERM_PROGRAM -eq 'vscode') {
        return $true
    }
    else {
        return $false
    }
}

<#
.SYNOPSIS
    Checks if Task Sequence Environment exists
.DESCRIPTION
    Tests if the Microsoft.SMS.TSEnvironment COM Object is accessible
.OUTPUTS
    Boolean - True if TS environment exists, False otherwise
#>
function Test-PSDTSEnvironment {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    try {
        Get-ChildItem -Path tsenv: -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

#endregion

#region NETWORK FUNCTIONS

<#
.SYNOPSIS
    Converts IPv4 address to integer
.DESCRIPTION
    Converts an IPv4 address string to a 32-bit unsigned integer
.PARAMETER IPAddress
    The IPv4 address to convert
.OUTPUTS
    UInt32 - The IP address as an integer
#>
function Convert-PSDIPv4ToInt {
    [CmdletBinding()]
    [OutputType([UInt32])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^(?:(?:0?0?\d|0?[1-9]\d|1\d\d|2[0-5][0-5]|2[0-4]\d)\.){3}(?:0?0?\d|0?[1-9]\d|1\d\d|2[0-5][0-5]|2[0-4]\d)$')]
        [string]$IPAddress
    )
    
    try {
        $bytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
        [Array]::Reverse($bytes)
        return [System.BitConverter]::ToUInt32($bytes, 0)
    }
    catch {
        Write-Error "Failed to convert IP address: $_"
        return 0
    }
}

<#
.SYNOPSIS
    Converts integer to IPv4 address
.DESCRIPTION
    Converts a 32-bit unsigned integer to an IPv4 address string
.PARAMETER Integer
    The integer to convert
.OUTPUTS
    String - The IPv4 address
#>
function Convert-PSDIntToIPv4 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [UInt32]$Integer
    )
    
    try {
        $bytes = [System.BitConverter]::GetBytes($Integer)
        [Array]::Reverse($bytes)
        return ([IPAddress]($bytes)).ToString()
    }
    catch {
        Write-Error "Failed to convert integer to IP: $_"
        return ""
    }
}

<#
.SYNOPSIS
    Converts CIDR to subnet mask
.DESCRIPTION
    Converts a CIDR prefix length to a dotted decimal subnet mask
.PARAMETER PrefixLength
    The CIDR prefix length (0-32)
.OUTPUTS
    String - The subnet mask in dotted decimal notation
#>
function Convert-PSDCIDRToNetmask {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )
    
    $bitString = ('1' * $PrefixLength).PadRight(32, '0')
    $strBuilder = New-Object -TypeName Text.StringBuilder
    
    for ($i = 0; $i -lt 32; $i += 8) {
        $null = $strBuilder.Append([Convert]::ToInt32($bitString.Substring($i, 8), 2))
        $null = $strBuilder.Append('.')
    }
    
    return $strBuilder.ToString().TrimEnd('.')
}

<#
.SYNOPSIS
    Converts subnet mask to CIDR
.DESCRIPTION
    Converts a dotted decimal subnet mask to CIDR prefix length
.PARAMETER SubnetMask
    The subnet mask in dotted decimal notation
.OUTPUTS
    Int - The CIDR prefix length
#>
function Convert-PSDNetmaskToCIDR {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^(?:(?:0|128|192|224|240|248|252|254|255)\.){3}(?:0|128|192|224|240|248|252|254|255)$')]
        [string]$SubnetMask
    )
    
    $byteRegex = '^(0|128|192|224|240|248|252|254|255)$'
    $invalidMaskMsg = "Invalid SubnetMask specified [$SubnetMask]"
    
    try {
        $octets = $SubnetMask.Split('.')
        foreach ($octet in $octets) {
            if ($octet -notmatch $byteRegex) {
                throw $invalidMaskMsg
            }
        }
        
        $binString = ($octets | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
        return ($binString.ToCharArray() | Where-Object { $_ -eq '1' }).Count
    }
    catch {
        Write-Error "Failed to convert netmask: $_"
        return 0
    }
}

#endregion

#region RUNSPACE FUNCTIONS

<#
.SYNOPSIS
    Creates a new synchronized hashtable for runspace communication
.DESCRIPTION
    Creates a thread-safe hashtable for sharing data between runspaces
.OUTPUTS
    Hashtable - A synchronized hashtable
#>
function New-PSDSyncHash {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    
    return [hashtable]::Synchronized(@{})
}

<#
.SYNOPSIS
    Waits for an asynchronous runspace to complete with timeout
.DESCRIPTION
    Waits for a PowerShell runspace to complete, with optional timeout
.PARAMETER AsyncHandle
    The async handle from BeginInvoke()
.PARAMETER PowerShellCommand
    The PowerShell command object
.PARAMETER TimeoutSeconds
    Optional timeout in seconds (default 0 = no timeout)
.OUTPUTS
    Boolean - True if completed successfully, False if timed out
#>
function Wait-PSDRunspace {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        $AsyncHandle,
        
        [Parameter(Mandatory = $true)]
        $PowerShellCommand,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0
    )
    
    if ($TimeoutSeconds -gt 0) {
        $TimeoutMilliseconds = $TimeoutSeconds * 1000
        $ElapsedTime = 0
        $Interval = 100
        
        do {
            $ElapsedTime += $Interval
            Start-Sleep -Milliseconds $Interval
            
            if ($AsyncHandle.IsCompleted) {
                $null = $PowerShellCommand.EndInvoke($AsyncHandle)
                return $true
            }
        }
        while ($ElapsedTime -lt $TimeoutMilliseconds)
        
        Write-Warning "Runspace timed out after $TimeoutSeconds seconds"
        return $false
    }
    else {
        # Wait indefinitely
        do {
            Start-Sleep -Milliseconds 100
        }
        while (!$AsyncHandle.IsCompleted)
        
        $null = $PowerShellCommand.EndInvoke($AsyncHandle)
        return $true
    }
}

#endregion

#region CHASSIS TYPE FUNCTIONS

<#
.SYNOPSIS
    Converts chassis type ID to friendly name
.DESCRIPTION
    Converts numeric chassis type to a human-readable name
.PARAMETER ChassisId
    The chassis type ID from Win32_SystemEnclosure
.OUTPUTS
    String - The friendly chassis type name
#>
function ConvertTo-PSDChassisType {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ChassisId
    )
    
    switch ($ChassisId) {
        1  { return "Other" }
        2  { return "Unknown" }
        3  { return "Desktop" }
        4  { return "Low Profile Desktop" }
        5  { return "Pizza Box" }
        6  { return "Mini Tower" }
        7  { return "Tower" }
        8  { return "Portable" }
        9  { return "Laptop" }
        10 { return "Notebook" }
        11 { return "Hand Held" }
        12 { return "Docking Station" }
        13 { return "All in One" }
        14 { return "Sub Notebook" }
        15 { return "Space-Saving" }
        16 { return "Lunch Box" }
        17 { return "Main System Chassis" }
        18 { return "Expansion Chassis" }
        19 { return "SubChassis" }
        20 { return "Bus Expansion Chassis" }
        21 { return "Peripheral Chassis" }
        22 { return "Storage Chassis" }
        23 { return "Rack Mount Chassis" }
        24 { return "Sealed-Case PC" }
        30 { return "Tablet" }
        31 { return "Convertible" }
        32 { return "Detachable" }
        default { return "Unknown" }
    }
}

#endregion

# Export all functions
$exportModuleMemberParams = @{
    Function = @(
        'Get-PSDState',
        'Initialize-PSDDebugMode',
        'Get-PSDCallerScript',
        'Get-PSDDebugState',
        'Get-PSDDataPath',
        'Set-PSDDataPath',
        'Get-PSDLogPathFromState',
        'Set-PSDLogPath',
        'Get-PSDTranscriptLogPath',
        'Set-PSDTranscriptLogPath',
        'Initialize-PSDWPFAssemblies',
        'New-PSDWPFWindow',
        'Test-PSDInWinPE',
        'Test-PSDIsISE',
        'Test-PSDIsVSCode',
        'Test-PSDTSEnvironment',
        'Convert-PSDIPv4ToInt',
        'Convert-PSDIntToIPv4',
        'Convert-PSDCIDRToNetmask',
        'Convert-PSDNetmaskToCIDR',
        'New-PSDSyncHash',
        'Wait-PSDRunspace',
        'ConvertTo-PSDChassisType'
    )
}

Export-ModuleMember @exportModuleMemberParams
