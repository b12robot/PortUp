function Get-Download {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^https?://')]
        [string]$DownloadUrl,

        [string]$FileName,
        
		[ValidateScript({
			if (-not (Test-Path "$_" -PathType Container)) {
				Write-Host "Invalid download folder path: '$_'" -ForegroundColor Red
				exit 1
            }
        })]
        [string]$DownloadPath = $PWD.Path,
		
		[ValidateScript({
			if (-not (Test-Path "$_" -PathType Container)) {
				Write-Host "Invalid metadata folder path: '$_'" -ForegroundColor Red
				exit 1
            }
        })]
        [string]$MetadataPath = $PWD.Path,
		
		[ValidateScript({
			if (-not (Test-Path "$_" -PathType Container)) {
				Write-Host "Invalid extraction folder path: '$_'" -ForegroundColor Red
				exit 1
            }
        })]
        [string]$ExtractionPath = $PWD.Path,
		
        [string]$ArchivePassword = $null,
		
		[switch]$ExtractArchive = $true,
		
		[switch]$CreateFolder = $true,
		
		[switch]$ForceDownload = $false,
		
		[switch]$UpgradeHttp = $true,
		
		[switch]$DebugMode = $true
    )
	
    begin {
		# Set ExecutionPolicy
		Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
		
		# Configure debug preference
		$DebugPreference = if ($DebugMode) { "Continue" } else { "SilentlyContinue" }
		
		# Content Type Map list
		[hashtable]$ContentTypeMap = @{
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
		
		# Validate Extension function
		function Validate-Extension {
			param (
				[string]$FileExtension,
				[string[]]$ValidExtensions = @(".exe", ".zip", ".rar", ".7z")
			)
			return (-not ($ValidExtensions -Contains $FileExtension))
		}
		
		# Save Metadata to JSON file function
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
		
		# Load Metadata from JSON file function
		function Load-Metadata {
			param (
				[string]$LoadPath
			)
			try {
				if (Test-Path $LoadPath) {
					return Get-Content -Path $LoadPath -Raw | ConvertFrom-Json
				} else {
					return @{}
				}
			} catch {
				throw "An error occurred while reading metadata file: $($_.Exception.Message)"
			}
		}
		
		# Format FileSize function
		function Format-FileSize {
			param(
				[long]$Bytes
			)
			switch ($Bytes) {
				{ $_ -ge 1GB } { return "{0:N2} GB" -f ($_ / 1GB) }
				{ $_ -ge 1MB } { return "{0:N2} MB" -f ($_ / 1MB) }
				{ $_ -ge 1KB } { return "{0:N2} KB" -f ($_ / 1KB) }
				default { return "$_ bytes" }
			}
		}
		
		# Update http requests to https
		if ($DownloadUrl.StartsWith("http:")) {
			if ($UpgradeHttp -eq $true) {
				$DownloadUrl = $DownloadUrl -replace 'http:', 'https:'
			}
		}
		
		# Handle GitHub requests
		if ($DownloadUrl -match "^https://github\.com/([^/]+/[^/]+)") {
			$Repo = $Matches[1]
			$ApiUrl = "https://api.github.com/repos/$Repo/releases"
			Write-Debug "GitHub API URL: $ApiUrl"
			
			# Get releases from GitHub
			try {
				$Releases = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -TimeoutSec 30
			} catch {
				throw "Failed to retrieve GitHub releases: $($_.Exception.Message)"
			}
			
			# Get release type
			$Stable = $Releases | Where-Object { -not $_.prerelease }
			$EarlyAccess = $Releases | Where-Object { $_.prerelease }
			
			if ($Stable.Count -gt 0) {
				$Releases = $Stable
			} elseif ($EarlyAccess.Count -gt 0) {
				$Releases = $EarlyAccess
			} else {
				Write-Host "No releases found in GitHub repository. Verify URL or filters." -ForegroundColor Red
				exit 1
			}
			
			# Sort releases and select latest
			$LatestReleases = $Releases | Sort-Object -Property published_at -Descending | Select-Object -First 1
			
			# Filter assets with filename
			[array]$FilteredAssets = if ($FileName) {
				$LatestReleases.assets | Where-Object { $_.name -like "$FileName" }
			} else {
				$LatestReleases.assets | Select-Object name, browser_download_url
			}
			
			if (-not $FilteredAssets) {
				Write-Host "No matching assets found. Verify filename filter." -ForegroundColor Red
				exit 1
			}
			
			# Select asset automatically or prompt user if multiple matches found
			if ($FilteredAssets.Count -eq 1) {
				$SelectedAsset = $FilteredAssets[0]
			} elseif ($FilteredAssets.Count -gt 1) {
				$Count = 0
				foreach ($Asset in $FilteredAssets) {
					$Count++
					Write-Host "$Count. $($Asset.name)"
				}
				do {
					try {
						[int]$Selection = Read-Host "Select (1-$($FilteredAssets.Count))"
						if ($Selection -match "^[1-9]\d+$" -and $Selection -le $FilteredAssets.Count) {
							$SelectedAsset = $FilteredAssets[$Selection - 1]
						} else {
							Write-Host "Invalid input. Enter a number between 1 and $($FilteredAssets.Count)." -ForegroundColor Red
						}
					} catch {
						Write-Host "Invalid input format. Numbers only." -ForegroundColor Red
					}
				} until ($SelectedAsset)
			}
			
			# Define file name and download URL
			$FileName = $SelectedAsset.name
			$DownloadUrl = $SelectedAsset.browser_download_url
		}
    }
	
    process {
        try {
			# Invoke HEAD request to get metadata
            $Response = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -TimeoutSec 30
            $ContentDisposition = $Response.Headers['Content-Disposition']
            $ContentType = $Response.Headers['Content-Type']
            $ContentLength = $Response.Headers['Content-Length']
            $NewETag = $Response.Headers['ETag'] -replace '["]', ''
            $NewLastModified = $Response.Headers['Last-Modified']
            Write-Debug "Download URL: $DownloadUrl"
            Write-Debug "================================================="
            Write-Debug "Content-Disposition: $ContentDisposition"
            Write-Debug "Content-Type: $ContentType"
            Write-Debug "Content-Length: $ContentLength"
            Write-Debug "ETag: $NewETag"
            Write-Debug "Last-Modified: $NewLastModified"
            Write-Debug "================================================="
        } catch {
            throw "An error occurred while retrieving metadata from HEAD request: $($_.Exception.Message)"
        }
		
        # Determine file name using various methods in order of preference
        # Method 1: Try to get filename from Content-Disposition
		if ((-not $FileName) -and ($ContentDisposition -match 'filename="?(.+?)(?=\.[^.]+(?:[";]|$))')) {
			$FileName = $matches[1]
			Write-Debug "FileName from ContentDisposition: '$FileName'"
		}
		
		# Method 2: Try to get filename from URL
		if (-not $FileName) {
			$FileName = [System.IO.Path]::GetFileName($DownloadUrl)
			$FileExtension = [System.IO.Path]::GetExtension($FileName)
			if (Validate-Extension -FileExtension $FileExtension) {
				$FileName = $FileName -replace '\.', ''
			}
			$FileName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
			Write-Debug "FileName from URL: '$FileName'"
		}
		
		# # Method 3: Use default name
		if (-not $FileName) {
			$FileName = "Undefined"
			Write-Debug "FileName from Default: '$FileName'"
		}
		
		# Clean up filename by removing invalid characters and limiting length
		$FileName = $FileName -replace "[{0}=]" -f ([System.IO.Path]::GetInvalidFileNameChars() -join '')
		$FileName = $FileName.Substring(0, [Math]::Min($FileName.Length, 50))
		Write-Debug "Cleaned FileName: '$FileName'"
		
		# Determine file extension using various methods in order of preference
        # Method 1: Try to get extension from filename
		if (Validate-Extension -FileExtension $FileExtension) {
			$FileExtension = [System.IO.Path]::GetExtension($FileName)
			if (-not $FileExtension) {}
			$FileName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
			Write-Debug "FileExtension from FileName: '$FileExtension'"
		}
		
		# Method 2: Try to get extension from Content-Disposition
		if ((Validate-Extension -FileExtension $FileExtension) -and ($ContentDisposition -match 'filename=.+(\.[^\.\s"]+)"?')) {
			$FileExtension = $matches[1]
			Write-Debug "FileExtension from ContentDisposition: '$FileExtension'"
		}
		
		# Method 3: Try to get extension from Content-Type
		if ((Validate-Extension -FileExtension $FileExtension) -and ($ContentType -match '^([\w\.\-]+\/[\w\.\-]+)')) {
			$ContentType = $matches[1]
			$FileExtension = $ContentTypeMap[$ContentType]
			Write-Debug "FileExtension from ContentType: '$FileExtension'"
		}
		
		# Method 4: Try to get extension from download URL
		if (Validate-Extension -FileExtension $FileExtension) {
			$FileExtension = [System.IO.Path]::GetExtension($DownloadUrl)
			Write-Debug "FileExtension from URL: '$FileExtension'"
		}
		
		# Method 5: Use default extension
		if (Validate-Extension -FileExtension $FileExtension) {
			$FileExtension = ".unknown"
			Write-Debug "FileExtension from Default: '$FileExtension'"
		}
		
        # Construct full paths for download, backup, extraction, and metadata
        $FullFileName = "$FileName$FileExtension"
        $FullDownloadPath = Join-Path -Path $DownloadPath -ChildPath $FullFileName
        $FullBackupPath = $FullDownloadPath + ".backup"
		if ($CreateFolder -eq $true) {
			$FullExtractionPath = Join-Path -Path $ExtractionPath -ChildPath $FileName
			$FullBackupFolderPath = Join-Path -Path $FullExtractionPath -ChildPath "Backup"
		} else {
			$FullExtractionPath = $ExtractionPath
			$FullBackupFolderPath = $FullExtractionPath
		}
        $FullMetadataPath = Join-Path -Path $MetadataPath -ChildPath "Metadata.json"
        Write-Debug "Full File Name: $FullFileName"
        Write-Debug "================================================="
        Write-Debug "Full Download Path: $FullDownloadPath"
        Write-Debug "Full Backup Path: $FullBackupPath"
        Write-Debug "Full Extraction Path: $FullExtractionPath"
        Write-Debug "Full Metadata Path: $FullMetadataPath"
		Write-Debug "================================================="
		
		
		
		# Load metadata from JSON file
		$Data = Load-Metadata -LoadPath $FullMetadataPath
		
		# Retrieve previous metadata if available
		if ($Data.PSObject.Properties[$FullFileName]) {
			$OldFileHash = $Data.$FullFileName.Hash
			$OldETag = $Data.$FullFileName.ETag
			$OldLastModified = $Data.$FullFileName.LMod
			Write-Debug "Old File Hash: $OldFileHash"
			Write-Debug "Old ETag: $OldETag"
			Write-Debug "Old Last-Modified: $OldLastModified"
		}
		
		# Determine if update is needed by comparing metadata
		$Difference = 0
		
		if ((-not (Test-Path $FullDownloadPath)) -and 
			(Test-Path -Path $FullExtractionPath -PathType Container) -and 
			((Get-ChildItem -Path $FullExtractionPath -Force | Measure-Object).Count -eq 0)) {
			$Difference++
			Write-Debug "File missing and folder hasn't have contents"
		}

		if (Test-Path $FullDownloadPath) {
			$NewFileHash = (Get-FileHash -Path $FullDownloadPath -Algorithm MD5).Hash
			if ($NewFileHash -ne $OldFileHash) {
				$Difference++
				Write-Debug "FileHash is diffrent"
			}
		}
		
		if ($NewETag -ne $OldETag) {
			$Difference++
			Write-Debug "ETag is diffrent"
		}
		
		if ($NewLastModified -ne $OldLastModified) {
			$Difference++
			Write-Debug "LastModified is diffrent"
		}
		
		if ($ForceDownload -eq $true) {
			$Difference++
			Write-Debug "ForceDownload is enabled"
		}
		
		# Download file if update is needed
		if ($Difference -gt 0) {
		Write-Host "New version available for: '$FullFileName'"
			
			# Display file size
			if ($ContentLength) {	
				Write-Host "File size: $(Format-FileSize -Bytes $ContentLength)"
			} else {
				Write-Host "File size: Unable to retrieve from server."
			}
			
			# Create backup of existing file
			if (Test-Path $FullDownloadPath) {
				if (Test-Path $FullBackupPath) {
					Remove-Item -Path $FullBackupPath -Force
				}
				Write-Host "Creating backup file..."
				Rename-Item -Path $FullDownloadPath -NewName ([System.IO.Path]::GetFileName($FullBackupPath)) -Force
				if (Test-Path $FullBackupPath) {
					Write-Host "Backup file successfully created."
				} else {
					Write-Host "Backup file could not be created."
					if (Test-Path $FullDownloadPath) {
						Remove-Item -Path $FullDownloadPath -Force
					}
				}
			}
			
			# Download file
			try {
				Write-Host "Downloading file..."
				Invoke-WebRequest -Uri $DownloadUrl -Method Get -OutFile $FullDownloadPath -UseBasicParsing -TimeoutSec 60
			} catch {
				Write-Host "Error occurred while downloading file: $($_.Exception.Message)" -ForegroundColor Red
			}
			
			# Validate download
			if ((Test-Path $FullDownloadPath) -and ((Get-Item $FullDownloadPath).Length -gt 0)) {
				Write-Host "File downloaded successfully: '$FullDownloadPath'" -ForegroundColor Green
				if (Test-Path $FullBackupPath) {
					Remove-Item -Path $FullBackupPath -Force
				}
				
				# Get hash for the new file
				$NewFileHash = (Get-FileHash -Path $FullDownloadPath -Algorithm MD5).Hash
				
				Write-Debug "New File Hash: $NewFileHash"
				Write-Debug "New ETag: $NewETag"
				Write-Debug "New Last Modified: $NewLastModified"
				
				if (-not $Data.PSObject.Properties[$FullFileName]) {
					# Add new file metadata
					Add-Member -InputObject $Data -MemberType NoteProperty -Name $FullFileName -Value ([PSCustomObject]@{
						Hash = $NewFileHash
						ETag = $NewETag
						LMod = $NewLastModified
					})
				} else {
					# Update existing file metadata
					$Data.$FullFileName = [PSCustomObject]@{
						Hash = $NewFileHash
						ETag = $NewETag
						LMod = $NewLastModified
					}
				}
				
				# Define paths to extraction tools
				$WinRarPath = "$env:ProgramFiles\WinRAR\WinRAR.exe"
				$SevenZipPath = "$env:ProgramFiles\7-Zip\7z.exe"
				
				# Extractable Extensions list
				[string[]]$ExtractableExtensions = @(".zip", ".rar", ".7z")
				
				# Ensure download directory exists
				if ($CreateFolder -eq $true) {
					if (-not (Test-Path -Path $FullExtractionPath -PathType Container)) {
						[void](New-Item -ItemType Directory -Path $FullExtractionPath -Force)
						if (Test-Path -Path $FullExtractionPath -PathType Container) {
							Write-Host "folder successfully created."
						} else {
							Write-Host "Folder could not be created." -ForegroundColor Red
						}
					}
				}
				
				# Extract archive
				if ($ExtractableExtensions -Contains $FileExtension) {
					if ($ExtractArchive) {
						if ($CreateFolder -eq $true) {
							if ((Get-ChildItem -Path $FullExtractionPath -Force | Measure-Object).Count -gt 0) {
								if (Test-Path -Path $FullBackupFolderPath -PathType Container) {
									Remove-Item -Path $FullBackupFolderPath -Force
								}
								# ERROR: Cannot rename the specified target, because it represents a path or device name.
								Rename-Item -Path $FullExtractionPath -NewName $FullBackupFolderPath -Force
							}
						}
						
						try {
							Write-Host "Extracting file..."
							# Method 1: Extract using built-in PowerShell for ZIP files
							if ($FileExtension -eq ".zip") {
								Write-Debug "Extracting archive using PowerShell"
								if (-not $ArchivePassword) {
									Expand-Archive -Path $FullDownloadPath -DestinationPath $FullExtractionPath -Force
								}
							}
							
							# Method 2: Extract using WinRAR for ZIP, RAR, 7Z files														  
							if (-not (Test-Path -Path $FullExtractionPath)) {
								if (Test-Path -Path $WinRarPath) {
									Write-Debug "Extracting archive using WinRAR"
									if (-not $ArchivePassword) {
										& "$WinRarPath" x -o+ -y -ibck "$FullDownloadPath" "$FullExtractionPath\"
								} else {
										& "$WinRarPath" x -o+ -y -ibck -p"$ArchivePassword" "$FullDownloadPath" "$FullExtractionPath\"
									}
								} else {
									Write-Host "WinRar not found." -ForegroundColor Yellow
								}
							}
							
							# Method 3: Extract using 7-Zip for ZIP, RAR, 7Z files													
							if (-not (Test-Path -Path $FullExtractionPath)) {
								if (Test-Path -Path $SevenZipPath) {
									Write-Debug "Extracting archive using 7-Zip"
									if (-not $ArchivePassword) {
										& "$SevenZipPath" x "$FullDownloadPath" -o"$FullExtractionPath" -y > $null 2>&1
									} else {
										& "$SevenZipPath" x "$FullDownloadPath" -p"$ArchivePassword" -o"$FullExtractionPath" -y > $null 2>&1
									}
								} else {
									Write-Host "7zip not found." -ForegroundColor Yellow
								}
							}
						} catch {
							Write-Host "Error occurred while extracting file: $($_.Exception.Message)" -ForegroundColor Red
						}
						
						# Check extraction result
						if ((Get-ChildItem -Path $FullExtractionPath -Force | Measure-Object).Count -eq 0) {
							Write-Host "Error occurred while extracting file: $($_.Exception.Message)" -ForegroundColor Red
							if (Test-Path -Path $FullExtractionPath -PathType Container) {
								Remove-Item -Path $FullExtractionPath -Force
							}
							if (Test-Path -Path $FullBackupFolderPath -PathType Container) {
								Rename-Item -Path $FullBackupFolderPath -NewName $FullExtractionPath -Force
							}
						} else {
							Write-Host "File extracted successfully: '$FullExtractionPath'" -ForegroundColor Green
							if (Test-Path -Path $FullBackupFolderPath -PathType Container) {
								Remove-Item -Path $FullBackupFolderPath -Force
							}
						}
					}
				} else {
					# Move non extractable files to folder
					if ($CreateFolder -eq $true) {
						Move-Item -Path $FullDownloadPath -Destination $FullExtractionPath -Force
					}
				}
			} else {
				# Restore backup if download failed
				Write-Host "File download failed." -ForegroundColor Red
				if (Test-Path -Path $FullDownloadPath -PathType Container) {
					Remove-Item -Path $FullDownloadPath -Force
				}
				if (Test-Path $FullBackupPath) {
					Rename-Item -Path $FullBackupPath -NewName ([System.IO.Path]::GetFileName($FullDownloadPath)) -Force
				}
			}
		} else {
			Write-Host "File is already up-to-date: '$FullFileName'"
		}
	}
	
	end {
		# Save updated metadata to JSON file
		Save-Metadata -SavePath $FullMetadataPath -SaveData $Data
		
		# Output metadata for debugging purposes
		$Data.PSObject.Properties | ForEach-Object {
			[PSCustomObject]@{
				File = $_.Name
				Hash = $_.Value.Hash
				ETag = $_.Value.ETag
				LMod = $_.Value.LMod
			}
		} | Format-List | Out-String | Write-Debug

		# Separate invokes each other
		Write-Host ""
	}
}
