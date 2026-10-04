# ctx.ps1 - numbered, per-project context archive for Claude Code (Windows).
# Works with Windows PowerShell 5.1 and PowerShell 7. Behaves exactly like ctx.py;
# apply every change to both. See the header of ctx.py for the list of modes.
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page.
param(
    [Parameter(Position = 0)][string]$Mode = "check",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
$IntKeys = @("window", "threshold", "cleanupEveryDays", "archiveAgeDays", "maxActive")
$OnWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$TailBytes = 512 * 1024
$SearchMax = 40
$Esc = [char]27

# ---------------- helpers ----------------
function Get-RootDir {
    if ($env:CTX_HOME) { return $env:CTX_HOME }
    if ($env:CLAUDE_CONFIG_DIR) { return (Join-Path $env:CLAUDE_CONFIG_DIR "ctx") }
    $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    return (Join-Path (Join-Path $h ".claude") "ctx")
}
$Root = Get-RootDir

function Read-Text($p) { return [System.IO.File]::ReadAllText($p, $utf8) }
function Write-Text($p, $t) {
    $d = Split-Path -Parent $p
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllText($p, $t, $utf8)
}
# Claude Code reads hook and tool output as UTF-8. Windows PowerShell 5.1 would encode
# [Console]::Out with the OEM code page and break non-ASCII text, so write UTF-8 bytes directly.
$script:StdOut = $null
function Out-Line([string]$s = "") {
    if ($null -eq $script:StdOut) { $script:StdOut = [Console]::OpenStandardOutput() }
    $b = $utf8.GetBytes($s + "`n")
    $script:StdOut.Write($b, 0, $b.Length)
    $script:StdOut.Flush()
}

function Get-Settings {
    $s = @{ window = 200000; threshold = 70; cleanupEveryDays = 14; archiveAgeDays = 30; maxActive = 10; roots = @() }
    $p = Join-Path $Root "settings.json"
    if (Test-Path $p) {
        try {
            $j = Read-Text $p | ConvertFrom-Json
            foreach ($k in $IntKeys) { if ($null -ne $j.$k) { $s[$k] = [int64]$j.$k } }
            if ($null -ne $j.roots) { $s.roots = @($j.roots | ForEach-Object { [string]$_ }) }
        } catch { }
    }
    return $s
}

function Save-Settings($s) {
    $o = [ordered]@{}
    foreach ($k in $IntKeys) { $o[$k] = $s[$k] }
    $o["roots"] = @($s.roots)
    Write-Text (Join-Path $Root "settings.json") ((ConvertTo-Json -InputObject $o -Depth 5) + "`n")
}

function Norm($p) {
    $full = [System.IO.Path]::GetFullPath($p).Replace("\", "/").TrimEnd("/")
    if ($OnWindows) { $full = $full.ToLower() }
    return $full
}

function Get-Sha6($t) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($t))
    return (($b | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 6)
}

# Returns @(project_name, project_folder)
function Resolve-Project($cwd, $s) {
    $b = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } elseif ($cwd) { $cwd } else { (Get-Location).Path }
    $base = Norm $b
    $here = if ($cwd) { Norm $cwd } else { $base }
    $projects = Join-Path $Root "projects"
    foreach ($r in $s.roots) {
        $rn = Norm $r
        if ($base -eq $rn -or $base.StartsWith($rn + "/")) {
            $src = if ($here -eq $rn -or $here.StartsWith($rn + "/")) { $here } else { $base }
            $restPath = $src.Substring($rn.Length).Trim("/")
            $seg = if ($restPath) { $restPath.Split("/")[0] } else { "" }
            $name = $null
            if ($seg -and -not $seg.StartsWith(".")) { $name = $seg }
            else {
                $ap = Join-Path $Root ".active"
                if (Test-Path $ap) { $v = (Read-Text $ap).Trim(); if ($v) { $name = $v } }
            }
            if (-not $name) { $name = "_general" }
            return @($name, (Join-Path $projects $name))
        }
    }
    $leaf = Split-Path -Leaf $base
    if (-not $leaf) { $leaf = "_general" }
    $name = [regex]::Replace($leaf, '[^\w.-]', '_')
    $pdir = Join-Path $projects $name
    $marker = Join-Path $pdir ".path"
    if ((Test-Path $marker) -and ((Read-Text $marker).Trim() -ne $base)) {
        $name = $name + "-" + (Get-Sha6 $base)
        $pdir = Join-Path $projects $name
        $marker = Join-Path $pdir ".path"
    }
    if (-not (Test-Path $marker)) { Write-Text $marker ($base + "`n") }
    return @($name, $pdir)
}

function Get-CtxNumbers($d) {
    $r = @()
    if (Test-Path $d) {
        foreach ($f in (Get-ChildItem -Path $d -File)) { if ($f.Name -match '^ctx-(\d+)\.md$') { $r += [int]$Matches[1] } }
    }
    return $r
}

function Get-MaxNumber($pdir) {
    $nums = @(Get-CtxNumbers $pdir)
    $a = Join-Path $pdir "archive"
    if (Test-Path $a) {
        foreach ($f in (Get-ChildItem -Path $a -File)) { if ($f.Name -match '^ctx-(\d+)') { $nums += [int]$Matches[1] } }
    }
    if ($nums.Count -eq 0) { return 0 }
    return [int](($nums | Measure-Object -Maximum).Maximum)
}

function Get-FrontMatter($p) {
    $fm = @{}
    try {
        $lines = [System.IO.File]::ReadAllLines($p, $utf8)
        if ($lines.Count -eq 0 -or $lines[0].Trim() -ne "---") { return $fm }
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq "---") { break }
            if ($lines[$i] -match '^(\w+):\s*(.*)$') { $fm[$Matches[1]] = $Matches[2].Trim() }
        }
    } catch { }
    return $fm
}

function Get-Fm($fm, $k) { if ($fm.ContainsKey($k)) { return $fm[$k] } return "" }

function Get-Text($content) {
    if ($null -eq $content) { return "" }
    if ($content -is [string]) { return $content }
    $parts = @()
    foreach ($b in $content) { if ($b.type -eq "text" -and $b.text) { $parts += $b.text } }
    return ($parts -join "`n")
}

# Returns @(lines, truncated)
function Get-TailLines($path, [long]$nbytes) {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $size = $fs.Length
        $trunc = $size -gt $nbytes
        if ($trunc) { [void]$fs.Seek($size - $nbytes, [System.IO.SeekOrigin]::Begin) }
        $len = [int]($size - $fs.Position)
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) { $n = $fs.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
    } finally { $fs.Dispose() }
    $lines = $utf8.GetString($buf, 0, $read).Split("`n")
    if ($trunc) { if ($lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] } else { $lines = @() } }
    return @{ lines = @($lines); trunc = $trunc }
}

function Get-ContextTokens($transcript) {
    $res = Get-TailLines $transcript $TailBytes
    $lines = $res.lines; $trunc = $res.trunc
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $l = $lines[$i]
            if ($l.Contains('"compact_boundary"')) { return 0 }
            if (-not $l.Contains('"usage"')) { continue }
            try { $e = $l | ConvertFrom-Json } catch { continue }
            if ($e.isSidechain) { continue }
            $u = $e.message.usage
            if ($null -eq $u) { continue }
            return ([int64]$u.input_tokens + [int64]$u.cache_read_input_tokens + [int64]$u.cache_creation_input_tokens + [int64]$u.output_tokens)
        }
        if (-not $trunc -or $attempt -gt 0) { break }
        $res = Get-TailLines $transcript ((Get-Item $transcript).Length + 1)
        $lines = $res.lines; $trunc = $res.trunc
    }
    return 0
}

function Get-Percent($tokens, $s) {
    return [int][math]::Round(100.0 * $tokens / [math]::Max(1, $s.window), [MidpointRounding]::ToEven)
}

function Read-Input {
    # Read stdin as UTF-8 bytes; [Console]::In would use the OEM code page on Windows PowerShell 5.1
    try {
        $ms = New-Object System.IO.MemoryStream
        [Console]::OpenStandardInput().CopyTo($ms)
        $raw = $utf8.GetString($ms.ToArray())
    } catch { return $null }
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-InputCwd($in) {
    if ($null -eq $in) { return $null }
    if ($in.cwd) { return $in.cwd }
    if ($in.workspace -and $in.workspace.current_dir) { return $in.workspace.current_dir }
    return $null
}

function F3($n) { return ([int]$n).ToString("000") }

# ---------------- hook modes ----------------
function Invoke-Check($in, $s) {
    if ($null -eq $in -or -not $in.transcript_path -or -not (Test-Path $in.transcript_path)) { return }
    $proj = (Resolve-Project (Get-InputCwd $in) $s)[0]
    $tokens = Get-ContextTokens $in.transcript_path
    $pct = Get-Percent $tokens $s
    $flag = Join-Path (Join-Path $Root ".state") ("asked-" + $in.session_id)
    if ($pct -lt $s.threshold) {
        if (Test-Path $flag) { Remove-Item $flag -Force }
        return
    }
    if (Test-Path $flag) { return }
    Write-Text $flag "$pct"
    Out-Line ("[ctx] Project: {0}. Context is about {1}% full ({2} / {3} tokens). First answer the user's message, then end your reply with the 'handoff' question from the ctx skill." -f $proj, $pct, $tokens, $s.window)
}

function Invoke-Start($in, $s) {
    $source = if ($in) { [string]$in.source } else { "" }
    $r = Resolve-Project (Get-InputCwd $in) $s; $proj = $r[0]; $pdir = $r[1]

    if ($source -eq "clear") {
        $pending = Join-Path $pdir ".pending"
        if (-not (Test-Path $pending)) { return }
        try { $num = [int]((Read-Text $pending).Trim()) } finally { Remove-Item $pending -Force }
        $cid = F3 $num
        $path = Join-Path $pdir "ctx-$cid.md"
        if (-not (Test-Path $path)) { return }
        Out-Line ("[ctx] Project: {0}. This new context starts from the handoff {0}/ctx-{1}. Treat the record below as this session's context; in your first reply say 'ctx-{1} loaded', summarise where we left off in 3-5 bullets and offer to continue with the open tasks." -f $proj, $cid)
        Out-Line
        Out-Line (Read-Text $path)
        return
    }

    if ($source -eq "compact") {
        $mx = Get-MaxNumber $pdir
        if ($mx -gt 0) { Out-Line ("[ctx] The conversation before compaction was archived as {0}/ctx-{1}. Tell the user in one line in your first reply." -f $proj, (F3 $mx)) }
        return
    }

    if ($source -eq "startup") {
        if (-not (Test-Path $Root)) { return }
        $state = Join-Path $Root ".state"
        if (Test-Path $state) {
            Get-ChildItem $state -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force
        }
        $today = (Get-Date).Date
        $stamp = Join-Path $Root ".last-cleanup"
        if (-not (Test-Path $stamp)) { Write-Text $stamp $today.ToString("yyyy-MM-dd"); return }
        try { $last = [datetime]::ParseExact((Read-Text $stamp).Trim(), "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture) }
        catch { $last = $today }
        if (($today - $last).TotalDays -lt $s.cleanupEveryDays) { return }
        Write-Text $stamp $today.ToString("yyyy-MM-dd")
        $cut = (Get-Date).AddDays(-$s.archiveAgeDays)
        $old = 0
        $pr = Join-Path $Root "projects"
        if (Test-Path $pr) {
            foreach ($p in (Get-ChildItem $pr -Directory)) {
                $a = Join-Path $p.FullName "archive"
                if (Test-Path $a) { $old += @(Get-ChildItem $a -File | Where-Object { $_.LastWriteTime -lt $cut }).Count }
            }
        }
        $active = @(Get-CtxNumbers $pdir).Count
        if ($old -eq 0 -and $active -lt $s.maxActive) { return }
        Out-Line ("[ctx] Cleanup is due. The archive has {0} files older than {1} days; project {2} has {3} active contexts. After answering the user's first message, ask in one line whether they want to review them with '/ctx cleanup'. Never delete anything on your own." -f $old, $s.archiveAgeDays, $proj, $active)
    }
}

function Invoke-Save($in, $s) {
    if ($null -eq $in -or -not $in.transcript_path -or -not (Test-Path $in.transcript_path)) { return }
    $r = Resolve-Project (Get-InputCwd $in) $s; $proj = $r[0]; $pdir = $r[1]
    $entries = New-Object System.Collections.ArrayList
    foreach ($l in [System.IO.File]::ReadAllLines($in.transcript_path, $utf8)) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try { [void]$entries.Add(($l | ConvertFrom-Json)) } catch { }
    }
    $start = 0
    for ($i = 0; $i -lt $entries.Count; $i++) { if ($entries[$i].subtype -eq "compact_boundary") { $start = $i + 1 } }
    $chunks = @()
    for ($i = $start; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        if ($e.type -ne "user" -and $e.type -ne "assistant") { continue }
        if ($e.isMeta -or $e.isSidechain) { continue }
        $t = (Get-Text $e.message.content).Trim()
        if (-not $t -or $t.StartsWith("[ctx]")) { continue }
        if ($t.Length -gt 3000) { $t = $t.Substring(0, 3000) + " ...[truncated]" }
        $who = if ($e.isCompactSummary) { "PREVIOUS SUMMARY" } elseif ($e.type -eq "user") { "USER" } else { "CLAUDE" }
        $chunks += "### $who`n$t`n"
    }
    if ($chunks.Count -eq 0) { return }
    $next = (Get-MaxNumber $pdir) + 1
    $trigger = if ($in.trigger) { $in.trigger } else { "unknown" }
    $header = "---`nno: $next`nproject: $proj`ndate: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`ntype: auto`nstatus: active`ntitle: (raw record before $trigger compaction)`nsummary: not summarised yet`n---`n`n"
    Write-Text (Join-Path $pdir ("ctx-" + (F3 $next) + ".md")) ($header + ($chunks -join "`n"))
}

function Invoke-StatusLine($in, $s) {
    $r = Resolve-Project (Get-InputCwd $in) $s; $proj = $r[0]; $pdir = $r[1]
    $line = "ctx $proj"
    $mx = Get-MaxNumber $pdir
    if ($mx -gt 0) { $line += " #" + (F3 $mx) }
    if (Test-Path (Join-Path $pdir ".pending")) { $line += " handoff ready" }
    if ($in -and $in.transcript_path -and (Test-Path $in.transcript_path)) {
        $pct = Get-Percent (Get-ContextTokens $in.transcript_path) $s
        $txt = "$pct%"
        if (-not $env:NO_COLOR) {
            $color = if ($pct -ge $s.threshold) { "31" } elseif ($pct -ge $s.threshold - 10) { "33" } else { "32" }
            $txt = "$Esc[" + $color + "m" + $txt + "$Esc[0m"
        }
        $line += " | " + $txt
    }
    Out-Line $line
}

# ---------------- tool modes ----------------
function Show-Where($s) {
    $r = Resolve-Project $null $s
    Out-Line ("project: " + $r[0])
    Out-Line ("dir: " + $r[1].Replace("\", "/"))
    Out-Line ("archive: " + (Join-Path $r[1] "archive").Replace("\", "/"))
    Out-Line ("pins: " + (Join-Path $Root "pins").Replace("\", "/"))
    Out-Line ("settings: " + (($IntKeys | ForEach-Object { "$_=" + $s[$_] }) -join " "))
}

function Show-List($s) {
    $r = Resolve-Project $null $s; $pdir = $r[1]
    Out-Line ("project: " + $r[0])
    $nums = @(@(Get-CtxNumbers $pdir) | Sort-Object)
    if ($nums.Count -eq 0) { Out-Line "(no contexts yet)" }
    foreach ($n in $nums) {
        $fm = Get-FrontMatter (Join-Path $pdir ("ctx-" + (F3 $n) + ".md"))
        Out-Line ("{0} | {1} | {2} | {3} | {4}" -f (F3 $n), (Get-Fm $fm "date"), (Get-Fm $fm "type"), (Get-Fm $fm "title"), (Get-Fm $fm "summary"))
    }
    $a = Join-Path $pdir "archive"
    $c = if (Test-Path $a) { @(Get-ChildItem $a -File).Count } else { 0 }
    Out-Line ("archive: $c files")
}

function Show-Pins {
    $d = Join-Path $Root "pins"
    $files = if (Test-Path $d) { @(Get-ChildItem $d -File -Filter "*.md" | Sort-Object Name) } else { @() }
    if ($files.Count -eq 0) { Out-Line "(no pins)" }
    foreach ($f in $files) {
        $fm = Get-FrontMatter $f.FullName
        $nm = Get-Fm $fm "name"; if (-not $nm) { $nm = $f.BaseName }
        Out-Line ("{0} | {1} | {2}" -f $nm, (Get-Fm $fm "project"), (Get-Fm $fm "description"))
    }
}

function Invoke-Search($s, $a) {
    $every = $a -contains "--all"
    $words = @($a | Where-Object { $_ -ne "--all" } | ForEach-Object { $_.ToLowerInvariant() })
    if ($words.Count -eq 0) { [Console]::Error.WriteLine("usage: search [--all] WORDS"); return 2 }
    $dirs = @()
    if ($every) {
        $pr = Join-Path $Root "projects"
        if (Test-Path $pr) {
            foreach ($p in (Get-ChildItem $pr -Directory | Sort-Object Name)) { $dirs += $p.FullName; $dirs += (Join-Path $p.FullName "archive") }
        }
        $dirs += (Join-Path $Root "pins")
    } else {
        $pdir = (Resolve-Project $null $s)[1]
        $dirs = @($pdir, (Join-Path $pdir "archive"))
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $hits = New-Object System.Collections.ArrayList
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        foreach ($f in (Get-ChildItem $d -File -Filter "*.md" | Sort-Object Name)) {
            try { $lines = (Read-Text $f.FullName).Split("`n") } catch { continue }
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $low = $lines[$i].ToLowerInvariant()
                $all = $true
                foreach ($w in $words) { if (-not $low.Contains($w)) { $all = $false; break } }
                if (-not $all) { continue }
                $snip = $lines[$i].Trim()
                if ($snip.Length -gt 160) { $snip = $snip.Substring(0, 157) + "..." }
                $rel = $f.FullName.Substring($rootFull.Length).TrimStart("\", "/").Replace("\", "/")
                [void]$hits.Add(("{0}:{1}: {2}" -f $rel, ($i + 1), $snip))
            }
        }
    }
    if ($hits.Count -eq 0) { Out-Line "(no matches)" }
    for ($i = 0; $i -lt [math]::Min($hits.Count, $SearchMax); $i++) { Out-Line $hits[$i] }
    if ($hits.Count -gt $SearchMax) { Out-Line ("... {0} more matches, narrow the search" -f ($hits.Count - $SearchMax)) }
    return 0
}

# ---------------- entry ----------------
$s = Get-Settings
$argv = @($Rest | Where-Object { $null -ne $_ })

if (@("check", "save", "start", "statusline") -contains $Mode) {
    try {
        $in = Read-Input
        switch ($Mode) {
            "check"      { Invoke-Check $in $s }
            "save"       { Invoke-Save $in $s }
            "start"      { Invoke-Start $in $s }
            "statusline" { Invoke-StatusLine $in $s }
        }
    } catch { }
    exit 0   # a hook must never block Claude Code
}

switch ($Mode) {
    "where"  { Show-Where $s }
    "list"   { Show-List $s }
    "next"   { Out-Line ([string]((Get-MaxNumber (Resolve-Project $null $s)[1]) + 1)) }
    "pins"   { Show-Pins }
    "search" { exit (Invoke-Search $s $argv) }
    "pending" {
        if ($argv.Count -lt 1) { exit 2 }
        Write-Text (Join-Path (Resolve-Project $null $s)[1] ".pending") ([string][int]$argv[0])
        Out-Line ("ok: the next /clear opens with ctx-{0}" -f (F3 $argv[0]))
    }
    "project" {
        if ($argv.Count -lt 1) { exit 2 }
        Write-Text (Join-Path $Root ".active") $argv[0].Trim()
        Out-Line ("ok: active project " + $argv[0].Trim())
    }
    "set" {
        if ($argv.Count -ne 2 -or -not ($IntKeys -contains $argv[0])) { exit 2 }
        $s[$argv[0]] = [int64]$argv[1]
        Save-Settings $s
        Out-Line ("ok: {0}={1}" -f $argv[0], $argv[1])
    }
    "add-root" {
        if ($argv.Count -lt 1) { exit 2 }
        $p = Norm $argv[0]
        $have = @($s.roots | ForEach-Object { Norm $_ })
        if (-not ($have -contains $p)) { $s.roots = @($s.roots) + $p }
        Save-Settings $s
        Out-Line ("ok: root " + $p)
    }
    default {
        [Console]::Error.WriteLine("usage: ctx.ps1 <check|save|start|statusline|where|list|next|pins|search [--all] WORDS|pending N|project NAME|set KEY VALUE|add-root PATH>")
        exit 2
    }
}
exit 0
