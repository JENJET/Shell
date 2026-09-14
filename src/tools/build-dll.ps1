param(
	[ValidateSet('x64', 'x86', 'ARM64')]
	[string]$Platform = 'x64',
	[string]$Configuration = 'release',
	[switch]$Deploy,
	[Alias('h', '?', 'help')]
	[switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage
{
	Write-Host "build-dll.ps1 - Build NileSoftShell shell.dll with MSBuild."
	Write-Host ""
	Write-Host "Usage:"
	Write-Host "  .\build-dll.ps1 [-Platform {x64|x86|ARM64}] [-Configuration <name>] [-Deploy] [-h]"
	Write-Host ""
	Write-Host "Parameters:"
	Write-Host "  -Platform <name>       Target platform: x64 (default), x86 or ARM64."
	Write-Host "  -Configuration <name>  Build configuration. Default: release."
	Write-Host "  -Deploy                Deploy the built shell.dll afterwards (calls deploy-shell.ps1)."
	Write-Host "  -h, -help, -?          Show this help text."
}

if($ShowHelp)
{
	Show-Usage
	exit 0
}

$srcRoot = Split-Path -Parent $PSScriptRoot
$solution = Join-Path $srcRoot 'Shell.sln'
$dllPath = Join-Path $srcRoot 'bin\shell.dll'

if(!(Test-Path -LiteralPath $solution -PathType Leaf))
{
	throw "Solution not found: $solution"
}

function Get-VsInstallPath
{
	$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
	if(!(Test-Path -LiteralPath $vswhere -PathType Leaf))
	{
		throw "vswhere.exe not found: $vswhere"
	}

	$paths = @(& $vswhere -all -products * -property installationPath)
	foreach($candidate in $paths)
	{
		if([string]::IsNullOrWhiteSpace($candidate))
		{
			continue
		}

		$msvcRoot = Join-Path $candidate.Trim() 'VC\Tools\MSVC'
		if(!(Test-Path -LiteralPath $msvcRoot -PathType Container))
		{
			continue
		}

		$hasCl = Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue |
			Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe') -PathType Leaf }
		if($hasCl)
		{
			return $candidate.Trim()
		}
	}

	throw "Visual Studio installation with cl.exe not found."
}

function Get-MsBuildPath($vsPath)
{
	$candidates = @(
		(Join-Path $vsPath 'MSBuild\Current\Bin\amd64\MSBuild.exe'),
		(Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe')
	)

	foreach($candidate in $candidates)
	{
		if(Test-Path -LiteralPath $candidate -PathType Leaf)
		{
			return $candidate
		}
	}

	throw "MSBuild.exe not found under $vsPath"
}

function Get-VcToolsVersion($vsPath)
{
	$msvcRoot = Join-Path $vsPath 'VC\Tools\MSVC'
	if(!(Test-Path -LiteralPath $msvcRoot -PathType Container))
	{
		throw "MSVC tools not found: $msvcRoot"
	}

	$found = Get-ChildItem -LiteralPath $msvcRoot -Directory |
		Sort-Object Name -Descending |
		Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe') -PathType Leaf } |
		Select-Object -First 1

	if(-not $found)
	{
		throw "No MSVC toolset with cl.exe found under $msvcRoot"
	}

	return $found.Name
}

function Get-WindowsSdkVersion
{
	$libRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
	if(!(Test-Path -LiteralPath $libRoot -PathType Container))
	{
		throw "Windows Kits Lib not found: $libRoot"
	}

	$arch = switch($Platform)
	{
		'x86' { 'x86' }
		'ARM64' { 'arm64' }
		default { 'x64' }
	}

	$found = Get-ChildItem -LiteralPath $libRoot -Directory |
		Sort-Object Name -Descending |
		Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "um\$arch") -PathType Container } |
		Select-Object -First 1

	if(-not $found)
	{
		throw "No Windows SDK with um\$arch libraries found under $libRoot"
	}

	return $found.Name
}

function Get-PlatformToolset($vsPath)
{
	$toolsetRoots = @(
		(Join-Path $vsPath 'MSBuild\Microsoft\VC\v180\Platforms\x64\PlatformToolsets'),
		(Join-Path $vsPath 'MSBuild\Microsoft\VC\v170\Platforms\x64\PlatformToolsets')
	)

	foreach($root in $toolsetRoots)
	{
		if(!(Test-Path -LiteralPath $root -PathType Container))
		{
			continue
		}

		foreach($name in @('v145', 'v143', 'v142'))
		{
			if(Test-Path -LiteralPath (Join-Path $root $name) -PathType Container)
			{
				return $name
			}
		}
	}

	return 'v143'
}

function Get-VcVarsArch
{
	switch($Platform)
	{
		'x86' { 'x86' }
		'ARM64' { 'x64_arm64' }
		default { 'x64' }
	}
}

$vsPath = Get-VsInstallPath
$msbuild = Get-MsBuildPath $vsPath
$vcTools = Get-VcToolsVersion $vsPath
$sdk = Get-WindowsSdkVersion
$toolset = Get-PlatformToolset $vsPath
$vcvarsall = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'

if(!(Test-Path -LiteralPath $vcvarsall -PathType Leaf))
{
	throw "vcvarsall.bat not found: $vcvarsall"
}

Write-Host "VS      : $vsPath"
Write-Host "MSBuild : $msbuild"
Write-Host "MSVC    : $vcTools"
Write-Host "SDK     : $sdk"
Write-Host "Toolset : $toolset"
Write-Host "Building dll ($Configuration|$Platform)..."

$msbuildArgs = @(
	"`"$solution`"",
	'/t:dll',
	'/m',
	'/v:minimal',
	"/p:Configuration=$Configuration",
	"/p:Platform=$Platform",
	"/p:WindowsTargetPlatformVersion=$sdk",
	"/p:PlatformToolset=$toolset",
	"/p:VCToolsVersion=$vcTools"
) -join ' '

$vcArch = Get-VcVarsArch
$buildCmd = "call `"$vcvarsall`" $vcArch $sdk -vcvars_ver=$vcTools && `"$msbuild`" $msbuildArgs"
$cmdExit = 0
cmd.exe /c $buildCmd
$cmdExit = $LASTEXITCODE
if($cmdExit -ne 0)
{
	throw "Build failed with exit code $cmdExit"
}

if(!(Test-Path -LiteralPath $dllPath -PathType Leaf))
{
	throw "Build finished but DLL not found: $dllPath"
}

Get-Item -LiteralPath $dllPath | Select-Object FullName, Length, LastWriteTime
Get-FileHash -Algorithm SHA256 -LiteralPath $dllPath | Select-Object Path, Hash

if($Deploy)
{
	& (Join-Path $PSScriptRoot 'deploy-shell.ps1')
}
