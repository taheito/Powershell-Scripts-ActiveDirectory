#
# CheckGPResultRemote.ps1
#
param
(
	[parameter(Mandatory=$true)]
	[string]$OUDistinguishedName,

	[parameter(Mandatory=$true)]
	[string]$LogFilePath,

	[parameter(Mandatory=$true)]
	[string]$GPRSoPTempDirectory
)

$ErrorActionPreference = "Continue"
Function WriteLog ([string]$message, [string]$logPath)
{
	Try
	{
		Add-Content -Value $message -Path "$logPath"
	}
	catch
	{
		$ErrorActionPreference = "Stop"
		$errorLog = $_
		Write-Host "Error occured during logging. Script will not proceed without logging."
		Write-Host "`rError:"
		Write-Host $errorLog
	}
	finally
	{

	}
}

Function CreateServerArray ($serverArray, $serverName, $serverADGroups,$RSoPGroups)
{
	$serverObject = New-Object -TypeName PSObject
	$serverObject | Add-Member -MemberType NoteProperty -Name "ServerName" -Value $serverName
	$serverObject | Add-Member -MemberType NoteProperty -Name "DiscoveredADGroups" -Value $serverADGroups

	if ($RSoPGroups -eq $null)
	{
		$serverObject | Add-Member -MemberType NoteProperty -Name "RSoPGroups" -Value "No RSoP data available"
	}
	else
	{
		$serverObject | Add-Member -MemberType NoteProperty -Name "RSoPGroups" -Value $RSoPGroups
	}

	$serverArray += $serverObject

	return $serverArray
}

Function CreateGroupStringArray ($groupMembership)
{
	$groupStringArray = @()

	foreach ($group in $groupMembership)
	{
		$groupStringArray += $group.Name
	}

	return $groupStringArray
}

Try
{
    $Servers = Get-ADComputer -SearchBase "$OUDistinguishedName" -Filter * -SearchScope Subtree
	$serversToBeInvestigated = @()
	$serversOverview = @()
	$serversNotChecked = 0

	Write-Host "Number of server computer objects which will be checked: $($Servers.Count)" -ForegroundColor Yellow

    foreach ($server in $Servers)
    {
		Try
		{
			$serverName = $server.SamAccountName.Replace("$","")

			#check if it is a Server 2003 version. If true, then this server cannot be checked. Written in log file which contains computer names which are not checked
			$ServerInfo = Get-AdComputer $serverName -Properties operatingSystem

			if (($serverInfo.operatingSystem -eq "Windows Server 2003") -or ($ServerInfo.operatingSystem -eq "Windows Server 2000"))
			{
				Write-Host "Server $serverName is not checked because the Windows OS version is too low to be able to check remotely`n" -ForegroundColor Yellow
				WriteLog -message "$serverName is not checked. OS not supported" -logPath $LogFilePath

				#add server object to server array
				$groupMemberships = Get-ADPrincipalGroupMembership -Identity $server.SamAccountName
				$groupStringArray = CreateGroupStringArray -groupMembership $groupMemberships
				$serversOverview += CreateServerArray -serverArray $serversOverview -serverADGroups $groupStringArray -serverName $server.SamAccountName -RSoPGroups $null
				$groupMemberships = $null
				$serversNotChecked++
			}
			else
			{
				#get groupmemberships of server computer object
				$groupMemberships = Get-ADPrincipalGroupMembership -Identity $server.SamAccountName
				$groupStringArray = CreateGroupStringArray -groupMembership $groupMemberships

				Write-Host "Group Membership of server $($server.SamAccountName)" -ForegroundColor Green
				foreach ($group in $groupMemberships)
				{
					Write-Host $group.Name -ForegroundColor Red
				}

				#temporary path where xml is stored, generated by RSoP
				$tempXMLPath = "$GPRSoPTempDirectory\$serverName.xml"
        
				Write-Host "Get RSoP data from server $serverName" -ForegroundColor Green
				Get-GPResultantSetOfPolicy -Computer $serverName -ReportType Xml -Path $tempXMLPath -User "lwmeijer\Administrator" -ErrorAction Continue | Out-Null


				if (Test-Path $tempXMLPath)
				{
					[xml]$xml = Get-Content -Path $tempXMLPath

					#get group membership of computer object
					$groups = $xml.Rsop.ComputerResults.SecurityGroup.Name

					Write-Host "Discovered groups in the GP Resultant Set of server $($server.Name)" -ForegroundColor Green
					Write-Host (($groups.'#text').Where{$_ -like "*SG_LWM*"}).Replace("LWMEIJER\","")

					Write-Host "Start compare of the actual group membership vs group memberships configured in AD ..." -ForegroundColor Green
					$compareOutput = Compare-Object -ReferenceObject (($groupMemberships.Name).Where{$_ -like "*SG_LWM*"} | Sort-Object) `
					-DifferenceObject ((($groups.'#text').Where{$_ -like "*SG_LWM*"}).Replace("LWMEIJER\","") | Sort-Object) -PassThru

					if ($compareOutput)
					{
						$serverObject = New-Object -TypeName PSObject
						$serverObject | Add-Member -MemberType NoteProperty -Name ServerName -Value $serverName
						$serverObject | Add-Member -MemberType NoteProperty -Name GroupsNotMatching -Value $compareOutput

						$serversToBeInvestigated += $serverObject

						#add to server overview
						$serversOverview += CreateServerArray -serverArray $serversOverview -serverADGroups $groupStringArray -serverName $server.SamAccountName -RSoPGroups $groups.'#text'
					}

					Write-Host "------------------------------------------------------------------------`n"

					#delete temp XML file
					Remove-Item -Path $tempXMLPath -Force

					#$tempXMLPath = $null
				}

				#reinitialize variables
				$groups = $null
				$xml = $null
				$compareOutput = $null
				$groupMemberships = $null
			}
		}
		Catch
		{
			$ErrorActionPreference = "Continue"
			Write-Host "Error occured, writing to log file..." -ForegroundColor Yellow
			Write-Host "------------------------------------------------------------------------`n"
			$errorLog = $_
			WriteLog -message "While processing computer object $serverName, following error occured: `n$errorLog`n`n" -logPath "$LogFilePath"
			if (Test-Path $tempXMLPath)
			{
				Remove-Item -Path $tempXMLPath -Force
			}

			$serversNotChecked++
		}
    }

	Write-Host "Number of servers which couldn't be checked: $serversNotChecked"

	if ($serversToBeInvestigated)
	{
		$serversToBeInvestigated | Out-GridView -Title "Servers which must be checked"
	}
	else
	{
		Write-Host "No servers were found which need further investigations regarding group memberships"
	}

	#output the server array
	$serversOverview | Out-GridView -Title " Complete Server Overview"

}
catch 
{
    Write-Host "TERMINATING ERROR OCCURED" -ForegroundColor DarkRed -BackgroundColor Cyan
    $errorLog = $_
	Write-Host $errorLog
}
finally
{
    Write-Host "Script ended"
}