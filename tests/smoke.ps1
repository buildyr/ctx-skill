# ctx smoke test for Windows (Windows PowerShell 5.1 or PowerShell 7).
#
#   powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
#
# Everything happens in a temporary sandbox. Your real ~/.claude folder is never written to:
# the installer test runs against a COPY of your settings.json and shows what would change.
# Keep this file pure ASCII (Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page);
# non-ASCII test strings are built with U "...\u00fc...".

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
function P { return [System.IO.Path]::Combine([string[]]$args) }
function U([string]$s) { return [regex]::Unescape($s) }

$Repo = Split-Path -Parent $PSScriptRoot
$Ctx = P $Repo "skill" "ctx" "scripts" "ctx.ps1"
$Installer = P $Repo "install" "install.ps1"
$Exe = (Get-Process -Id $PID).Path
$Sandbox = P ([System.IO.Path]::GetTempPath()) ("ctx-smoke-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$script:Pass = 0; $script:Fail = 0

function Ok($m) { $script:Pass++; Write-Host "  OK    $m" -ForegroundColor Green }
function Bad($m, $d = "") { $script:Fail++; Write-Host "  FAIL  $m" -ForegroundColor Red; if ($d) { Write-Host "        $d" } }
function Info($m) { Write-Host "  INFO  $m" -ForegroundColor Cyan }
function Check($cond, $m, $d = "") { if ($cond) { Ok $m } else { Bad $m $d } }

function Q([string]$a) { return '"' + $a.Replace('"', '\"') + '"' }

# Runs a .ps1 in a fresh process the way Claude Code does: UTF-8 JSON on stdin, UTF-8 read from stdout.
function Invoke-Ps([string]$file, [string[]]$argv = @(), [string]$stdin = "", [string]$cwd = $null) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $all = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", (Q $file)) + @($argv | ForEach-Object { Q $_ })
    $psi.Arguments = $all -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $p = [System.Diagnostics.Process]::Start($psi)
    $b = $utf8.GetBytes($stdin)
    $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEnd()
    $e = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ out = $o.TrimEnd("`r", "`n"); err = $e; code = $p.ExitCode }
}

function Write-Utf8($path, $text) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, $utf8)
}

function New-Transcript($path, [int]$total) {
    $lines = @(
        (@{ type = "user"; message = @{ role = "user"; content = (U "Kay\u0131t formunu ekleyelim") } } | ConvertTo-Json -Compress -Depth 10),
        (@{ type = "assistant"; message = @{ role = "assistant"; content = @(@{ type = "text"; text = "Added the form: src/signup.tsx" });
              usage = @{ input_tokens = 10; cache_read_input_tokens = ($total - 60); cache_creation_input_tokens = 0; output_tokens = 50 } } } | ConvertTo-Json -Compress -Depth 10)
    )
    Write-Utf8 $path (($lines -join "`n") + "`n")
}

function HookJson($transcript, $cwd, $source = "", $session = "smoke1") {
    return (@{ session_id = $session; transcript_path = $transcript; cwd = $cwd; source = $source; trigger = "auto" } | ConvertTo-Json -Compress)
}

$saved = @{ CTX_HOME = $env:CTX_HOME; CLAUDE_PROJECT_DIR = $env:CLAUDE_PROJECT_DIR; NO_COLOR = $env:NO_COLOR; USERPROFILE = $env:USERPROFILE; HOME = $env:HOME; CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR }
$realClaude = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { P $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }) ".claude" }

try {
    New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null
    $env:CTX_HOME = P $Sandbox "ctxhome"
    $env:NO_COLOR = "1"
    Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host ("ctx smoke test - PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    Write-Host "Sandbox: $Sandbox"
    Write-Host ""
    Write-Host "Hooks and helper"

    $projName = U "m\u00fc\u015fteri-paneli"
    $proj = P $Sandbox "work" $projName
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $tr = P $Sandbox "transcript.jsonl"

    New-Transcript $tr 100000
    $r = Invoke-Ps $Ctx @("check") (HookJson $tr $proj)
    Check ($r.out -eq "" -and $r.code -eq 0) "check: silent below the threshold" $r.out

    New-Transcript $tr 150000
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Ps $Ctx @("check") (HookJson $tr $proj)
    $sw.Stop()
    Check ($r.out.Contains("75% full") -and $r.out.Contains("Project: $projName")) "check: note above the threshold, Turkish folder name intact" $r.out
    Info ("hook run time: {0} ms (added to every message you send)" -f $sw.ElapsedMilliseconds)

    $r = Invoke-Ps $Ctx @("save") (HookJson $tr $proj)
    $saved1 = P $env:CTX_HOME "projects" $projName "ctx-001.md"
    $body = if (Test-Path $saved1) { [System.IO.File]::ReadAllText($saved1, $utf8) } else { "" }
    Check ($body.Contains((U "Kay\u0131t formunu ekleyelim"))) "save: ctx-001 written with Turkish text intact" $saved1

    Write-Utf8 (P $env:CTX_HOME "projects" $projName "ctx-002.md") ("---`nno: 2`ntitle: " + (U "\u00f6deme ak\u0131\u015f\u0131") + "`n---`n" + (U "\u00d6deme a\u011f ge\u00e7idi: \u0130yzico, \u015fimdilik test modunda.") + "`n")
    $r = Invoke-Ps $Ctx @("list") "" $proj
    Check ($r.out.Contains("project: $projName") -and $r.out.Contains((U "\u00f6deme ak\u0131\u015f\u0131"))) "list: Turkish project name and title" $r.out

    $r = Invoke-Ps $Ctx @("search", (U "a\u011f"), (U "ge\u00e7idi")) "" $proj
    Check ($r.out.Contains("ctx-002.md:5:")) "search: Turkish words" $r.out

    $null = Invoke-Ps $Ctx @("pending", "2") "" $proj
    $r = Invoke-Ps $Ctx @("start") (HookJson $tr $proj "clear")
    Check ($r.out.Contains("ctx-002 loaded") -and $r.out.Contains((U "\u00d6deme a\u011f ge\u00e7idi: \u0130yzico"))) "handoff: /clear loads ctx-002, Turkish text intact" $r.out

    $r = Invoke-Ps $Ctx @("statusline") (@{ transcript_path = $tr; workspace = @{ current_dir = $proj } } | ConvertTo-Json -Compress)
    Check ($r.out -eq "ctx $projName #002 | 75%") "statusline: project, number, fill" $r.out

    $r = Invoke-Ps $Ctx @("check") "not json"
    Check ($r.code -eq 0 -and $r.out -eq "") "broken input: silent, exit code 0" $r.out

    Write-Host ""
    Write-Host "Installer (sandbox home, your real settings are not touched)"

    $home2 = P $Sandbox "home"
    $settings = P $home2 ".claude" "settings.json"
    $realSettings = P $realClaude "settings.json"
    if (Test-Path $realSettings) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $settings) -Force | Out-Null
        Copy-Item $realSettings $settings
        Info "testing against a copy of $realSettings"
    } else {
        Write-Utf8 $settings "{`n  `"model`": `"opus`"`n}`n"
        Info "no settings.json found at $realSettings; using a sample"
    }
    $orig = [System.IO.File]::ReadAllText($settings, $utf8) | ConvertFrom-Json

    # If ctx is already installed on this machine, the copy contains ctx's own hooks and status line.
    # Strip them so the baseline is "settings without ctx", which is what the checks below assume.
    $oursMark = "skills/ctx/scripts/ctx."
    $changed = $false
    if ($null -ne $orig.PSObject.Properties["hooks"]) {
        foreach ($p in @($orig.hooks.PSObject.Properties)) {
            $kept = @(@($p.Value) | Where-Object { -not (@($_.hooks) | Where-Object { ([string]$_.command).Replace("\", "/").Contains($oursMark) }) })
            if ($kept.Count -ne @($p.Value).Count) {
                $changed = $true
                if ($kept.Count -eq 0) { $orig.hooks.PSObject.Properties.Remove($p.Name) } else { $orig.hooks.($p.Name) = $kept }
            }
        }
        if (@($orig.hooks.PSObject.Properties).Count -eq 0) { $orig.PSObject.Properties.Remove("hooks") }
    }
    if ($null -ne $orig.PSObject.Properties["statusLine"] -and ([string]$orig.statusLine.command).Replace("\", "/").Contains($oursMark)) {
        $orig.PSObject.Properties.Remove("statusLine"); $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($settings, (ConvertTo-Json -InputObject $orig -Depth 32) + "`n", $utf8)
        Info "ctx is already installed here; its hooks were stripped from the copy to get a clean baseline"
    }

    function Get-Cmds($obj, [bool]$ours) {
        $r = @()
        if ($null -ne $obj.PSObject.Properties["hooks"]) {
            foreach ($ev in $obj.hooks.PSObject.Properties) {
                foreach ($g in @($ev.Value)) {
                    foreach ($h in @($g.hooks)) {
                        $isOurs = ([string]$h.command).Replace("\", "/").Contains("skills/ctx/scripts/ctx.")
                        if ($isOurs -eq $ours) { $r += ($ev.Name + " :: " + $h.command) }
                    }
                }
            }
        }
        return @($r | Sort-Object)
    }

    $env:USERPROFILE = $home2; $env:HOME = $home2
    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    $r = Invoke-Ps $Installer @()
    Check ($r.code -eq 0) "install runs" ($r.err + $r.out)
    $after = [System.IO.File]::ReadAllText($settings, $utf8) | ConvertFrom-Json
    Check ((Get-Cmds $after $true).Count -eq 3) "3 ctx hooks added"
    Check (((Get-Cmds $orig $false) -join "|") -eq ((Get-Cmds $after $false) -join "|")) "all your existing hooks kept"
    $missing = @($orig.PSObject.Properties.Name | Where-Object { $null -eq $after.PSObject.Properties[$_] })
    Check ($missing.Count -eq 0) "all your other settings kept" ($missing -join ", ")
    if ($null -ne $orig.PSObject.Properties["statusLine"]) {
        Check (($orig.statusLine | ConvertTo-Json -Compress) -eq ($after.statusLine | ConvertTo-Json -Compress)) "your status line left alone"
    } else {
        Check (([string]$after.statusLine.command).EndsWith(" statusline")) "ctx status line added (you had none)"
    }
    Check (Test-Path (P $home2 ".claude" "skills" "ctx" "SKILL.md")) "skill copied"
    Check ((Test-Path (P $home2 ".claude" "skills" "ctx-statusline" ".claude-plugin" "plugin.json")) -and (Test-Path (P $home2 ".claude" "skills" "ctx-statusline" "hooks" "register.ts"))) "desktop status line plugin copied"

    $r = Invoke-Ps $Installer @()
    $again = [System.IO.File]::ReadAllText($settings, $utf8) | ConvertFrom-Json
    Check ((Get-Cmds $again $true).Count -eq 3) "running the installer again does not duplicate hooks"

    $r = Invoke-Ps $Installer @("-Uninstall")
    $back = [System.IO.File]::ReadAllText($settings, $utf8) | ConvertFrom-Json
    $same = ($orig | ConvertTo-Json -Depth 32 -Compress) -eq ($back | ConvertTo-Json -Depth 32 -Compress)
    Check $same "uninstall restores your settings exactly"
    Check (-not (Test-Path (P $home2 ".claude" "skills" "ctx"))) "uninstall removes the skill"
    Check (-not (Test-Path (P $home2 ".claude" "skills" "ctx-statusline"))) "uninstall removes the desktop status line plugin"

    Write-Host ""
    Write-Host "Install into another .claude folder (-ConfigDir)"
    $vaultCfg = P $Sandbox "vault" ".claude"
    $vSettings = P $vaultCfg "settings.json"
    $vFwd = $vaultCfg.Replace("\", "/")
    $vSkill = P $vaultCfg "skills" "ctx"

    # No other copy exists yet, so a -ConfigDir install must not warn.
    $r = Invoke-Ps $Installer @("-ConfigDir", $vaultCfg)
    Check ($r.code -eq 0) "install with -ConfigDir runs" ($r.err + $r.out)
    Check (Test-Path (P $vSkill "SKILL.md")) "skill copied into that folder"
    Check (Test-Path (P $vaultCfg "skills" "ctx-statusline" ".claude-plugin" "plugin.json")) "desktop status line plugin copied into that folder"
    Check (-not (Test-Path (P $home2 ".claude" "skills" "ctx"))) "nothing was installed in the default folder"
    $vj = [System.IO.File]::ReadAllText($vSettings, $utf8) | ConvertFrom-Json
    $vCmds = Get-Cmds $vj $true
    Check ($vCmds.Count -eq 3) "3 ctx hooks in that folder's settings.json"
    Check ((($vCmds -join "|").Replace("\", "/")).Contains($vFwd + "/skills/ctx/scripts/ctx.ps1")) "hooks point at that folder"
    $md = [System.IO.File]::ReadAllText((P $vSkill "SKILL.md"), $utf8)
    Check ($md.Contains($vFwd + "/skills/ctx/scripts/ctx.ps1") -and -not $md.Contains('$HOME/.claude/skills/ctx')) "SKILL.md helper path points at that folder"
    Check (-not $r.out.Contains("WARNING")) "no warning when it is the only copy" $r.out

    # Now a second copy in the default folder: the installer must warn and leave it alone.
    $r = Invoke-Ps $Installer @()
    $defHash = (Get-FileHash $settings).Hash
    $r = Invoke-Ps $Installer @("-ConfigDir", $vaultCfg)
    Check ($r.out.Contains("WARNING") -and $r.out.Contains($settings)) "warns when ctx is also registered in the default folder" $r.out
    Check ($r.out.Contains("-Uninstall -ConfigDir")) "the warning shows the removal command" $r.out
    Check ((Get-FileHash $settings).Hash -eq $defHash) "the other settings.json was not changed"
    $vj = [System.IO.File]::ReadAllText($vSettings, $utf8) | ConvertFrom-Json
    Check ((Get-Cmds $vj $true).Count -eq 3) "re-install with -ConfigDir does not duplicate hooks"

    # Removal is scoped to the folder you name.
    $r = Invoke-Ps $Installer @("-Uninstall", "-ConfigDir", $vaultCfg)
    Check (-not (Test-Path $vSkill)) "uninstall -ConfigDir removes that copy"
    Check (-not (Test-Path (P $vaultCfg "skills" "ctx-statusline"))) "uninstall -ConfigDir removes its plugin"
    $vj = [System.IO.File]::ReadAllText($vSettings, $utf8) | ConvertFrom-Json
    Check ((Get-Cmds $vj $true).Count -eq 0) "uninstall -ConfigDir removes its hooks"
    $def = [System.IO.File]::ReadAllText($settings, $utf8) | ConvertFrom-Json
    Check (((Get-Cmds $def $true).Count -eq 3) -and (Test-Path (P $home2 ".claude" "skills" "ctx" "SKILL.md")) -and (Test-Path (P $home2 ".claude" "skills" "ctx-statusline"))) "the default install is untouched"
    $null = Invoke-Ps $Installer @("-Uninstall")
}
catch {
    Bad "unexpected error" $_.Exception.Message
}
finally {
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $saved[$k] }
    }
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($script:Fail -eq 0) { Write-Host ("All {0} checks passed. Your real Claude Code settings were not modified." -f $script:Pass) -ForegroundColor Green }
else { Write-Host ("{0} passed, {1} failed. Your real Claude Code settings were not modified." -f $script:Pass, $script:Fail) -ForegroundColor Red }
exit $script:Fail
