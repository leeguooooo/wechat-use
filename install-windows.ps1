param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\wechat-use'),
    [string]$SkillDir,
    [switch]$NoPath
)
$ErrorActionPreference = 'Stop'
$tag = 'windows-v0.1.0'
$name = "wechat-use-$tag-x64.zip"
$base = "https://github.com/leeguooooo/wechat-use/releases/download/$tag"
$temp = Join-Path ([IO.Path]::GetTempPath()) ('wechat-use-install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $zip = Join-Path $temp $name
    $checksum = Join-Path $temp ($name + '.sha256')
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $zip
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$name.sha256" -OutFile $checksum
    $expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
    if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) { throw 'Download checksum mismatch; installation stopped.' }
    $unpacked = Join-Path $temp 'package'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
    $arguments = @{ InstallDir = $InstallDir; NoPath = $NoPath }
    if ($SkillDir) { $arguments.SkillDir = $SkillDir }
    & (Join-Path $unpacked 'install.ps1') @arguments
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
