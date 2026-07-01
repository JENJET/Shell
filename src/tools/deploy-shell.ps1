param(
	[string]$Source = (Join-Path $PSScriptRoot '..\bin\shell.dll'),
	[string]$Destination = 'D:\Softs\NileSoftShell\shell.dll',
	[int]$Attempts = 20,
	[int]$DelayMilliseconds = 300,
	[switch]$NoRestartExplorer,
	[switch]$NoRestartStoppedProcesses
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$sourcePath = (Resolve-Path -LiteralPath $Source).Path
$destinationPath = Get-FullPath $Destination
$destinationDir = Split-Path -Path $destinationPath -Parent

if(!(Test-Path -LiteralPath $sourcePath -PathType Leaf))
{
	throw "Source file not found: $sourcePath"
}

if(!(Test-Path -LiteralPath $destinationDir -PathType Container))
{
	throw "Destination directory not found: $destinationDir"
}

$copied = $false
$stoppedProcesses = @{}

for($i = 0; $i -lt $Attempts -and !$copied; $i++)
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
		if($i + 1 -ge $Attempts)
		{
			throw "Failed to replace $destinationPath because it is still locked."
		}

		Start-Sleep -Milliseconds $DelayMilliseconds
	}
}

if(!$NoRestartExplorer -and !(Get-Process -Name explorer -ErrorAction SilentlyContinue))
{
	Start-Process explorer.exe
}

if(!$NoRestartStoppedProcesses)
{
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
}

$sourceHash = Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath
$destinationHash = Get-FileHash -Algorithm SHA256 -LiteralPath $destinationPath

if($sourceHash.Hash -ne $destinationHash.Hash)
{
	throw "Hash mismatch after copy."
}

Get-Item -LiteralPath $sourcePath, $destinationPath |
	Select-Object FullName, Length, LastWriteTime

$sourceHash, $destinationHash |
	Select-Object Path, Hash
