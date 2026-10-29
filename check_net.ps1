$reportPath = "$env:USERPROFILE\network_report.txt"
$logPath = "$env:USERPROFILE\network_history.log"
$targets = @(
    @{ Name = "YouTube";      Url = "https://www.youtube.com"; Host = "youtube.com"; Port = 443 },
    @{ Name = "Discord";      Url = "https://discord.com";   Host = "discord.com"; Port = 443 },
    @{ Name = "Google (DNS)"; Url = "https://dns.google";    Host = "dns.google";  Port = 443 },
    @{ Name = "Yandex";       Url = "https://yandex.ru";     Host = "ya.ru";       Port = 443 }
)
$timeoutSec = 5

$lines = @()
$isOk = $true
$verdict = ""
$advice = ""
$pingSummary = ""
$speedText = "N/A"
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$lines += "=== Отчет о подключении ($now) ==="

# 1. DNS
try {
    $null = Resolve-DnsName -Name "www.google.com" -ErrorAction Stop
    $lines += "DNS: OK"
} catch {
    $lines += "DNS: ERROR"
    $isOk = $false
}

# 2. IP
try {
    $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5 -ErrorAction Stop)
    $lines += "IP: $myIp"
} catch {
    $lines += "IP: ERROR"
}

# 3. Шлюз (роутер)
try {
    $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Select-Object -First 1).NextHop
    if ($gateway -and $gateway -ne "0.0.0.0") {
        $lines += "Gateway (Router): $gateway"
    }
} catch {}

# 4. Глобальный Ping
try {
    $ping = Test-Connection -ComputerName "8.8.8.8" -Count 2 -Quiet -ErrorAction Stop
    if ($ping) { $lines += "Ping 8.8.8.8: OK" } else { $lines += "Ping 8.8.8.8: ERROR"; $isOk = $false }
} catch {
    $lines += "Ping 8.8.8.8: ERROR"
    $isOk = $false
}

# 5. Сайты
$failedSites = @()
$hasDpi = $false
foreach ($t in $targets) {
    $httpStatus = "ERROR"
    $tcpStatus = "ERROR"
    $pingMs = "N/A"
    $diag = ""

    try {
        $resp = Invoke-WebRequest -Uri $t.Url -Method Head -TimeoutSec $timeoutSec -UseBasicParsing -ErrorAction Stop
        $httpStatus = "OK (HTTP $($resp.StatusCode))"
    } catch {
        $err = $_
        if ($err.Exception.Response) {
            $codeNum = [int]$err.Exception.Response.StatusCode
            $httpStatus = "OK (HTTP $codeNum)"
        }
    }

    try {
        $tcp = Test-NetConnection -ComputerName $t.Url.Replace("https://","").Replace("http://","") -Port $t.Port -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($tcp) { $tcpStatus = "OK" }
    } catch {}

    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $reply = $p.Send($t.Host, 1000)
        if ($reply.Status -eq 'Success') { 
            $pingMs = "$($reply.RoundtripTime) ms"
        }
    } catch {}

    if ($httpStatus -eq "ERROR") {
        if ($tcpStatus -eq "OK") { $diag = " [DPI/SNI]"; $hasDpi = $true } else { $diag = " [IP/DNS]" }
        $isOk = $false
        $failedSites += $t.Name
    } else {
        if ($pingMs -ne "N/A") { $pingSummary += "$($t.Name): $pingMs; " }
    }
    
    $lines += "$($t.Name) -> HTTP: $httpStatus | TCP:$($t.Port): $tcpStatus | Ping: $pingMs$diag"
}

# 6. Zapret
$zapret = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match "winws|zapret|goodbyedpi"
}
if ($zapret) {
    $names = ($zapret | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
    $lines += "Zapret: RUNNING ($names)"
} else {
    $lines += "Zapret: NOT FOUND"
    $isOk = $false
}

# 7. Speedtest
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-WebRequest -Uri "https://speed.cloudflare.com/__down?bytes=1000000" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    $sw.Stop()
    $mbps = [math]::Round((8 / $sw.Elapsed.TotalSeconds), 1)
    $speedText = "$mbps Mbps"
    $lines += "Speed approx: ~$speedText"
} catch {
    $lines += "Speed approx: ERROR"
}

# Вердикт и Советы
if (-not $isOk) {
    if ($failedSites.Count -gt 0) {
        $verdict = "Проблема с доступом к: " + ($failedSites -join ", ")
        if ($hasDpi) { 
            $advice = "DPI активен! Zapret не справляется. СОВЕТ: Откройте папку с Zapret, запустите service.bat и попробуйте сменить стратегию (например, на ALT, ALT2 или ALT3). Также можно обновить списки доменов." 
        }
    } elseif ($lines -match "Zapret: NOT FOUND") {
        $verdict = "Zapret не запущен!"
        $advice = "СОВЕТ: Запустите service.bat от имени Администратора и выберите 'Install Service', чтобы Zapret запускался автоматически."
    } else {
        $verdict = "Есть ошибки при проверке сети."
    }
    
    $lines += "`n[ВЕРДИКТ] $verdict"
    if ($advice -ne "") { $lines += "[СОВЕТ] $advice" }
    
    [Console]::Beep(500, 500)
} else {
    # Если всё ок, добавляем совет на будущее
    $lines += "`n[СТАТУС] Все системы работают штатно."
    $lines += "[СОВЕТ] Если YouTube начнет тупить, проверьте файл list-general.txt в папке Zapret — возможно, пора обновить списки."
}

$nl = [Environment]::NewLine
$reportText = $lines -join $nl
$reportText | Out-File -FilePath $reportPath -Encoding UTF8

# Логирование
$shortLog = "$now | " + $(if ($isOk) { "OK (Speed: $speedText)" } else { "ERROR: $verdict" })
$shortLog | Out-File -FilePath $logPath -Append -Encoding UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$isDarkMode = $false
try {
    $reg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction Stop
    if ($reg.AppsUseLightTheme -eq 0) { $isDarkMode = $true }
} catch {}

if ($isOk) {
    # Уведомление
    $notification = New-Object System.Windows.Forms.NotifyIcon
    $notification.Icon = [System.Drawing.SystemIcons]::Information
    $notification.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $notification.BalloonTipTitle = "Сеть в порядке (Скорость: $speedText)"
    
    if ($pingSummary.EndsWith("; ")) { $pingSummary = $pingSummary.Substring(0, $pingSummary.Length - 2) }
    $notification.BalloonTipText = $pingSummary
    
    $notification.Visible = $true
    $notification.ShowBalloonTip(7000)
    Start-Sleep -Seconds 7
    $notification.Dispose()
} else {
    # Окно с ошибками
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ОШИБКА ПОДКЛЮЧЕНИЯ"
    $form.Size = New-Object System.Drawing.Size(700, 580) # Чуть увеличили под советы
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    if ($isDarkMode) {
        $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $textColor = [System.Drawing.Color]::White
        $btnColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    } else {
        $form.BackColor = [System.Drawing.Color]::White
        $textColor = [System.Drawing.Color]::Black
        $btnColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    }

    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.Size = New-Object System.Drawing.Size(680, 50)
    $headerLabel.Location = New-Object System.Drawing.Point(10, 10)
    $headerLabel.TextAlign = "MiddleCenter"
    $headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $headerLabel.Text = "❌ ОБНАРУЖЕНЫ ОШИБКИ"
    $headerLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80)
    $form.Controls.Add($headerLabel)

    $detailsLabel = New-Object System.Windows.Forms.Label
    $detailsLabel.Size = New-Object System.Drawing.Size(660, 330)
    $detailsLabel.Location = New-Object System.Drawing.Point(15, 60)
    $detailsLabel.Font = New-Object System.Drawing.Font("Consolas", 10)
    $detailsLabel.ForeColor = $textColor
    $detailsLabel.Text = $reportText
    $form.Controls.Add($detailsLabel)

    $verdictLabel = New-Object System.Windows.Forms.Label
    $verdictLabel.Size = New-Object System.Drawing.Size(660, 80)
    $verdictLabel.Location = New-Object System.Drawing.Point(15, 400)
    $verdictLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $verdictLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
    
    $boxText = "ПРИЧИНА: $verdict"
    if ($advice -ne "") { $boxText += "`n`n$advice" }
    $verdictLabel.Text = $boxText
    $form.Controls.Add($verdictLabel)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = "Закрыть"
    $button.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $button.Size = New-Object System.Drawing.Size(120, 35)
    $button.Location = New-Object System.Drawing.Point(280, 490)
    $button.BackColor = $btnColor
    $button.ForeColor = $textColor
    $button.FlatStyle = 'Flat'
    $button.Add_Click({ $form.Close() })
    $form.Controls.Add($button)
    $form.AcceptButton = $button

    $form.ShowDialog() | Out-Null
}