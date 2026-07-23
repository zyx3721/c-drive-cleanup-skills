param(
    [ValidatePattern("^[A-Za-z]:$")]
    [string]$Drive = "C:",
    [ValidateSet("Quick", "Full")]
    [string]$ScanMode = "Quick",
    [ValidateRange(1, 500)]
    [int]$Top = 20,
    [ValidateRange(0.01, 1024)]
    [double]$MinimumLargeFileGB = 1,
    [ValidateRange(0.01, 1024)]
    [double]$MinimumLargeDirectoryGB = 0.25,
    [switch]$IncludeTopLevel,
    [switch]$AnalyzeComponentStore,
    [string]$JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw "Administrator privileges are required. Relaunch Codex or PowerShell as Administrator, then run the scan again."
}

function Convert-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function Get-DirectoryMeasurement {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.PSIsContainer) {
        return [pscustomobject]@{ Path = $Path; Exists = $false; Bytes = 0L; Size = "0 B"; Files = 0L; Errors = 0L; ErrorSamples = @() }
    }

    $total = 0L
    $files = 0L
    $errors = 0L
    $errorSamples = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($item.FullName)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try {
            foreach ($filePath in [System.IO.Directory]::EnumerateFiles($current)) {
                try {
                    $total += [long]([System.IO.FileInfo]::new($filePath)).Length
                    $files += 1
                } catch { $errors += 1; if ($errorSamples.Count -lt 5) { $errorSamples.Add(("{0}: {1}" -f $filePath, $_.Exception.Message)) } }
            }
            foreach ($directoryPath in [System.IO.Directory]::EnumerateDirectories($current)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($directoryPath)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $pending.Push($directoryPath) }
                } catch { $errors += 1; if ($errorSamples.Count -lt 5) { $errorSamples.Add(("{0}: {1}" -f $directoryPath, $_.Exception.Message)) } }
            }
        } catch {
            $errors += 1
            if ($errorSamples.Count -lt 5) { $errorSamples.Add(("{0}: {1}" -f $current, $_.Exception.Message)) }
        }
    }
    [pscustomobject]@{
        Path = $item.FullName
        Exists = $true
        Bytes = $total
        Size = Convert-Bytes $total
        Files = $files
        Errors = $errors
        ErrorSamples = @($errorSamples)
    }
}

function Get-FileMeasurement {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer) { return $null }
    [pscustomobject]@{ Path = $item.FullName; Bytes = [long]$item.Length; Size = Convert-Bytes ([long]$item.Length) }
}

function Add-DirectoryCandidate {
    param([System.Collections.Generic.List[object]]$List, [string]$Category, [string]$Path, [string]$Risk, [string]$Note)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    foreach ($existing in $List) {
        if ($existing.Path -eq $Path) { return }
    }
    $size = Get-DirectoryMeasurement -Path $Path
    if (-not $size.Exists) { return }
    $List.Add([pscustomobject]@{
        Category = $Category; Path = $size.Path; Bytes = $size.Bytes; Size = $size.Size
        Files = $size.Files; Errors = $size.Errors; Risk = $Risk; Note = $Note
        ErrorSamples = $size.ErrorSamples
    }) | Out-Null
}

function Get-RecycleBinMeasurement {
    param([Parameter(Mandatory = $true)][string]$Root)
    $size = Get-DirectoryMeasurement -Path (Join-Path $Root '$Recycle.Bin')
    [pscustomobject]@{
        Category = "Recycle Bin"; Path = $size.Path; Bytes = $size.Bytes; Size = $size.Size; Risk = "safe-with-approval"
        Errors = $size.Errors; ErrorSamples = $size.ErrorSamples
    }
}

function Add-TopRecord {
    param([System.Collections.Generic.List[object]]$List, [object]$Record, [int]$Limit)
    if ($List.Count -lt $Limit) {
        $List.Add($Record) | Out-Null
        return
    }
    $smallestIndex = 0
    for ($index = 1; $index -lt $List.Count; $index += 1) {
        if ($List[$index].Bytes -lt $List[$smallestIndex].Bytes) { $smallestIndex = $index }
    }
    if ($Record.Bytes -gt $List[$smallestIndex].Bytes) { $List[$smallestIndex] = $Record }
}

function Get-PathClassification {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $normalized = $Path.TrimEnd('\\').ToLowerInvariant()
    $windowsTemp = (Join-Path $Root 'Windows\Temp').ToLowerInvariant()
    $updateDownloads = (Join-Path $Root 'Windows\SoftwareDistribution\Download').ToLowerInvariant()
    $deliveryCache = (Join-Path $Root 'Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache').ToLowerInvariant()
    $werPath = (Join-Path $Root 'ProgramData\Microsoft\Windows\WER').ToLowerInvariant()
    $recycleBin = (Join-Path $Root '$Recycle.Bin').ToLowerInvariant()
    $windowsRoot = (Join-Path $Root 'Windows').ToLowerInvariant()
    $programFilesRoot = (Join-Path $Root 'Program Files').ToLowerInvariant()
    $programDataRoot = (Join-Path $Root 'ProgramData').ToLowerInvariant()

    if ($normalized -eq $windowsTemp -or $normalized -eq $updateDownloads) {
        return [pscustomobject]@{ Category = "Windows temporary data"; Risk = "safe-with-approval"; Note = "Close applications and use the documented service-aware cleanup procedure." }
    }
    if ($normalized -eq $deliveryCache) {
        return [pscustomobject]@{ Category = "Delivery Optimization cache"; Risk = "safe-with-approval"; Note = "Prefer Windows Settings or Disk Cleanup." }
    }
    if ($normalized -eq $werPath) {
        return [pscustomobject]@{ Category = "Windows Error Reporting"; Risk = "safe-with-approval"; Note = "Problem reports; normally low risk." }
    }
    if ($normalized -eq $recycleBin) {
        return [pscustomobject]@{ Category = "Recycle Bin"; Risk = "safe-with-approval"; Note = "Empty through Windows or Clear-RecycleBin only after approval." }
    }
    if ($normalized -match "\\users\\[^\\]+\\appdata\\local\\temp$") {
        return [pscustomobject]@{ Category = "User temporary files"; Risk = "safe-with-approval"; Note = "Close applications first and skip locked files." }
    }
    if ($normalized -match "\\appdata\\local\\(google\\chrome|microsoft\\edge)\\user data\\(default|profile [^\\]+)\\(cache|code cache|gpucache)$") {
        return [pscustomobject]@{ Category = "Browser cache"; Risk = "safe-with-approval"; Note = "Close the browser first; prefer its settings." }
    }
    if ($normalized -match "\\(downloads|desktop|documents|onedrive)$") {
        return [pscustomobject]@{ Category = "User data"; Risk = "review-first"; Note = "Review files; do not bulk-delete user data." }
    }
    if ($normalized -match "\\(docker|virtualbox vms|\.gradle\\caches|\.m2\\repository|\.nuget\\packages|npm-cache|pip\\cache)$") {
        return [pscustomobject]@{ Category = "Development or virtualized data"; Risk = "review-first"; Note = "Use the owning product's cleanup command after reviewing active projects and data." }
    }
    if ($normalized.StartsWith($windowsRoot) -or $normalized.StartsWith($programFilesRoot) -or $normalized.StartsWith($programDataRoot)) {
        return [pscustomobject]@{ Category = "System or application data"; Risk = "official-tool-only"; Note = "Do not delete manually; use Windows, the application, or its uninstaller." }
    }
    return [pscustomobject]@{ Category = "Unclassified"; Risk = "review-first"; Note = "Inspect the owning application and contents before acting." }
}

function Get-FullDriveInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][long]$MinimumDirectoryBytes,
        [Parameter(Mandatory = $true)][long]$MinimumFileBytes,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $directories = [System.Collections.Generic.List[object]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    $cleanupCandidates = [System.Collections.Generic.List[object]]::new()
    $errorSamples = [System.Collections.Generic.List[string]]::new()
    $frames = @{}
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $rootFrame = [pscustomobject]@{ Path = $Root; Parent = $null; Exit = $false; Bytes = 0L; Files = 0L; Errors = 0L }
    $stack.Push($rootFrame)
    $scannedDirectories = 0L
    $scannedFiles = 0L
    $skippedReparsePoints = 0L
    $errors = 0L

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        if ($frame.Exit) {
            $classification = Get-PathClassification -Path $frame.Path -Root $Root
            $record = [pscustomobject]@{
                Path = $frame.Path; Bytes = $frame.Bytes; Size = Convert-Bytes $frame.Bytes; Files = $frame.Files; Errors = $frame.Errors
                Category = $classification.Category; Risk = $classification.Risk; Note = $classification.Note
            }
            if ($record.Bytes -ge $MinimumDirectoryBytes) { Add-TopRecord -List $directories -Record $record -Limit $Limit }
            if ($classification.Risk -eq "safe-with-approval") { Add-TopRecord -List $cleanupCandidates -Record $record -Limit $Limit }
            if ($null -ne $frame.Parent) {
                $parent = $frames[$frame.Parent]
                $parent.Bytes += $frame.Bytes
                $parent.Files += $frame.Files
                $parent.Errors += $frame.Errors
            }
            $frames.Remove($frame.Path)
            continue
        }

        $frames[$frame.Path] = $frame
        $scannedDirectories += 1
        $frame.Exit = $true
        $stack.Push($frame)
        try {
            foreach ($filePath in [System.IO.Directory]::EnumerateFiles($frame.Path)) {
                try {
                    $file = [System.IO.FileInfo]::new($filePath)
                    $frame.Bytes += [long]$file.Length
                    $frame.Files += 1
                    $scannedFiles += 1
                    if ($file.Length -ge $MinimumFileBytes) {
                        $classification = Get-PathClassification -Path $file.FullName -Root $Root
                        Add-TopRecord -List $files -Record ([pscustomobject]@{
                            Path = $file.FullName; Bytes = [long]$file.Length; Size = Convert-Bytes ([long]$file.Length)
                            Category = $classification.Category; Risk = $classification.Risk; Note = $classification.Note
                        }) -Limit $Limit
                    }
                } catch {
                    $errors += 1; $frame.Errors += 1
                    if ($errorSamples.Count -lt 10) { $errorSamples.Add(("{0}: {1}" -f $filePath, $_.Exception.Message)) }
                }
            }
            foreach ($directoryPath in [System.IO.Directory]::EnumerateDirectories($frame.Path)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($directoryPath)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $skippedReparsePoints += 1
                    } else {
                        $stack.Push([pscustomobject]@{ Path = $directoryPath; Parent = $frame.Path; Exit = $false; Bytes = 0L; Files = 0L; Errors = 0L })
                    }
                } catch {
                    $errors += 1; $frame.Errors += 1
                    if ($errorSamples.Count -lt 10) { $errorSamples.Add(("{0}: {1}" -f $directoryPath, $_.Exception.Message)) }
                }
            }
        } catch {
            $errors += 1; $frame.Errors += 1
            if ($errorSamples.Count -lt 10) { $errorSamples.Add(("{0}: {1}" -f $frame.Path, $_.Exception.Message)) }
        }
    }

    [pscustomobject]@{
        Directories = @($directories | Sort-Object Bytes -Descending)
        Files = @($files | Sort-Object Bytes -Descending)
        CleanupCandidates = @($cleanupCandidates | Sort-Object Bytes -Descending)
        ScannedDirectories = $scannedDirectories; ScannedFiles = $scannedFiles; SkippedReparsePoints = $skippedReparsePoints
        Errors = $errors; ErrorSamples = @($errorSamples)
    }
}

function Get-ComponentStoreAnalysis {
    if (-not $AnalyzeComponentStore) { return $null }
    try {
        $output = (& dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String).Trim()
        [pscustomobject]@{ Requested = $true; ExitCode = $LASTEXITCODE; Status = if ($LASTEXITCODE -eq 0) { "success" } else { "failed" }; Output = $output }
    } catch {
        [pscustomobject]@{ Requested = $true; ExitCode = $null; Status = "failed"; Output = $_.Exception.Message }
    }
}

$driveName = $Drive.Substring(0, 1).ToUpperInvariant()
$root = "$driveName`:\"
$psDrive = Get-PSDrive -Name $driveName -ErrorAction Stop
$totalBytes = [long]($psDrive.Used + $psDrive.Free)
$volume = [pscustomobject]@{
    Drive = "$driveName`:"; Root = $root; UsedBytes = [long]$psDrive.Used; FreeBytes = [long]$psDrive.Free; TotalBytes = $totalBytes
    Used = Convert-Bytes ([long]$psDrive.Used); Free = Convert-Bytes ([long]$psDrive.Free); Total = Convert-Bytes $totalBytes
    FreePercent = if ($totalBytes) { [math]::Round(($psDrive.Free / $totalBytes) * 100, 2) } else { 0 }
}

$candidates = [System.Collections.Generic.List[object]]::new()
if ($ScanMode -eq "Quick") {
    Add-DirectoryCandidate $candidates "Windows temporary files" (Join-Path $root "Windows\Temp") "safe-with-approval" "Close applications first; skip locked files."
    Add-DirectoryCandidate $candidates "Windows Update downloads" (Join-Path $root "Windows\SoftwareDistribution\Download") "safe-with-approval" "Only when Windows Update is idle; use the service-aware cleanup procedure."
    Add-DirectoryCandidate $candidates "Delivery Optimization cache" (Join-Path $root "Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") "safe-with-approval" "Prefer Windows Settings or Disk Cleanup."
    Add-DirectoryCandidate $candidates "Windows Error Reporting" (Join-Path $root "ProgramData\Microsoft\Windows\WER") "safe-with-approval" "Problem reports; normally low risk."
    Add-DirectoryCandidate $candidates "CBS logs" (Join-Path $root "Windows\Logs\CBS") "review-first" "Keep while troubleshooting Windows servicing issues."
    Add-DirectoryCandidate $candidates "Installer package cache" (Join-Path $root "ProgramData\Package Cache") "avoid-manual-delete" "Required by application repair and uninstall."

    $userProfiles = Get-ChildItem -LiteralPath (Join-Path $root "Users") -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("All Users", "Default", "Default User", "Public") }
    foreach ($profile in $userProfiles) {
        $profileRoot = $profile.FullName
        Add-DirectoryCandidate $candidates "User temporary files" (Join-Path $profileRoot "AppData\Local\Temp") "safe-with-approval" "Close applications first; skip locked files."
        Add-DirectoryCandidate $candidates "Downloads" (Join-Path $profileRoot "Downloads") "review-first" "User files; inspect before removal."
        Add-DirectoryCandidate $candidates "Desktop" (Join-Path $profileRoot "Desktop") "review-first" "User files; inspect before removal."
        Add-DirectoryCandidate $candidates "Documents" (Join-Path $profileRoot "Documents") "review-first" "User files and project data; inspect before removal."
        Add-DirectoryCandidate $candidates "OneDrive" (Join-Path $profileRoot "OneDrive") "review-first" "Cloud-synced data; change availability through the sync client."
        Add-DirectoryCandidate $candidates "npm cache" (Join-Path $profileRoot "AppData\Local\npm-cache") "review-first" "Use npm cache commands rather than manual deletion."
        Add-DirectoryCandidate $candidates "pip cache" (Join-Path $profileRoot "AppData\Local\pip\Cache") "review-first" "Use pip cache purge after reviewing active environments."
        Add-DirectoryCandidate $candidates "NuGet packages" (Join-Path $profileRoot ".nuget\packages") "review-first" "May be reused by local builds."
        Add-DirectoryCandidate $candidates "Gradle cache" (Join-Path $profileRoot ".gradle\caches") "review-first" "May be reused by local builds."
        Add-DirectoryCandidate $candidates "Maven repository" (Join-Path $profileRoot ".m2\repository") "review-first" "May be reused by local builds."
        Add-DirectoryCandidate $candidates "Docker data" (Join-Path $profileRoot "AppData\Local\Docker") "review-first" "Use Docker commands; images and volumes can contain active data."
        Add-DirectoryCandidate $candidates "VirtualBox VMs" (Join-Path $profileRoot "VirtualBox VMs") "review-first" "Virtual machine images; do not delete manually."
        foreach ($browser in @("Google\Chrome", "Microsoft\Edge")) {
            $userData = Join-Path $profileRoot "AppData\Local\$browser\User Data"
            if (Test-Path -LiteralPath $userData) {
                Get-ChildItem -LiteralPath $userData -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" } |
                    ForEach-Object {
                        foreach ($cacheName in @("Cache", "Code Cache", "GPUCache")) {
                            Add-DirectoryCandidate $candidates "$browser $cacheName" (Join-Path $_.FullName $cacheName) "safe-with-approval" "Close the browser first; prefer browser settings."
                        }
                    }
            }
        }
    }
}

$rootFiles = @("pagefile.sys", "hiberfil.sys", "swapfile.sys", "MEMORY.DMP") |
    ForEach-Object { Get-FileMeasurement -Path (Join-Path $root $_) } | Where-Object { $null -ne $_ }

$topLevel = @()
$largeDirectories = @()
$largeFiles = @()
$fullScan = $null
if ($ScanMode -eq "Full") {
    $fullScan = Get-FullDriveInventory -Root $root -MinimumDirectoryBytes ([long]($MinimumLargeDirectoryGB * 1GB)) -MinimumFileBytes ([long]($MinimumLargeFileGB * 1GB)) -Limit $Top
    $largeDirectories = $fullScan.Directories
    $largeFiles = $fullScan.Files
} elseif ($IncludeTopLevel) {
    $topLevel = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Get-DirectoryMeasurement -Path $_.FullName } |
        Sort-Object Bytes -Descending | Select-Object -First $Top
}

$cleanupCandidates = if ($fullScan) { $fullScan.CleanupCandidates } else { @($candidates | Sort-Object Bytes -Descending | Select-Object -First $Top) }
$recycleBin = if ($fullScan) { $fullScan.CleanupCandidates | Where-Object { $_.Category -eq "Recycle Bin" } | Select-Object -First 1 } else { Get-RecycleBinMeasurement -Root $root }
if (-not $recycleBin) { $recycleBin = Get-RecycleBinMeasurement -Root $root }

$report = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString("s"); ScanMode = $ScanMode; IsAdministrator = $true; Volume = $volume
    RecycleBin = $recycleBin; RootFiles = $rootFiles
    CleanupCandidates = @($cleanupCandidates); TopLevelDirectories = @($topLevel)
    LargeDirectories = @($largeDirectories); LargeFiles = @($largeFiles); LargeUserFiles = @($largeFiles)
    ScanNotes = @(
        "All measurements are read-only logical file sizes.",
        "Errors count skipped items such as protected or locked paths; reported totals may be lower than disk usage.",
        "WinSxS reclaimable size, restore points, installed applications, and virtual disks require separate product or Windows tools."
    )
    FullScan = $fullScan
    ComponentStore = Get-ComponentStoreAnalysis
}

if ($JsonPath) {
    $parent = Split-Path -Parent $JsonPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { throw "JsonPath parent directory does not exist: $parent" }
    $report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $JsonPath -Encoding utf8
}

""; "Volume"; $volume | Format-List Drive, Root, Used, Free, Total, FreePercent | Out-String | Write-Output
"Cleanup candidates (read-only estimates)"; $report.CleanupCandidates | Format-Table Category, Size, Risk, Note, Errors, Path -AutoSize | Out-String | Write-Output
"Root files (official tools only)"; $report.RootFiles | Format-Table Size, Path -AutoSize | Out-String | Write-Output
"Recycle Bin"; $report.RecycleBin | Format-Table Size, Risk, Errors, Path -AutoSize | Out-String | Write-Output
if ($report.TopLevelDirectories.Count) { "Top-level directories"; $report.TopLevelDirectories | Format-Table Size, Files, Errors, Path -AutoSize | Out-String | Write-Output }
if ($report.LargeDirectories.Count) { "Largest directories across the drive"; $report.LargeDirectories | Format-Table Size, Category, Risk, Errors, Path -AutoSize | Out-String | Write-Output }
if ($report.LargeFiles.Count) { "Largest files across the drive"; $report.LargeFiles | Format-Table Size, Category, Risk, Path -AutoSize | Out-String | Write-Output }
if ($report.ComponentStore) { "Component Store Analysis"; $report.ComponentStore | Format-List Status, ExitCode, Output | Out-String | Write-Output }
if ($JsonPath) { "JSON report written to $JsonPath" }
