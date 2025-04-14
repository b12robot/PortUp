function Get-Download {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^https?://')]
        [string]$DownloadUrl,

        [string]$FileName,
        
        [ValidateScript({
            if (-not (Test-Path "$_" -PathType Container)) {
                throw "Invalid download folder path: '$_'"
            }
        })]
        [string]$DownloadPath = $PWD.Path,
        
        [ValidateScript({
            if (-not (Test-Path "$_" -PathType Container)) {
                throw "Invalid metadata folder path: '$_'"
            }
        })]
        [string]$MetadataPath = $PWD.Path,
        
        [ValidateScript({
            if (-not (Test-Path "$_" -PathType Container)) {
                throw "Invalid extraction folder path: '$_'"
            }
        })]
        [string]$ExtractionPath = $PWD.Path,
        
        [string]$ArchivePassword = $null,
        
        [switch]$ForceDownload = $false,
        
        [switch]$DebugMode = $false
    )
    
    begin {
        # Set ExecutionPolicy
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

        # Check Powershell Version
		if (-not ($PSVersionTable.PSVersion.Major -ge 5)) {
			throw "Please update powershell version to 5 or later, Current powershell version: $($PSVersionTable.PSVersion)"
		}

        # Configure Debug Preference
        $DebugPreference = if ($DebugMode) { "Continue" } else { "SilentlyContinue" }

        # Load Metadata
        function Load-Metadata {
            param (
                [string]$LoadPath
            )
            try {
                if (Test-Path $LoadPath) {
                    return Get-Content -Path $LoadPath -Raw | ConvertFrom-Json
                } else {
                    return [PSCustomObject]::new()
                }
            } catch {
                throw "An error occurred while reading metadata file: $($_.Exception.Message)"
            }
        }

        # Save Metadata
        function Save-Metadata {
            param (
                [string]$SavePath,
                [object]$SaveData
            )
            try {
                $SaveData | ConvertTo-Json -Depth 10 | Set-Content -Path $SavePath -Force -Encoding UTF8
            } catch {
                throw "An error occurred while saving metadata file: $($_.Exception.Message)"
            }
        }

        # Add or Update Metadata
        function Update-Metadata {
            param (
                [PSObject]$UpdateData,
                [string]$FileKey,
                [string]$Hash,
                [string]$ETag,
                [string]$LMod
            )
            try {
                Write-Debug "Key: $FileKey"
                Write-Debug "Hash: $Hash"
                Write-Debug "ETag: $ETag"
                Write-Debug "LMod: $LMod"
                if ($UpdateData.PSObject.Properties[$FileKey]) {
                    # Update existing file metadata
					Write-Debug "Updating metadata..."				   
                    $UpdateData.PSObject.Properties[$FileKey].Value.Hash = $Hash
                    $UpdateData.PSObject.Properties[$FileKey].Value.ETag = $ETag
                    $UpdateData.PSObject.Properties[$FileKey].Value.LMod = $LMod
                } else { 
                    # Add new file metadata
					Write-Debug "Adding metadata..."				 
                    Add-Member -InputObject $UpdateData -MemberType NoteProperty -Name $FileKey -Value (
                        [PSCustomObject]@{
                            Hash = $Hash
                            ETag = $ETag
                            LMod = $LMod
                        }
                    )
                }
                return $UpdateData
            } catch {
                throw "An error occurred while updating metadata: $($_.Exception.Message)"
            }
        }

        # Remove Metadata
        function Remove-Metadata {
            param (
                [PSObject]$RemoveData,
                [string]$FileKey
            )
            try {
                if ($RemoveData.PSObject.Properties[$FileKey]) {
                    # If exist remove metadata
                    Write-Debug "Removing metadata for key: $FileKey"
                    $RemoveData.PSObject.Properties.Remove($FileKey)
                }
                return $RemoveData
            } catch {
                throw "An error occurred while removing metadata: $($_.Exception.Message)"
            }
        }

        # Format FileSize Function
        function Format-FileSize {
            param(
                [long]$Bytes
            )
            switch ($Bytes) {
                { $Bytes -ge 1GB } { return "{0:N2} GB" -f ($Bytes / 1GB) }
                { $Bytes -ge 1MB } { return "{0:N2} MB" -f ($Bytes / 1MB) }
                { $Bytes -ge 1KB } { return "{0:N2} KB" -f ($Bytes / 1KB) }
                default { return $Bytes }
            }
        }

        # Github Request Function
        function Github-Request {
            param(
                [string]$ApiUrl,
                [string]$Filter
            )
            # Get Releases from GitHub
            try {
                $Releases = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -TimeoutSec 30
            } catch {
                throw "Failed to retrieve GitHub releases: $($_.Exception.Message)"
            }
            
            # Get Release Type
            $Stable = $Releases | Where-Object { -not $_.prerelease }
            $EarlyAccess = $Releases | Where-Object { $_.prerelease }

            # If exist select Stable else EarlyAccess
            if ($Stable.Count -gt 0) {
                $Releases = $Stable
            } elseif ($EarlyAccess.Count -gt 0) {
                $Releases = $EarlyAccess
            } else {
                throw "No releases found in GitHub repository: $($_.Exception.Message)"
            }
            
            # Sort Releases and Select Latest
            $LatestRelease = $Releases | Sort-Object -Property published_at -Descending | Select-Object -First 1

            # Filter Assets
            [array]$FilteredAssets = if ($Filter) {
                $LatestRelease.assets | Where-Object { $_.name -like "$Filter" }
            } else {
                $LatestRelease.assets | Select-Object name, browser_download_url
            }
            if (-not $FilteredAssets) {
                throw "No matching assets found. Verifiy filter: '$Filter'"
            }
            
            # Select Asset Automatically or Prompt User if Multiple Matches Found
            if ($FilteredAssets.Count -eq 1) {
                # Auto select asset
                $SelectedAsset = $FilteredAssets[0]
            } elseif ($FilteredAssets.Count -gt 1) {
                # List Assets
                $Count = 0
                foreach ($Asset in $FilteredAssets) {
                    $Count++
                    Write-Host "$Count. $($Asset.name)"
                }
                # Select Asset
                do {
                    try {
                        [int]$Selection = Read-Host "Select (1-$($FilteredAssets.Count))"
                        if (($Selection -ge 1) -and ($Selection -le $FilteredAssets.Count)) {
                            $SelectedAsset = $FilteredAssets[$Selection - 1]
                        } else {
                            Write-Host "Invalid input. Enter a number between 1 and $($FilteredAssets.Count)." -ForegroundColor Red
                        }
                    } catch {
                        Write-Host "Invalid input format. Numbers only." -ForegroundColor Red
                    }
                } until ($SelectedAsset)
            }
            return $SelectedAsset
        }

        # Download File Function
        function Download-File {
            param(
                [string]$DownloadUrl,
                [string]$FullDownloadPath
            )

            # Construct Backup Path
            $FullBackupPath = $FullDownloadPath + ".backup"
            Write-Debug "Full Backup Path: $FullBackupPath"

            # Create Backup of Existing File
            if (Test-Path $FullDownloadPath) {

                # If old backup file exists, remove it
                if (Test-Path $FullBackupPath) {
                    Remove-Item -Path $FullBackupPath -Force -ErrorAction SilentlyContinue
                }

                # Backup File
                try {
                    Rename-Item -Path $FullDownloadPath -NewName ([System.IO.Path]::GetFileName($FullBackupPath)) -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Warning "Failed to backup the original file."

                    # If download file still exists, delete it
                    if (Test-Path $FullDownloadPath) {
                        Remove-Item -Path $FullDownloadPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            
            # Download File
            try {
                Write-Host "Downloading file..." -ForegroundColor Yellow
                Invoke-WebRequest -Uri $DownloadUrl -Method Get -OutFile $FullDownloadPath -UseBasicParsing -TimeoutSec 60

                # Validate Download
                if ((Test-Path $FullDownloadPath) -and ((Get-Item $FullDownloadPath).Length -gt 0)) {

                    # Download Successful
                    Write-Host "File downloaded successfully: '$FullDownloadPath'" -ForegroundColor Green
                }
            } catch {
                # Restore Backup if Download Failed
                if (Test-Path $FullBackupPath) {

                    # If download file exists, remove it
                    if (Test-Path $FullDownloadPath) {
                        Remove-Item -Path $FullDownloadPath -Force -ErrorAction SilentlyContinue
                    }

                    # Restore File
                    try {
                        Rename-Item -Path $FullBackupPath -NewName ([System.IO.Path]::GetFileName($FullDownloadPath)) -Force -ErrorAction SilentlyContinue
                    } catch {
                        Write-Warning "Failed to restore the backup file."

                        # If backup file still exists, remove it
                        if (Test-Path $FullBackupPath) {
                            Remove-Item -Path $FullBackupPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                throw "Error occurred while downloading: $($_.Exception.Message)"
            }
        }
        
        # Extract File Function
        function Extract-File {
            param(
                [string]$FullDownloadPath,
                [string]$FullExtractionPath,
                [string]$ArchivePassword
            )
            
            # Define Extraction Tools Paths
            $WinRarPath = "$env:ProgramFiles\WinRAR\WinRAR.exe"
            $SevenZipPath = "$env:ProgramFiles\7-Zip\7z.exe"
            
            # If extraction folder does not exist, create it
            if (-not (Test-Path -Path $FullExtractionPath -PathType Container)) {
                New-Item -ItemType Directory -Path $FullExtractionPath -Force | Out-Null
            }
            
            # If extraction folder exists but is not empty, clear its contents
            if ((Get-ChildItem -Path $FullExtractionPath -Force).Count -gt 0) {
                Get-ChildItem -Path $FullExtractionPath -Recurse | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            }
            
            try {
                Write-Host "Extracting file..." -ForegroundColor Yellow
                # Method 1: Extract using built-in PowerShell for ZIP files
                if ([System.IO.Path]::GetExtension($FullDownloadPath) -eq ".zip") {
                    Write-Debug "Extracting archive using PowerShell"
                    if (-not $ArchivePassword) {
                        Expand-Archive -Path $FullDownloadPath -DestinationPath $FullExtractionPath -Force
                    }
                }

                # Method 2: Extract using 7-Zip for ZIP, RAR, 7Z files
                if ((Get-ChildItem -Path $FullExtractionPath -Force).Count -eq 0) {
                    if (Test-Path -Path $SevenZipPath) {
                        Write-Debug "Extracting archive using 7-Zip"
                        if (-not $ArchivePassword) {
                            & "$SevenZipPath" x "$FullDownloadPath" -o"$FullExtractionPath" -y > $null 2>&1
                        } else {
                            & "$SevenZipPath" x "$FullDownloadPath" -o"$FullExtractionPath" -p"$ArchivePassword" -y > $null 2>&1
                        }
                    } else {
                        Write-Host "7-Zip not found." -ForegroundColor Red
                    }
                }

                # Method 3: Extract using WinRAR for ZIP, RAR, 7Z files
                if ((Get-ChildItem -Path $FullExtractionPath -Force).Count -eq 0) {                                                 
                    if (Test-Path -Path $WinRarPath) {
                        Write-Debug "Extracting archive using WinRAR"
                        if (-not $ArchivePassword) {
                            & "$WinRarPath" x -o+ -y -ibck "$FullDownloadPath" "$FullExtractionPath\" > $null 2>&1
                        } else {
                            & "$WinRarPath" x -o+ -y -ibck -p"$ArchivePassword" "$FullDownloadPath" "$FullExtractionPath\" > $null 2>&1
                        }
                    } else {
                        Write-Host "WinRAR not found." -ForegroundColor Red
                    }
                }

                # Check Extraction Result
                if ((Get-ChildItem -Path $FullExtractionPath -Force).Count -gt 0) {
                    Write-Host "File extracted successfully: '$FullExtractionPath'" -ForegroundColor Green

                    # Remove download file
                    if (Test-Path $FullDownloadPath) {
                        Remove-Item -Path $FullDownloadPath -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                Write-Error "Error occurred while extracting file: $($_.Exception.Message)"
            }
        }
    }
    
    process {
        # Invoke GitHub Request
        if ($DownloadUrl -match "^https://github\.com/([^/]+/[^/]+)") {
            $Repo = $Matches[1]
            $ApiUrl = "https://api.github.com/repos/$Repo/releases"
            Write-Debug "GitHub API URL: $ApiUrl"
            $SelectedAsset = Github-Request -ApiUrl $ApiUrl -Filter $FileName
            $DownloadUrl = $SelectedAsset.browser_download_url
        }

        # Invoke HEAD Request
        try {
            $Response = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -TimeoutSec 30
            $ContentDisposition = $Response.Headers['Content-Disposition']
            $ContentType = $Response.Headers['Content-Type']
            $ContentLength = $Response.Headers['Content-Length']
            $NewEntityTag = $Response.Headers['ETag'] -replace '["]', ''
            $NewLastModified = $Response.Headers['Last-Modified']
            Write-Debug "Download URL: $DownloadUrl"
            Write-Debug "================================================="
            Write-Debug "Content-Disposition: $ContentDisposition"
            Write-Debug "Content-Type: $ContentType"
            Write-Debug "Content-Length: $ContentLength"
            Write-Debug "ETag: $NewEntityTag"
            Write-Debug "Last-Modified: $NewLastModified"
            Write-Debug "================================================="
        } catch {
            throw "An error occurred while retrieving metadata from HEAD request: $($_.Exception.Message)"
        }
        
        # Valid Extensions List
        [string[]]$ValidExtensions = @(".exe", ".zip", ".rar", ".7z")
        
        # Determine File Name Using Various Methods in Order of Preference
        # Method 1: Try to Get Filename from GitHub API
        if (-not $FileName) {
            $FileName = $SelectedAsset.name
            Write-Debug "FileName from GitHub API: '$FileName'"
        }

        # Method 2: Try to Get Filename from Content-Disposition
        if ((-not $FileName) -and ($ContentDisposition -match 'filename="?(.+?)(?=\.[^.]+(?:[";]|$))')) {
            $FileName = $matches[1]
            Write-Debug "FileName from ContentDisposition: '$FileName'"
        }
        
        # Method 3: Try to Get Filename from URL
        if (-not $FileName) {
            $FileName = [System.IO.Path]::GetFileName($DownloadUrl)
            $FileExtension = [System.IO.Path]::GetExtension($FileName)
            if (-not ($ValidExtensions -contains $FileExtension)) {
                $FileName = $FileName -replace '\.', ''
            }
            $FileName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
            Write-Debug "FileName from URL: '$FileName'"
        }
        
        # Method 4: Use Default Name
        if (-not $FileName) {
            $FileName = "Undefined"
            Write-Debug "FileName from Default: '$FileName'"
        }
        
        # Clean Up Filename by Removing Invalid Characters and Limiting Length
        $invalidChars = [Regex]::Escape(([System.IO.Path]::GetInvalidFileNameChars() -join ''))
        $FileName = $FileName -replace "[$invalidChars]", ""
        $FileName = $FileName.Substring(0, [Math]::Min($FileName.Length, 50))
        Write-Debug "Cleaned FileName: '$FileName'"

        # Determine File Extension Using Various Methods in Order of Preference
        # Method 1: Try to Get Extension from FileName
        if (-not ($ValidExtensions -contains $FileExtension)) {
            $FileExtension = [System.IO.Path]::GetExtension($FileName)
            if ($ValidExtensions -contains $FileExtension) {
                $FileName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
                Write-Debug "FileExtension from FileName: '$FileExtension'"
            }
        }
        
        # Method 2: Try to Get Extension from Content-Disposition
        if ((-not ($ValidExtensions -contains $FileExtension)) -and ($ContentDisposition -match 'filename=.+(\.[^\.\s"]+)"?')) {
            $FileExtension = $matches[1]
            Write-Debug "FileExtension from ContentDisposition: '$FileExtension'"
        }
        
        # Method 3: Try to Get Extension from Content-Type
        if ((-not ($ValidExtensions -contains $FileExtension)) -and ($ContentType -match '^([\w\.\-]+\/[\w\.\-]+)')) {
            $ContentType = $matches[1]
            $ContentTypeMap = @{
                "application/exe"              = ".exe"
                "application/x-msdownload"     = ".exe"
                "application/x-executable"     = ".exe"
                "application/vnd.microsoft.portable-executable" = ".exe"
                "application/zip"              = ".zip"
                "application/x-zip-compressed" = ".zip"
                "application/x-zip"            = ".zip"
                "application/vnd.rar"          = ".rar"
                "application/x-rar-compressed" = ".rar"
                "application/x-rar"            = ".rar"
                "application/x-7z-compressed"  = ".7z"
            }			 
            $FileExtension = $ContentTypeMap[$ContentType]
            Write-Debug "FileExtension from ContentType: '$FileExtension'"
        }
        
        # Method 4: Try to Get Extension from Download URL
        if (-not ($ValidExtensions -contains $FileExtension)) {
            $FileExtension = [System.IO.Path]::GetExtension($DownloadUrl)
            Write-Debug "FileExtension from URL: '$FileExtension'"
        }
        
        # Method 5: Use Default Extension
        if (-not ($ValidExtensions -contains $FileExtension)) {
            $FileExtension = ".unknown"
            Write-Debug "FileExtension from Default: '$FileExtension'"
        }
        
        # Construct Full Paths for Download, Backup, Extraction, and Metadata
        Write-Debug "================================================="
        $FullFileName = "$FileName$FileExtension"
        Write-Debug "Full File Name: $FullFileName"

        $FullDownloadPath = Join-Path -Path $DownloadPath -ChildPath $FullFileName
        Write-Debug "Full Download Path: $FullDownloadPath"

        $FullExtractionPath = Join-Path -Path $ExtractionPath -ChildPath $FileName
        Write-Debug "Full Extraction Path: $FullExtractionPath"

        $FullMetadataPath = Join-Path -Path $MetadataPath -ChildPath "Metadata.json"
        Write-Debug "Full Metadata Path: $FullMetadataPath"
        Write-Debug "================================================="
        
        # Load Metadata from JSON File
        $Data = Load-Metadata -LoadPath $FullMetadataPath

        # Retrieve Previous Metadata if Available
        if ($Data.PSObject.Properties[$FullFileName]) {
            $OldFileHash = $Data.$FullFileName.Hash
            $OldEntityTag = $Data.$FullFileName.ETag
            $OldLastModified = $Data.$FullFileName.LMod
            Write-Debug "Old File Hash: $OldFileHash"
            Write-Debug "Old ETag: $OldEntityTag"
            Write-Debug "Old Last-Modified: $OldLastModified"
        }
        
        # Determine if Update is Needed by Comparing Metadata
        $Difference = 0
        
        if ((-not (Test-Path $FullDownloadPath)) -and (Test-Path $FullExtractionPath -PathType Container)) {
            if ((Get-ChildItem -Path $FullExtractionPath -Force).Count -eq 0) {
                $Difference++
                Write-Debug "File is missing and the folder is empty"
            }
        }        

        if (Test-Path $FullDownloadPath) {
            $NewFileHash = (Get-FileHash -Path $FullDownloadPath -Algorithm MD5).Hash
            if ($NewFileHash -ne $OldFileHash) {
                $Difference++
                Write-Debug "FileHash is different"
            }
        }
        
        if ($NewEntityTag -ne $OldEntityTag) {
            $Difference++
            Write-Debug "Entity Tag is different"
        }
        
        if ($NewLastModified -ne $OldLastModified) {
            $Difference++
            Write-Debug "LastModified is different"
        }
        
        if ($ForceDownload -eq $true) {
            $Difference++
            Write-Debug "ForceDownload is enabled"
        }
        
        # Download File if Update is Needed
        if ($Difference -gt 0) {
            Write-Host "New version available for: $FileName" -ForegroundColor Yellow

            # Display File Size
            if ($ContentLength) {
                Write-Host "File size: $(Format-FileSize -Bytes $ContentLength)" -ForegroundColor Yellow
            } else {
                Write-Host "File size: Unable to retrieve from server." -ForegroundColor Yellow
            }

            # Download File
            Download-File -DownloadUrl $DownloadUrl -FullDownloadPath $FullDownloadPath

            # Get Hash for the New File
            $NewFileHash = (Get-FileHash -Path $FullDownloadPath -Algorithm MD5).Hash
            
            # Update Metadata
            $Data = Update-Metadata -UpdateData $Data -FileKey $FullFileName -Hash $NewFileHash -ETag $NewEntityTag -LMod $NewLastModified
        } else {
            Write-Host "File is already up-to-date: $FileName" -ForegroundColor Green
        }
        
        # Extractable Extensions List
        [string[]]$ExtractableExtensions = @(".zip", ".rar", ".7z")
        
        # Extract File if Extension is Extractable
        if ($ExtractableExtensions -Contains $FileExtension) {
            if ((-not (Test-Path $FullExtractionPath -PathType Container)) -or ((Get-ChildItem -Path $FullExtractionPath -Force).Count -eq 0)) {
                Extract-File -FullDownloadPath $FullDownloadPath -FullExtractionPath $FullExtractionPath -ArchivePassword $ArchivePassword
            }   
        }
    }
    
    end {
        # If file missing and the folder is empty and file metadata exist remove metadata
        if ((-not (Test-Path $FullDownloadPath)) -and (Test-Path $FullExtractionPath -PathType Container)) {
            if ((Get-ChildItem -Path $FullExtractionPath -Force).Count -eq 0) {
                Remove-Metadata -RemoveData $Data -FileKey $FullFileName
            }
        }

        # Save Updated Metadata
        Save-Metadata -SavePath $FullMetadataPath -SaveData $Data

        # Output Metadata for Debugging Purposes
        $Data.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{
                File = $_.Name
                Hash = $_.Value.Hash
                ETag = $_.Value.ETag
                LMod = $_.Value.LMod
            }
        } | Format-List | Out-String | Write-Debug

        # Separate Invokes Each Other
        Write-Host ""
    }
}
