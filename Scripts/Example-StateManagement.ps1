# Example: Using PSD State Management

# This example demonstrates how to use the new PSDState class
# to manage state without global variables

#region SETUP
# Import the common module
Import-Module "$PSScriptRoot\PSDCommon.psm1" -Force

# Initialize debug mode (checks TSEnv and sets state)
Initialize-PSDDebugMode
#endregion

#region EXAMPLE 1: Using State Class Directly

Write-Host "`n=== Example 1: Direct State Class Usage ===" -ForegroundColor Cyan

# Get the singleton instance
$state = Get-PSDState

# Set some values
$state.SetDataPath("C:\MININT")
$state.SetLogPath("C:\MININT\Logs\PSD.log")
$state.SetDebugEnabled($true)

# Get values
Write-Host "Data Path: $($state.GetDataPath())"
Write-Host "Log Path: $($state.GetLogPath())"
Write-Host "Debug Enabled: $($state.IsDebugEnabled())"

# Check if values exist
if ($state.HasDataPath()) {
    Write-Host "Data path is configured!" -ForegroundColor Green
}

#endregion

#region EXAMPLE 2: Using Helper Functions

Write-Host "`n=== Example 2: Helper Function Usage ===" -ForegroundColor Cyan

# Set values using helpers
Set-PSDDataPath -Path "D:\DeploymentShare"
Set-PSDLogPath -Path "D:\Logs\Deployment.log"
Set-PSDTranscriptLogPath -Path "D:\Logs\Transcript.log"

# Get values using helpers
Write-Host "Data Path: $(Get-PSDDataPath)"
Write-Host "Log Path: $(Get-PSDLogPathFromState)"
Write-Host "Transcript: $(Get-PSDTranscriptLogPath)"
Write-Host "Debug State: $(Get-PSDDebugState)"

#endregion

#region EXAMPLE 3: Custom Properties

Write-Host "`n=== Example 3: Custom Properties ===" -ForegroundColor Cyan

# Get state instance
$state = Get-PSDState

# Add custom properties for your specific needs
$state.SetProperty("DeploymentPhase", "WinPE")
$state.SetProperty("TaskSequenceName", "Windows 11 Enterprise")
$state.SetProperty("StartTime", (Get-Date))
$state.SetProperty("ComputerName", "PC-12345")
$state.SetProperty("DeploymentType", "NewComputer")

# Check if property exists before getting
if ($state.HasProperty("TaskSequenceName")) {
    Write-Host "Task Sequence: $($state.GetProperty('TaskSequenceName'))"
}

# Get all custom properties
$allProps = $state.GetAllProperties()
Write-Host "`nAll Custom Properties:"
$allProps.GetEnumerator() | ForEach-Object {
    Write-Host "  $($_.Key): $($_.Value)"
}

# Remove a property
$state.RemoveProperty("StartTime")
Write-Host "`nAfter removing StartTime, HasProperty: $($state.HasProperty('StartTime'))"

#endregion

#region EXAMPLE 4: Cross-Function State Sharing

Write-Host "`n=== Example 4: State Sharing Between Functions ===" -ForegroundColor Cyan

function Set-DeploymentInfo {
    param(
        [string]$Phase,
        [string]$TaskSequence,
        [string]$Computer
    )
    
    $state = Get-PSDState
    $state.SetProperty("Phase", $Phase)
    $state.SetProperty("TaskSequence", $TaskSequence)
    $state.SetProperty("Computer", $Computer)
    
    Write-Host "Deployment info set: $Phase - $TaskSequence - $Computer" -ForegroundColor Green
}

function Get-DeploymentInfo {
    $state = Get-PSDState
    
    return [PSCustomObject]@{
        Phase = $state.GetProperty("Phase")
        TaskSequence = $state.GetProperty("TaskSequence")
        Computer = $state.GetProperty("Computer")
    }
}

# Set deployment info in one function
Set-DeploymentInfo -Phase "FullOS" -TaskSequence "Win11-Deploy" -Computer "DESKTOP-ABC"

# Get it in another function - state is shared!
$deployInfo = Get-DeploymentInfo
Write-Host "`nRetrieved Deployment Info:"
$deployInfo | Format-List

#endregion

#region EXAMPLE 5: Clearing State (for testing/cleanup)

Write-Host "`n=== Example 5: Clearing State ===" -ForegroundColor Cyan

$state = Get-PSDState

Write-Host "Before Clear:"
Write-Host "  Data Path: $($state.GetDataPath())"
Write-Host "  Debug Enabled: $($state.IsDebugEnabled())"
Write-Host "  Custom Props: $($state.GetAllProperties().Count)"

# Clear all state
$state.Clear()

Write-Host "`nAfter Clear:"
Write-Host "  Data Path: '$($state.GetDataPath())'"
Write-Host "  Debug Enabled: $($state.IsDebugEnabled())"
Write-Host "  Custom Props: $($state.GetAllProperties().Count)"

#endregion

#region EXAMPLE 6: Migration Pattern

Write-Host "`n=== Example 6: Migration from Global Variables ===" -ForegroundColor Cyan

# OLD WAY (Don't do this):
# $global:MyDataPath = "C:\Data"
# $global:MyLogPath = "C:\Logs\app.log"
# if ($global:MyDataPath -ne "") { ... }

# NEW WAY (Do this instead):
$state = Get-PSDState
$state.SetDataPath("C:\Data")
$state.SetLogPath("C:\Logs\app.log")
if ($state.HasDataPath()) {
    Write-Host "Using new state management!" -ForegroundColor Green
    Write-Host "  Data Path: $($state.GetDataPath())"
    Write-Host "  Log Path: $($state.GetLogPath())"
}

#endregion

Write-Host "`n=== Examples Complete ===" -ForegroundColor Cyan
Write-Host "State management is centralized, testable, and maintainable!" -ForegroundColor Green
