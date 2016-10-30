#-----------------------
# InstallMostThings.ps1
#-----------------------


# Version configuration. We put them here rather than in packer variables so that this script block can be run on any machine,
# not just a CI server. Note Git is a full location, not a version as interim releases have more than just the version in the path.
echo "$(date) InstallMostThings.ps1 starting" >> $env:SystemDrive\packer\configure.log

$FULL_GIT_LOCATION="https://github.com/git-for-windows/git/releases/download/v2.10.1.windows.1/Git-2.10.1-64-bit.exe"
$NANO_GIT_LOCATION="https://github.com/git-for-windows/git/releases/download/v2.10.1.windows.1/PortableGit-2.10.1-64-bit.7z.exe"
$JDK_LOCATION="http://download.oracle.com/otn-pub/java/jdk/8u111-b14/jdk-8u111-windows-x64.exe"  # 10/24/2016
$NPP_LOCATION="https://notepad-plus-plus.org/repository/7.x/7.1/npp.7.1.Installer.x64.exe" # 10/24/2016
$SQLITE_LOCATION="https://sqlite.org/2016/sqlite-amalgamation-3150000.zip" # 10/24/2016
$DOCKER_LOCATION="https://master.dockerproject.org/windows/amd64"
$DELVE_LOCATION="github.com/derekparker/delve/cmd/dlv"

# Stop on error
$ErrorActionPreference="stop"

function Test-Nano() {  
    $EditionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID').EditionId  
    return (($EditionId -eq "ServerStandardNano") -or   
            ($EditionId -eq "ServerDataCenterNano") -or   
            ($EditionId -eq "NanoServer") -or   
            ($EditionId -eq "ServerTuva"))  
}  

function Copy-File {  
    [CmdletBinding()]  
    param(  
        [string] $SourcePath,  
        [string] $DestinationPath  
    )  

    if ($SourcePath -eq $DestinationPath) { return }  

    if (Test-Path $SourcePath) { 
        Copy-Item -Path $SourcePath -Destination $DestinationPath 
    } elseif (($SourcePath -as [System.URI]).AbsoluteURI -ne $null) {  
        if (Test-Nano) {
            $handler = New-Object System.Net.Http.HttpClientHandler  
            $client = New-Object System.Net.Http.HttpClient($handler)  
            $client.Timeout = New-Object System.TimeSpan(0, 30, 0)  
            $cancelTokenSource = [System.Threading.CancellationTokenSource]::new()   
            $responseMsg = $client.GetAsync([System.Uri]::new($SourcePath), $cancelTokenSource.Token)  
            $responseMsg.Wait()  

            if (!$responseMsg.IsCanceled) {  
                $response = $responseMsg.Result  
                if ($response.IsSuccessStatusCode) {  
                    $downloadedFileStream = [System.IO.FileStream]::new($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)  
                    $copyStreamOp = $response.Content.CopyToAsync($downloadedFileStream)  
                    $copyStreamOp.Wait()  
                    $downloadedFileStream.Close()  
                    if ($copyStreamOp.Exception -ne $null) {  
                        throw $copyStreamOp.Exception  
                    }        
                }  
            }    
        }  
        elseif ($PSVersionTable.PSVersion.Major -ge 5) { 
            # We disable progress display because it kills performance for large downloads (at least on 64-bit PowerShell)  
            $ProgressPreference = 'SilentlyContinue'  
            wget -Uri $SourcePath -OutFile $DestinationPath -UseBasicParsing  
            $ProgressPreference = 'Continue'  
        } else {  
            $webClient = New-Object System.Net.WebClient  
            $webClient.DownloadFile($SourcePath, $DestinationPath)  
        }   
    } else {  
        throw "Cannot copy from $SourcePath"  
    }  
}  

if (-not (Test-Nano)) {
    echo "$(date)  Git:           $FULL_GIT_LOCATION"    >> $env:SystemDrive\packer\configure.log
} else { 
    echo "$(date)  Git:           $NANO_GIT_LOCATION"    >> $env:SystemDrive\packer\configure.log
}
if ($env:LOCAL_CI_INSTALL -ne 1) {echo "$(date)  JDK:           $JDK_LOCATION"         >> $env:SystemDrive\packer\configure.log }
echo "$(date)  Notepad++:     $NPP_LOCATION"         >> $env:SystemDrive\packer\configure.log
if ($env:LOCAL_CI_INSTALL -eq 1) { echo "$(date)  SQLite:        $SQLITE_LOCATION"      >> $env:SystemDrive\packer\configure.log }
echo "$(date)  Docker:        $DOCKER_LOCATION"      >> $env:SystemDrive\packer\configure.log


try {

    # Create directory for our local run scripts
    mkdir $env:SystemDrive\scripts -ErrorAction SilentlyContinue 2>&1 | Out-Null

    # Set PATH for machine and current session
    echo "$(date) InstallMostThings.ps1 Updating path" >> $env:SystemDrive\packer\configure.log
    if ($env:LOCAL_CI_INSTALL -eq 1) {
        if (-not ($env:PATH -like '*c:\gopath\bin*'))    { $env:Path = "c:\gopath\bin;$env:Path" }
        if (-not ($env:PATH -like '*c:\go\bin*'))        { $env:Path = "c:\go\bin;$env:Path" }
    } else {
        if (-not ($env:PATH -like '*c:\jdk\bin*'))       { $env:Path = "c:\jdk\bin;$env:Path" }
    }
    if (-not ($env:PATH -like '*c:\gcc\bin*'))       { $env:Path = "c:\gcc\bin;$env:Path" }
    if (-not ($env:PATH -like '*c:\git\usr\bin*'))                     { $env:Path = "c:\git\usr\bin;$env:Path" }
    if (-not ($env:PATH -like '*c:\git\bin*'))                         { $env:Path = "c:\git\bin;$env:Path" }
    if (-not ($env:PATH -like '*c:\git\cmd*'))                         { $env:Path = "c:\git\cmd;$env:Path" }
    if (-not ($env:PATH -like '*c:\CIUtilities*'))                     { $env:Path = "c:\CIUtilities;$env:Path" }
    if (-not ($env:PATH -like '*c:\Program Files (x86)\Notepad++*'))   { $env:Path = "c:\Program Files (x86)\Notepad++;$env:Path" }
    if (-not ($env:PATH -like '*c:\pstools*'))                         { $env:Path = "c:\pstools;$env:Path" }
    setx "PATH" "$env:PATH" /M

    # Only need golang, delve locally if this is a dev VM
    if ($env:LOCAL_CI_INSTALL -eq 1) {
        # Work out the version of GO from dockerfile.Windows currently on master
        echo "$(date) InstallMostThings.ps1 Working out GO version..." >> $env:SystemDrive\packer\configure.log
        Copy-File -SourcePath "https://raw.githubusercontent.com/docker/docker/master/Dockerfile.windows" -DestinationPath "$env:Temp\dockerfile.Windows"
        $pattern=select-string $env:Temp\dockerfile.windows -pattern "GO_VERSION="
        if ($pattern.Count -lt 1) {
            Throw "Could not find GO_VERSION= in dockerfile.Windows!"
        }
        $line=$pattern[0]
        $line=$line -replace "\\",""
        $line=$line -replace("``","")
        $line=$line.TrimEnd()
        $index=$line.indexof("=")
        if ($index -eq -1) {
            Throw "Could not find '=' in the GO_VERSION line of dockerfile.Windows"
        }
        $GO_VERSION=$line.Substring($index+1)
        echo "$(date) InstallMostThings.ps1 Need GO version $GO_VERSION" >> $env:SystemDrive\packer\configure.log

        # Download and install golang, plus set GOROOT and GOPATH for machine and current session.
        echo "$(date) InstallMostThings.ps1 Downloading go..." >> $env:SystemDrive\packer\configure.log
        if (-not (Test-Nano)) {
            Copy-File -SourcePath "https://storage.googleapis.com/golang/go$GO_VERSION.windows-amd64.msi" -DestinationPath "$env:Temp\go.msi"
            echo "$(date) InstallMostThings.ps1 Installing go..." >> $env:SystemDrive\packer\configure.log
            Start-Process msiexec -ArgumentList "-i $env:Temp\go.msi -quiet" -Wait
        } else {
            Copy-File -SourcePath "https://storage.googleapis.com/golang/go$GO_VERSION.windows-amd64.zip" -DestinationPath "$env:Temp\go.zip"
            echo "$(date) InstallMostThings.ps1 Extracting go..." >> $env:SystemDrive\packer\configure.log
            Expand-Archive $env:Temp\go.zip $env:SystemDrive\ -Force
        }
        echo "$(date) InstallMostThings.ps1 Updating GOROOT and GOPATH..." >> $env:SystemDrive\packer\configure.log
        $env:GOROOT="$env:SystemDrive\go"
        $env:GOPATH="$env:SystemDrive\gopath"
        setx "GOROOT" "$env:GOROOT" /M  # persist
    }

    # Install GCC
    echo "$(date) InstallMostThings.ps1 Downloading compiler 1 of 3..." >> $env:SystemDrive\packer\configure.log
    Copy-File -SourcePath "https://raw.githubusercontent.com/jhowardmsft/docker-tdmgcc/master/gcc.zip" -DestinationPath "$env:Temp\gcc.zip"
     echo "$(date) InstallMostThings.ps1 Downloading compiler 2 of 3..." >> $env:SystemDrive\packer\configure.log
    Copy-File -SourcePath "https://raw.githubusercontent.com/jhowardmsft/docker-tdmgcc/master/runtime.zip" -DestinationPath "$env:Temp\runtime.zip"
    echo "$(date) InstallMostThings.ps1 Downloading compiler 3 of 3..." >> $env:SystemDrive\packer\configure.log
    Copy-File -SourcePath "https://raw.githubusercontent.com/jhowardmsft/docker-tdmgcc/master/binutils.zip" -DestinationPath "$env:Temp\binutils.zip"
    echo "$(date) InstallMostThings.ps1 Extracting compiler 1 of 3..." >> $env:SystemDrive\packer\configure.log
    Expand-Archive $env:Temp\gcc.zip $env:SystemDrive\gcc -Force
    echo "$(date) InstallMostThings.ps1 Extracting compiler 2 of 3..." >> $env:SystemDrive\packer\configure.log
    Expand-Archive $env:Temp\runtime.zip $env:SystemDrive\gcc -Force
    echo "$(date) InstallMostThings.ps1 Extracting compiler 3 of 3..." >> $env:SystemDrive\packer\configure.log
    Expand-Archive $env:Temp\binutils.zip $env:SystemDrive\gcc -Force

    # Download 7z to extract GIT on nanoserver
    #if (Test-Nano) {
    #    echo "$(date) InstallMostThings.ps1 Downloading 7z (nano only)..." >> $env:SystemDrive\packer\configure.log
    #    Copy-File -SourcePath "http://www.7-zip.org/a/7z1602-x64.exe" -DestinationPath "$env:Temp\7zsetup.exe"
    #}

    # Download and install git
    echo "$(date) InstallMostThings.ps1 Downloading git..." >> $env:SystemDrive\packer\configure.log
    if (-not (Test-Nano)) {
        Copy-File -SourcePath "$FULL_GIT_LOCATION" -DestinationPath "$env:Temp\gitsetup.exe"
        echo "$(date) InstallMostThings.ps1 Installing git..." >> $env:SystemDrive\packer\configure.log
        $installPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $installItem = 'Git_is1'
        New-Item -Path $installPath -Name $installItem -Force
        $installKey = $installPath+'\'+$installItem
        New-ItemProperty $installKey -Name 'Inno Setup CodeFile: Path Option' -Value 'CmdTools' -PropertyType 'String' -Force
        New-ItemProperty $installKey -Name 'Inno Setup CodeFile: Bash Terminal Option' -Value 'ConHost' -PropertyType 'String' -Force
        New-ItemProperty $installKey -Name 'Inno Setup CodeFile: CRLF Option' -Value 'CRLFCommitAsIs' -PropertyType 'String' -Force
        Start-Process $env:Temp\gitsetup.exe -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /DIR=$env:SystemDrive\git" -Wait
    } else {
        Copy-File -SourcePath "$NANO_GIT_LOCATION" -DestinationPath "$env:Temp\gitsetup.exe"
    }

    # Perform an initial clone so that we can do a local verification outside of jenkins through c:\scripts\doit.sh
    if ($env:LOCAL_CI_INSTALL -ne 1) {
        echo "$(date) InstallMostThings.ps1 Cloning docker sources..." >> $env:SystemDrive\packer\configure.log
        Start-Process -wait git -ArgumentList "clone https://github.com/docker/docker $env:SystemDrive\gopath\src\github.com\docker\docker"
    }

    # Install delve debugger (after GIT is installed) if on a dev VM
    if ($env:LOCAL_CI_INSTALL -eq 1) {
        echo "$(date) InstallMostThings.ps1 Installing delve..." >> $env:SystemDrive\packer\configure.log
        go get $DELVE_LOCATION
    }

    # Keep for reference. This is how you might download OpenSSH-Win64
    # Download and extract OpenSSH-Win64  
    #if ($env:LOCAL_CI_INSTALL -ne 1) {
    #    echo "$(date) Phase1.ps1 downloading OpenSSH..." >> $env:SystemDrive\packer\configure.log
    #    mkdir $env:SystemDrive\OpenSSH-Win64 -erroraction silentlycontinue 2>&1 | Out-Null
    #    $wc=New-Object net.webclient;$wc.Downloadfile("https://github.com/PowerShell/Win32-OpenSSH/releases/download/5_30_2016/OpenSSH-Win64.zip","$env:Temp\OpenSSH-Win64.zip")
    #    echo "$(date) Phase1.ps1 unzipping OpenSSH-Win64..." >> $env:SystemDrive\packer\configure.log
    #    Expand-Archive $env:Temp\OpenSSH-Win64.zip "$env:SystemDrive\" -Force
    #}

    # Keep for reference. This is how you might setup OpenSSH-Win64. Unfortunately, while it connects, I just cannot
    # get it to work with mingw and remove cygwin. I'd really rather the Jenkins SSH plugin were smart enough to
    # know it's at a cmd prompt, not a cygwin shell prompt. The steps below would be for phase 4.
    # cd c:\OpenSSH-Win64\
    # .\Install-SSHD.ps1
    # .\Install-SSHLSA.ps1
    # .\ssh-keygen -A
    # "PasswordAuthentication no`n" | Out-File -Append .\sshd_config -Encoding utf8
    # mkdir $env:SystemDrive\users\$env:USERNAME\.ssh
    # Copy-Item $env:SystemDrive\packer\authorized_keys $env:SystemDrive\users\$env:USERNAME\.ssh
    # Set-Service sshd -StartupType Automatic
    # Set-Service ssh-agent -StartupType Automatic
    # net start sshd

    echo "$(date) InstallMostThings.ps1 Downloading utilities..." >> $env:SystemDrive\packer\configure.log
    if (-not(Test-Path "C:\CIUtilities")) { mkdir "C:\CIUtilities" | Out-Null }
    if (-not (Test-Path "c:\CIUtilities\docker-ci-zap.exe")) {
        Copy-File -SourcePath "https://github.com/jhowardmsft/docker-ci-zap/raw/master/docker-ci-zap.exe" -DestinationPath "c:\CIUtilities\docker-ci-zap.exe"
        Unblock-File "c:\CIUtilities\docker-ci-zap.exe" -ErrorAction Stop
    }

    if (-not (Test-Path "c:\CIUtilities\docker-signal.exe")) {
        Copy-File -SourcePath "https://github.com/jhowardmsft/docker-signal/raw/master/docker-signal.exe" -DestinationPath "c:\CIUtilities\docker-signal.exe"
        Unblock-File "c:\CIUtilities\docker-signal.exe" -ErrorAction Stop
    }

    # Download docker client
    echo "$(date) InstallMostThings.ps1 Downloading docker.exe..." >> $env:SystemDrive\packer\configure.log
    Copy-File -SourcePath "$DOCKER_LOCATION/docker.exe" -DestinationPath "$env:SystemRoot\System32\docker.exe"

    # Download docker daemon
    echo "$(date) InstallMostThings.ps1 Downloading dockerd.exe..." >> $env:SystemDrive\packer\configure.log
    Copy-File -SourcePath "$DOCKER_LOCATION/dockerd.exe" -DestinationPath "$env:SystemRoot\System32\dockerd.exe"

    if (-not (Test-Nano)) {
        # Download and install Notepad++
        echo "$(date) InstallMostThings.ps1 Downloading Notepad++..." >> $env:SystemDrive\packer\configure.log
        $wc=New-Object net.webclient;$wc.Downloadfile($NPP_LOCATION,"$env:Temp\nppinstaller.exe")
        echo "$(date) InstallMostThings.ps1 Installing Notepad++..." >> $env:SystemDrive\packer\configure.log
        Start-Process -wait $env:Temp\nppinstaller.exe -ArgumentList "/S"
    }

    # Download and install PSTools
    echo "$(date) InstallMostThings.ps1 Downloading PSTools..." >> $env:SystemDrive\packer\configure.log
    Copy-File -SourcePath "https://download.sysinternals.com/files/PSTools.zip" -DestinationPath "$env:Temp\pstools.zip"
    echo "$(date) InstallMostThings.ps1 Installing PSTools..." >> $env:SystemDrive\packer\configure.log
    Expand-Archive $env:Temp\pstools.zip c:\pstools

    # Not needed for RTM
    # Add registry keys for enabling nanoserver. 
    #echo "$(date) InstallMostThings.ps1 Adding nano registry keys..." >> $env:SystemDrive\packer\configure.log
    #REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers" /v SkipVersionCheck /t REG_DWORD /d 2 /f | Out-Null
    #REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers" /v SkipSkuCheck /t REG_DWORD /d 2 /f | Out-Null

    if (-not (Test-Nano)) {
        # Stop Server Manager from opening at logon
        echo "$(date) InstallMostThings.ps1 Turning off server manager at logon..." >> $env:SystemDrive\packer\configure.log
        REG ADD "HKLM\SOFTWARE\Microsoft\ServerManager" /v DoNotOpenServerManagerAtLogon /t REG_DWORD /d 1 /f | Out-Null
    }

    # BUGBUG This could be problematic with Copy-File
    # Download and install Java Development Kit if not a development VM. Needed for Jenkins connectivity.
    # http://stackoverflow.com/questions/10268583/downloading-java-jdk-on-linux-via-wget-is-shown-license-page-instead
    if (-not (Test-Nano)) {
        if ($env:LOCAL_CI_INSTALL -ne 1) {
            echo "$(date) InstallMostThings.ps1 Downloading JDK..." >> $env:SystemDrive\packer\configure.log
            $wc=New-Object net.webclient;
            $wc.Headers.Set("Cookie","oraclelicense=accept-securebackup-cookie")
            $wc.Downloadfile("$JDK_LOCATION","$env:Temp\jdkinstaller.exe")
            echo "$(date) InstallMostThings.ps1 Installing JDK..." >> $env:SystemDrive\packer\configure.log
            Start-Process -Wait "$env:Temp\jdkinstaller.exe" -ArgumentList "/s /INSTALLDIRPUBJRE=$env:SystemDrive\jdk"
        }
    }

    # If a dev VM, download sources for, and compile sqlite3.dll from amalgamation sources in case of a dynamically linked docker binary
    if ($env:LOCAL_CI_INSTALL -eq 1) {
        echo "$(date) InstallMostThings.ps1 Downloading SQLite sources..." >> $env:SystemDrive\packer\configure.log
        Copy-File -SourcePath "$SQLITE_LOCATION" -DestinationPath "$env:Temp\sqlite.zip"
        echo "$(date) InstallMostThings.ps1 Extracting SQLite sources..." >> $env:SystemDrive\packer\configure.log
        Expand-Archive $env:Temp\sqlite.zip $env:SystemDrive\sqlite
        cd $env:SystemDrive\sqlite
        move .\sql*\* .
        echo "$(date) InstallMostThings.ps1 Compiling SQLite3.dll..." >> $env:SystemDrive\packer\configure.log
        Start-Process -wait gcc -ArgumentList "-shared sqlite3.c -o sqlite3.dll"
        copy sqlite3.dll $env:SystemRoot\system32
    }

    # Download slave.jar from Jenkins
    # Keep for reference. Just in case can get off SSH due to other reasons.
    #$JAR_LOCATION="http://jenkins.dockerproject.org/jnlpJars/slave.jar"
    #if ($env:LOCAL_CI_INSTALL -ne 1) { echo "$(date)  Jenkins JAR:   $JAR_LOCATION"         >> $env:SystemDrive\packer\configure.log }
    #if ($env:LOCAL_CI_INSTALL -ne 1) {
    #    Use Copy-Item for nanoserver compatibility...
    #    Invoke-WebRequest http://jenkins.dockerproject.org/jnlpJars/slave.jar -OutFile slave.jar
    #    echo "$(date) InstallMostThings.ps1 Downloading slave.jar from Jenkins..." >> $env:SystemDrive\packer\configure.log
    #    $wc=New-Object net.webclient;
    #    $wc.Downloadfile("$JAR_LOCATION","$env:Temp\slave.jar")
    #}

}
Catch [Exception] {
    echo "$(date) InstallMostThings.ps1 Error '$_'" >> $env:SystemDrive\packer\configure.log
    Throw $_
}
Finally {
    echo "$(date) InstallMostThings.ps1 Completed." >> $env:SystemDrive\packer\configure.log
}  

