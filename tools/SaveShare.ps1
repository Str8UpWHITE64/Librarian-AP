<#
Librarian-AP save sharing: hand an Archipelago run's save to another player.

  Export: pick one of your AP saves; writes a zip (the save, plus a small manifest.json) to your Desktop.
  Import: puts a zip from someone else into a free AP save slot on this PC, so the mod loads it when you connect.

Released as Librarian-AP_SaveShare.bat: tools/build_release.py puts this script behind a short batch header, so it is
one file that runs with a double-click (drop a save zip on it to import). Command line, for scripting:
  Librarian-AP_SaveShare.bat -Action list
  Librarian-AP_SaveShare.bat -Action export -Slot 20 [-Out <folder or .zip>]
  Librarian-AP_SaveShare.bat -Action import -Zip <file.zip> [-WriteConfig yes|no]
  -GameDir <game folder> when the game is not in a Steam library; -SavedDir and -ConfigPath override those paths.

What a run's save is on a PC:
  SaveGames\Map01\SaveNN\GameData.sav + SlotData.sav   the game's save (the mod keeps the run in slots 20-30)
  LibrarianAP_slots.txt   "<seed>|<AP slot number>=NN,h<layout>": which save belongs to which run, plus the book layout
                          hash the mod checks a loaded save against
The AP server also records the save number. When an imported save cannot keep its number here, the line is marked
",moved" and the mod tells the server the new number on the next connect.
Nothing else is needed: items, checks and traps live on the server. Passwords are never exported.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Zip,
    [ValidateSet('', 'list', 'export', 'import')][string]$Action = '',
    [int]$Slot = 0,
    [string]$Out,
    [string]$SavedDir,
    [string]$ConfigPath,
    [string]$GameDir,
    [ValidateSet('ask', 'yes', 'no')][string]$WriteConfig = 'ask'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$FORMAT = 1
$SLOT_MIN = 20
$SLOT_MAX = 30
$GAME_FOLDER = 'Librarian Tidy Up the Arcane Library!'
$MOD_REL = 'Librarian\Binaries\Win64\Mods\Librarian-AP'

# The game folder: -GameDir, else every Steam library (registry + libraryfolders.vdf), else Steam's uninstall entry.
function Find-GameDir {
    if ($GameDir) { return $GameDir }
    $roots = @()
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $item = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($v in $item.SteamPath, $item.InstallPath) { if ($v) { $roots += ($v -replace '/', '\') } }
        } catch { }
    }
    $libs = @()
    foreach ($r in $roots) {
        $libs += $r
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
                $libs += $m.Groups[1].Value.Replace('\\', '\')
            }
        }
    }
    foreach ($l in $libs) {
        $g = Join-Path $l ('steamapps\common\' + $GAME_FOLDER)
        if (Test-Path -LiteralPath (Join-Path $g $MOD_REL)) { return $g }
    }
    try {
        $u = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 4197610' -ErrorAction Stop
        if ($u.InstallLocation -and (Test-Path -LiteralPath (Join-Path $u.InstallLocation $MOD_REL))) { return $u.InstallLocation }
    } catch { }
    return ''
}

$GameDir = Find-GameDir
$MOD_DIR = ''
if ($GameDir) { $MOD_DIR = Join-Path $GameDir $MOD_REL }
if (-not $SavedDir) { $SavedDir = Join-Path $env:LOCALAPPDATA 'Librarian\Saved' }
if (-not $ConfigPath -and $MOD_DIR) { $ConfigPath = Join-Path $MOD_DIR 'Scripts\ap_config.json' }
$SAVES = Join-Path $SavedDir 'SaveGames\Map01'
$RECORDS = Join-Path $SavedDir 'LibrarianAP_slots.txt'
$Interactive = ($Action -eq '')
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)

function Say([string]$text) { Write-Host $text }
$script:Expected = $false
function Fail([string]$text) { $script:Expected = $true; throw [System.Exception]::new($text) }

function Ask([string]$prompt) {
    if (-not $Interactive) { return '' }
    $a = Read-Host $prompt
    if ($null -eq $a) { return '' }
    return $a.Trim()
}

function Game-Running {
    $p = Get-Process -Name 'Librarian-Win64-Shipping', 'Librarian' -ErrorAction SilentlyContinue
    return [bool]$p
}

function Save-Folder([int]$n) { return Join-Path $SAVES ('Save{0:D2}' -f $n) }

# ------------------------------------------------------------------ the record file
# Parsed the way the mod reads it (AP/SaveIdentity.lua read_local): "key=slot", "key=slot,hNNN" (layout hash),
# "key=slot,NNN" (an older hash the mod no longer compares), each optionally followed by ",moved".
function Read-Records {
    $list = @()
    if (-not (Test-Path -LiteralPath $RECORDS)) { return $list }
    foreach ($raw in [System.IO.File]::ReadAllLines($RECORDS, $Utf8)) {
        $line = $raw.Trim()
        $moved = $false
        if ($line.EndsWith(',moved')) { $line = $line.Substring(0, $line.Length - 6); $moved = $true }
        $m = [regex]::Match($line, '^(.+)\|(\d+)=(\d+)(?:,(h?)(\d+))?$')
        if (-not $m.Success) { continue }
        $layout = $null
        if ($m.Groups[4].Value -eq 'h') { $layout = $m.Groups[5].Value }
        $list += [pscustomobject]@{
            Seed = $m.Groups[1].Value; ApSlot = [int]$m.Groups[2].Value; Slot = [int]$m.Groups[3].Value
            Layout = $layout; Moved = $moved; Line = $raw
        }
    }
    return $list
}

# ------------------------------------------------------------------ reading and patching the save's SlotData
# A property is stored as: FString name, FString type, 4 bytes, int32 size, 1 flag byte, then the value.
function Find-Prop([byte[]]$data, [string]$name, [string]$type) {
    $text = $Latin1.GetString($data)
    $needle = [char]($name.Length + 1) + [string][char]0 + [char]0 + [char]0 + $name + [char]0 +
              [char]($type.Length + 1) + [char]0 + [char]0 + [char]0 + $type + [char]0
    $i = $text.IndexOf($needle, [System.StringComparison]::Ordinal)
    if ($i -lt 0) { return -1 }
    $at = $i + $needle.Length + 4
    if ($at + 9 -gt $data.Length) { return -1 }
    if ([BitConverter]::ToInt32($data, $at) -ne 4) { return -1 }
    return $at + 5
}

function Read-Int([byte[]]$data, [string]$name) {
    $at = Find-Prop $data $name 'IntProperty'
    if ($at -lt 0) { return 0 }   # the game leaves out properties still at zero
    return [BitConverter]::ToInt32($data, $at)
}

function Read-Progress([string]$slotData) {
    $d = [System.IO.File]::ReadAllBytes($slotData)
    $t = 0.0
    $at = Find-Prop $d 'PlayTime' 'FloatProperty'
    if ($at -ge 0) { $t = [BitConverter]::ToSingle($d, $at) }
    return [pscustomobject]@{
        Books = Read-Int $d 'InsertedBookNum'; BookMax = Read-Int $d 'BookMaxNum'
        Rows = Read-Int $d 'CompleteRowNum'; RowMax = Read-Int $d 'RowMaxNum'
        Hours = [math]::Round($t / 3600.0, 1)
    }
}

function Is-Gvas([string]$path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    return ($b.Length -gt 4 -and $Latin1.GetString($b, 0, 4) -eq 'GVAS')
}

# ------------------------------------------------------------------ slot name and server, from the mod's logs
# "[conn] Connected to <server> as <name> (slot <n>, seed <seed>)", newest log first.
function Find-Connection([string]$seed, [int]$apSlot) {
    if (-not $MOD_DIR) { return $null }
    $dir = Join-Path $MOD_DIR 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $pat = 'Connected to (\S+) as (.+) \(slot ' + $apSlot + ', seed ' + [regex]::Escape($seed) + '\)'
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter 'AP_*.log' | Sort-Object LastWriteTime -Descending)) {
        $hit = Select-String -LiteralPath $f.FullName -Pattern $pat | Select-Object -Last 1
        if ($hit) {
            $m = $hit.Matches[0]
            return [pscustomobject]@{ Server = $m.Groups[1].Value; Name = $m.Groups[2].Value }
        }
    }
    return $null
}

function Mod-Version {
    if (-not $MOD_DIR) { return '' }
    $p = Join-Path $MOD_DIR 'Scripts\main.lua'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $hit = Select-String -LiteralPath $p -Pattern 'local MOD_VERSION = "([^"]+)"' | Select-Object -First 1
    if ($hit) { return $hit.Matches[0].Groups[1].Value }
    return ''
}

# The installed mod understands the ",moved" mark (it is what lets a save change number).
function Mod-Takes-Moved {
    if (-not $MOD_DIR) { return $false }
    $p = Join-Path $MOD_DIR 'Scripts\AP\SaveIdentity.lua'
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    return [bool](Select-String -LiteralPath $p -SimpleMatch -Pattern ',moved' -Quiet)
}

# ------------------------------------------------------------------ JSON written by hand
# The mod's own JSON reader takes plain escapes only (no \uXXXX), so nothing here goes through ConvertTo-Json.
function Json-Str([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $s.ToCharArray()) {
        switch ($c) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default { if ([int]$c -ge 32) { [void]$sb.Append($c) } }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Json-Val($v, [int]$level) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [string]) { return Json-Str $v }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single]) {
        return ([System.Convert]::ToString($v, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    $pad = '  ' * ($level + 1)
    $close = '  ' * $level
    if ($v -is [System.Collections.IDictionary] -or $v -is [pscustomobject]) {
        $pairs = @()
        if ($v -is [System.Collections.IDictionary]) { $keys = @($v.Keys) } else { $keys = @($v.PSObject.Properties.Name) }
        foreach ($k in $keys) { $pairs += $pad + (Json-Str ([string]$k)) + ': ' + (Json-Val $v.$k ($level + 1)) }
        if ($pairs.Count -eq 0) { return '{}' }
        return "{`n" + ($pairs -join ",`n") + "`n" + $close + '}'
    }
    if ($v -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($x in $v) { $items += $pad + (Json-Val $x ($level + 1)) }
        if ($items.Count -eq 0) { return '[]' }
        return "[`n" + ($items -join ",`n") + "`n" + $close + ']'
    }
    return Json-Str ([string]$v)
}

function Write-Text([string]$path, [string]$text) {
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $text, $Utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ------------------------------------------------------------------ list
function Get-Runs {
    $runs = @()
    foreach ($r in (Read-Records)) {
        if ($r.Slot -lt $SLOT_MIN -or $r.Slot -gt $SLOT_MAX) { continue }
        $folder = Save-Folder $r.Slot
        $gd = Join-Path $folder 'GameData.sav'
        $sd = Join-Path $folder 'SlotData.sav'
        $there = (Test-Path -LiteralPath $gd) -and (Test-Path -LiteralPath $sd)
        $prog = $null
        $saved = $null
        if ($there) {
            try { $prog = Read-Progress $sd } catch { $prog = $null }
            $saved = (Get-Item -LiteralPath $gd).LastWriteTime
        }
        $conn = Find-Connection $r.Seed $r.ApSlot
        $runs += [pscustomobject]@{ Record = $r; There = $there; Progress = $prog; Saved = $saved; Conn = $conn }
    }
    return $runs
}

function Show-Runs($runs) {
    if ($runs.Count -eq 0) {
        Say 'No Archipelago saves found on this PC.'
        Say ('  (looked in ' + $RECORDS + ')')
        return
    }
    Say 'Archipelago saves on this PC:'
    if ($MOD_DIR) { Say ('  (game folder: ' + $GameDir + ')') }
    Say ''
    foreach ($x in $runs) {
        $r = $x.Record
        $who = 'AP slot #' + $r.ApSlot
        if ($x.Conn) { $who = $x.Conn.Name + ' (AP slot #' + $r.ApSlot + ') on ' + $x.Conn.Server }
        Say ('  Save {0}   {1}' -f $r.Slot, $who)
        if ($x.There) {
            $p = $x.Progress
            $line = '           seed ' + $r.Seed
            if ($p) { $line += ('   {0}/{1} books shelved, {2}/{3} rows, {4} h played' -f $p.Books, $p.BookMax, $p.Rows, $p.RowMax, $p.Hours) }
            Say $line
            Say ('           last saved ' + $x.Saved.ToString('yyyy-MM-dd HH:mm'))
        } else {
            Say ('           seed ' + $r.Seed + '   (save files missing - cannot export)')
        }
    }
    $dup = $runs | Group-Object { $_.Record.Slot } | Where-Object { $_.Count -gt 1 }
    foreach ($g in $dup) {
        Say ('  Note: save {0} is listed for more than one run; only the last one to play there owns it.' -f $g.Name)
    }
    Say ''
}

# ------------------------------------------------------------------ export
function Do-Export {
    if (Game-Running) { Fail 'Close the game first: it writes your latest progress into the save when you quit.' }
    $runs = @(Get-Runs)
    Show-Runs $runs
    $ready = @($runs | Where-Object { $_.There })
    if ($ready.Count -eq 0) { Fail 'There is no AP save to export.' }
    $n = $Slot
    if ($n -eq 0) {
        if ($ready.Count -eq 1) {
            $n = $ready[0].Record.Slot
            $a = Ask ('Export save {0}? (y/n)' -f $n)
            if ($a -notmatch '^[yY]') { Fail 'Nothing exported.' }
        } else {
            $a = Ask 'Which save number do you want to export?'
            if ($a -notmatch '^\d+$') { Fail 'Nothing exported.' }
            $n = [int]$a
        }
    }
    $pick = @($ready | Where-Object { $_.Record.Slot -eq $n })
    if ($pick.Count -eq 0) { Fail ('Save {0} is not one of the AP saves listed above.' -f $n) }
    # When two records name one save, the last line is the newest claim (the mod appends when it claims).
    $x = $pick[$pick.Count - 1]
    $r = $x.Record
    if (-not $r.Layout) {
        Say 'Note: this save has no layout record yet (it is written the next time the game saves during play).'
        Say '      It will still import, but the new owner has to shelve one book before checks are sent.'
    }

    $name = ''
    $server = ''
    if ($x.Conn) { $name = $x.Conn.Name; $server = $x.Conn.Server }
    if (-not $name -and $Interactive) {
        $name = Ask 'Slot name of this run (as in your YAML; leave empty to skip)'
        $server = Ask 'Server address, e.g. archipelago.gg:38281 (leave empty to skip)'
    }

    $folder = Save-Folder $r.Slot
    $manifest = [ordered]@{
        format = $FORMAT
        what = 'Librarian-AP save'
        seed = $r.Seed
        ap_slot = $r.ApSlot
        slot_name = $name
        server = $server
        game_slot = $r.Slot
        layout = $r.Layout
        mod_version = (Mod-Version)
        exported = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    }
    if ($x.Progress) {
        $manifest.progress = [ordered]@{
            books = $x.Progress.Books; book_max = $x.Progress.BookMax
            rows = $x.Progress.Rows; row_max = $x.Progress.RowMax; hours = $x.Progress.Hours
        }
    }

    $label = $name
    if (-not $label) { $label = 'AP slot ' + $r.ApSlot }
    $file = ('Librarian-AP save - {0} - {1}.zip' -f $label, $r.Seed)
    $file = ($file.ToCharArray() | ForEach-Object { if ([System.IO.Path]::GetInvalidFileNameChars() -contains $_) { '_' } else { $_ } }) -join ''
    if ($Out -and $Out.ToLower().EndsWith('.zip')) {
        $dest = $Out
    } else {
        $dir = $Out
        if (-not $dir) { $dir = [Environment]::GetFolderPath('Desktop') }
        if (-not $dir) { $dir = (Get-Location).Path }
        $dest = Join-Path $dir $file
    }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    $zipOut = [System.IO.Compression.ZipFile]::Open($dest, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in 'GameData.sav', 'SlotData.sav') {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipOut, (Join-Path $folder $f), $f)
        }
        $e = $zipOut.CreateEntry('manifest.json')
        $w = New-Object System.IO.StreamWriter($e.Open(), $Utf8)
        $w.Write((Json-Val $manifest 0) + "`n")
        $w.Close()
    } finally { $zipOut.Dispose() }

    Say ''
    Say ('Exported save {0} to:' -f $r.Slot)
    Say ('  ' + $dest)
    Say ''
    Say 'Send that file to the new player. They run Librarian-AP_SaveShare.bat and choose Import (or drop the file on it).'
    Say 'Do not play this slot yourself after handing it over: two copies of one run drift apart.'
}

# ------------------------------------------------------------------ import
function Read-Package([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Fail ('File not found: ' + $path) }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('LibrarianAP_import_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zipIn = [System.IO.Compression.ZipFile]::OpenRead($path)
    try {
        foreach ($want in 'manifest.json', 'GameData.sav', 'SlotData.sav') {
            $e = $zipIn.Entries | Where-Object { $_.FullName -eq $want } | Select-Object -First 1
            if (-not $e) { Fail ('This is not a Librarian-AP save package (no ' + $want + ' inside).') }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $tmp $want))
        }
    } finally { $zipIn.Dispose() }
    $m = [System.IO.File]::ReadAllText((Join-Path $tmp 'manifest.json'), $Utf8) | ConvertFrom-Json
    if ($m.what -ne 'Librarian-AP save' -or [int]$m.format -gt $FORMAT) {
        Fail 'This save package is from a newer version of the tool; update the mod and try again.'
    }
    if (-not $m.seed -or [string]$m.seed -match '[|=\r\n]') { Fail 'The package has no valid seed.' }
    if ([int]$m.game_slot -lt $SLOT_MIN -or [int]$m.game_slot -gt $SLOT_MAX) { Fail 'The package names no AP save slot.' }
    if ($m.layout -and [string]$m.layout -notmatch '^\d+$') { Fail 'The package has a broken layout record.' }
    foreach ($f in 'GameData.sav', 'SlotData.sav') {
        if (-not (Is-Gvas (Join-Path $tmp $f))) { Fail ($f + ' in the package is not a game save.') }
    }
    return [pscustomobject]@{ Manifest = $m; Dir = $tmp }
}

function Slot-Free([int]$n, $recs) {
    if (Test-Path -LiteralPath (Save-Folder $n)) { return $false }
    # A record whose save is missing still names its slot: that run is waiting for its save to come back.
    foreach ($r in $recs) { if ($r.Slot -eq $n) { return $false } }
    return $true
}

function Write-Config([string]$server, [string]$name) {
    $cfg = [ordered]@{}
    if (Test-Path -LiteralPath $ConfigPath) {
        $old = [System.IO.File]::ReadAllText($ConfigPath, $Utf8) | ConvertFrom-Json
        foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    }
    if ($server) { $cfg['server'] = $server }
    if ($name) { $cfg['slot'] = $name }
    if (-not $cfg.Contains('password')) { $cfg['password'] = '' }
    Write-Text $ConfigPath ((Json-Val $cfg 0) + "`n")
}

function Do-Import([string]$path) {
    if (Game-Running) { Fail 'Close the game first, then import.' }
    if (-not $path) {
        $path = (Ask 'Path of the save zip to import (you can drag the file into this window)').Trim('"')
        if (-not $path) { Fail 'Nothing imported.' }
    }
    $pkg = Read-Package $path
    $m = $pkg.Manifest
    try {
        $seed = [string]$m.seed
        $apSlot = [int]$m.ap_slot
        $from = [int]$m.game_slot
        $who = 'AP slot #' + $apSlot
        if ($m.slot_name) { $who = [string]$m.slot_name + ' (AP slot #' + $apSlot + ')' }
        Say ('Save package: ' + $who + ', seed ' + $seed)
        if ($m.progress) {
            Say ('  {0}/{1} books shelved, {2}/{3} rows, {4} h played' -f $m.progress.books, $m.progress.book_max,
                 $m.progress.rows, $m.progress.row_max, $m.progress.hours)
        }

        $recs = @(Read-Records)
        $key = $seed + '|' + $apSlot
        $same = @($recs | Where-Object { ($_.Seed + '|' + $_.ApSlot) -eq $key })
        $others = @($recs | Where-Object { ($_.Seed + '|' + $_.ApSlot) -ne $key })
        $moved = Mod-Takes-Moved

        $to = 0
        if (Slot-Free $from $others) { $to = $from }
        elseif ($moved) {
            for ($n = $SLOT_MIN; $n -le $SLOT_MAX; $n++) { if (Slot-Free $n $others) { $to = $n; break } }
        } else {
            if ($MOD_DIR) { $why = 'the Librarian-AP mod installed here is too old to move a save to another number. Update the mod' }
            else { $why = 'the game folder was not found, so the mod cannot be asked to move it. Run this with -GameDir <game folder>' }
            Fail (('Save {0} is already used on this PC, and ' + $why + ', or free save {0}.') -f $from)
        }
        if ($to -eq 0) {
            Fail ('Every AP save slot ({0}-{1}) is in use on this PC. Delete one from the game''s Load menu, then import again.' -f $SLOT_MIN, $SLOT_MAX)
        }
        if ($Interactive) {
            $a = Ask ('Import it into save {0}? (y/n)' -f $to)
            if ($a -notmatch '^[yY]') { Fail 'Nothing imported.' }
        }

        # The save files. SlotData carries its own slot number; it is set to the new one, as the game writes it.
        $dest = Save-Folder $to
        New-Item -ItemType Directory -Path $dest | Out-Null
        Copy-Item -LiteralPath (Join-Path $pkg.Dir 'GameData.sav') -Destination (Join-Path $dest 'GameData.sav')
        $sd = [System.IO.File]::ReadAllBytes((Join-Path $pkg.Dir 'SlotData.sav'))
        if ($to -ne $from) {
            $at = Find-Prop $sd 'SlotIndex' 'IntProperty'
            if ($at -ge 0) { [Array]::Copy([BitConverter]::GetBytes([int]$to), 0, $sd, $at, 4) }
        }
        [System.IO.File]::WriteAllBytes((Join-Path $dest 'SlotData.sav'), $sd)

        # The record: every other line kept as it was, this run's line replaced.
        $line = $key + '=' + $to
        if ($m.layout) { $line += ',h' + [string]$m.layout }
        if ($moved) { $line += ',moved' }
        $keep = @()
        if (Test-Path -LiteralPath $RECORDS) {
            foreach ($raw in [System.IO.File]::ReadAllLines($RECORDS, $Utf8)) {
                $mk = [regex]::Match($raw, '^(.*?)=\d+')
                if ($mk.Success -and $mk.Groups[1].Value -eq $key) { continue }
                if ($raw.Trim() -ne '') { $keep += $raw }
            }
        }
        $keep += $line
        Write-Text $RECORDS (($keep -join "`n") + "`n")

        Say ''
        Say ('Imported into save {0}.' -f $to)
        foreach ($s in $same) {
            if ($s.Slot -ne $to -and (Test-Path -LiteralPath (Save-Folder $s.Slot))) {
                Say ('Your own earlier save for this slot (save {0}) is no longer used; delete it from the Load menu if you like.' -f $s.Slot)
            }
        }

        # Connection details, only with permission.
        $name = [string]$m.slot_name
        $server = [string]$m.server
        if (($name -or $server) -and $ConfigPath) {
            $do = $WriteConfig
            if ($do -eq 'ask') {
                $do = 'no'
                if ($Interactive) {
                    Say ''
                    $a = Ask ('Fill in the connect window with server "{0}" and slot "{1}"? (y/n)' -f $server, $name)
                    if ($a -match '^[yY]') { $do = 'yes' }
                }
            }
            if ($do -eq 'yes') {
                Write-Config $server $name
                Say 'Server and slot name written to ap_config.json (your password, if any, was left as it was).'
            }
        }
        if (-not $ConfigPath) {
            Say 'Note: the game folder was not found, so the connect details were not filled in.'
        }
        Say ''
        Say 'Start the game and connect as that slot: the mod loads the save by itself.'
        Say 'The previous owner should not play this slot any more.'
    } finally {
        Remove-Item -LiteralPath $pkg.Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ main
$code = 0
try {
    if ($Action -eq '' -and $Zip) { $Action = 'import' }
    if ($Action -eq '') {
        Say 'Librarian-AP save sharing'
        Say ''
        Say '  1  Export one of my AP saves (to hand it to someone)'
        Say '  2  Import a save someone gave me'
        Say ''
        $a = Ask 'Choose 1 or 2'
        if ($a -eq '1') { $Action = 'export' } elseif ($a -eq '2') { $Action = 'import' } else { Fail 'Nothing done.' }
        Say ''
    }
    switch ($Action) {
        'list' { Show-Runs @(Get-Runs) }
        'export' { Do-Export }
        'import' { Do-Import $Zip }
    }
} catch {
    Say ''
    Say ('Stopped: ' + $_.Exception.Message)
    if (-not $script:Expected) { Say ('  (at line ' + $_.InvocationInfo.ScriptLineNumber + ' of the script)') }
    $code = 1
}
exit $code
