$apiKey = $env:GOOGLE_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = $env:GEMINI_API_KEY
}
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    # Check registry as fallback
    $apiKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')?.GetValue('GOOGLE_API_KEY')
}
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')?.GetValue('GEMINI_API_KEY')
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Error "API Key not found in env or registry."
    exit 1
}

$params = @{
    DeviceName      = "LG ULTRAGEAR(DisplayPort)"
    InstanceId      = "DISPLAY\GSM5BD3\5&2018DE76&1&UID4354"
    HardwareId      = "MONITOR\GSM5BD3"
    Manufacturer    = "LG"
    InstalledDriver = "LG 1.0.0.0 (oem19.inf)"
    Motherboard     = "Micro-Star International Co., Ltd. MS-7E51 (Board: MAG X870 TOMAHAWK WIFI (MS-7E51))"
    Cpu             = "AMD Ryzen 7 9700X 8-Core Processor             "
    Os              = "Microsoft Windows 10 Pro 64-bit"
    ApiKey          = $apiKey
    TracePath       = "C:\Users\joty79\AppData\Local\DeviceCheck\machines\38e0b268763434c30a1b38c6\agent-logs\test_trace.jsonl"
    CheckpointPath  = "C:\Users\joty79\AppData\Local\DeviceCheck\machines\38e0b268763434c30a1b38c6\agent-state\test_checkpoint.json"
    ToolCacheRoot   = "C:\Users\joty79\AppData\Local\DeviceCheck\machines\38e0b268763434c30a1b38c6\agent-tool-cache"
    ModelName       = "gemini-3.1-flash-lite"
    MaxIterations   = 10
}

Write-Host "Running Get-DriverUpdateAgent.ps1 with test params..."
& ".\Get-DriverUpdateAgent.ps1" @params
