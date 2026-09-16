param(
	[ValidateSet('x64', 'x86', 'ARM64')]
	[string]$Platform = 'x64',
	[string]$Configuration = 'release',
	[string]$Destination = 'D:\Softs\NileSoftShell\shell.dll',
	[switch]$NoDeploy,
	[Alias('h', '?', 'help')]
	[switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage
{
	Write-Host "build.ps1 - Build NileSoftShell (default: release /O2) and deploy shell.dll."
	Write-Host ""
	Write-Host "Usage:"
	Write-Host "  .\build.cmd [-Platform {x64|x86|ARM64}] [-Configuration <name>] [-Destination <path>] [-NoDeploy] [-h]"
	Write-Host ""
	Write-Host "Parameters:"
	Write-Host "  -Platform <name>       Target platform: x64 (default), x86 or ARM64."
	Write-Host "  -Configuration <name>  Build configuration. Default: release."
	Write-Host "  -Destination <path>    Deploy path. Default: D:\Softs\NileSoftShell\shell.dll."
	Write-Host "  -NoDeploy              Build only, do not replace the installed shell.dll."
	Write-Host "  -h, -help, -?          Show this help text."
}

if($ShowHelp)
{
	Show-Usage
	exit 0
}

$srcRoot = Join-Path $PSScriptRoot 'src'
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

function Get-FullPath($path)
{
	if([System.IO.Path]::IsPathRooted($path))
	{
		return [System.IO.Path]::GetFullPath($path)
	}

	return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $path))
}

function Get-ProcessUsingModule($modulePath)
{
	Get-Process | ForEach-Object {
		$process = $_
		try
		{
			if($process.Modules | Where-Object { $_.FileName -ieq $modulePath })
			{
				$process
			}
		}
		catch
		{
		}
	}
}

function Get-ProcessCommandLine($processId)
{
	try
	{
		$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $processId"
		if($processInfo)
		{
			return $processInfo.CommandLine
		}
	}
	catch
	{
	}

	return $null
}

function Get-CommandLineArguments($commandLine, $executablePath)
{
	if([string]::IsNullOrWhiteSpace($commandLine))
	{
		return $null
	}

	$trimmed = $commandLine.Trim()
	if($trimmed.StartsWith('"'))
	{
		$endQuote = $trimmed.IndexOf('"', 1)
		if($endQuote -ge 0)
		{
			return $trimmed.Substring($endQuote + 1).Trim()
		}
	}

	if($trimmed.Length -ge $executablePath.Length -and
	   $trimmed.Substring(0, $executablePath.Length) -ieq $executablePath)
	{
		return $trimmed.Substring($executablePath.Length).Trim()
	}

	return $null
}

function Show-OutputInfo($path)
{
	Get-Item -LiteralPath $path | Select-Object FullName, Length, LastWriteTime
	Get-FileHash -Algorithm SHA256 -LiteralPath $path | Select-Object Path, Hash
}

function Deploy-ShellDll($sourcePath, $destinationPath)
{
	$destinationDir = Split-Path -Path $destinationPath -Parent
	if(!(Test-Path -LiteralPath $destinationDir -PathType Container))
	{
		throw "Destination directory not found: $destinationDir"
	}

	$copied = $false
	$stoppedProcesses = @{}
	$attempts = 20
	$delayMilliseconds = 300

	for($i = 0; $i -lt $attempts -and !$copied; $i++)
	{
		$holders = @(Get-ProcessUsingModule $destinationPath)
		foreach($holder in $holders)
		{
			$holderPath = $null
			try
			{
				$holderPath = $holder.Path
			}
			catch
			{
			}

			if($holderPath -and !$stoppedProcesses.ContainsKey($holderPath))
			{
				$commandLine = Get-ProcessCommandLine $holder.Id
				$stoppedProcesses[$holderPath] = [PSCustomObject]@{
					ProcessName = $holder.ProcessName
					Path = $holderPath
					Arguments = Get-CommandLineArguments $commandLine $holderPath
				}
			}

			Write-Host "Stopping process using shell.dll: $($holder.ProcessName) ($($holder.Id))"
			Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
		}

		Start-Sleep -Milliseconds 200

		try
		{
			Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
			$copied = $true
		}
		catch
		{
			if($i + 1 -ge $attempts)
			{
				throw "Failed to replace $destinationPath because it is still locked."
			}

			Start-Sleep -Milliseconds $delayMilliseconds
		}
	}

	if(!(Get-Process -Name explorer -ErrorAction SilentlyContinue))
	{
		Start-Process explorer.exe
	}

	foreach($record in $stoppedProcesses.Values)
	{
		if($record.ProcessName -ieq 'explorer')
		{
			continue
		}

		if(!(Test-Path -LiteralPath $record.Path -PathType Leaf))
		{
			continue
		}

		$alreadyRunning = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
			try
			{
				$_.Path -ieq $record.Path
			}
			catch
			{
				$false
			}
		})

		if($alreadyRunning.Count -eq 0)
		{
			Write-Host "Restarting stopped process: $($record.ProcessName) ($($record.Path))"
			if([string]::IsNullOrWhiteSpace($record.Arguments))
			{
				Start-Process -FilePath $record.Path
			}
			else
			{
				Start-Process -FilePath $record.Path -ArgumentList $record.Arguments
			}
		}
	}

	$sourceHash = Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath
	$destinationHash = Get-FileHash -Algorithm SHA256 -LiteralPath $destinationPath
	if($sourceHash.Hash -ne $destinationHash.Hash)
	{
		throw "Hash mismatch after copy."
	}

	Show-OutputInfo $sourcePath
	Show-OutputInfo $destinationPath
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

Write-Host "VS            : $vsPath"
Write-Host "MSBuild       : $msbuild"
Write-Host "MSVC          : $vcTools"
Write-Host "SDK           : $sdk"
Write-Host "Toolset       : $toolset"
Write-Host "Configuration : $Configuration"
Write-Host "Platform      : $Platform"
Write-Host "Optimization  : O2"
Write-Host "Building dll..."

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
$prevCL = [Environment]::GetEnvironmentVariable('_CL_')
$env:_CL_ = '/O2'
$cmdExit = 1
try
{
	$buildCmd = "call `"$vcvarsall`" $vcArch $sdk -vcvars_ver=$vcTools && `"$msbuild`" $msbuildArgs"
	cmd.exe /c $buildCmd
	$cmdExit = $LASTEXITCODE
}
finally
{
	if($null -eq $prevCL)
	{
		Remove-Item Env:_CL_ -ErrorAction SilentlyContinue
	}
	else
	{
		$env:_CL_ = $prevCL
	}
}

if($cmdExit -ne 0)
{
	throw "Build failed with exit code $cmdExit"
}

if(!(Test-Path -LiteralPath $dllPath -PathType Leaf))
{
	throw "Build finished but DLL not found: $dllPath"
}

Show-OutputInfo $dllPath

if(-not $NoDeploy)
{
	$destinationPath = Get-FullPath $Destination
	Write-Host "Deploying to $destinationPath"
	Deploy-ShellDll $dllPath $destinationPath
}
