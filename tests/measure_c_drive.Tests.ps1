$scriptPath = Join-Path $PSScriptRoot '..\scripts\measure_c_drive.ps1'
. $scriptPath -LibraryMode

Describe 'measure_c_drive helper functions' {
    It 'keeps system-directory classification within directory boundaries' {
        (Get-PathClassification -Path 'C:\Windows\System32' -Root 'C:\').Risk | Should Be 'official-tool-only'
        (Get-PathClassification -Path 'C:\WindowsBackup' -Root 'C:\').Risk | Should Be 'review-first'
    }

    It 'classifies a user temporary directory as safe with approval' {
        (Get-PathClassification -Path 'C:\Users\example\AppData\Local\Temp' -Root 'C:\').Risk | Should Be 'safe-with-approval'
    }

    It 'returns zero skipped reparse points for a missing directory' {
        $measurement = Get-DirectoryMeasurement -Path (Join-Path $TestDrive 'missing')

        $measurement.Exists | Should Be $false
        $measurement.SkippedReparsePoints | Should Be 0
    }

    It 'builds elevated child arguments without recursively requesting elevation' {
        $arguments = Get-ElevatedScanArguments -ScriptPath 'C:\Program Files\skill\measure_c_drive.ps1' -ReportPath 'C:\Users\example\AppData\Local\Temp\report.json'

        ($arguments -contains '-JsonPath') | Should Be $true
        ($arguments -contains '"C:\Program Files\skill\measure_c_drive.ps1"') | Should Be $true
        ($arguments -contains '"C:\Users\example\AppData\Local\Temp\report.json"') | Should Be $true
        ($arguments -contains '-ElevateIfNeeded') | Should Be $false
    }

    It 'records full-drive inventory and classifies Windows temporary data' {
        $root = Join-Path $TestDrive 'drive'
        $temp = Join-Path $root 'Windows\Temp'
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $temp 'cache.bin'), [byte[]](1..16))

        $inventory = Get-FullDriveInventory -Root $root -MinimumDirectoryBytes 1 -MinimumFileBytes 1 -Limit 10

        $inventory.ScannedFiles | Should Be 1
        ($inventory.CleanupCandidates | Where-Object Path -eq $temp).Risk | Should Be 'safe-with-approval'
    }
}
