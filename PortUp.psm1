function Get-Download {
	param (
		[Parameter(Mandatory = $true)]
		[ValidatePattern('^https?://')]
		[string]$DownloadUrl,
		[string]$FileName,
		[string]$FileExtension,
		[string]$DownloadPath = (Get-Location).Path,
		[string]$MetadataPath = (Get-Location).Path,
		[switch]$DebugMode = $false
	)
	
	begin {
		Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
		$DebugPreference = if ($DebugMode) { "Continue" } else { "SilentlyContinue" }
	}
	
	process {
		function Validate-Extension {
			param (
				[string]$FileExtension,
				[string[]]$ValidExtensions = @(".exe", ".zip", ".rar", ".7z", ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".pdf", ".txt", ".csv", ".xml", ".json", ".mp3", ".wav", ".mp4", ".avi", ".mkv", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx")
			)
			return $ValidExtensions -Contains $FileExtension
		}
		
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
		
		function Format-FileSize {
			param([long]$Bytes)
			switch ($Bytes) {
				{ $_ -ge 1GB } { return "{0:N2} GB" -f ($_ / 1GB) }
				{ $_ -ge 1MB } { return "{0:N2} MB" -f ($_ / 1MB) }
				{ $_ -ge 1KB } { return "{0:N2} KB" -f ($_ / 1KB) }
				default { return "$_ bytes" }
			}
		}
		
		Write-Debug "DownloadUrl: $DownloadUrl"
		if ($DownloadUrl -match "^https://github\.com/([^/]+/[^/]+)") {
			$ApiUrl = "https://api.github.com/repos/$($Matches[1])/releases/latest"
			Write-Debug "ApiUrl: $ApiUrl"
			
			try {
				$ReleaseData = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 30
			} catch {
				throw "An error occurred while retrieving data from the GitHub API: $($_.Exception.Message)"
			}
			
			[array]$Assets = if ($FileName -and $FileExtension) {
				$ReleaseData.assets | Where-Object { $_.name -like "*$FileName*$FileExtension" }
			} elseif ($FileName) {
				$ReleaseData.assets | Where-Object { $_.name -like "*$FileName*" }
			} elseif ($FileExtension) {
				$ReleaseData.assets | Where-Object { $_.name -like "*$FileExtension" }
			} else {
				$ReleaseData.assets | Select-Object name, browser_download_url
			}
			
			if ($Assets.Count -eq 1) {
				$SelectedAsset = $Assets[0]
			} elseif ($Assets.Count -gt 1) {
				foreach ($Asset in $Assets) {
					$Count++
					Write-Host "$Count. $($Asset.name)"
				}
				do {
					try {
						[int]$Selection = Read-Host "Select (1-$($Assets.Count))"
						if ($Selection -match "^[1-9]\d+$" -and $Selection -le $Assets.Count) {
							$SelectedAsset = $Assets[$Selection - 1]
						} else {
							Write-Host "Invalid selection, try again." -ForegroundColor Red
						}
					} catch {
						Write-Host "Input string was not in correct format." -ForegroundColor Red
					}
				} until ($SelectedAsset)
			} else {
				Write-Host "No downloadable assets found." -ForegroundColor Red
				exit 1
			}
			
			$FileName = $SelectedAsset.name
			$DownloadUrl = $SelectedAsset.browser_download_url
		}
		
		try {
			$Response = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -TimeoutSec 30
			$ContentDisposition = $Response.Headers['Content-Disposition']
			$ContentType = $Response.Headers['Content-Type']
			[int]$ContentLength = $Response.Headers['Content-Length']
			$ETag = $Response.Headers['ETag'] -replace '["]', ''
			$LastModified = $Response.Headers['Last-Modified']
			Write-Debug "================================================="
			Write-Debug "  Disposition: $ContentDisposition"
			Write-Debug "         Type: $ContentType"
			Write-Debug "       Length: $ContentLength"
			Write-Debug "         ETag: $ETag"
			Write-Debug " LastModified: $LastModified"
			Write-Debug "================================================="
		} catch {
			throw "An error occurred while retrieving metadata from HEAD request: $($_.Exception.Message)"
		}
		
		if (-not $FileName -and $ContentDisposition -match '="?(.+)\.') {
			$FileName = $matches[1]
			Write-Debug "     FileName: '$FileName' from Content-Disposition"
		}
		
		if (-not $FileName) {
			$FileName = [System.IO.Path]::GetFileName($DownloadUrl)
			$FileName = $FileName -replace "[{0}]" -f ([System.IO.Path]::GetInvalidFileNameChars() -join '')
			$FileName = $FileName.Substring(0, [Math]::Min($FileName.Length, 50))
			Write-Debug "     FileName: '$FileName' from URL"
		}
		
		if (-not $FileName) {
			$FileName = "Undefined"
			Write-Debug "     FileName: '$FileName' from Default"
		}
		
		if (-not (Validate-Extension -FileExtension $FileExtension) -and ($FileName -match '\..+')) {
			$FileExtension = [System.IO.Path]::GetExtension($FileName)
			Write-Debug "FileExtension: '$FileExtension' from FileName"
		}
		
		if (-not (Validate-Extension -FileExtension $FileExtension) -and ($ContentDisposition -match '=.+(\.[^\.\s"]+)"?')) {
			$FileExtension = $matches[1]
			Write-Debug "FileExtension: '$FileExtension' from Content-Disposition"
		}
		
		if (-not (Validate-Extension -FileExtension $FileExtension) -and ($ContentType -match '^([\w\.\-]+\/[\w\.\-]+)')) {
			$ContentType = $matches[1]
			[hashtable]$ContentTypeMap = @{
				"application/exe"              = ".exe"
				"application/x-msdownload"     = ".exe"
				"application/zip"              = ".zip"
				"application/x-rar-compressed" = ".rar"
				"application/x-7z-compressed"  = ".7z"
				"application/x-tar"            = ".tar"
				"application/gzip"             = ".gz"
				"application/x-iso9660-image"  = ".iso"
				"image/jpeg"                   = ".jpg"
				"image/png"                    = ".png"
				"image/gif"                    = ".gif"
				"image/bmp"                    = ".bmp"
				"text/plain"                   = ".txt"
				"text/csv"                     = ".csv"
				"application/xml"              = ".xml"
				"application/json"             = ".json"
				"application/pdf"              = ".pdf"
				"audio/mpeg"                   = ".mp3"
				"audio/wav"                    = ".wav"
				"video/mp4"                    = ".mp4"
				"video/x-msvideo"              = ".avi"
				"video/x-matroska"             = ".mkv"
				"application/msword"           = ".doc"
				"application/vnd.openxmlformats-officedocument.wordprocessingml.document" = ".docx"
				"application/vnd.ms-excel"     = ".xls"
				"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = ".xlsx"
				"application/vnd.ms-powerpoint"= ".ppt"
				"application/vnd.openxmlformats-officedocument.presentationml.presentation" = ".pptx"
			}
			$FileExtension = $ContentTypeMap[$ContentType]
			Write-Debug "FileExtension: '$FileExtension' from Content-Type"
		}
		
		if (-not (Validate-Extension -FileExtension $FileExtension)) {
			$FileExtension = [System.IO.Path]::GetExtension($DownloadUrl)
			Write-Debug "FileExtension: '$FileExtension' from URL"
		}
		
		if (-not (Validate-Extension -FileExtension $FileExtension)) {
			$FileExtension = ".unknown"
			Write-Debug "FileExtension: '$FileExtension' from Default"
		}
		
		$FileName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
		$FullFileName = "$FileName$FileExtension"
		$DownloadPath = Join-Path -Path $DownloadPath -ChildPath $FullFileName
		$BackupPath = $DownloadPath + ".backup"
		$MetadataPath = Join-Path -Path $MetadataPath -ChildPath "Metadata.json"
		Write-Debug " FullFileName: $FullFileName"
		Write-Debug "================================================="
		Write-Debug " DownloadPath: $DownloadPath"
		Write-Debug "   BackupPath: $BackupPath"
		Write-Debug " MetadataPath: $MetadataPath"
		
		$Data = Load-Metadata -LoadPath $MetadataPath
		
		if (Test-Path $DownloadPath) {
			$FileHash = (Get-FileHash -Path $DownloadPath -Algorithm MD5).Hash
			Write-Debug "     FileHash: $FileHash"
		}
		
		if ($Data.PSObject.Properties[$FullFileName]) {
			$OldFileHash = $Data.$FullFileName.Hash
			$OldETag = $Data.$FullFileName.ETag
			$OldLastModified = $Data.$FullFileName.LMod
		}
		
		Write-Debug "OldFileHash: $OldFileHash"
		Write-Debug "OldETag: $OldETag"
		Write-Debug "OldLastModified: $OldLastModified"
		
		if ($FileHash -ne $OldFileHash) {
			$Difference++
		}
		
		if ($ETag -ne $OldETag) {
			$Difference++
		}
		
		if ($LastModified -ne $OldLastModified) {
			$Difference++
		}
		
		Write-Debug "Difference: $Difference"
		
		if ($Difference -gt 0) {
			
			if (Test-Path $DownloadPath) {
				Write-Host "Update available."
			}
			
			if ($ContentLength) {	
				Format-FileSize -Bytes $ContentLength
			} else {
				Write-Host "Unable to retrieve size from Content-Length"
			}
			
			if (Test-Path $DownloadPath) {
				if (Test-Path $BackupPath) {
					Write-Host "Removing old backup file..."
					Remove-Item -Path $BackupPath -Force
				}
				Write-Host "Creating backup file..."
				Rename-Item -Path $DownloadPath -NewName ([System.IO.Path]::GetFileName($BackupPath)) -Force
			}
			
			try {
				Write-Host "Downloading file..."
				Invoke-WebRequest -Uri $DownloadUrl -Method Get -OutFile $DownloadPath -UseBasicParsing -TimeoutSec 30
			} catch {
				if (Test-Path $DownloadPath) {
					Remove-Item -Path $DownloadPath -Force
				}
				Write-Error "Error occurred while downloading file: $($_.Exception.Message)"
			}
			
			if ((Test-Path $DownloadPath) -and ((Get-Item $DownloadPath).Length -gt 0)) {
				Write-Host "File successfully downloaded."
				if (Test-Path $BackupPath) {
					Write-Host "Removing backup file..."
					Remove-Item -Path $BackupPath -Force
				}
				
				$FileHash = (Get-FileHash -Path $DownloadPath -Algorithm MD5).Hash
				Write-Debug "FileHash: $FileHash"
				
				if (-not $Data.PSObject.Properties[$FullFileName]) {
					Add-Member -InputObject $Data -MemberType NoteProperty -Name $FullFileName -Value ([PSCustomObject]@{
						Hash = $FileHash
						ETag = $ETag
						LMod = $LastModified
					})
				} else {
					$Data.$FullFileName = [PSCustomObject]@{
						Hash = $FileHash
						ETag = $ETag
						LMod = $LastModified
					}
				}
				
			} else {
				Write-Host "File download failed."
				if (Test-Path $BackupPath) {
					Write-Host "Restoring backup file."
					Rename-Item -Path $BackupPath -NewName ([System.IO.Path]::GetFileName($DownloadPath)) -Force
				}
			}
		} else {
			if (Test-Path $DownloadPath) {Write-Host "Update not found."}
		}
	}
	
	end {
		Save-Metadata -SavePath $MetadataPath -SaveData $Data
		Write-Debug ($Data.PSObject.Properties | ForEach-Object {"
			File: $($_.Name)
			Hash: $($_.Value.Hash)
			ETag: $($_.Value.ETag)
			LMod: $($_.Value.LMod)"
		} | Out-String)
	}
}
