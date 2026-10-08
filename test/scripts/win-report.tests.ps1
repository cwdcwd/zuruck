# Tests Send-ZuruckReport (scripts/win/zuruck.psm1) on PowerShell 7 for Linux.
# DPAPI and the HTTP call are replaced inside the module scope; run via run-windows-report.sh.
$ErrorActionPreference = 'Stop'
$env:ZURUCK_HOME = (New-Item -ItemType Directory -Path /tmp/zh -Force).FullName
New-Item -ItemType Directory /tmp/zh/secrets -Force | Out-Null
Set-Content /tmp/zh/config.psd1 "@{ ClientName = 'fenster02'; Repository = 's3:x/b/fenster02'; Region = 'us-west-2'; AwsAccessKeyId = 'AKIA'; BackupPaths = @('C:\x') }"
Set-Content /tmp/stub-status.ps1 'param([switch]$Json) ''{"verdict":"fresh","threshold_hours":48}'''
$m = Import-Module /w/zuruck.psm1 -Force -PassThru
& $m {
  function script:Get-ZuruckEntropy { ,[byte[]](1,2,3) }
  function script:Unprotect-ZuruckSecret { param($InFile, $Entropy) 'tok-xyz' }
  function script:Invoke-RestMethod { param($Uri,$Method,$Body,$ContentType,$Headers,$TimeoutSec,[switch]$UseBasicParsing)
    $global:sent = @{ Uri = $Uri; Method = $Method; Body = $Body; Auth = $Headers.Authorization } }
}
$script:fail = 0
function check($d, $c) { if ($c) { "ok   - $d" } else { "FAIL - $d"; $script:fail++ } }

Send-ZuruckReport -ExitCode 0 -StatusScript /tmp/stub-status.ps1
check 'no-op without ingest.psd1' (-not (Get-Variable sent -Scope Global -ErrorAction SilentlyContinue))

Set-Content /tmp/zh/ingest.psd1 "@{ Url = 'http://collector.lan:8790/api/ingest' }"
Send-ZuruckReport -ExitCode 3 -StatusScript /tmp/stub-status.ps1
$b = $global:sent.Body | ConvertFrom-Json
check 'posts to configured url' ($global:sent.Uri -eq 'http://collector.lan:8790/api/ingest' -and $global:sent.Method -eq 'Post')
check 'bearer header'           ($global:sent.Auth -eq 'Bearer tok-xyz')
check 'status fields kept'      ($b.verdict -eq 'fresh' -and $b.threshold_hours -eq 48)
check 'report envelope'         ($b.report.client -eq 'fenster02' -and $b.report.platform -eq 'windows' -and $b.report.exit_code -eq 3 -and $b.report.schema -eq 1)

& $m { function script:Invoke-RestMethod { throw 'connection refused' } }
$w = Send-ZuruckReport -ExitCode 0 -StatusScript /tmp/stub-status.ps1 3>&1
check 'collector down only warns' ("$w" -match 'ingest report failed')
"failed: $script:fail"
exit $script:fail
