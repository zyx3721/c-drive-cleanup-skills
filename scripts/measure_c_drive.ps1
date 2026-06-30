param(
    [string]$Drive = "C:",
    [int]$Top = 20,
    [switch]$IncludeTopLevel,
    [string]$JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-Bytes {
    param([double]$Bytes)

    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function Get-FolderSize {
    param([Parameter(Mandatory = $true)][string]$Path)

    $total = 0L
    $files = 0L
    $errors = 0L

    $exists = $false
    try {
        $exists = Test-Path -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        $errors += 1
    }

    if (-not $exists) {
        return [pscustomobject]@{
            Path = $Path
            Exists = $false
            Bytes = 0L
            Size = Convert-Bytes 0
            Files = 0L
            Errors = $errors
        }
    }

    try {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable scanErrors |
            ForEach-Object {
                $total += $_.Length
                $files += 1
            }
        $errors = @($scanErrors).Count
    }
    catch {
        $errors += 1
    }

    return [pscustomobject]@{
        Path = $Path
        Exists = $true
        Bytes = $total
        Size = Convert-Bytes $total
        Files = $files
        Errors = $errors
    }
}

function Add-Candidate {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Category,
        [string]$Path,
        [string]$Risk,
        [string]$Note
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
    foreach ($item in $List) {
        if ([System.IO.Path]::GetFullPath($item.Path).TrimEnd('\').ToLowerInvariant() -eq $normalizedPath) {
            return
        }
    }

    $size = Get-FolderSize -Path $Path
    if (-not $size.Exists) { return }

    $List.Add([pscustomobject]@{
        Category = $Category
        Path = $size.Path
        Bytes = $size.Bytes
        Size = $size.Size
        Files = $size.Files
        Errors = $size.Errors
        Risk = $Risk
        Note = $Note
    }) | Out-Null
}

if ($Drive -notmatch "^[A-Za-z]:$") {
    throw "Drive must look like C: or D:."
}

$driveName = $Drive.Substring(0, 1).ToUpperInvariant()
$psDrive = Get-PSDrive -Name $driveName -ErrorAction Stop
$root = "$driveName`:\"

$volume = [pscustomobject]@{
    Drive = "$driveName`:"
    Root = $root
    Used = Convert-Bytes ($psDrive.Used)
    Free = Convert-Bytes ($psDrive.Free)
    Total = Convert-Bytes ($psDrive.Used + $psDrive.Free)
    UsedBytes = [int64]$psDrive.Used
    FreeBytes = [int64]$psDrive.Free
    TotalBytes = [int64]($psDrive.Used + $psDrive.Free)
    FreePercent = if (($psDrive.Used + $psDrive.Free) -gt 0) { [math]::Round(($psDrive.Free / ($psDrive.Used + $psDrive.Free)) * 100, 2) } else { 0 }
}

$candidates = [System.Collections.Generic.List[object]]::new()

Add-Candidate $candidates "User temp" $env:TEMP "safe-with-approval" "Close apps first; skip locked files."
Add-Candidate $candidates "Windows temp" (Join-Path $root "Windows\Temp") "safe-with-approval" "Close apps first; skip locked files."
Add-Candidate $candidates "Windows Update downloads" (Join-Path $root "Windows\SoftwareDistribution\Download") "safe-with-approval" "Use only when Windows Update is idle; restart update services."
Add-Candidate $candidates "Delivery Optimization cache" (Join-Path $root "Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") "safe-with-approval" "Prefer Windows Settings or Disk Cleanup."
Add-Candidate $candidates "CBS logs" (Join-Path $root "Windows\Logs\CBS") "review-first" "Logs can help troubleshooting; compress or clear only if not needed."
Add-Candidate $candidates "WER reports" (Join-Path $root "ProgramData\Microsoft\Windows\WER") "safe-with-approval" "Problem reports; usually low risk."
Add-Candidate $candidates "ProgramData package cache" (Join-Path $root "ProgramData\Package Cache") "avoid-manual-delete" "Installer repair cache; do not delete manually."

$usersRoot = Join-Path $root "Users"
if (Test-Path -LiteralPath $usersRoot) {
    Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("All Users", "Default", "Default User", "Public") } |
        ForEach-Object {
            Add-Candidate $candidates "User Downloads" (Join-Path $_.FullName "Downloads") "review-first" "User files; review before deleting."
            Add-Candidate $candidates "User AppData temp" (Join-Path $_.FullName "AppData\Local\Temp") "safe-with-approval" "Close apps first; skip locked files."
            Add-Candidate $candidates "Browser cache root" (Join-Path $_.FullName "AppData\Local\Microsoft\Edge\User Data\Default\Cache") "safe-with-approval" "Prefer browser settings; close browser first."
            Add-Candidate $candidates "Chrome cache root" (Join-Path $_.FullName "AppData\Local\Google\Chrome\User Data\Default\Cache") "safe-with-approval" "Prefer browser settings; close browser first."
        }
}

$topLevel = @()
if ($IncludeTopLevel) {
    $topLevel = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Get-FolderSize -Path $_.FullName } |
        Sort-Object Bytes -Descending |
        Select-Object -First $Top
}

$report = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString("s")
    Volume = $volume
    CleanupCandidates = $candidates | Sort-Object Bytes -Descending | Select-Object -First $Top
    TopLevelDirectories = $topLevel
}

if ($JsonPath) {
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
}

Write-Host ""
Write-Host "Volume"
$volume | Format-List Drive,Root,Used,Free,Total,FreePercent

Write-Host ""
Write-Host "Cleanup candidates (read-only estimates)"
$report.CleanupCandidates | Format-Table Category,Size,Risk,Path -AutoSize

if ($IncludeTopLevel) {
    Write-Host ""
    Write-Host "Top-level directories (read-only estimates)"
    $report.TopLevelDirectories | Format-Table Size,Path,Errors -AutoSize
}

if ($JsonPath) {
    Write-Host ""
    Write-Host "JSON report written to $JsonPath"
}
