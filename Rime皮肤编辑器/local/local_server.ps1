param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
  [int]$Port = 0,
  [int]$IdleTimeoutMs = 60000,
  [switch]$NoIdleExit
)

$ErrorActionPreference = 'Stop'
$BackupRoot = 'Rime皮肤编辑器备份'
$StaticRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$TokenBytes = New-Object byte[] 18
[System.Security.Cryptography.RandomNumberGenerator]::Fill($TokenBytes)
$Token = -join ($TokenBytes | ForEach-Object { $_.ToString('x2') })

function Resolve-AllowedPath {
  param([string]$RequestedPath)
  if ([string]::IsNullOrWhiteSpace($RequestedPath) -or $RequestedPath.StartsWith('/') -or $RequestedPath.StartsWith('\') -or $RequestedPath.Contains([char]0)) {
    throw '不允许访问这个路径。'
  }
  $Parts = @($RequestedPath -replace '\\','/' -split '/' | Where-Object { $_ })
  if ($Parts -contains '..') { throw '不允许访问这个路径。' }
  $IsFrontendFile = $Parts.Count -eq 1 -and @('squirrel.custom.yaml', 'weasel.custom.yaml', 'default.custom.yaml') -contains $Parts[0]
  $IsCustomFile = $Parts.Count -eq 1 -and $Parts[0].EndsWith('.custom.yaml')
  $IsSchemaFile = $Parts.Count -eq 1 -and $Parts[0].EndsWith('.schema.yaml')
  $IsBackupFile = $Parts.Count -ge 2 -and $Parts[0] -eq $BackupRoot
  if (-not ($IsFrontendFile -or $IsCustomFile -or $IsSchemaFile -or $IsBackupFile)) { throw '不允许访问这个路径。' }
  $TargetPath = $Root
  foreach ($Part in $Parts) {
    $TargetPath = Join-Path $TargetPath $Part
  }
  $Target = [System.IO.Path]::GetFullPath($TargetPath)
  $RootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  if ($Target -ne $RootFull -and -not $Target.StartsWith($RootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '不允许访问这个路径。'
  }
  return $Target
}

function Get-QueryValue {
  param($Request, [string]$Name)
  $Query = $Request.Url.Query
  if ($Query.StartsWith('?')) { $Query = $Query.Substring(1) }
  foreach ($Pair in $Query -split '&') {
    if ([string]::IsNullOrWhiteSpace($Pair)) { continue }
    $Parts = $Pair -split '=', 2
    $Key = [Uri]::UnescapeDataString($Parts[0].Replace('+', ' '))
    if ($Key -ne $Name) { continue }
    if ($Parts.Count -lt 2) { return '' }
    return [Uri]::UnescapeDataString($Parts[1].Replace('+', ' '))
  }
  return ''
}

function Send-Json {
  param($Response, [int]$Status, $Value)
  $Json = ConvertTo-Json $Value -Depth 20 -Compress
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
  $Response.StatusCode = $Status
  $Response.ContentType = 'application/json; charset=utf-8'
  $Response.Headers['cache-control'] = 'no-store'
  $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $Response.Close()
}

function Read-BodyJson {
  param($Request)
  $Reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
  $Text = $Reader.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($Text)) { return @{} }
  return $Text | ConvertFrom-Json
}

function Get-ConfigSnapshot {
  $RawFiles = @{}
  $FileExists = @{}
  foreach ($Item in @(
    @('squirrel', 'squirrel.custom.yaml'),
    @('weasel', 'weasel.custom.yaml'),
    @('default', 'default.custom.yaml')
  )) {
    $Path = Resolve-AllowedPath $Item[1]
    $Exists = Test-Path $Path -PathType Leaf
    $FileExists[$Item[0]] = $Exists
    $RawFiles[$Item[0]] = if ($Exists) { Get-Content $Path -Raw -Encoding UTF8 } else { '' }
  }
  return @{
    folderName = Split-Path $Root -Leaf
    rootPath = [System.IO.Path]::GetFullPath($Root)
    rawFiles = $RawFiles
    fileExists = $FileExists
    customFiles = @(Get-RootCustomFiles)
    hasAnySchemaFile = [bool](Get-ChildItem $Root -File -Filter '*.schema.yaml' -ErrorAction SilentlyContinue | Select-Object -First 1)
  }
}

function Get-RootCustomFiles {
  $FrontendFiles = @('squirrel.custom.yaml', 'weasel.custom.yaml', 'default.custom.yaml')
  $Items = @()
  foreach ($File in Get-ChildItem $Root -File -Filter '*.custom.yaml' -ErrorAction SilentlyContinue | Sort-Object Name) {
    if ($FrontendFiles -contains $File.Name) { continue }
    $Path = Resolve-AllowedPath $File.Name
    $Items += @{ name = $File.Name; text = Get-Content $Path -Raw -Encoding UTF8 }
  }
  return $Items
}

function Get-Backups {
  $BackupDir = Join-Path $Root $BackupRoot
  if (-not (Test-Path $BackupDir -PathType Container)) { return @() }
  $Items = @()
  foreach ($Dir in Get-ChildItem $BackupDir -Directory) {
    $Files = @(Get-ChildItem $Dir.FullName -File | ForEach-Object { $_.Name } | Sort-Object)
    $ManifestPath = Join-Path $Dir.FullName 'manifest.json'
    $Manifest = Read-Manifest $ManifestPath
    $Items += @{ name = $Dir.Name; manifest = $Manifest; availableFiles = $Files }
  }
  return @($Items | Sort-Object name -Descending)
}

function Remove-Backup {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq '.' -or $Name -eq '..' -or $Name.Contains('/') -or $Name.Contains('\') -or $Name.Contains([char]0)) {
    throw '不允许访问这个路径。'
  }
  $Marker = Resolve-AllowedPath "$BackupRoot/$Name/manifest.json"
  $BackupDir = Split-Path $Marker -Parent
  if (Test-Path $BackupDir -PathType Container) {
    Remove-Item $BackupDir -Recurse -Force
  }
}

function Read-Manifest {
  param([string]$ManifestPath)
  if (-not (Test-Path $ManifestPath -PathType Leaf)) { return $null }
  try {
    return Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    return $null
  }
}

$Listener = $null
$ActualPort = $Port
$PortsToTry = if ($Port -gt 0) { @($Port) } else { 17890..17920 }
foreach ($CandidatePort in $PortsToTry) {
  try {
    $Candidate = [System.Net.HttpListener]::new()
    $Candidate.Prefixes.Add("http://localhost:$CandidatePort/")
    $Candidate.Start()
    $Listener = $Candidate
    $ActualPort = $CandidatePort
    break
  } catch {
    if ($Candidate) { $Candidate.Close() }
  }
}
if (-not $Listener) {
  throw '无法启动本地服务：17890-17920 端口都不可用。'
}
$Url = "http://localhost:$ActualPort/?token=$Token"
$LastSeen = Get-Date
Write-Host "Rime 皮肤编辑器已启动：$Url"
Write-Host "配置目录：$Root"
Write-Host "关闭这个窗口即可停止本地服务。"
Start-Process $Url

while ($Listener.IsListening) {
  $AsyncResult = $Listener.BeginGetContext($null, $null)
  while (-not $AsyncResult.AsyncWaitHandle.WaitOne(500)) {
    if (-not $NoIdleExit -and $IdleTimeoutMs -gt 0 -and ((Get-Date) - $LastSeen).TotalMilliseconds -ge $IdleTimeoutMs) {
      $Listener.Stop()
      break
    }
  }
  if (-not $Listener.IsListening) { break }
  $Context = $Listener.EndGetContext($AsyncResult)
  try {
    $Request = $Context.Request
    $Response = $Context.Response
    $Path = $Request.Url.AbsolutePath
    if ($Path.StartsWith('/api/')) {
      if ($Request.Headers['x-rime-editor-token'] -ne $Token) {
        $QueryToken = Get-QueryValue $Request 'token'
      } else {
        $QueryToken = $Token
      }
      if ($QueryToken -ne $Token) {
        Send-Json $Response 403 @{ error = '访问令牌无效。' }
        continue
      }
      $LastSeen = Get-Date
      if ($Request.HttpMethod -eq 'POST' -and $Path -eq '/api/ping') {
        Send-Json $Response 200 @{ ok = $true }
        continue
      }
      if ($Request.HttpMethod -eq 'POST' -and $Path -eq '/api/close') {
        Send-Json $Response 200 @{ ok = $true }
        $Listener.Stop()
        break
      }
      if ($Request.HttpMethod -eq 'GET' -and $Path -eq '/api/config') {
        Send-Json $Response 200 (Get-ConfigSnapshot)
        continue
      }
      if ($Request.HttpMethod -eq 'GET' -and $Path -eq '/api/backups') {
        Send-Json $Response 200 @{ backups = Get-Backups }
        continue
      }
      if ($Request.HttpMethod -eq 'DELETE' -and $Path -eq '/api/backup') {
        Remove-Backup (Get-QueryValue $Request 'name')
        Send-Json $Response 200 @{ ok = $true }
        continue
      }
      if ($Request.HttpMethod -eq 'GET' -and $Path -eq '/api/file') {
        $FilePath = Resolve-AllowedPath (Get-QueryValue $Request 'path')
        if (-not (Test-Path $FilePath -PathType Leaf)) {
          Send-Json $Response 404 @{ error = '文件不存在。' }
          continue
        }
        Send-Json $Response 200 @{ exists = $true; text = Get-Content $FilePath -Raw -Encoding UTF8 }
        continue
      }
      if ($Request.HttpMethod -eq 'PUT' -and $Path -eq '/api/file') {
        $Body = Read-BodyJson $Request
        $FilePath = Resolve-AllowedPath $Body.path
        New-Item -ItemType Directory -Force -Path (Split-Path $FilePath -Parent) | Out-Null
        Set-Content -Path $FilePath -Value ([string]$Body.text) -Encoding UTF8 -NoNewline
        Send-Json $Response 200 @{ ok = $true }
        continue
      }
      if ($Request.HttpMethod -eq 'DELETE' -and $Path -eq '/api/file') {
        $FilePath = Resolve-AllowedPath (Get-QueryValue $Request 'path')
        if (Test-Path $FilePath -PathType Leaf) { Remove-Item $FilePath -Force }
        Send-Json $Response 200 @{ ok = $true }
        continue
      }
      if ($Request.HttpMethod -eq 'POST' -and $Path -eq '/api/mkdir') {
        $Body = Read-BodyJson $Request
        $Marker = Resolve-AllowedPath "$($Body.path)/manifest.json"
        New-Item -ItemType Directory -Force -Path (Split-Path $Marker -Parent) | Out-Null
        Send-Json $Response 200 @{ ok = $true }
        continue
      }
      Send-Json $Response 404 @{ error = '接口不存在。' }
      continue
    }

    $Relative = if ($Path -eq '/') { 'index.html' } else { [Uri]::UnescapeDataString($Path.TrimStart('/')) }
    $StaticPath = [System.IO.Path]::GetFullPath((Join-Path $StaticRoot $Relative))
    $StaticRootFull = [System.IO.Path]::GetFullPath($StaticRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (($StaticPath -ne $StaticRootFull -and -not $StaticPath.StartsWith($StaticRootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) -or -not (Test-Path $StaticPath -PathType Leaf)) {
      $Response.StatusCode = 404
      $Response.Close()
      continue
    }
    $Bytes = [System.IO.File]::ReadAllBytes($StaticPath)
    $Response.Headers['cache-control'] = 'no-store'
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.Close()
  } catch {
    Send-Json $Context.Response 400 @{ error = $_.Exception.Message }
  }
}
