function Get-Download {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^https?://')]
        [string]$DownloadUrl,

        [ValidateScript({
            if (-not (Test-Path -Path $_ -PathType Container)) {
                throw "Invalid download folder path: '$_'"
            }
            return $true
        })]
        [string]$DownloadPath = $PWD.Path,

        [ValidateScript({
            if (-not (Test-Path -Path $_ -PathType Container)) {
                throw "Invalid metadata folder path: '$_'"
            }
            return $true
        })]
        [string]$MetadataPath = $PWD.Path,

        [ValidateScript({
            if (-not (Test-Path -Path $_ -PathType Container)) {
                throw "Invalid extraction folder path: '$_'"
            }
            return $true
        })]
        [string]$ExtractionPath = $PWD.Path,

        [string]$FileName,

        [string]$GithubFilter,

        [string]$ArchivePassword,

        [switch]$ForceDownload,

        [ValidateSet('Always','Needed','Never')]
        [string]$Script:CreateFolder = 'Needed',

        [switch]$SelectLatest,

        [switch]$DebugMode = $false
    )

    # Set Debug Preference
    $DebugPreference = if ($DebugMode) { "Continue" } else { "SilentlyContinue" }

    # Invoke GitHub Request
    if ($DownloadUrl -match "^https://github\.com/([^/]+/[^/]+)") {
        $ApiUrl = "https://api.github.com/repos/$($Matches[1])/releases"
        Write-Debug "GitHub API URL: $ApiUrl"
        $SelectedAsset = Github-Request -ApiUrl $ApiUrl -Filter $GithubFilter
        $DownloadUrl = $SelectedAsset.browser_download_url

        # Method 1: Try to Get Filename from GitHub API
        if (-not $FileName) {
            $FileName = $SelectedAsset.name
            Write-Debug "FileName from GitHub API: '$FileName'"
        }
    }

    Write-Debug "Download URL: $DownloadUrl"

    # Invoke HEAD Request
    try {
        $Response = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -TimeoutSec 30
        $ContentDisposition = $Response.Headers['Content-Disposition']
        $ContentType = $Response.Headers['Content-Type']
        $Script:ContentLength = $Response.Headers['Content-Length']
        $EntityTag = $Response.Headers['ETag'] -replace '["]', ''
        $LastModified = $Response.Headers['Last-Modified']
        Write-Debug "Content-Disposition: $ContentDisposition"
        Write-Debug "Content-Type: $ContentType"
        Write-Debug "Content-Length: $Script:ContentLength"
        Write-Debug "Entity-Tag: $EntityTag"
        Write-Debug "Last-Modified: $LastModified"
    } catch {
        Write-Error "An error occurred while retrieving metadata from HEAD request: $($_.Exception.Message)"
    }
    
    # Valid Extensions List
    [string[]]$ValidExtensions = @(".exe", ".zip", ".rar", ".7z")

    # Extractable Extensions List
    [string[]]$ExtractableExtensions = @(".zip", ".rar", ".7z")
    
    # Determine File Name Using Various Methods in Order of Preference
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
        Write-Host "'$FileName' URL file name for '$DownloadUrl'" -ForegroundColor Yellow
        Write-Debug "FileName from URL: '$FileName'"
    }
    
    # Method 4: Use Default Name
    if (-not $FileName) {
        $FileName = "Undefined"
        Write-Host "'$FileName' Default file name for '$DownloadUrl'" -ForegroundColor Yellow
        Write-Debug "FileName from Default: '$FileName'"
    }
    
    # Clean Up Filename by Removing Invalid Characters and Limiting Length
    $InvalidChars = [Regex]::Escape(([System.IO.Path]::GetInvalidFileNameChars() -join ''))
    $FileName = $FileName -replace "[$InvalidChars]", ""
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
    
    # Check file extension exists
    if (-not ($ValidExtensions -contains $FileExtension)) {
        Write-Error "'$FileExtension' file extension not recognized for '$DownloadUrl'"
    }
    
    # Construct Full Paths for Download, Backup, Extraction, and Metadata
    $FileExtension = $FileExtension.ToLowerInvariant()
    $FullFileName = "$FileName$FileExtension"
    Write-Debug "Full File Name: $FullFileName"

    if ($Script:CreateFolder -eq 'Always') {
        $FullDownloadPath = Join-Path -Path $DownloadPath -ChildPath $FileName
        Create-Folder -FolderPath $FullDownloadPath
        $FullDownloadPath = Join-Path -Path $FullDownloadPath -ChildPath $FullFileName
    }
    else {
        $FullDownloadPath = Join-Path -Path $DownloadPath -ChildPath $FullFileName
    }
    Write-Debug "Full Download Path: $FullDownloadPath"

    if ($Script:CreateFolder -eq 'Always') {
        $FullExtractionPath = Join-Path -Path $ExtractionPath -ChildPath $FileName
    }
    elseif ($Script:CreateFolder -eq 'Needed') {
        if ($ExtractableExtensions -Contains $FileExtension) {
            $FullExtractionPath = Join-Path -Path $ExtractionPath -ChildPath $FileName
        }
        else {
            $FullExtractionPath = $ExtractionPath
        }
    }
    elseif ($Script:CreateFolder -eq 'Never') {
        $FullExtractionPath = $ExtractionPath
    }
    Write-Debug "Full Extraction Path: $FullExtractionPath"
    Create-Folder -FolderPath $FullExtractionPath

    $FullMetadataPath = Join-Path -Path $MetadataPath -ChildPath "Metadata.json"
    Write-Debug "Full Metadata Path: $FullMetadataPath"

    # Load Metadata from JSON File
    $Data = Load-Metadata -LoadPath $FullMetadataPath

    # Retrieve Previous Metadata if Available
    if ($Data.PSObject.Properties[$FullFileName]) {
        $OldDownloadPath = $Data.$FullFileName.Path
        $OldFileHash = $Data.$FullFileName.Hash
        $OldEntityTag = $Data.$FullFileName.ETag
        $OldLastModified = $Data.$FullFileName.LMod
        Write-Debug "Old Download Path: $OldDownloadPath"
        Write-Debug "Old File Hash: $OldFileHash"
        Write-Debug "Old ETag: $OldEntityTag"
        Write-Debug "Old Last-Modified: $OldLastModified"
    }

    # Determine if Update is Needed by Comparing Metadata
    $Difference = 0
    
    if ((-not (Test-Path -Path $FullDownloadPath)) -and (Test-Path -Path $FullExtractionPath -PathType Container)) {
        if ((Get-ChildItem -Path $FullExtractionPath -Force).Count -eq 0) {
            $Difference++
            Write-Debug "File is missing and the folder is empty"
        }
    }

    if (Test-Path -Path $FullDownloadPath) {
        $FileHash = (Get-FileHash -Path $FullDownloadPath -Algorithm MD5).Hash
        if ($FileHash -ne $OldFileHash) {
            $Difference++
            Write-Debug "FileHash is different"
        }
    }

    if ($DownloadPath -ne $OldDownloadPath) {
        $Difference++
        Write-Debug "File Path is different"
    }

    if ($EntityTag -ne $OldEntityTag) {
        $Difference++
        Write-Debug "Entity Tag is different"
    }
    
    if ($LastModified -ne $OldLastModified) {
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
        if ($Script:ContentLength) {
            Write-Host "File size: $(Format-FileSize -Bytes $Script:ContentLength)" -ForegroundColor Yellow
        } else {
            Write-Host "File size: Unable to retrieve from server." -ForegroundColor Yellow
        }

        # Download File
        Download-File -DownloadUrl $DownloadUrl -DownloadPath $FullDownloadPath

        # Get Hash for the New File
        $FileHash = (Get-FileHash -Path $FullDownloadPath -Algorithm MD5).Hash
        
        Write-Host $DownloadPath

        # Update Metadata
        $Data = Update-Metadata -UpdateData $Data -FileKey "$FullFileName" -Path $DownloadPath -Hash $FileHash -ETag $EntityTag -LMod $LastModified
    } else {
        Write-Host "File is already up-to-date: $FileName" -ForegroundColor Green
    }
        
    # Extract File if Extension is Extractable
    if ($ExtractableExtensions -Contains $FileExtension) {
        if ($Difference -gt 0) {
            Extract-File -ArchivePath $FullDownloadPath  -ExtractionPath $FullExtractionPath  -ArchivePassword $ArchivePassword
        }
    }
    
    # If file missing but metadata exist remove metadata
    $Data.PSObject.Properties | ForEach-Object {
        $FileName = $_.Name
        $Path = $_.Value.Path
        $FullOldFilePath = Join-Path -Path $Path -ChildPath $FileName
        if (-not (Test-Path -Path $FullOldFilePath)) {
            Remove-Metadata -RemoveData $Data -FileKey $FileName
        }
    }
    
    # Save Updated Metadata
    Save-Metadata -SavePath $FullMetadataPath -SaveData $Data

    # Output Metadata for Debugging Purposes
    $Data.PSObject.Properties | ForEach-Object {
        [PSCustomObject]@{
            File = $_.Name
            Path = $_.Value.Path
            Hash = $_.Value.Hash
            ETag = $_.Value.ETag
            LMod = $_.Value.LMod
        }
    } | Format-List | Out-String | Write-Debug

    # Separate Invokes Each Other
    Write-Host ""
}

# Load Metadata Function
function Load-Metadata {
    param (
        [string]$LoadPath
    )

    try {
        if (Test-Path -Path $LoadPath) {
            return Get-Content -Path $LoadPath -Raw | ConvertFrom-Json
        }
        else {
            return [PSCustomObject]@()
        }
    }
    catch {
        Write-Error "Failed to load metadata from '$LoadPath': $($_.Exception.Message)"
        return [PSCustomObject]@{}
    }
}

# Save Metadata Function
function Save-Metadata {
    param (
        [string]$SavePath,
        [PSCustomObject]$SaveData
    )

    try {
        $SaveData | ConvertTo-Json -Depth 10 | Set-Content -Path $SavePath -Force -Encoding UTF8
    }
    catch {
        Write-Error "Failed to save metadata to '$SavePath': $($_.Exception.Message)"
    }
}

# Add or Update Metadata Function
function Update-Metadata {
    param (
        [PSCustomObject]$UpdateData,
        [string]$FileKey,
        [string]$Path,
        [string]$Hash,
        [string]$ETag,
        [string]$LMod
    )

    try {
        Write-Debug "Key: $FileKey"
        Write-Debug "Path: $Path"
        Write-Debug "Hash: $Hash"
        Write-Debug "ETag: $ETag"
        Write-Debug "LMod: $LMod"

        if ($UpdateData.PSObject.Properties[$FileKey]) {
            Write-Debug "Updating existing metadata..."
            $UpdateData.$FileKey.Path = $Path
            $UpdateData.$FileKey.Hash = $Hash
            $UpdateData.$FileKey.ETag = $ETag
            $UpdateData.$FileKey.LMod = $LMod
        }
        else {
            Write-Debug "Adding new metadata entry..."
            Add-Member -InputObject $UpdateData -MemberType NoteProperty -Name $FileKey -Value (
                [PSCustomObject]@{
                    Path = $Path
                    Hash = $Hash
                    ETag = $ETag
                    LMod = $LMod
                }
            )
        }

        return $UpdateData
    }
    catch {
        Write-Error "Failed to update metadata for key '$FileKey': $($_.Exception.Message)"
    }
}

# Remove Metadata Function
function Remove-Metadata {
    param (
        [PSCustomObject]$RemoveData,
        [string]$FileKey
    )

    try {
        if ($RemoveData.PSObject.Properties.Match($FileKey)) {
            $RemoveData.PSObject.Properties.Remove($FileKey)
        }
        return $RemoveData
    }
    catch {
        Write-Error "Failed to remove metadata for key '$FileKey': $($_.Exception.Message)"
    }
}

# Format FileSize Function
function Format-FileSize {
    param (
        [ValidateNotNull()]
        [long]$Bytes
    )

    try {
        if ($Bytes -ge 1GB) {
            return "{0:N2} GB" -f ($Bytes / 1GB)
        }
        elseif ($Bytes -ge 1MB) {
            return "{0:N2} MB" -f ($Bytes / 1MB)
        }
        elseif ($Bytes -ge 1KB) {
            return "{0:N2} KB" -f ($Bytes / 1KB)
        }
        else {
            return "$Bytes B"
        }
    }
    catch {
        Write-Error "Failed to format file size: $($_.Exception.Message)"
    }
}

# Create Folder Function
function Create-Folder {
    param (
        [ValidateNotNullOrEmpty()]
        [string]$FolderPath
    )

    try {
        if (-not (Test-Path -Path $FolderPath -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $FolderPath -Force)
            Write-Debug "Created folder: $FolderPath"
        }
    }
    catch {
        Write-Error "An error occurred while creating folder '$FolderPath': $($_.Exception.Message)"
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
    }
    catch {
        Write-Error "Failed to retrieve GitHub releases: $($_.Exception.Message)"
    }
    
    # Get Release Type
    $Stable = $Releases | Where-Object { -not $_.prerelease }
    $EarlyAccess = $Releases | Where-Object { $_.prerelease }

    # If exist select Stable else EarlyAccess
    if ($Stable.Count -gt 0) {
        $Releases = $Stable
    }
    elseif ($EarlyAccess.Count -gt 0) {
        $Releases = $EarlyAccess
    }
    else {
        Write-Error "No releases found in GitHub repository: '$ApiUrl'"
    }
    
    # Sort Releases and Select Latest
    $LatestRelease = $Releases | Sort-Object -Property published_at -Descending | Select-Object -First 1

    # Filter Assets
    [array]$FilteredAssets = if ($Filter) {
        $LatestRelease.assets | Where-Object { $_.name -like "$Filter" }
    }
    else {
        $LatestRelease.assets | Select-Object name, browser_download_url
    }
    if (-not $FilteredAssets) {
        Write-Error "No matching assets found. Verifiy filter: '$Filter'"
    }
    
    # Select Asset Automatically or Prompt User if Multiple Matches Found
    if ($FilteredAssets.Count -eq 1) {
        # Auto select asset
        $SelectedAsset = $FilteredAssets[0]
    }
    elseif ($FilteredAssets.Count -gt 1) {
        if ($SelectLatest -eq $true) {
            # Auto select latest asset
            $SelectedAsset = $FilteredAssets | Sort-Object -Property created_at -Descending | Select-Object -First 1
        }
        else {
            # Prompt user to select asset
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
                    }
                    else {
                        Write-Host "Invalid input. Enter a number between 1 and $($FilteredAssets.Count)." -ForegroundColor Red
                    }
                }
                catch {
                    Write-Host "Invalid input format. Numbers only." -ForegroundColor Red
                }
            } until ($SelectedAsset)
        }
    }
    return $SelectedAsset
}

# Download File Function
function Download-File {
    param(
        [string]$DownloadUrl,
        [string]$DownloadPath
    )

    # Construct Backup Path
    $BackupPath = "${DownloadPath}.backup"
    Write-Debug "Download Backup Path: $BackupPath"

    # Create Backup of Existing File
    if (Test-Path -Path $DownloadPath) {
        try {
            if (Test-Path -Path $BackupPath) {
                [void](Remove-Item -Path $BackupPath -Force)
            }

            Rename-Item -Path $DownloadPath -NewName ([System.IO.Path]::GetFileName($BackupPath)) -Force
        }
        catch {
            Write-Warning "Failed to backup the original file."

            if (Test-Path -Path $DownloadPath) {
                [void](Remove-Item -Path $DownloadPath -Force)
            }
        }
    }

    # Download File
    try {
        Write-Host "Downloading file..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $DownloadUrl -Method Get -OutFile $DownloadPath -UseBasicParsing -TimeoutSec 60

        if (Test-Path -Path $DownloadPath) {
            $FileLength = (Get-Item $DownloadPath).Length

            if ($null -ne $Script:ContentLength) {
                if ($FileLength -eq $Script:ContentLength) {
                    $DownloadSuccessful = $true
                }
                else {
                    Write-Warning "File size mismatch! Expected: $Script:ContentLength bytes, Actual: $FileLength bytes."
                }
            }
            elseif ($FileLength -gt 0) {
                $DownloadSuccessful = $true
            }
        }

        if ($DownloadSuccessful) {
            Write-Host "File downloaded successfully: '$DownloadPath'" -ForegroundColor Green

            if (Test-Path -Path $BackupPath) {
                [void](Remove-Item -Path $BackupPath -Force)
            }
        }
    }
    catch {
        Write-Error "An error occurred while downloading: $($_.Exception.Message)"

        # Restore Backup if Download Failed
        if (Test-Path -Path $BackupPath) {
            if (Test-Path -Path $DownloadPath) {
                [void](Remove-Item -Path $DownloadPath -Force)
            }

            try {
                Rename-Item -Path $BackupPath -NewName ([System.IO.Path]::GetFileName($DownloadPath)) -Force
                Write-Warning "Backup restored."
            }
            catch {
                Write-Warning "Failed to restore the backup file."

                if (Test-Path -Path $BackupPath) {
                    [void](Remove-Item -Path $BackupPath -Force)
                }
            }
        }
    }
}

# Extract File Function
function Extract-File {
    param (
        [string]$ArchivePath,
        [string]$ExtractionPath,
        [string]$ArchivePassword
    )

    function Test-Extraction {
        param (
            [string]$Path
        )
        return ([void](Get-ChildItem -Path $Path -Recurse -Force) | Where-Object { -not $_.PSIsContainer }).Count -gt 0
    }

    $SevenZipPath = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    $WinRarPath   = Join-Path $env:ProgramFiles 'WinRAR\Rar.exe'
    $FileExtension = [System.IO.Path]::GetExtension($ArchivePath)
    $FileExtracted = $false
    $BackupPath = "${ExtractionPath}_backup"
    Write-Debug "Extraction Backup Path: $BackupPath"

    if (($FileExtension -in '.rar', '.7z') -and (-not (Test-Path -Path $SevenZipPath)) -and (-not (Test-Path -Path $WinRarPath))) {
        Write-Warning "Neither 7-Zip nor WinRAR is installed. Cannot extract '$FileExtension' archive '$ArchivePath'."
    }
    
    if ($Script:CreateFolder -ne "Never") {
        if (Test-Path -Path $ExtractionPath) {
            try {
                if (Test-Path -Path $BackupPath) {
                    [void](Remove-Item -Path $BackupPath -Force)
                }

                Rename-Item -Path $ExtractionPath -NewName ([System.IO.Path]::GetFileName($BackupPath)) -Force
            }
            catch {
                Write-Warning "Failed to backup the original file."
                
                if (Test-Path -Path $ExtractionPath) {
                    [void](Get-ChildItem -Path $ExtractionPath -Force | Remove-Item -Recurse -Force)
                }
                else {
                    [void](New-Item -Path $ExtractionPath -ItemType Directory -Force)
                }
            }
        }
    }
    
    # Method 1: PowerShell (Zip Only - No Password)
    if ((-not $FileExtracted) -and ($FileExtension -eq '.zip') -and (-not $ArchivePassword)) {
        Write-Debug "Extracting archive using PowerShell..."
        try {
            Expand-Archive -Path $ArchivePath -DestinationPath $ExtractionPath
            if (Test-Extraction -Path $ExtractionPath) { $FileExtracted = $true }
        }
        catch {
            Write-Warning "Extraction failed with PowerShell: $($_.Exception.Message)"
        }
    }

    # Method 2: 7-Zip CLI
    if (-not $FileExtracted -and (Test-Path -Path $SevenZipPath)) {
        Write-Debug "Extracting archive using 7-Zip..."
        $SevenZipArgs = @("x", "-y")
        if ($ArchivePassword) { $SevenZipArgs += "-p$ArchivePassword" }
        $SevenZipArgs += "-o$ExtractionPath", "$ArchivePath"
        try {
            & $SevenZipPath @SevenZipArgs > $null 2>&1
            if (Test-Extraction -Path $ExtractionPath) { $FileExtracted = $true }
        }
        catch {
            Write-Warning "Extraction failed with 7-Zip: $($_.Exception.Message)"
        }
    }

    # Method 3: WinRAR CLI
    if (-not $FileExtracted -and (Test-Path -Path $WinRarPath)) {
        Write-Debug "Extracting archive using WinRAR..."
        $WinRarArgs = @("x", "-o+", "-y", "-inul", "-ibck")
        if ($ArchivePassword) { $WinRarArgs += "-p$ArchivePassword" }
        $WinRarArgs += "$ArchivePath", "$ExtractionPath"
        try {
            & $WinRarPath @WinRarArgs > $null 2>&1
            if (Test-Extraction -Path $ExtractionPath) { $FileExtracted = $true }
        }
        catch {
            Write-Warning "Extraction failed with WinRAR: $($_.Exception.Message)"
        }
    }

    # Check Extraction Result
    if ($FileExtracted) {
        Write-Host "Extraction succesfull: '$ExtractionPath'." -ForegroundColor Green
        Remove-Item -Path $ArchivePath -Force

        if (Test-Path -Path $BackupPath) {
            [void](Remove-Item -Path $BackupPath -Force)
        }
    }
    else {
        Write-Error "An error occurred while extracting: $($_.Exception.Message)"

        # Restore Backup if Extraction Failed
        if (Test-Path -Path $BackupPath) {
            if (Test-Path -Path $ExtractionPath) {
                [void](Remove-Item -Path $ExtractionPath -Force)
            }

            try {
                Rename-Item -Path $BackupPath -NewName ([System.IO.Path]::GetFileName($ExtractionPath)) -Force
                Write-Warning "Backup restored."
            }
            catch {
                Write-Warning "Failed to restore the backup file."

                if (Test-Path -Path $BackupPath) {
                    [void](Remove-Item -Path $BackupPath -Force)
                }
            }
        }
    }
}
