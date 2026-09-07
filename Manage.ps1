[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall','Status')][string]$Action = 'Status',
    [string]$Root,
    [ValidateSet('Docker','Native')][string]$Mode,
    [string]$ComposeFile,
    [string]$Service = 'server',
    [switch]$ServerStopped
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$packageDir = $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $packageDir 'payload\manifest.json') -Raw | ConvertFrom-Json

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-FileDigest([string]$Path) { return Get-BytesHash ([IO.File]::ReadAllBytes($Path)) }
function Read-Normalized([string]$Path) { return ([IO.File]::ReadAllText($Path)).Replace("`r`n", "`n") }
function Get-NormalizedHash([string]$Path) { return Get-BytesHash ($utf8.GetBytes((Read-Normalized $Path))) }
function Get-SafePath([string]$Base, [string]$Relative) {
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\','/')
    $full = [IO.Path]::GetFullPath((Join-Path $Base $Relative))
    if (!$full.StartsWith($baseFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes installation folder: $Relative"
    }
    $probe = $full
    while ($probe -and $probe.Length -gt $baseFull.Length) {
        if ((Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Linked paths are not supported: $probe"
        }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
    return $full
}
function Ensure-Parent([string]$Path) { [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null }
function Invoke-Docker([string[]]$Arguments, [switch]$Capture) {
    if ($Capture) {
        $result = & docker @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed (exit $LASTEXITCODE)." }
        return ($result -join "`n")
    }
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed (exit $LASTEXITCODE)." }
}
function Save-State { Write-Utf8 $statePath ($script:state | ConvertTo-Json -Depth 12) }
function Get-ComposeArgs([string]$Overlay = '') {
    $argsList = @('compose','--project-directory',$Root,'-f',$script:composePath)
    if ($Overlay) { $argsList += @('-f',$Overlay) }
    return $argsList
}
function Get-ServiceContainer {
    $ids = Invoke-Docker -Arguments ((Get-ComposeArgs) + @('ps','-a','-q',$Service)) -Capture
    $list = @($ids -split '\r?\n' | Where-Object { $_.Trim() })
    if ($list.Count -ne 1) { throw 'Exactly one existing server container is required. Start the normal EveJS server first.' }
    return $list[0].Trim()
}
function Write-Overlay([string]$Path, [string]$Image) {
    # JSON is valid YAML; serialization avoids path/identifier quoting ambiguity.
    $services = @{}; $services[$Service] = @{image=$Image; pull_policy='never'}
    Write-Utf8 $Path (@{services=$services} | ConvertTo-Json -Depth 5)
}
function Wait-Healthy {
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while ([DateTime]::UtcNow -lt $deadline) {
        $cid = Get-ServiceContainer
        $info = (Invoke-Docker -Arguments @('inspect',$cid) -Capture | ConvertFrom-Json)[0]
        if ($info.State.Status -in @('exited','dead','removing')) { throw 'The server stopped during startup.' }
        if ($info.State.Health -and $info.State.Health.Status -eq 'healthy') { return }
        if (!$info.State.Health -and $info.State.Status -eq 'running') {
            Write-Warning 'This server has no healthcheck. Confirm login and command usage manually.'; return
        }
        if ($info.State.Health -and $info.State.Health.Status -eq 'unhealthy') { throw 'The server healthcheck failed.' }
        Write-Host 'Waiting for the server healthcheck...'
        Start-Sleep -Seconds 5
    }
    throw 'Server healthcheck timed out.'
}
function Assert-NativeStopped {
    if (!$ServerStopped) {
        $answer = Read-Host 'Stop the native EveJS server now, then type STOPPED to continue'
        if ($answer -cne 'STOPPED') { throw 'Cancelled. No server files changed.' }
    }
}
function Prepare-Patch([string]$OriginalDir, [string]$StageDir) {
    $version = (Get-Content -LiteralPath (Join-Path $OriginalDir 'package.json') -Raw | ConvertFrom-Json).version
    if ($version -ne $manifest.evejsVersion) { throw "Unsupported EveJS version: $version. This package supports $($manifest.evejsVersion)." }
    $records = @()
    foreach ($entry in $manifest.files) {
        $src = Get-SafePath $OriginalDir $entry.path
        if ((Get-NormalizedHash $src) -ne $entry.originalHash) {
            throw "Compatibility check failed: $($entry.path). This file is modified or from a different release. No patch applied."
        }
        $text = Read-Normalized $src
        foreach ($edit in $entry.edits) {
            if ([regex]::Matches($text,[regex]::Escape($edit.find)).Count -ne 1) { throw "Patch anchor mismatch: $($entry.path)" }
            $text = $text.Replace($edit.find,$edit.replace)
        }
        $dst = Get-SafePath $StageDir $entry.path
        Ensure-Parent $dst; Write-Utf8 $dst $text
        if ((Get-FileDigest $dst) -ne $entry.patchedHash) { throw "Patched file validation failed: $($entry.path)" }
        $records += @{path=$entry.path; originalHash=(Get-FileDigest $src); patchedHash=$entry.patchedHash}
    }
    $helper = Join-Path $packageDir ('payload\' + $manifest.added.file)
    if ((Get-FileDigest $helper) -ne $manifest.added.sha256) { throw 'Package payload checksum failed.' }
    $helperDst = Get-SafePath $StageDir $manifest.added.path
    Ensure-Parent $helperDst; [IO.File]::Copy($helper,$helperDst,$false)
    return $records
}

try {
    if (!$Root) {
        $toolsFolder = Split-Path -Parent $packageDir
        $candidateRoot = Split-Path -Parent $toolsFolder
        if ((Split-Path -Leaf $toolsFolder) -ieq 'tools' -and
            (Test-Path -LiteralPath (Join-Path $candidateRoot 'package.json')) -and
            (Test-Path -LiteralPath (Join-Path $candidateRoot 'server') -PathType Container)) {
            $Root = $candidateRoot
            Write-Host "EveJS installation: $Root"
        }
    }
    if (!$Root) { $Root = (Read-Host 'EveJS installation folder (for example E:\)').Trim().Trim('"') }
    if (!$Root -or !(Test-Path -LiteralPath $Root -PathType Container)) { throw 'EveJS folder does not exist.' }
    $Root = (Resolve-Path -LiteralPath $Root).ProviderPath
    $stateDir = Get-SafePath $Root '.autominingdrones'
    $statePath = Join-Path $stateDir 'state.json'
    $script:state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
    if ($state -and $state.root -ne $Root) { throw 'Recorded installation path differs. Use the original installation folder.' }

    if ($Action -eq 'Status') {
        if (!$state) { Write-Host 'AutoMiningDrones is not installed in this folder.'; exit 0 }
        Write-Host "AutoMiningDrones $($state.version): $($state.status) ($($state.mode))"
        if ($state.mode -eq 'Native' -and $state.status -eq 'installed') {
            foreach ($record in $state.files) {
                $p = Get-SafePath $Root $record.path
                if (!(Test-Path -LiteralPath $p) -or (Get-FileDigest $p) -ne $record.patchedHash) { throw "File changed: $($record.path). Do not restore old files over an EveJS update." }
            }
            $p = Get-SafePath $Root $state.addedPath
            if (!(Test-Path -LiteralPath $p) -or (Get-FileDigest $p) -ne $state.addedHash) { throw 'Runtime helper is missing or modified.' }
            Write-Host 'Installed file checksums match.'
        }
        if ($state.mode -eq 'Docker' -and $state.status -eq 'installed') {
            $script:composePath=$state.compose; $Service=$state.service
            $cid=Get-ServiceContainer
            $current=Invoke-Docker -Arguments @('inspect','--format','{{.Image}}',$cid) -Capture
            if ($current.Trim() -ne $state.patchedImageID) { throw 'The running server image differs from the installed patch image.' }
            Write-Host 'The server uses the patch image.'
        }
        exit 0
    }

    if ($Action -eq 'Uninstall') {
        if (!$state -or $state.status -eq 'uninstalled') { Write-Host 'Nothing to uninstall.'; exit 0 }
        if ($state.mode -eq 'Native') {
            Assert-NativeStopped
            foreach ($record in $state.files) {
                $p=Get-SafePath $Root $record.path
                $backup=Get-SafePath $state.originalDir $record.path
                if ((Get-FileDigest $p) -ne $record.patchedHash) { throw "Refusing to overwrite a changed file: $($record.path). Restore/merge it manually using the retained backup." }
                if ((Get-FileDigest $backup) -ne $record.originalHash) { throw 'An original-file backup failed its checksum.' }
            }
            $helper=Get-SafePath $Root $state.addedPath
            if ((Get-FileDigest $helper) -ne $state.addedHash) { throw 'Runtime helper was modified. Uninstall stopped.' }
            foreach ($record in $state.files) {
                if ((Get-FileDigest (Get-SafePath $state.stageDir $record.path)) -ne $record.patchedHash) { throw 'Rollback-stage checksum failed. Uninstall stopped before changing files.' }
            }
            if ((Get-FileDigest (Get-SafePath $state.stageDir $state.addedPath)) -ne $state.addedHash) { throw 'Rollback helper checksum failed.' }
            try {
                foreach ($record in $state.files) { [IO.File]::Copy((Get-SafePath $state.originalDir $record.path),(Get-SafePath $Root $record.path),$true) }
                Remove-Item -LiteralPath $helper
                foreach ($record in $state.files) { if ((Get-FileDigest (Get-SafePath $Root $record.path)) -ne $record.originalHash) { throw 'Restore verification failed.' } }
            } catch {
                $restoreFailure=$_
                try {
                    foreach ($record in $state.files) { [IO.File]::Copy((Get-SafePath $state.stageDir $record.path),(Get-SafePath $Root $record.path),$true) }
                    [IO.File]::Copy((Get-SafePath $state.stageDir $state.addedPath),$helper,$true)
                } catch { $state.status='recovery-required'; Save-State; Write-Warning 'Uninstall rollback failed. Keep the server stopped and retain .autominingdrones for recovery.' }
                throw $restoreFailure
            }
        } else {
            $script:composePath=$state.compose; $Service=$state.service
            $cid=Get-ServiceContainer
            $current=(Invoke-Docker -Arguments @('inspect','--format','{{.Image}}',$cid) -Capture).Trim()
            if ($current -ne $state.patchedImageID -and $current -ne $state.baseImageID) { throw 'Server image changed after installation. Refusing to replace a newer or unrelated image.' }
            Invoke-Docker -Arguments ((Get-ComposeArgs $state.restoreOverlay) + @('up','-d','--no-deps','--force-recreate',$Service))
            Wait-Healthy
        }
        $state.status='uninstalled'; Save-State
        Write-Host 'Uninstalled. Original server code restored. Backups are retained in .autominingdrones.'
        if ($state.mode -eq 'Native') { Write-Host 'Start the native EveJS server normally.' }
        exit 0
    }

    if ($state -and $state.status -ne 'uninstalled') { throw "Existing patch state: $($state.status). Run Status or Uninstall before installing again." }
    if (!$Mode) {
        $choice=Read-Host 'Installation type: D for Docker, N for native Node.js'
        if ($choice -match '^(?i:d|docker)$') { $Mode='Docker' }
        elseif ($choice -match '^(?i:n|native)$') { $Mode='Native' }
        else { throw 'Choose Docker or Native.' }
    }
    if ($Mode -eq 'Native') { Assert-NativeStopped }
    $transaction=[Guid]::NewGuid().ToString('N')
    $txDir=Get-SafePath $stateDir ('backups\' + $transaction)
    $originalDir=Join-Path $txDir 'original'; $stageDir=Join-Path $txDir 'stage'
    [IO.Directory]::CreateDirectory($originalDir) | Out-Null
    [IO.Directory]::CreateDirectory($stageDir) | Out-Null
    $baseImageID=$null; $baseTag=$null; $patchTag=$null
    if ($Mode -eq 'Native') {
        foreach ($relative in @('package.json') + @($manifest.files | ForEach-Object {$_.path})) {
            $src=Get-SafePath $Root $relative; $dst=Get-SafePath $originalDir $relative
            Ensure-Parent $dst; [IO.File]::Copy($src,$dst,$false)
        }
        if (Test-Path -LiteralPath (Get-SafePath $Root $manifest.added.path)) { throw 'Runtime helper already exists. No files overwritten.' }
    } else {
        Get-Command docker -ErrorAction Stop | Out-Null
        if (!$ComposeFile) {
            foreach ($candidate in @('compose.yaml','compose.yml','docker-compose.yml','docker-compose.yaml')) {
                if (Test-Path -LiteralPath (Join-Path $Root $candidate)) { $ComposeFile=Join-Path $Root $candidate; break }
            }
        }
        if (!$ComposeFile) { throw 'Compose file not found. Supply -ComposeFile with its full path.' }
        $script:composePath=(Resolve-Path -LiteralPath $ComposeFile).ProviderPath
        $cfg=Invoke-Docker -Arguments ((Get-ComposeArgs) + @('config','--format','json')) -Capture | ConvertFrom-Json
        if (!$cfg.services.$Service) { throw "Compose service not found: $Service" }
        foreach ($mount in $cfg.services.$Service.volumes) {
            if ($mount.target -eq '/app' -or $mount.target -eq '/app/server' -or $mount.target -like '/app/server/src*') {
                # Unrelated, narrower generated-image/certificate mounts are allowed.
                if ($mount.target -in @('/app','/app/server','/app/server/src','/app/server/src/services') -or $mount.target -like '/app/server/src/services/drone*' -or $mount.target -like '/app/server/src/services/chat*') {
                    throw 'A bind mount covers patched server code. This Docker layout is not supported.'
                }
            }
        }
        $cid=Get-ServiceContainer
        $baseImageID=(Invoke-Docker -Arguments @('inspect','--format','{{.Image}}',$cid) -Capture).Trim()
        foreach ($relative in @('package.json') + @($manifest.files | ForEach-Object {$_.path})) {
            $dst=Get-SafePath $originalDir $relative; Ensure-Parent $dst
            Invoke-Docker -Arguments @('cp',($cid + ':/app/' + $relative),$dst)
        }
        $baseTag='autominingdrones-base:' + $transaction
        $patchTag='autominingdrones:1.1.0-' + $transaction
    }
    $records=@(Prepare-Patch $originalDir $stageDir)
    $script:state=@{version=$manifest.version; root=$Root; mode=$Mode; status='prepared'; originalDir=$originalDir; stageDir=$stageDir; files=$records; addedPath=$manifest.added.path; addedHash=$manifest.added.sha256; service=$Service; compose=$script:composePath; baseImageID=$baseImageID; baseTag=$baseTag; patchedImageID=''; patchTag=$patchTag; overlay=(Join-Path $txDir 'compose.patch.json'); restoreOverlay=(Join-Path $txDir 'compose.original.json')}
    Save-State
    try {
        if ($Mode -eq 'Native') {
            foreach ($record in $records) { [IO.File]::Copy((Get-SafePath $stageDir $record.path),(Get-SafePath $Root $record.path),$true) }
            [IO.File]::Copy((Get-SafePath $stageDir $state.addedPath),(Get-SafePath $Root $state.addedPath),$false)
        } else {
            Invoke-Docker -Arguments @('tag',$baseImageID,$baseTag)
            $df="FROM $baseTag`n"
            foreach ($relative in @($manifest.files | ForEach-Object {$_.path}) + @($manifest.added.path)) { $df += "COPY --chown=node:node $relative /app/$relative`n" }
            $df += "RUN node --check /app/server/src/services/drone/droneRuntime.js && node --check /app/server/src/services/drone/autoMiningDrones.js && node --check /app/server/src/services/chat/chatCommands.js`n"
            Write-Utf8 (Join-Path $stageDir 'Dockerfile') $df
            Invoke-Docker -Arguments @('build','--pull=false','-t',$patchTag,$stageDir)
            $state.patchedImageID=(Invoke-Docker -Arguments @('image','inspect','--format','{{.Id}}',$patchTag) -Capture).Trim()
            Write-Overlay $state.overlay $patchTag
            Write-Overlay $state.restoreOverlay $baseTag
            Save-State
            Invoke-Docker -Arguments ((Get-ComposeArgs $state.overlay) + @('up','-d','--no-deps','--force-recreate',$Service))
            Wait-Healthy
        }
        $state.status='installed'; Save-State
    } catch {
        $failure=$_
        Write-Warning 'Installation failed. Attempting to restore the original server.'
        try {
            if ($Mode -eq 'Native') {
                foreach ($record in $records) { [IO.File]::Copy((Get-SafePath $originalDir $record.path),(Get-SafePath $Root $record.path),$true) }
                $helper=Get-SafePath $Root $state.addedPath
                if ((Test-Path -LiteralPath $helper) -and (Get-FileDigest $helper) -eq $state.addedHash) { Remove-Item -LiteralPath $helper }
            } elseif (Test-Path -LiteralPath $state.restoreOverlay) {
                Invoke-Docker -Arguments ((Get-ComposeArgs $state.restoreOverlay) + @('up','-d','--no-deps','--force-recreate',$Service))
                Wait-Healthy
            }
            $state.status='uninstalled'; Save-State
        } catch { $state.status='recovery-required'; Save-State; Write-Warning "Automatic restore failed: $_. Retained state: $statePath" }
        throw $failure
    }
    Write-Host 'AutoMiningDrones installed successfully.'
    if ($Mode -eq 'Native') { Write-Host 'Start the native EveJS server normally.' }
    Write-Host 'In game: launch mining drones, then use /autominingdrones on with a staff/GM character.'
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
