# ctx installer (Windows)
#   powershell -ExecutionPolicy Bypass -File install\install.ps1                     install / update
#   powershell -ExecutionPolicy Bypass -File install\install.ps1 -Root F:\vault      also mark F:\vault as a root folder
#   powershell -ExecutionPolicy Bypass -File install\install.ps1 -StatusLine         replace an existing status line with ctx's
#   powershell -ExecutionPolicy Bypass -File install\install.ps1 -ConfigDir F:\vault\.claude   install into another .claude folder
#   powershell -ExecutionPolicy Bypass -File install\install.ps1 -Uninstall          remove (archive data is kept)
#                                                   (add -ConfigDir to remove from that folder instead)
param([switch]$Uninstall, [string]$Root = "", [switch]$StatusLine, [string]$ConfigDir = "")

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$defaultDir = Join-Path $homeDir ".claude"
$envDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { "" }
$claudeDir = if ($ConfigDir) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigDir) } elseif ($envDir) { $envDir } else { $defaultDir }
# The archive location is decided by ctx.ps1 itself (CLAUDE_CONFIG_DIR or ~/.claude), not by where the skill is installed.
$dataDir = Join-Path $(if ($envDir) { $envDir } else { $defaultDir }) "ctx"
$src = Join-Path (Split-Path -Parent $PSScriptRoot) "skill\ctx"
$dest = Join-Path (Join-Path $claudeDir "skills") "ctx"
$plugSrc = Join-Path (Split-Path -Parent $PSScriptRoot) "plugin\ctx-statusline"
$plugDest = Join-Path (Join-Path $claudeDir "skills") "ctx-statusline"
$settings = Join-Path $claudeDir "settings.json"
$script = (Join-Path (Join-Path $dest "scripts") "ctx.ps1").Replace("\", "/")
$mark = "skills/ctx/scripts/ctx."

function Test-Ours($cmd) { return ($cmd -and ([string]$cmd).Replace("\", "/").Contains($mark)) }
function Test-OurGroup($g) { foreach ($h in @($g.hooks)) { if (Test-Ours $h.command) { return $true } }; return $false }
function Get-Cmd($m) { return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`" $m" }

function New-Group($m, $matcher) {
    $hook = [pscustomobject]@{ type = "command"; command = (Get-Cmd $m) }
    if ($matcher) { return [pscustomobject]@{ matcher = $matcher; hooks = @($hook) } }
    return [pscustomobject]@{ hooks = @($hook) }
}

function Set-Prop($obj, $name, $value) {
    if ($null -eq $obj.PSObject.Properties[$name]) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
    else { $obj.$name = $value }
}

function Update-Settings([bool]$install) {
    $data = [pscustomobject]@{}
    if (Test-Path $settings) {
        $txt = [System.IO.File]::ReadAllText($settings, $utf8).Trim()
        if ($txt) { $data = $txt | ConvertFrom-Json }
        Copy-Item $settings "$settings.bak-ctx" -Force
    }
    if ($null -eq $data.PSObject.Properties["hooks"]) { Set-Prop $data "hooks" ([pscustomobject]@{}) }
    $hooks = $data.hooks
    foreach ($p in @($hooks.PSObject.Properties)) {
        $kept = @(@($p.Value) | Where-Object { -not (Test-OurGroup $_) })
        if ($kept.Count -eq 0) { $hooks.PSObject.Properties.Remove($p.Name) } else { $hooks.($p.Name) = $kept }
    }
    $sl = if ($null -ne $data.PSObject.Properties["statusLine"]) { $data.statusLine } else { $null }
    $slOurs = ($null -ne $sl) -and (Test-Ours $sl.command)
    $note = ""
    if ($install) {
        $add = [ordered]@{
            UserPromptSubmit = (New-Group "check" $null)
            PreCompact       = (New-Group "save" $null)
            SessionStart     = (New-Group "start" "startup|clear|compact")
        }
        foreach ($ev in $add.Keys) {
            if ($null -eq $hooks.PSObject.Properties[$ev]) { $hooks | Add-Member -NotePropertyName $ev -NotePropertyValue @($add[$ev]) }
            else { $hooks.$ev = @($hooks.$ev) + $add[$ev] }
        }
        if ($null -eq $sl -or $slOurs -or $StatusLine) {
            Set-Prop $data "statusLine" ([pscustomobject]@{ type = "command"; command = (Get-Cmd "statusline"); padding = 0 })
        } else {
            $note = "You already have a status line, so it was left alone. Re-run with -StatusLine to use ctx's."
        }
    } elseif ($slOurs) {
        $data.PSObject.Properties.Remove("statusLine")
    }
    if (@($hooks.PSObject.Properties).Count -eq 0) { $data.PSObject.Properties.Remove("hooks") }
    if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($settings, (ConvertTo-Json -InputObject $data -Depth 32) + "`n", $utf8)
    if ($note) { Write-Host $note }
}

function Test-HasCtx($dir) {
    $f = Join-Path $dir "settings.json"
    if (-not (Test-Path $f)) { return $false }
    return ([System.IO.File]::ReadAllText($f, $utf8) -match 'skills[/\\]+ctx[/\\]+scripts[/\\]+ctx\.')
}

# Claude Code merges hooks from every settings.json it reads, so ctx registered in two places runs twice.
# Look at the places this machine is known to use (default folder, CLAUDE_CONFIG_DIR, each ctx root's .claude) and only warn.
function Show-DuplicateWarning {
    $cands = @($defaultDir)
    if ($envDir) { $cands += $envDir }
    $cs = Join-Path $dataDir "settings.json"
    if (Test-Path $cs) {
        try { foreach ($r in @(([System.IO.File]::ReadAllText($cs, $utf8) | ConvertFrom-Json).roots)) { if ($r) { $cands += (Join-Path $r ".claude") } } } catch { }
    }
    if ($Root) { $cands += (Join-Path $Root ".claude") }
    $here = $claudeDir.Replace("\", "/").TrimEnd("/")
    $seen = @{}
    foreach ($c in $cands) {
        $n = $c.Replace("\", "/").TrimEnd("/")
        if ($n -eq $here -or $seen.ContainsKey($n.ToLower())) { continue }
        $seen[$n.ToLower()] = $true
        if (Test-HasCtx $c) {
            Write-Host ""
            Write-Host "WARNING: ctx hooks are also registered in $(Join-Path $c 'settings.json')."
            Write-Host "  Claude Code merges both files, so every ctx hook would run twice. Nothing was changed there."
            Write-Host "  To remove that copy: powershell -ExecutionPolicy Bypass -File install\install.ps1 -Uninstall -ConfigDir `"$c`""
        }
    }
}

if ($Uninstall) {
    if (Test-Path $settings) { Update-Settings $false }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    if (Test-Path $plugDest) { Remove-Item $plugDest -Recurse -Force }
    Write-Host "ctx removed from $claudeDir. Its hooks and status line were taken out of settings.json (backup: settings.json.bak-ctx)."
    Write-Host "Your archive is still in $dataDir; delete it by hand if you no longer need it."
    exit 0
}

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -Path (Join-Path $src "*") -Destination $dest -Recurse -Force

# Status line for the desktop app (a plugin Claude Code loads from the skills folder; quiet in the terminal).
if (Test-Path $plugDest) { Remove-Item $plugDest -Recurse -Force }
New-Item -ItemType Directory -Path $plugDest -Force | Out-Null
Copy-Item -Path (Join-Path $plugSrc "*") -Destination $plugDest -Recurse -Force
Copy-Item -Path (Join-Path $plugSrc ".claude-plugin") -Destination $plugDest -Recurse -Force

# SKILL.md ships with the default location in its helper commands; point the installed copy at where it really is.
$stockSkill = (Join-Path (Join-Path $defaultDir "skills") "ctx").Replace("\", "/")
$realSkill = $dest.Replace("\", "/")
if ($realSkill -ne $stockSkill) {
    $skillMd = Join-Path $dest "SKILL.md"
    $txt = [System.IO.File]::ReadAllText($skillMd, $utf8)
    [System.IO.File]::WriteAllText($skillMd, $txt.Replace('$HOME/.claude/skills/ctx', $realSkill), $utf8)
}

Update-Settings $true
if ($Root) { & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $dest "scripts") "ctx.ps1") add-root $Root }

Write-Host "ctx installed:"
Write-Host "  skill    : $dest"
Write-Host "  desktop status line plugin: $plugDest"
Write-Host "  settings : $settings (backup: settings.json.bak-ctx)"
Write-Host "  data     : $dataDir"
Show-DuplicateWarning
Write-Host ""
Write-Host "Restart Claude Code, check with /hooks, then use /ctx."
