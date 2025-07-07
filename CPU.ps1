# ============================================
# CONFIGURATION PARAMETERS
# ============================================

# CPU threshold
$threshold = 80

# SMTP (Email) configuration - update these values as needed
$SmtpServer = "smtp.example.com"
$SmtpPort   = 25
$EmailFrom  = "alert@example.com"
$EmailTo    = "manager@example.com"
$Subject    = "High CPU Utilization Alert"

# Sampling configuration: 1 sample per minute for 60 minutes (1 hour)
$sampleInterval = 60    # seconds between samples
$maxSamples     = 60    # total number of samples (1 hour)

# List of remote servers (VMs) to monitor
$servers = @("VM1", "VM2", "VM3")

# ============================================
# CREDENTIALS
# ============================================
# If you already have credentials, you can create a PSCredential object.
# Example using plain text (for demonstration only -- use secure storage in production):
$username = "DOMAIN\YourUsername"
$password = ConvertTo-SecureString "YourPassword" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($username, $password)

# Alternatively, to prompt for credentials interactively:
# $cred = Get-Credential

# ============================================
# FUNCTION: Monitor a Single Server
# ============================================
function Monitor-ServerCPU {
    param (
        [string]$server,
        [int]$sampleInterval,
        [int]$maxSamples,
        [int]$threshold,
        [System.Management.Automation.PSCredential]$cred
    )
    
    # Prepare result object
    $result = [PSCustomObject]@{
        Server     = $server
        AverageCpu = 0
        InstantCpu = 0
        Alert      = $false
        Details    = ""
    }
    
    try {
        # Create a persistent session on the remote server using the provided credentials
        $session = New-PSSession -ComputerName $server -Credential $cred
        
        $cpuReadings = @()
        
        Write-Output "[$server] Starting CPU sampling for $maxSamples sample(s)..."
        
        for ($i = 0; $i -lt $maxSamples; $i++) {
            # Execute Get-Counter remotely using the persistent session
            $counterData = Invoke-Command -Session $session -ScriptBlock {
                Get-Counter "\Processor(_Total)\% Processor Time"
            }
            # Extract the value for the _Total instance
            $value = ($counterData.CounterSamples | Where-Object { $_.InstanceName -eq "_Total" }).CookedValue
            $cpuReadings += $value
            
            Write-Output "[$server] Sample $($i+1): $([math]::Round($value,2))%"
            
            # Wait for the specified interval before the next sample (except after the last sample)
            if ($i -lt ($maxSamples - 1)) {
                Start-Sleep -Seconds $sampleInterval
            }
        }
        
        # Calculate the average CPU utilization over the sampling period
        $avgCpu = ($cpuReadings | Measure-Object -Average).Average
        $result.AverageCpu = [math]::Round($avgCpu,2)
        
        Write-Output "[$server] Average CPU over last hour: $($result.AverageCpu)%"
        
        # Get the instantaneous CPU usage via WMI from the remote server
        $instantCpu = Invoke-Command -Session $session -ScriptBlock {
            (Get-WmiObject -Class Win32_Processor).LoadPercentage
        }
        $result.InstantCpu = $instantCpu
        Write-Output "[$server] Instantaneous CPU: $instantCpu%"
        
        # Evaluate against the threshold
        if (($avgCpu -gt $threshold) -or ($instantCpu -gt $threshold)) {
            $result.Alert = $true
            $result.Details = "Average CPU: $($result.AverageCpu)% | Instant CPU: $instantCpu%"
        }
        
        # Clean up the remote session
        Remove-PSSession -Session $session
    }
    catch {
        $result.Alert = $true
        $result.Details = "Error: $($_.Exception.Message)"
        Write-Output "[$server] Error encountered: $($_.Exception.Message)"
    }
    
    return $result
}

# ============================================
# MAIN SCRIPT: Monitor All Servers Concurrently
# ============================================
Write-Output "Starting CPU monitoring on remote servers..."

$jobs = @()

foreach ($server in $servers) {
    Write-Output "Starting monitoring job for server: $server"
    # Start a background job for each server
    $job = Start-Job -ScriptBlock {
        param($server, $sampleInterval, $maxSamples, $threshold, $cred)
        # Call the function to monitor this server's CPU usage
        Monitor-ServerCPU -server $server -sampleInterval $sampleInterval -maxSamples $maxSamples -threshold $threshold -cred $cred
    } -ArgumentList $server, $sampleInterval, $maxSamples, $threshold, $cred

    $jobs += $job
}

# Wait for all background jobs to finish
Write-Output "Waiting for all monitoring jobs to complete..."
Wait-Job -Job $jobs

# Collect results from all jobs and remove the jobs
$results = $jobs | ForEach-Object {
    $res = Receive-Job -Job $_
    Remove-Job -Job $_
    $res
}

# ============================================
# Aggregate Results and Send Email Alert if Needed
# ============================================
$alertMessages = @()

foreach ($res in $results) {
    if ($res.Alert -eq $true) {
        $alertMessages += "Server: $($res.Server) - $($res.Details)"
    }
}

if ($alertMessages.Count -gt 0) {
    $Body = "High CPU utilization detected on the following servers:`n" + ($alertMessages -join "`n")
    Write-Output "Alert triggered. Sending email..."
    
    Send-MailMessage -From $EmailFrom `
                     -To $EmailTo `
                     -Subject $Subject `
                     -Body $Body `
                     -SmtpServer $SmtpServer `
                     -Port $SmtpPort
}
else {
    Write-Output "All servers are operating within normal parameters. No alert sent."
}
