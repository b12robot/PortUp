# Module path directory. (Optional)
# By default, the current working directory is used.
# The 'PortUp.psm1' module must be in the same directory as this script, or you must change the directory accordingly.
Import-Module "$($pwd.Path)\PortUp.psm1"

# URL of the file to be downloaded (Required)
# Get-Download -DownloadUrl "https://example.com/file.zip"

# Name and extension of the downloaded file. (Optional)
# If not specified, it will attempt to automatically retrieve it from the URL.
# Get-Download -DownloadUrl "https://example.com/file.zip" -FileName "examplefile.zip" or -FileName "*.zip"

# Directory where the downloaded file will be saved. (Optional)
# By default, the current working directory is used.
# Get-Download -DownloadUrl "https://example.com/file.zip" -DownloadPath "C:\\Users\\UserName\\Downloads"

# Directory where metadata will be saved. (Optional)
# By default, the current working directory is used.
# Get-Download -DownloadUrl "https://example.com/file.zip" -MetadataPath "C:\\Users\\UserName\\Documents\\Metadata.json"

# Debug mode. (Optional)
# By default, it is off. When enabled, extra information will be displayed.
# Get-Download -DownloadUrl "https://example.com/file.zip" -DebugMode

# Example:
Get-Download -DownloadUrl "https://download.scdn.co/SpotifySetup.exe"
pause
exit
