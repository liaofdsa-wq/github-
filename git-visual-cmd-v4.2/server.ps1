# Git Visual Helper v4.2 - local-only server with allowlisted Git operations.
# Windows PowerShell 5.1+; no arbitrary shell commands are accepted from the browser.
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port = 8765
$Base = "http://127.0.0.1:$Port"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
$script:Token = [Guid]::NewGuid().ToString('N')

function Git-Call([string]$Directory, [string[]]$ArgsList) {
    # PS 5.1's native invocation strips embedded quotes. Quote for Windows argv
    # directly and read Git's UTF-8 streams without PowerShell error formatting.
    $arguments = @('--no-pager','-c','core.quotepath=false','-C',$Directory) + $ArgsList
    $quoted = foreach ($argument in $arguments) {
        $escaped = [regex]::Replace([string]$argument, '(\\*)"', '$1$1\"')
        '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:GitExecutable
    $info.Arguments = $quoted -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = $OutputEncoding
    $info.StandardErrorEncoding = $OutputEncoding
    $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $info.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(75000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Git 操作超過 75 秒。請檢查網路與認證，再刷新狀態確認結果。'
        }
        $output = $stdout.GetAwaiter().GetResult().TrimEnd([char[]]@([char]13,[char]10))
        $errorText = $stderr.GetAwaiter().GetResult().TrimEnd([char[]]@([char]13,[char]10))
        $text = if ($output -and $errorText) { $output + "`n" + $errorText } elseif ($output) { $output } else { $errorText }
        return @{ code = $process.ExitCode; text = $text }
    } finally { $process.Dispose() }
}

function Repo-Root([string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { throw '請先貼上 Git 專案資料夾路徑。' }
    if ($Directory.IndexOf([char]0) -ge 0) { throw '資料夾路徑包含不合法字元。' }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw '找不到資料夾。請從檔案總管複製完整路徑。' }
    $full = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $root = Git-Call $full @('rev-parse','--show-toplevel')
    if ($root.code -ne 0) { throw '這個資料夾不是 Git Repository。請先 Clone 或建立 Git 專案。' }
    return (($root.text -split "`n")[0].Trim())
}

function Current-Branch([string]$Root) {
    $branch = Git-Call $Root @('symbolic-ref','--quiet','--short','HEAD')
    if ($branch.code -ne 0) { return '' }
    return $branch.text.Trim()
}

function Git-Graph([string]$Directory) {
    $root = Repo-Root $Directory
    $branch = Current-Branch $root
    $head = Git-Call $root @('rev-parse','--verify','HEAD')
    $status = Git-Call $root @('status','--porcelain=v1','--untracked-files=all')
    $remote = Git-Call $root @('remote','get-url','origin')
    $upstream = Git-Call $root @('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}')
    $counts = if ($upstream.code -eq 0) { Git-Call $root @('rev-list','--left-right','--count','HEAD...@{upstream}') } else { @{code=1;text=''} }
    $ahead = 0; $behind = 0
    if ($counts.code -eq 0 -and $counts.text -match '^\s*(\d+)\s+(\d+)') { $ahead = [int]$Matches[1]; $behind = [int]$Matches[2] }
    $branchRefs = Git-Call $root @('for-each-ref','--format=%(refname:short)%09%(objectname)%09%(refname)','refs/heads','refs/remotes')
    $log = Git-Call $root @('--no-pager','log','--all','--topo-order','--date-order','-n','90','--pretty=format:%H%x1f%P%x1f%s%x1e')
    $refs = @()
    if ($branchRefs.code -eq 0) {
        foreach ($line in ($branchRefs.text -split "`r?`n")) {
            $parts = $line.Split([char]9)
            if ($parts.Length -lt 3) { continue }
            if ($parts[2] -match '^refs/remotes/.+/HEAD$') { continue }
            $kind = if ($parts[2].StartsWith('refs/remotes/')) { 'remote' } else { 'local' }
            $refs += @{ name = $parts[0]; hash = $parts[1]; kind = $kind }
        }
    }
    $commits = @()
    if ($log.code -eq 0) {
        foreach ($record in $log.text.Split([char]30)) {
            $record = $record.Trim([char[]]@([char]13,[char]10,[char]32))
            if ([string]::IsNullOrEmpty($record)) { continue }
            $parts = $record.Split([char]31)
            if ($parts.Length -lt 3 -or $parts[0] -notmatch '^[0-9a-f]{40,64}$') { continue }
            $parents = @()
            if (-not [string]::IsNullOrWhiteSpace($parts[1])) { $parents = @($parts[1].Split(' ') | Where-Object { $_ }) }
            $commits += @{ hash = $parts[0]; parents = $parents; subject = $parts[2] }
        }
    }
    $dirtyCount = 0
    $changedFiles = @()
    if ($status.code -eq 0 -and -not [string]::IsNullOrWhiteSpace($status.text)) {
        $changedFiles = @($status.text -split "`r?`n" | Where-Object { $_ })
        $dirtyCount = $changedFiles.Count
    }
    return @{
        ok = $true; root = $root; branch = $branch
        head = if ($head.code -eq 0) { $head.text.Trim() } else { '' }
        dirty = $dirtyCount; changes = @($changedFiles | Select-Object -First 30)
        remote = if ($remote.code -eq 0) { $remote.text.Trim() } else { '' }
        upstream = if ($upstream.code -eq 0) { $upstream.text.Trim() } else { '' }
        ahead = $ahead; behind = $behind
        refs = @($refs); commits = @($commits)
    }
}

function Valid-Branch([string]$Root, [string]$Name) {
    if ($Name.Length -gt 100 -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
        throw '分支名稱只能使用英文字母、數字、-、_、.、/，並以字母或數字開頭。'
    }
    $res = Git-Call $Root @('check-ref-format','--branch',$Name)
    if ($res.code -ne 0) { throw '分支名稱不符合 Git 規範。' }
}

function Ensure-Clean([string]$Root) {
    $s = Git-Call $Root @('status','--porcelain=v1','--untracked-files=all')
    if ($s.code -ne 0) { throw "無法讀取目前狀態：$($s.text)" }
    if (-not [string]::IsNullOrWhiteSpace($s.text)) { throw '工作區仍有未提交的檔案。請先 Commit 或處理修改，避免切換／拉取造成混亂。' }
}

function Require-Success([hashtable]$Result, [string]$Description) {
    if ($Result.code -ne 0) {
        $details = if ($Result.text.Length -gt 3800) { $Result.text.Substring(0,3800) } else { $Result.text }
        throw "$Description 失敗（Exit code $($Result.code)）：`n$details"
    }
    return $Result
}

function Git-Action([hashtable]$Form) {
    $root = Repo-Root ([string]$Form['path'])
    $operation = [string]$Form['op']
    $current = Current-Branch $root
    $argsForDisplay = ''
    switch ($operation) {
        'branch' {
            Ensure-Clean $root
            $name = ([string]$Form['branch']).Trim()
            Valid-Branch $root $name
            $res = Git-Call $root @('switch','-c',$name)
            $argsForDisplay = 'git switch -c <新分支名稱>'
            break
        }
        'switch' {
            Ensure-Clean $root
            $name = ([string]$Form['branch']).Trim()
            Valid-Branch $root $name
            $existing = Git-Call $root @('show-ref','--verify','--quiet',"refs/heads/$name")
            if ($existing.code -ne 0) { throw '本機沒有這個分支，請先建立或 Fetch。' }
            $res = Git-Call $root @('switch',$name)
            $argsForDisplay = 'git switch <既有分支>'
            break
        }
        'commit' {
            $message = ([string]$Form['message']).Trim()
            if ($message.Length -lt 1 -or $message.Length -gt 200 -or $message -match "[`r`n`0]") { throw 'Commit 訊息請輸入 1～200 字，不能換行。' }
            $state = Git-Call $root @('status','--porcelain=v1','--untracked-files=all')
            if ($state.code -ne 0 -or [string]::IsNullOrWhiteSpace($state.text)) { throw '沒有可提交的修改。請先在資料夾新增或編輯檔案。' }
            if (($current -eq 'main' -or $current -eq 'master') -and $Form['allowMain'] -ne 'yes') { throw '你目前在主分支，請先建立個人分支；若確定要在 main Commit，需額外確認。' }
            Require-Success (Git-Call $root @('add','-A')) 'Git add' | Out-Null
            $preview = Git-Call $root @('--no-pager','diff','--cached','--name-status')
            if ([string]::IsNullOrWhiteSpace($preview.text)) { throw '暫存區沒有可提交的檔案。' }
            $res = Git-Call $root @('commit','-m',$message)
            $argsForDisplay = 'git add -A && git commit -m <訊息>'
            break
        }
        'push' {
            if (-not $current) { throw '目前不在正常分支（detached HEAD），請先切換分支。' }
            if (($current -eq 'main' -or $current -eq 'master') -and $Form['allowMain'] -ne 'yes') { throw '為避免誤推主分支，請先建立個人分支；若要 Push main，需額外確認。' }
            $rem = Git-Call $root @('remote','get-url','origin')
            if ($rem.code -ne 0) { throw '尚未設定 origin 遠端儲存庫，請先連線到 GitHub。' }
            $res = Git-Call $root @('push','-u','origin','HEAD')
            $argsForDisplay = 'git push -u origin HEAD'
            break
        }
        'pull' {
            Ensure-Clean $root
            $res = Git-Call $root @('pull','--ff-only')
            $argsForDisplay = 'git pull --ff-only'
            break
        }
        'fetch' {
            $res = Git-Call $root @('fetch','--all','--prune')
            $argsForDisplay = 'git fetch --all --prune'
            break
        }
        default { throw '不支援的操作。只允許 branch、switch、commit、push、pull、fetch。' }
    }
    Require-Success $res $operation | Out-Null
    return @{ ok=$true; operation=$operation; command=$argsForDisplay; output=$res.text; graph=(Git-Graph $root) }
}

function Decode-Form([string]$Body) {
    $result = @{}
    if ($Body.Length -gt 16000) { throw '請求過大。' }
    foreach ($pair in $Body.Split('&')) {
        if (-not $pair) { continue }
        # PowerShell 5.1 interprets .Split(@('='),2) as StringSplitOptions=2.
        # Use IndexOf / Substring so only the first '=' separates key and value.
        $separator = $pair.IndexOf('=')
        if ($separator -ge 0) {
            $encodedKey = $pair.Substring(0, $separator)
            $encodedValue = $pair.Substring($separator + 1)
        } else {
            $encodedKey = $pair
            $encodedValue = ''
        }
        $key = [Uri]::UnescapeDataString($encodedKey.Replace('+',' '))
        if ($key -notin @('path','op','branch','message','allowMain')) { continue }
        $result[$key] = [Uri]::UnescapeDataString($encodedValue.Replace('+',' '))
    }
    return $result
}

function Send-Http([System.IO.Stream]$Stream, [int]$Code, [string]$Mime, [string]$Content) {
    $body = $script:Utf8.GetBytes($Content)
    $status = switch ($Code) { 200 {'OK'} 400 {'Bad Request'} 403 {'Forbidden'} 404 {'Not Found'} 405 {'Method Not Allowed'} default {'Internal Server Error'} }
    $head = "HTTP/1.1 $Code $status`r`nContent-Type: $Mime`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nX-Frame-Options: DENY`r`nConnection: close`r`n`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes,0,$headBytes.Length)
    $Stream.Write($body,0,$body.Length)
    $Stream.Flush()
}

$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $gitCmd) { $gitCmd = Get-Command git -ErrorAction SilentlyContinue }
if (-not $gitCmd) {
    Write-Host '[ERROR] Git is not installed or not on PATH. Install Git for Windows first.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}
$script:GitExecutable = $gitCmd.Source
$indexPath = Join-Path $ScriptDir 'index.html'
if (-not (Test-Path -LiteralPath $indexPath)) { Write-Host '[ERROR] index.html is missing.'; exit 1 }
$server = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try { $server.Start() }
catch {
    Write-Host "[ERROR] Port $Port is already in use. Close the other helper window first." -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}
Write-Host 'Git Helper v4.2 is running locally. Operations are restricted to known Git commands.' -ForegroundColor Green
Write-Host "URL: $Base"
Write-Host 'Keep this window open. Press Ctrl+C to stop.'
try { Start-Process $Base | Out-Null } catch { Write-Host "Open the URL manually: $Base" }

try {
    while ($true) {
        $client = $null
        try {
            $client = $server.AcceptTcpClient()
            # Browsers can preconnect without sending a request. Do not let an
            # idle speculative socket stall this single-threaded local server.
            $client.ReceiveTimeout = 2000
            $client.SendTimeout = 15000
            $stream = $client.GetStream()
            # Browser sends application/x-www-form-urlencoded, which contains only ASCII bytes.
            $reader = [System.IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
            $request = $reader.ReadLine()
            if ($request -notmatch '^(GET|POST)\s+(\S+)\s+HTTP/1\.[01]$') {
                Send-Http $stream 405 'text/plain; charset=utf-8' 'Method not allowed.'
                continue
            }
            $method = $Matches[1]
            $target = $Matches[2]
            $headers = @{}
            for ($i=0; $i -lt 80; $i++) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line -eq '') { break }
                $colon = $line.IndexOf(':')
                if ($colon -gt 0) { $headers[$line.Substring(0,$colon).Trim().ToLowerInvariant()] = $line.Substring($colon+1).Trim() }
            }
            if ($headers['host'] -ne "127.0.0.1:$Port") {
                Send-Http $stream 403 'text/plain; charset=utf-8' 'Only requests to 127.0.0.1 are allowed.'
                continue
            }
            if ($method -eq 'GET' -and ($target -eq '/' -or $target -eq '/index.html')) {
                $html = (Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8).Replace('__LOCAL_API_TOKEN__',$script:Token)
                Send-Http $stream 200 'text/html; charset=utf-8' $html
            }
            elseif ($method -eq 'GET' -and $target -match '^/api/graph\?path=([^&]*)$') {
                try {
                    $path = [Uri]::UnescapeDataString($Matches[1])
                    $data = Git-Graph $path
                    Send-Http $stream 200 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $data -Depth 12 -Compress)
                } catch {
                    Send-Http $stream 400 'application/json; charset=utf-8' (ConvertTo-Json -InputObject @{ok=$false;error=$_.Exception.Message} -Compress)
                }
            }
            elseif ($method -eq 'POST' -and $target -eq '/api/action') {
                try {
                    $client.ReceiveTimeout = 15000
                    $length = 0
                    if (-not [int]::TryParse([string]$headers['content-length'],[ref]$length) -or $length -lt 0 -or $length -gt 16000) { throw '請求長度無效。' }
                    $buffer = New-Object char[] $length
                    $readTotal = 0
                    while ($readTotal -lt $length) {
                        $got = $reader.Read($buffer,$readTotal,$length-$readTotal)
                        if ($got -le 0) { throw '請求資料不完整。' }
                        $readTotal += $got
                    }
                    # Consume the bounded body before rejecting, otherwise closing TCP
                    # with unread bytes can reset the connection and lose the JSON error.
                    # Anti-CSRF: the token appears only in HTML from this local origin.
                    if ($headers['x-git-helper-token'] -ne $script:Token) { throw '拒絕未授權的本機操作請求。請重新開啟工具。' }
                    if ($headers.ContainsKey('origin') -and $headers['origin'] -ne $Base) { throw '拒絕其他網站送來的請求。' }
                    if ($headers['content-type'] -notmatch '^application/x-www-form-urlencoded(?:;|$)') { throw '不支援的請求格式。' }
                    $form = Decode-Form (-join $buffer)
                    $result = Git-Action $form
                    Send-Http $stream 200 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $result -Depth 12 -Compress)
                } catch {
                    Send-Http $stream 400 'application/json; charset=utf-8' (ConvertTo-Json -InputObject @{ok=$false;error=$_.Exception.Message} -Compress)
                }
            }
            elseif ($target -eq '/favicon.ico') { Send-Http $stream 404 'text/plain; charset=utf-8' 'Not found' }
            else { Send-Http $stream 404 'text/plain; charset=utf-8' 'Not found' }
        }
        catch { Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        finally { if ($null -ne $client) { $client.Close() } }
    }
}
finally { $server.Stop() }
