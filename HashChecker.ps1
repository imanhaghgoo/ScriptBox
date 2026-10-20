# File Hash Verification
# Asks for file path, hash, and algorithm number, then compares.

$ErrorActionPreference = "Stop"
$ExitCode = 0

$Algorithms = @{
    '1' = @{ Name = 'MD5';    Length = 32  }
    '2' = @{ Name = 'SHA1';   Length = 40  }
    '3' = @{ Name = 'SHA256'; Length = 64  }
    '4' = @{ Name = 'SHA384'; Length = 96  }
    '5' = @{ Name = 'SHA512'; Length = 128 }
}

try {
    $FilePath = (Read-Host "Enter the complete file path").Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "File not found: $FilePath"
    }

    $OfficialHash = ((Read-Host "Enter the official hash") -replace '[\s:\-]', '').ToUpper()

    Write-Host "`n[1] MD5   [2] SHA1   [3] SHA256   [4] SHA384   [5] SHA512"
    $Choice = (Read-Host "Select algorithm number").Trim()
    if (-not $Algorithms.ContainsKey($Choice)) {
        throw "Invalid choice. Enter a number from 1 to 5."
    }

    $Algorithm = $Algorithms[$Choice].Name
    $Length    = $Algorithms[$Choice].Length

    if ($OfficialHash -notmatch "^[A-F0-9]{$Length}$") {
        throw "Invalid $Algorithm hash. It must be exactly $Length hexadecimal characters."
    }

    Write-Host "`nCalculating $Algorithm hash..."
    $Result     = Get-FileHash -LiteralPath $FilePath -Algorithm $Algorithm
    $ActualHash = $Result.Hash

    Write-Host "`nFile:         $($Result.Path)"
    Write-Host "Algorithm:    $Algorithm"
    Write-Host "Official:     $OfficialHash"
    Write-Host "Calculated:   $ActualHash"

    if ($ActualHash -eq $OfficialHash) {
        Write-Host "`n[PASS] Hash matches." -ForegroundColor Green
    }
    else {
        Write-Host "`n[FAIL] Hash mismatch! Do not trust this file until investigated." -ForegroundColor Red
        $ExitCode = 1
    }
}
catch {
    Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    $ExitCode = 2
}

exit $ExitCode
