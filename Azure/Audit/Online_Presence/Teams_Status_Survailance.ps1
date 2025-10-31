<#
Poll-SpecificPresence.ps1
Polls a specific Teams presence every 60 seconds for 6 hours minutes and exports to CSV
#>

# --- CONFIG ---
$pollSeconds = 60
$durationMinutes = 360
$outCsv = "User_Presence_Log.csv"
$userId = "USER-OBJECT-ID"  # replace with your target Object ID

# --- Get your Access Token from the Graph Explorer ---
$token = "ACCESS-TOKEN-HERE" 
$headers = @{ 
    "Authorization" = "Bearer $token"; 
    "Accept" = "application/json" 
}

# Prepare CSV
if (-not (Test-Path $outCsv)) {
    "Timestamp,Availability,Activity" | Out-File -FilePath $outCsv -Encoding utf8
}

$endTime = (Get-Date).AddMinutes($durationMinutes)
Write-Host "Starting polling until $endTime every $pollSeconds seconds. Logging to $outCsv"

while ((Get-Date) -lt $endTime) {
    $now = Get-Date
    try {
        $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/communications/presences/$userId" -Headers $headers -Method Get
        $avail = $response.availability
        $act = $response.activity

        # Log CSV row
        "$($now.ToString('o')),$avail,$act" | Out-File -Append -FilePath $outCsv -Encoding utf8
        Write-Host "$($now.ToString('HH:mm:ss')) - $avail / $act"

    } catch {
        Write-Warning "Graph call failed: $($_.Exception.Message). Skipping this poll."
    }

    Start-Sleep -Seconds $pollSeconds
}

Write-Host "Polling complete. CSV saved to $outCsv"
