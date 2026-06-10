@{
    RootModule        = 'PingPlus.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'b8f6c2e4-7a3d-4c1b-9e5a-2f0d6c8a1b3e'
    Author            = 'Feenixu'
    Copyright         = '(c) 2026 Feenixu. MIT License.'
    Description       = 'A non-destructive wrapper around Windows ping.exe that logs every reply/timeout to JSONL and renders a dependency-free local HTML report (latency graph, availability strip, outage windows). Configurable log retention.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Invoke-PingPlus',
        'Show-PingReport',
        'Get-PingStats',
        'Get-PingPlusPaths',
        'Get-PingPlusConfig',
        'Edit-PingPlusConfig',
        'Invoke-PingRetention'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('ping', 'network', 'monitoring', 'diagnostics', 'latency', 'Windows')
            LicenseUri   = 'https://github.com/Feenixu/ping-plus/blob/master/LICENSE'
            ProjectUri   = 'https://github.com/Feenixu/ping-plus'
            ReleaseNotes = 'See CHANGELOG.md'
        }
    }
}
