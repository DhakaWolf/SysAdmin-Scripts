<#
. Script Name: Update-ChromeDriver.ps1
. Author: Zac Porter
. Email: Zackory.Porter@trs.texas.gov ; Alt: porter.zackory@gmail.com
. Purpose: Used as a scheduled task (or a Configuration Item in ConfigMgr) to keep Google Chrome and ChromeDriver in sync in respect to SeleniumBasic. 


################ CHANGE LOG ################
v1.0 - Initial Script, pulled from a source on the internet that i've long since forgotten. - 9/1/2022

v1.1 - Google moved to using a REST API endpoint hosted on GitHub to supply data for downloading Google Chrome Test Builds and ChromeDriver. - 8/24/2023
        - Updated version detection to pull in all the way up to the build number as that's needed for the REST lookup. More info can be found here ( Unless Google changes THIS url too D:< ): https://www.chromium.org/developers/version-numbers/
        - Changed Invoke-WebRequest features to Invoke-RESTMethod to better handle REST API lookups.
        - Added Logging for easier troubleshooting
        - Tidied up the code and added notes in some of the more complex bits. 
        - Added exit codes: 
            - 45: Google Chrome not installed.
            - 46: REST data was not provided to client from GitHub.
            - 47: Unable to locate download link within the REST data using query. 
            - 48: Download from Google's CDN failed.
            - 49: SeleniumBasic not installed. 
            - 50: Failed to extract package from archive.
            - 51: Injection to SeleniumBasic directory failed. 

#>

param([switch]$Elevated)
function Test-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
    $currentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if ((Test-Admin) -eq $false)  {
    if ($elevated) {
        # tried to elevate, did not work, aborting
    } else {
        Start-Process powershell.exe -Verb RunAs -ArgumentList ('-noprofile -noexit -file "{0}" -elevated' -f ($myinvocation.MyCommand.Definition))
    }
    exit
}

#Setup Logging 
$varLogLoc = "$env:windir\CCM\Logs\Update-ChromeDriver.log" # Path for log file. 

IF (Test-Path $varLogLoc) {
    If ((Get-Item $varLogLoc).length -lt 10MB) {
      Write-Output [$(Get-Date)]:" Log file is smaller than 10MB does not need to be archived." | Out-File $varLogLoc -Append -Force
      Write-Output [$(Get-Date)]:" >>> Starting logging..." | Out-File $varLogLoc -Append -Force
    } Else {
        Write-Output [$(Get-Date)]:" Log file is over the threshold of 10MB" | Out-File $varLogLoc -Append -Force
        Write-Output [$(Get-Date)]:" Archiving log file..." | Out-File $varLogLoc -Append -Force
                $varLogPath = $varLogLoc.Replace('Update-ChromeDriver.log','')
                $varLogPurge = Get-ChildItem -Path $varLogPath -Filter "Update-ChromeDriver_*"
            Foreach($varDelTarg in $varLogPurge){Remove-Item $varLogPath\$varDelTarg -Force -Confirm:$false} -ErrorAction SilentlyContinue
                $varLogArc = $varLogLoc.Replace('.log','')+"_"+"$(Get-Date -f MMddyyyyhhmm)"+".log"
            Rename-Item $varLogLoc -NewName $varLogArc -Force
            New-Item -ItemType File $varLogLoc
        Write-Output [$(Get-Date)]:" >>> Starting logging..." | Out-File $varLogLoc -Append -Force
    }
}
Write-Output [$(Get-Date)]:[$(Get-Date)]:"Update-ChromeDriver.ps1 has started!" | Out-File $varLogLoc -Append -Force

'Running PowerShell with Full Privileges'
#Get Version of Chrome on Machine
$varChromeVer = (Get-Item (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe').'(Default)').VersionInfo.ProductVersion
If ($varChromeVer -eq $null){
    Write-Output [$(Get-Date)]:"Failed to detect Google Chrome installation. A reinstall of Google Chrome may be needed." | Out-File $varLogLoc -Append -Force
    Exit 45
} Else {
    Write-Output [$(Get-Date)]:"Google Chrome full version number detected: $varChromeVer" | Out-File $varLogLoc -Append -Force
}

#Chrome Version XXX.0.XXXX - Get the MAJOR.MINOR.BUILD numbers from the version of Chrome. 
$varChromeVerLookup = $varChromeVer.Substring(0,$varChromeVer.LastIndexOf('.')) # Use version number detected on system. 
####$varChromeVerLookup = "115.0.5771" # For script testing only, uncomment to use. 

#Use REST to query download url for our version of ChromeDriver
$objChromeCDNs = Invoke-RestMethod -Method GET -Uri "https://googlechromelabs.github.io/chrome-for-testing/latest-patch-versions-per-build-with-downloads.json" # Documentation found here: https://github.com/GoogleChromeLabs/chrome-for-testing#json-api-endpoints
If ($objChromeCDNs -eq $null){
    Write-Output [$(Get-Date)]:"Failed to contact GitHub to obtain REST data." | Out-File $varLogLoc -Append -Force
    Exit 46
} Else {
    Write-Output [$(Get-Date)]:"Obtained REST data from https://googlechromelabs.github.io" | Out-File $varLogLoc -Append -Force
}
$varDLIndexQuery = 'builds."'+$varChromeVerLookup+'".downloads.chromedriver.Where({$_.Platform -eq "win32"})' 
$varDLIndex = Invoke-Expression "`$objChromeCDNs.$varDLIndexQuery"
$varDLLink = $varDLIndex.url
If ($varDLLink -eq $null){
    Write-Output [$(Get-Date)]:"Failed to locate download link in REST data obtained from Google. Check that $varChromeVerLookup has an available ChromeDriver download." | Out-File $varLogLoc -Append -Force
    Exit 47
} Else {
    Write-Output [$(Get-Date)]:"Download link listed is: $varDLLink" | Out-File $varLogLoc -Append -Force
}

#Download the latest ChromeDriver release available for our version of Chrome.
Write-Output [$(Get-Date)]:"Downloading chromedriver_win32.zip from CDN..." | Out-File $varLogLoc -Append -Force 
Try{
    $varDLLoc = "$env:ProgramFiles\SeleniumBasic"
    $varDLFileName = "chromedriver_win32.zip"
    $varCDPackage = $varDLLoc+$varDLFileName
    Invoke-WebRequest -Uri $varDLLink -OutFile $varCDPackage -UseBasicParsing -ErrorAction Stop
} Catch {
    Write-Output [$(Get-Date)]:"Download failed. Review link provided is still active or that the client can reach the address." | Out-File $varLogLoc -Append -Force
    Exit 48
}

#Extract the exe to the appropriate PSModule Selenium directory.
$varModulePath = "$env:PROGRAMFILES\SeleniumBasic" # This is the SeleniumBasic directory. Modify depending on install location. 
If(!(Test-Path $varModulePath)){
    Write-Output [$(Get-Date)]:"SeleniumBasic installation path not found in the expected location. Reinstall SeleniumBasic to this path -> $varModulePath " | Out-File $varLogLoc -Append -Force 
    Exit 49
} Else {
    Write-Output [$(Get-Date)]:"SeleniumBasic detected! $varModulePath" | Out-File $varLogLoc -Append -Force 
}
Write-Output [$(Get-Date)]:"Unpacking chromedriver-win32.zip..." | Out-File $varLogLoc -Append -Force 
Try{
    Expand-Archive -LiteralPath $varCDPackage -DestinationPath $varDLLoc -Force
} Catch {
    Write-Output [$(Get-Date)]:"Failed to expand archive!" | Out-File $varLogLoc -Append -Force
    Exit 50
}
Write-Output [$(Get-Date)]:"Injecting chromedriver.exe to $varModulePath..." | Out-File $varLogLoc -Append -Force 
Try{
    Move-Item $varDLLoc\chromedriver-win32\chromedriver.exe $varModulePath\chromedriver.exe -Force
} Catch {
    Write-Output [$(Get-Date)]:"Unable to inject chromedriver.exe!" | Out-File $varLogLoc -Append -Force 
    Exit 51
}

#Clean up temporary files
if (Test-Path $varCDPackage) {
    Remove-Item $varCDPackage -Force
} Else {
}
if (Test-Path "$varDLLoc\chromedriver-win32\"){
    Remove-Item "$varDLLoc\chromedriver-win32\" -Recurse -Force
}

Write-Output [$(Get-Date)]:"Successfully updated chromedriver to $varChromeVerLookup !!" | Out-File $varLogLoc -Append -Force 