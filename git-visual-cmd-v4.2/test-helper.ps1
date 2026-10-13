# Run with Windows PowerShell 5.1. All repositories are disposable local fixtures.
param([string]$BaseUri = '')
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'server.ps1') -Raw -Encoding UTF8
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:GitExecutable = (Get-Command git.exe).Source
$fixture = Join-Path $PSScriptRoot ('測試 空白 ' + [Guid]::NewGuid().ToString('N'))
$remoteFixture = $fixture + '-remote.git'
$peerFixture = $fixture + '-peer'
$script:Failures = @()
$script:Passed = 0
function Check($Name, [scriptblock]$Test) {
    try { & $Test; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failures += $Name; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Run-Git([string[]]$Arguments) { Require-Success (Git-Call $fixture $Arguments) 'fixture git' | Out-Null }
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    Run-Git @('init','-b','main')
    Run-Git @('config','user.name','Helper Test')
    Run-Git @('config','user.email','helper-test@example.invalid')
    Check 'empty repository graph' {
        $g = Git-Graph $fixture
        Assert ($g.branch -eq 'main' -and $g.commits.Count -eq 0) 'empty graph is invalid'
    }
    Check 'create branch before first commit' {
        $r = Git-Action @{path=$fixture;op='branch';branch='feature/test'}
        Assert ($r.graph.branch -eq 'feature/test') 'branch was not switched'
    }
    [IO.File]::WriteAllText((Join-Path $fixture '中文檔案.txt'), '第一版', $OutputEncoding)
    Check 'commit with Chinese and embedded quotes' {
        $message = '修正 "中文" & 100% 完成'
        $r = Git-Action @{path=$fixture;op='commit';message=$message}
        Assert ($r.graph.commits[0].subject -ceq $message) ('message changed: ' + $r.graph.commits[0].subject)
        Assert ($r.graph.dirty -eq 0) 'commit did not clean worktree'
    }
    Check 'graph includes detached HEAD commit' {
        Run-Git @('switch','--detach')
        [IO.File]::WriteAllText((Join-Path $fixture '中文檔案.txt'), '第二版', $OutputEncoding)
        Run-Git @('add','-A')
        Run-Git @('commit','-m','Detached commit')
        $g = Git-Graph $fixture
        Assert ($g.commits.hash -contains $g.head) 'HEAD is missing from graph'
        Run-Git @('switch','feature/test')
    }
    Check 'status preserves porcelain leading spaces' {
        [IO.File]::WriteAllText((Join-Path $fixture '中文檔案.txt'), '未提交', $OutputEncoding)
        $g = Git-Graph $fixture
        Assert ($g.changes[0].StartsWith(' M ')) ('wrong status: ' + $g.changes[0])
    }
    Check 'dirty worktree blocks branch switching' {
        try { Git-Action @{path=$fixture;op='branch';branch='blocked'} | Out-Null; throw 'operation was accepted' }
        catch { Assert ($_.Exception.Message -match '未提交') 'expected dirty-worktree rejection' }
    }
    Check 'form decode preserves equals plus and UTF-8' {
        $f = Decode-Form 'message=%E4%B8%AD%E6%96%87%2B=a+b&op=commit'
        Assert ($f.message -ceq '中文+=a b') 'form decoding changed text'
    }
    if ($BaseUri) {
        $page = Invoke-WebRequest -Uri "$BaseUri/" -UseBasicParsing -TimeoutSec 30
        $token = [regex]::Match($page.Content, "X-Git-Helper-Token':'([a-f0-9]{32})'").Groups[1].Value
        function Http-Graph {
            Invoke-RestMethod -Uri ($BaseUri + '/api/graph?path=' + [Uri]::EscapeDataString($fixture)) -TimeoutSec 30
        }
        function Http-Action([hashtable]$Form) {
            $Form.path = $fixture
            $body = ($Form.GetEnumerator() | ForEach-Object { [Uri]::EscapeDataString($_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
            Invoke-RestMethod -Uri "$BaseUri/api/action" -Method Post -Headers @{'X-Git-Helper-Token'=$token;Origin=$BaseUri} -ContentType 'application/x-www-form-urlencoded' -Body $body -TimeoutSec 90
        }
        Check 'HTTP HTML includes live token' { Assert ($token.Length -eq 32 -and $page.Content.Contains('Git 視覺操作室')) 'HTML or token is invalid' }
        Check 'HTTP idle browser preconnect does not stall service' {
            $uri = [Uri]$BaseUri
            $idle = New-Object Net.Sockets.TcpClient
            try {
                $idle.Connect($uri.Host,$uri.Port)
                $timer = [Diagnostics.Stopwatch]::StartNew()
                $response = Invoke-WebRequest -Uri "$BaseUri/" -UseBasicParsing -TimeoutSec 8
                Assert ($response.StatusCode -eq 200 -and $timer.Elapsed.TotalSeconds -lt 8) 'idle socket stalled request'
            } finally { $idle.Close() }
        }
        Check 'HTTP invalid path returns readable JSON error' {
            try { Invoke-RestMethod -Uri ($BaseUri + '/api/graph?path=' + [Uri]::EscapeDataString($fixture + '-missing')) -TimeoutSec 30 | Out-Null; throw 'invalid path accepted' }
            catch { Assert ($_.Exception.Response.StatusCode.value__ -eq 400 -and $_.ErrorDetails.Message -match '找不到資料夾') 'expected path error JSON' }
        }
        Check 'HTTP graph supports Chinese paths' {
            $g = Http-Graph
            Assert ($g.ok -and $g.root -eq $fixture.Replace('\','/')) 'HTTP graph path mismatch'
        }
        Check 'HTTP rejects unauthorized operations' {
            try { Invoke-RestMethod -Uri "$BaseUri/api/action" -Method Post -Headers @{'X-Git-Helper-Token'='invalid'} -ContentType 'application/x-www-form-urlencoded' -Body 'op=fetch' -TimeoutSec 30 | Out-Null; throw 'request accepted' }
            catch { Assert ($_.Exception.Response.StatusCode.value__ -eq 400) ('expected HTTP 400: ' + $_.Exception.Message) }
        }
        Run-Git @('restore','中文檔案.txt')
        Check 'HTTP creates branch' {
            $r = Http-Action @{op='branch';branch='feature/http'}
            Assert ($r.ok -and $r.graph.branch -eq 'feature/http') 'branch failed'
        }
        [IO.File]::WriteAllText((Join-Path $fixture 'HTTP中文.txt'), 'HTTP 修改', $OutputEncoding)
        Check 'HTTP commits exact Unicode message' {
            $message = 'HTTP "中文" & 100% ! 完成'
            $r = Http-Action @{op='commit';message=$message}
            Assert ($r.graph.commits[0].subject -ceq $message -and $r.graph.dirty -eq 0) 'HTTP commit changed message'
        }
        Check 'HTTP switches branch' {
            $r = Http-Action @{op='switch';branch='feature/test'}
            Assert ($r.graph.branch -eq 'feature/test') 'switch failed'
        }
        Check 'HTTP protects main commit' {
            Run-Git @('switch','-c','main')
            [IO.File]::WriteAllText((Join-Path $fixture '中文檔案.txt'), '主分支修改', $OutputEncoding)
            try { Http-Action @{op='commit';message='must reject'} | Out-Null; throw 'main commit accepted' }
            catch { Assert ($_.Exception.Response.StatusCode.value__ -eq 400) 'expected main rejection' }
            Assert ((Current-Branch $fixture) -eq 'main') 'branch changed unexpectedly'
            Run-Git @('restore','中文檔案.txt')
            Run-Git @('switch','feature/test')
        }
        Run-Git @('init','--bare',$remoteFixture)
        Run-Git @('remote','add','origin',$remoteFixture)
        Check 'HTTP push creates remote tracking branch' {
            $r = Http-Action @{op='push'}
            Assert ($r.graph.upstream -eq 'origin/feature/test' -and $r.graph.ahead -eq 0) 'push did not establish upstream'
        }
        Run-Git @('clone','--branch','feature/test',$remoteFixture,$peerFixture)
        foreach ($argsList in @(@('config','user.name','Peer Test'),@('config','user.email','peer@example.invalid'))) {
            Require-Success (Git-Call $peerFixture $argsList) 'peer config' | Out-Null
        }
        [IO.File]::WriteAllText((Join-Path $peerFixture '遠端修改.txt'), '遠端新增', $OutputEncoding)
        foreach ($argsList in @(@('add','-A'),@('commit','-m','遠端新版本'),@('push'))) {
            Require-Success (Git-Call $peerFixture $argsList) 'peer git' | Out-Null
        }
        Check 'HTTP fetch updates remote graph' {
            $r = Http-Action @{op='fetch'}
            Assert ($r.graph.behind -eq 1) 'fetch did not detect new remote commit'
        }
        Check 'HTTP pull fast forwards local branch' {
            $r = Http-Action @{op='pull'}
            Assert ($r.graph.behind -eq 0 -and $r.graph.commits[0].subject -eq '遠端新版本') 'pull did not fast forward'
        }
    }
} finally {
    $expectedParent = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
    foreach ($cleanupPath in @($fixture,$remoteFixture,$peerFixture)) {
        $resolvedFixture = [IO.Path]::GetFullPath($cleanupPath)
        if ($resolvedFixture.StartsWith($expectedParent) -and (Split-Path $resolvedFixture -Leaf).StartsWith('測試 空白 ') -and (Test-Path -LiteralPath $resolvedFixture)) {
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
        }
    }
}
if ($script:Failures.Count) { throw "$($script:Failures.Count) test(s) failed: $($script:Failures -join ', ')" }
Write-Host "All $($script:Passed) helper tests passed."
