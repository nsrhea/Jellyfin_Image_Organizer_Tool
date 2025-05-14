#Requires -Version 5.1
#Requires -Assembly System.Windows.Forms
#Requires -Assembly System.Drawing

<#
.SYNOPSIS
A PowerShell GUI tool to compare source files/folders/archives against target media folders,
extract matching archives, rename specific image files, and move processed images.

.DESCRIPTION
This tool provides a graphical interface to manage media-related image files.
- Compares items in a source folder against 'Show Name (YYYY)' folders in target locations.
- Extracts matching .zip, .rar, or .7z archives in the source folder using 7-Zip. (Button 1)
- Renames backdrop images ('* - Backdrop') found within source subfolders to 'backdrop.ext'. (Button 2)
- Moves loose backdrop images ('Show Name (YYYY) - Backdrop.ext') found directly in the source folder to the target show folder, renaming them appropriately (overwrites existing). (Button 2)
- Renames season poster images ('Show Name (YYYY) - Season X.ext') found within source subfolders to 'seasonXX-poster.ext' or 'season-specials-poster.ext' (overwrites existing). (Button 3)
- Renames show poster images ('Show Name (YYYY).ext') found within source subfolders to 'folder.ext' (overwrites existing). (Button 3)
- Moves loose season poster images ('Show Name (YYYY) - Season X.ext') found directly in the source folder to the target show folder, renaming them appropriately (overwrites existing). (Button 3)
- Moves loose show poster images ('Show Name (YYYY).ext') found directly in the source folder to the target show folder, renaming them to 'folder.ext' (overwrites existing). (Button 3)
- Renames episode thumbnail images ('*SXXEXX*') found within source subfolders to match corresponding video filenames ('video_filename-thumb.ext') (overwrites existing). (Button 4)
- Moves processed images from source subfolders (thumbs, season posters, backdrops, folder images) to the appropriate target show/season folders (overwrites existing). (Button 5)
- Allows users to select source and target folders, which are saved for future use.
- Provides individual buttons for each step and a "Run All" button.

.NOTES
Date:   2025-04-20 (Updated 2025-04-20)
Requires: PowerShell 5.1+, .NET Framework 4.5+, 7-Zip (7z.exe must be in system PATH).
Backup your data before extensive use! Overwriting is enabled.
#>

# --- Configuration ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Path for storing configuration (Source/Target folders)
# Uses the script's directory for the config file, or PWD if run interactively.
$scriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    # Fallback to current working directory if script path isn't available (e.g., running code directly in ISE/console)
    Write-Warning "Cannot determine script path. Using current working directory ($PWD) for config file."
    $scriptDir = $PWD.Path
} else {
    # Get the directory containing the running script
    $scriptDir = Split-Path -Parent $scriptPath
}
# *** CONFIG FILE LOCATION ***: This will be in the same directory as the .ps1 script file by default.
$ConfigFilePath = Join-Path $scriptDir "MediaToolConfig.json"


# --- Global Variables ---
$sourcePath = $null
$targetPaths = [System.Collections.Generic.List[string]]::new()
$logTextBox = $null # Will be assigned the GUI textbox object
$sevenZipPath = $null # Path to 7z.exe

# --- Utility Functions ---

# Function to check if 7z.exe is available in PATH
function Test-7ZipPath {
    $exe = "7z.exe"
    $envPaths = $env:Path -split ';'
    $foundPath = $null
    foreach ($p in $envPaths) {
        # Skip empty path segments
        if ([string]::IsNullOrWhiteSpace($p)) { continue }

        $fullPath = Join-Path $p $exe -ErrorAction SilentlyContinue
        # Check if $fullPath is not null and exists
        if ($null -ne $fullPath -and (Test-Path $fullPath -PathType Leaf)) {
            $foundPath = $fullPath
            break
        }
    }
    # Also check common Program Files locations as a fallback
    if (-not $foundPath) {
        $progFiles = @(
            "$env:ProgramFiles\7-Zip\$exe",
            "$env:ProgramFiles(x86)\7-Zip\$exe"
        )
        foreach ($pf in $progFiles) {
            if (Test-Path $pf -PathType Leaf) {
                $foundPath = $pf
                break
            }
        }
    }
    return $foundPath
}

# Function to add log entries to the GUI TextBox
function Add-LogEntry {
    param(
        [string]$Message,
        [Parameter(Mandatory=$false)]
        $ColorInput = $null,
        [Parameter(Mandatory=$false)]
        [switch]$Bold,
        [bool]$NewLine = $true
    )

    # Determine the actual color object to use inside the function
    $effectiveColor = $null
    if ($ColorInput -ne $null -and $ColorInput -is [System.Drawing.Color]) {
        $effectiveColor = $ColorInput
    } elseif ($logTextBox -ne $null) {
         try {
             if ($logTextBox.ForeColor -ne $null) { $effectiveColor = $logTextBox.ForeColor }
         } catch {}
    }
    if ($effectiveColor -eq $null) { $effectiveColor = [System.Drawing.Color]::Black }

    if ($logTextBox) {
        if ($logTextBox.IsDisposed -or -not $logTextBox.IsHandleCreated) {
             try { $logTextBox.AppendText($Message + $(if ($NewLine) { "`r`n" } else { "" })) } catch {}
        }
        else {
             try {
                 $logTextBox.Invoke([Action]{
                    if (-not $logTextBox.IsDisposed) {
                        $originalFont = $logTextBox.SelectionFont
                        $currentFont = $originalFont
                        # Apply bold if requested and original font is valid
                        if ($Bold.IsPresent -and $originalFont -ne $null) {
                            try {
                                $currentFont = New-Object System.Drawing.Font($originalFont, [System.Drawing.FontStyle]::Bold)
                            } catch {
                                Write-Warning "Could not create bold font. Using regular."
                                $currentFont = $originalFont # Fallback
                            }
                        }

                        $logTextBox.SelectionStart = $logTextBox.TextLength
                        $logTextBox.SelectionLength = 0
                        $logTextBox.SelectionColor = $effectiveColor
                        # Apply font (bold or original)
                        if ($currentFont -ne $null) {
                            $logTextBox.SelectionFont = $currentFont
                        }
                        $logTextBox.AppendText($Message + $(if ($NewLine) { "`r`n" } else { "" }))

                        # Reset font and color immediately after appending
                        if ($originalFont -ne $null) {
                             $logTextBox.SelectionFont = $originalFont
                        }
                        $logTextBox.SelectionColor = $logTextBox.ForeColor

                        $logTextBox.ScrollToCaret()

                        # Dispose of the bold font object if created and different
                        if ($Bold.IsPresent -and $currentFont -ne $null -and $currentFont -ne $originalFont) {
                            $currentFont.Dispose()
                        }
                    }
                })
             } catch {
                 try { $logTextBox.AppendText($Message + $(if ($NewLine) { "`r`n" } else { "" })) } catch {}
             }
        }
    } else {
        # Fallback to console (no bold support here easily)
        $consoleColor = switch ($effectiveColor.Name) {
            "Red" { "Red" } "DarkRed" { "DarkRed" } "Green" { "Green" } "DarkGreen" { "DarkGreen" }
            "Blue" { "Blue" } "DarkBlue" { "DarkBlue" } "Yellow" { "Yellow" } "Goldenrod" { "DarkYellow" }
            "Orange" { "DarkYellow" } "Cyan" { "Cyan" } "DarkCyan" { "DarkCyan" } "Magenta" { "Magenta" }
            "DarkMagenta" { "DarkMagenta" } "Gray" { "Gray" } "DarkGray" { "DarkGray" } "Black" { "Black" }
            "White" { "White" } "LightGray" { "Gray"}
            default { if ($Host.UI.RawUI.BackgroundColor -eq 'Black') {'White'} else {'Black'} }
        }
        Write-Host $Message -ForegroundColor $consoleColor
    }
}


# Function to load saved configuration
function Load-Configuration {
    # Ensure ConfigFilePath is valid before testing
    if ([string]::IsNullOrWhiteSpace($ConfigFilePath)) {
        Add-LogEntry "Configuration file path could not be determined. Cannot load configuration." -ColorInput ([System.Drawing.Color]::Red)
        return
    }

    if (Test-Path $ConfigFilePath -PathType Leaf) { # Check it's a file
        try {
            $configContent = Get-Content $ConfigFilePath -Raw -ErrorAction Stop
            # Handle potentially empty config file
            if ([string]::IsNullOrWhiteSpace($configContent)) {
                 Add-LogEntry "Configuration file '$ConfigFilePath' is empty." -ColorInput ([System.Drawing.Color]::Orange)
                 return
            }
            $config = $configContent | ConvertFrom-Json -ErrorAction Stop

            if ($config -ne $null) {
                if ($config.PSObject.Properties.Name -contains 'SourcePath' -and -not [string]::IsNullOrWhiteSpace($config.SourcePath)) {
                    $script:sourcePath = $config.SourcePath
                }
                if ($config.PSObject.Properties.Name -contains 'TargetPaths' -and $config.TargetPaths -ne $null) {
                    # Clear existing before adding loaded paths
                    $script:targetPaths.Clear()
                    # Ensure we only add non-empty strings
                    $config.TargetPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
                        $script:targetPaths.Add($_)
                    }
                }
                Add-LogEntry "Configuration loaded from '$ConfigFilePath'" -ColorInput ([System.Drawing.Color]::Blue)
            } else {
                 Add-LogEntry "Failed to parse JSON from configuration file '$ConfigFilePath'." -ColorInput ([System.Drawing.Color]::Red)
            }
        } catch {
            Add-LogEntry "Error loading or parsing configuration: $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
            Add-LogEntry "Configuration file might be corrupt or inaccessible: '$ConfigFilePath'" -ColorInput ([System.Drawing.Color]::Red)
        }
    } else {
        Add-LogEntry "Configuration file not found at '$ConfigFilePath'. Using defaults (blank)." -ColorInput ([System.Drawing.Color]::Orange)
    }
}

# Function to save configuration
function Save-Configuration {
    # Ensure ConfigFilePath is valid before saving
    if ([string]::IsNullOrWhiteSpace($ConfigFilePath)) {
        Add-LogEntry "Configuration file path could not be determined. Cannot save configuration." -ColorInput ([System.Drawing.Color]::Red)
        return
    }

    $config = @{
        SourcePath  = $script:sourcePath
        TargetPaths = $script:targetPaths.ToArray() # Convert List to Array for JSON
    }
    try {
        $config | ConvertTo-Json -Depth 3 | Out-File -FilePath $ConfigFilePath -Encoding UTF8 -Force -ErrorAction Stop
        Add-LogEntry "Configuration saved to '$ConfigFilePath'" -ColorInput ([System.Drawing.Color]::Blue)
    } catch {
        Add-LogEntry "Error saving configuration: $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
    }
}

# Function to browse for a folder
function Select-FolderDialog {
    param(
        [string]$InitialDirectory = [Environment]::GetFolderPath('MyComputer'),
        [string]$Description = "Select a folder"
    )
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $Description
    # Ensure initial directory exists before setting it
    if (-not [string]::IsNullOrWhiteSpace($InitialDirectory) -and (Test-Path $InitialDirectory -PathType Container)) {
        $folderBrowser.SelectedPath = $InitialDirectory
    } else {
        # Default to MyComputer if initial is invalid/empty
        $folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
    }
    $folderBrowser.ShowNewFolderButton = $true # Allow creating new folders
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    } else {
        return $null
    }
}

# --- Core Logic Functions (Adapted from User Input) ---

# Gets unique 'Show Name (YYYY)' directory names from all target paths
function Get-TargetShowNames {
    param(
        [System.Collections.Generic.List[string]]$TargetBasePaths
    )
    # Use a HashSet for efficient unique storage, ignoring case
    $allShowNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($targetBasePath in $TargetBasePaths) {
        if (Test-Path $targetBasePath -PathType Container) {
            # Get only immediate subdirectories
            Get-ChildItem -Path $targetBasePath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                # Strict validation for 'Name (YYYY)' format at the end of the name
                if ($_.Name -match '^.+ \(\d{4}\)$') {
                    [void]$allShowNames.Add($_.Name)
                } else {
                     # Add-LogEntry "Debug: Folder '$($_.Name)' in '$targetBasePath' skipped (doesn't match 'Name (YYYY)' format)." -ColorInput ([System.Drawing.Color]::DarkGray)
                }
            }
        } else {
             Add-LogEntry "Target path not found or not a directory: '$targetBasePath'" -ColorInput ([System.Drawing.Color]::Orange)
        }
    }
    # Pipe HashSet directly to Sort-Object
    return $allShowNames | Sort-Object
}

# Gets map of target show names to full paths
function Get-TargetShowFoldersMap {
     param(
        [System.Collections.Generic.List[string]]$TargetBasePaths
    )
    $map = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($targetRoot in $TargetBasePaths) {
         if (Test-Path $targetRoot -PathType Container) {
             Get-ChildItem -Path $targetRoot -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '^.+ \(\d{4}\)$'} | ForEach-Object {
                 if (-not $map.ContainsKey($_.Name)) {
                    $map.Add($_.Name, $_.FullName)
                 }
            }
         }
    }
    return $map
}


# 1. Extract Archives
function Extract-MatchingArchives {
    param(
        [string]$SourceRoot,
        [System.Collections.Generic.List[string]]$TargetRoots
    )
    Add-LogEntry "--- Starting Archive Extraction ---" -ColorInput ([System.Drawing.Color]::Green)
    if (-not $script:sevenZipPath) {
         Add-LogEntry "7-Zip executable (7z.exe) not found in PATH or common locations. Cannot extract .rar/.7z files." -ColorInput ([System.Drawing.Color]::Red)
         Add-LogEntry "--- Aborted Archive Extraction ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
         return
    }

    $targetShowNames = Get-TargetShowNames -TargetBasePaths $TargetRoots
    if ($targetShowNames -eq $null -or $targetShowNames.Count -eq 0) { # Check for null as well now
        Add-LogEntry "No valid 'Show Name (YYYY)' folders found in target directories." -ColorInput ([System.Drawing.Color]::Orange)
        Add-LogEntry "--- Finished Archive Extraction (No Targets) ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
        return
    }
    Add-LogEntry "Found $($targetShowNames.Count) target show names to match against." -ColorInput ([System.Drawing.Color]::Gray)

    $archiveExtensions = @('.zip', '.rar', '.7z') # Define allowed extensions (lowercase)
    $archiveFiles = Get-ChildItem -Path $SourceRoot -File -ErrorAction SilentlyContinue | Where-Object { $archiveExtensions -contains $_.Extension.ToLower() }

    if ($null -eq $archiveFiles -or $archiveFiles.Count -eq 0) {
        Add-LogEntry "No archive files (.zip, .rar, .7z) found in '$SourceRoot'." -ColorInput ([System.Drawing.Color]::Orange)
         Add-LogEntry "--- Finished Archive Extraction (No Archives) ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
        return
    }
    Add-LogEntry "Found $($archiveFiles.Count) archive files in source." -ColorInput ([System.Drawing.Color]::Gray)

    $matchingArchiveFound = $false
    $imageExtensions = @(".jpg", ".jpeg", ".png") # Keep only these extensions (lowercase)

    foreach ($archiveFile in $archiveFiles) {
        $archiveBaseName = $archiveFile.BaseName
        # Use -contains operator which is case-insensitive by default with string arrays
        if ($targetShowNames -contains $archiveBaseName) {
            Add-LogEntry "✅ Match found: '$archiveBaseName'" -ColorInput ([System.Drawing.Color]::Green) -Bold
            $matchingArchiveFound = $true

            $archiveFilePath = $archiveFile.FullName
            $destinationPath = Join-Path $SourceRoot $archiveBaseName

            # Create destination folder
            if (-not (Test-Path -Path $destinationPath -PathType Container)) {
                Add-LogEntry "📁 Creating extraction folder: '$destinationPath'" -ColorInput ([System.Drawing.Color]::Green)
                try {
                    New-Item -Path $destinationPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                } catch {
                     Add-LogEntry "❌ Error creating directory '$destinationPath': $($_.Exception.Message). Skipping extraction for this archive." -ColorInput ([System.Drawing.Color]::Red)
                     continue # Skip to next archive
                }
            } else {
                 Add-LogEntry "📁 Destination folder already exists: '$destinationPath'" -ColorInput ([System.Drawing.Color]::Gray)
            }

            # Extract using 7-Zip
            Add-LogEntry "📦 Extracting '$($archiveFile.Name)' to '$destinationPath' using 7-Zip..." -ColorInput ([System.Drawing.Color]::Blue)

            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $script:sevenZipPath
            # Quote paths appropriately for the 7z command line
            $quotedArchivePath = "`"$archiveFilePath`""
            # Note: No space between -o and the quoted path for 7zip
            $quotedDestinationArg = "-o`"$destinationPath`""
            # Construct the final argument string
            $processInfo.Arguments = "x $quotedArchivePath $quotedDestinationArg -y"

            Add-LogEntry "   Running: `"$($processInfo.FileName)`" $($processInfo.Arguments)" -ColorInput ([System.Drawing.Color]::DarkGray) # Log the exact command string

            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            $extractionSuccess = $false # Flag to track success

            try {
                 $process.Start() | Out-Null
                 # Capture potential errors from stderr
                 $errors = $process.StandardError.ReadToEnd()
                 $process.WaitForExit()

                 if ($process.ExitCode -ne 0) {
                     # Log any errors captured from stderr
                     if (-not [string]::IsNullOrWhiteSpace($errors)) {
                        Add-LogEntry "   7-Zip Errors: $errors" -ColorInput ([System.Drawing.Color]::Red) -ErrorAction SilentlyContinue
                     }
                     Throw "7-Zip extraction failed with exit code $($process.ExitCode)."
                 }

                Add-LogEntry "👍 Extraction successful." -ColorInput ([System.Drawing.Color]::Green)
                $extractionSuccess = $true # Mark extraction as successful

            } catch {
                Add-LogEntry "❌ Error during 7-Zip execution for '$archiveFilePath': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                # Log $process.ExitCode if available
                if ($process -ne $null -and $process.HasExited) { Add-LogEntry "   7-Zip Exit Code: $($process.ExitCode)" -ColorInput ([System.Drawing.Color]::Red) }
            } finally {
                 if ($process -ne $null) { $process.Dispose() }
            }

            # Only proceed with delete and cleanup if extraction was successful
            if ($extractionSuccess) {
                # *** ADDED RETRY LOGIC FOR DELETION ***
                $deleteSuccess = $false
                $maxRetries = 5
                $retryDelaySeconds = 1
                for ($retry = 1; $retry -le $maxRetries; $retry++) {
                    try {
                        Remove-Item -Path $archiveFilePath -Force -ErrorAction Stop
                        Add-LogEntry "🗑️ Deleted archive file: '$archiveFilePath'" -ColorInput ([System.Drawing.Color]::Goldenrod)
                        $deleteSuccess = $true
                        break # Exit loop on success
                    } catch [System.IO.IOException] {
                        if ($retry -eq $maxRetries) {
                            Add-LogEntry "⚠️ Could not delete archive file '$archiveFilePath' after $maxRetries attempts: $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                        } else {
                             Add-LogEntry "   File lock detected on '$($archiveFile.Name)', retrying deletion in $retryDelaySeconds second(s)... (Attempt $retry/$maxRetries)" -ColorInput ([System.Drawing.Color]::Orange)
                             Start-Sleep -Seconds $retryDelaySeconds
                        }
                    } catch {
                        # Catch other potential errors during delete
                         Add-LogEntry "⚠️ Unexpected error deleting archive file '$archiveFilePath': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                         break # Don't retry on unexpected errors
                    }
                } # End retry loop

                # --- Post-Extraction Cleanup within the new folder ---
                if ($deleteSuccess) { # Optionally only cleanup if delete worked, or always cleanup
                    Add-LogEntry "🧹 Cleaning up non-image files in '$destinationPath'..." -ColorInput ([System.Drawing.Color]::Blue)
                    $filesInNewFolder = Get-ChildItem -Path $destinationPath -Recurse -File -ErrorAction SilentlyContinue
                    if ($null -ne $filesInNewFolder) {
                        # Get a list of files to delete first
                        $filesToDelete = $filesInNewFolder | Where-Object { $imageExtensions -notcontains $_.Extension.ToLower() }

                        if ($filesToDelete.Count -gt 0) {
                            foreach ($fileItem in $filesToDelete) {
                                try {
                                    Remove-Item $fileItem.FullName -Force -ErrorAction Stop
                                    # Use Goldenrod for deletion logs
                                    Add-LogEntry "🧹 Deleted non-image file: $($fileItem.FullName)" -ColorInput ([System.Drawing.Color]::Goldenrod)
                                } catch {
                                    Add-LogEntry "⚠️ Could not delete file: $($fileItem.FullName) — $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                                }
                            }
                        } else {
                            Add-LogEntry "   No non-image files found to delete." -ColorInput ([System.Drawing.Color]::Gray)
                        }
                    } else {
                        Add-LogEntry "   No files found inside '$destinationPath' after extraction to cleanup." -ColorInput ([System.Drawing.Color]::Gray)
                    }
                } # End if deleteSuccess
            } # End if extractionSuccess

        } # End if ($targetShowNames -contains $archiveBaseName)
    } # End foreach ($archiveFile in $archiveFiles)

    if (-not $matchingArchiveFound) {
        Add-LogEntry "No archives found in '$SourceRoot' that match folder names in target directories." -ColorInput ([System.Drawing.Color]::Orange)
    }
     Add-LogEntry "--- Finished Archive Extraction ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
}


# 2. Rename Existing Backdrops & Move Loose Backdrops
function Rename-ExistingBackdrops {
    param(
        [string]$SourceRoot,
        [System.Collections.Generic.List[string]]$TargetRoots
    )
    Add-LogEntry "--- Starting Backdrop Rename ---" -ColorInput ([System.Drawing.Color]::Green)
    # Get target folder map
    $targetShowFoldersMap = Get-TargetShowFoldersMap -TargetBasePaths $TargetRoots
    if ($targetShowFoldersMap.Count -eq 0) {
        Add-LogEntry "No valid 'Show Name (YYYY)' folders found in target directories. Cannot process backdrops." -ColorInput ([System.Drawing.Color]::Orange)
        Add-LogEntry "--- Finished Backdrop Rename (No Targets) ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
        return
    }

    $renamedCount = 0
    $movedLooseCount = 0
    $imageExtensionsForBackdrop = @(".jpg", ".jpeg", ".png")
    $regexLooseBackdrop = '^(.+ \(\d{4}\)) - Backdrop$'

    # --- Process Loose Backdrop files in SourceRoot first ---
    Add-LogEntry "🔍 Checking for loose Backdrop image files in source root '$SourceRoot'..." -ColorInput ([System.Drawing.Color]::Gray)
    $looseSourceFiles = Get-ChildItem -Path $SourceRoot -File -Force -ErrorAction SilentlyContinue | Where-Object { $imageExtensionsForBackdrop -contains $_.Extension.ToLower() }

    if ($null -ne $looseSourceFiles) {
        foreach ($looseFile in $looseSourceFiles) {
            # Check if the loose file matches the 'Show Name (YYYY) - Backdrop' pattern
            if ($looseFile.BaseName -match $regexLooseBackdrop) {
                $showNamePart = $matches[1]
                # Check if the show name part matches a target folder
                if ($targetShowFoldersMap.ContainsKey($showNamePart)) {
                    $targetShowPath = $targetShowFoldersMap[$showNamePart]
                    $targetFileName = "backdrop$($looseFile.Extension)"
                    $targetPath = Join-Path $targetShowPath $targetFileName

                    Add-LogEntry "   Found loose backdrop matching target: '$($looseFile.Name)' -> '$targetFileName'" -ColorInput ([System.Drawing.Color]::Gray)
                    try {
                        # REMOVED Test-Path check to allow overwrite
                        if (-not (Test-Path $targetShowPath -PathType Container)) {
                            Add-LogEntry "      ❌ Target directory '$targetShowPath' does not exist! Cannot move '$($looseFile.Name)'." -ColorInput ([System.Drawing.Color]::Red)
                        } else {
                            # Move the original loose file directly to the target with the new name, overwriting if needed
                            Move-Item -Path $looseFile.FullName -Destination $targetPath -Force -ErrorAction Stop
                            Add-LogEntry "      ✅ Moved and Renamed loose backdrop: '$($looseFile.Name)' to '$targetPath'" -ColorInput ([System.Drawing.Color]::Green)
                            $movedLooseCount++
                        }
                    } catch {
                         Add-LogEntry "      ❌ Error moving loose backdrop '$($looseFile.FullName)': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                    }
                } # End if show name matches target
            } # End if loose file matches backdrop pattern
        } # End foreach loose file
    } else {
         Add-LogEntry "   No loose image files found in '$SourceRoot' to check for backdrops." -ColorInput ([System.Drawing.Color]::Gray)
    }
    # --- END Loose File Processing ---


    # --- Process Subfolders ---
    $sourceFolders = Get-ChildItem -Path $SourceRoot -Directory -ErrorAction SilentlyContinue
    if($null -eq $sourceFolders -or $sourceFolders.Count -eq 0) {
        Add-LogEntry "No subfolders found in the source directory '$SourceRoot' to process for renaming backdrops." -ColorInput ([System.Drawing.Color]::Gray)
    } else {
        foreach ($folder in $sourceFolders) {
            # Process only source folders that match a target show name (case-insensitive)
            if ($targetShowFoldersMap.ContainsKey($folder.Name)) {
                Add-LogEntry "🔍 Checking for backdrops in source folder: '$($folder.FullName)'" -ColorInput ([System.Drawing.Color]::Gray)
                # Use Where-Object for filtering
                Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue |
                    Where-Object { ($imageExtensionsForBackdrop -contains $_.Extension.ToLower()) -and ($_.BaseName -like "* - Backdrop") } |
                    ForEach-Object {
                        $fileToRename = $_
                        $newFileName = "backdrop$($fileToRename.Extension)"
                        $newPath = Join-Path $fileToRename.DirectoryName $newFileName
                        try {
                            # REMOVED Test-Path check to allow overwrite
                            Rename-Item -Path $fileToRename.FullName -NewName $newFileName -Force -ErrorAction Stop
                            Add-LogEntry "🖼️ Renamed '$($fileToRename.Name)' to '$newFileName' in '$($folder.Name)'" -ColorInput ([System.Drawing.Color]::Green)
                            $renamedCount++
                        } catch {
                            Add-LogEntry "⚠️ Could not rename '$($fileToRename.FullName)' to '$newFileName' in '$($folder.Name)' - $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                        }
                    }
            } else {
                # Add-LogEntry "Debug: Skipping source folder '$($folder.Name)' as it doesn't match any target show name." -ColorInput ([System.Drawing.Color]::DarkGray)
            }
        } # End foreach folder
    } # End else

    # Adjusted final log message
    if ($renamedCount -gt 0) {
        Add-LogEntry "Successfully renamed $renamedCount backdrop file(s) within subfolders." -ColorInput ([System.Drawing.Color]::Green)
    }
     if ($movedLooseCount -gt 0) {
        Add-LogEntry "Successfully moved and renamed $movedLooseCount loose backdrop file(s)." -ColorInput ([System.Drawing.Color]::Green)
    }
    if ($renamedCount -eq 0 -and $movedLooseCount -eq 0) {
        Add-LogEntry "No Backdrop files were found that required processing (either loose or in subfolders)." -ColorInput ([System.Drawing.Color]::Orange)
    }
    Add-LogEntry "--- Finished Backdrop Rename ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
}


# 3. Rename Media Images (Season Posters, Loose Season Posters, Loose Show Posters, Folder Images in Subfolders)
function Rename-SeasonPosters { # Keep name for button binding, but logic expanded
    param(
        [string]$SourceRoot,
        [System.Collections.Generic.List[string]]$TargetRoots
    )
     Add-LogEntry "--- Starting Media Image Rename ---" -ColorInput ([System.Drawing.Color]::Green)

    # Create map of target show names to paths
    $targetShowFoldersMap = Get-TargetShowFoldersMap -TargetBasePaths $TargetRoots
    if ($targetShowFoldersMap.Count -eq 0) {
        Add-LogEntry "No valid 'Show Name (YYYY)' folders found in target directories. Cannot process loose files or subfolders." -ColorInput ([System.Drawing.Color]::Orange)
        Add-LogEntry "--- Finished Media Image Rename (No Targets) ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
        return
    }

    $imageExtensions = @(".jpg", ".jpeg", ".png")
    $renamedSeasonCount = 0
    $renamedFolderCount = 0 # Counter for folder images renamed within subfolders
    $movedLooseSeasonPosterCount = 0
    $movedLooseShowPosterCount = 0 # Counter for loose show posters moved/renamed to folder.ext

    # --- Process loose files in SourceRoot first ---
    Add-LogEntry "🔍 Checking for loose image files in source root '$SourceRoot'..." -ColorInput ([System.Drawing.Color]::Gray)
    $looseSourceFiles = Get-ChildItem -Path $SourceRoot -File -Force -ErrorAction SilentlyContinue | Where-Object { $imageExtensions -contains $_.Extension.ToLower() }

    if ($null -ne $looseSourceFiles) {
        foreach ($looseFile in $looseSourceFiles) {
            # Check 1: Loose Season Poster ('Show Name (YYYY) - Season X')
            if ($looseFile.BaseName -match '^(.+ \(\d{4}\)) - Season (\d+)$') {
                $showNamePart = $matches[1]
                $seasonNum = [int]$matches[2]
                $extension = $looseFile.Extension

                if ($targetShowFoldersMap.ContainsKey($showNamePart)) {
                    $targetShowPath = $targetShowFoldersMap[$showNamePart]
                    $targetFileName = ""
                    if ($seasonNum -eq 0) { $targetFileName = "season-specials-poster$extension" }
                    else { $targetFileName = "season{0:D2}-poster{1}" -f $seasonNum, $extension }
                    $targetPath = Join-Path $targetShowPath $targetFileName

                    Add-LogEntry "   Found loose season poster matching target: '$($looseFile.Name)' -> '$targetFileName'" -ColorInput ([System.Drawing.Color]::Gray)
                    try {
                        # REMOVED Test-Path check to allow overwrite
                        if (-not (Test-Path $targetShowPath -PathType Container)) { Add-LogEntry "      ❌ Target directory '$targetShowPath' does not exist! Cannot move '$($looseFile.Name)'." -ColorInput ([System.Drawing.Color]::Red) }
                        else {
                            Move-Item -Path $looseFile.FullName -Destination $targetPath -Force -ErrorAction Stop
                            Add-LogEntry "      ✅ Moved and Renamed loose season poster: '$($looseFile.Name)' to '$targetPath'" -ColorInput ([System.Drawing.Color]::Green)
                            $movedLooseSeasonPosterCount++
                        }
                    } catch { Add-LogEntry "      ❌ Error moving loose season poster '$($looseFile.FullName)': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red) }
                } # End if show name matches target
            }
            # Check 2: Loose Show Poster ('Show Name (YYYY).ext')
            elseif ($targetShowFoldersMap.ContainsKey($looseFile.BaseName)) {
                 $targetShowPath = $targetShowFoldersMap[$looseFile.BaseName]
                 $targetFileName = "folder$($looseFile.Extension)" # Target name is folder.ext
                 $targetPath = Join-Path $targetShowPath $targetFileName

                 Add-LogEntry "   Found loose show poster matching target: '$($looseFile.Name)' -> '$targetFileName'" -ColorInput ([System.Drawing.Color]::Gray)
                 try {
                     # REMOVED Test-Path check to allow overwrite
                     if (-not (Test-Path $targetShowPath -PathType Container)) { Add-LogEntry "      ❌ Target directory '$targetShowPath' does not exist! Cannot move '$($looseFile.Name)'." -ColorInput ([System.Drawing.Color]::Red) }
                     else {
                         Move-Item -Path $looseFile.FullName -Destination $targetPath -Force -ErrorAction Stop
                         Add-LogEntry "      ✅ Moved and Renamed loose show poster: '$($looseFile.Name)' to '$targetPath'" -ColorInput ([System.Drawing.Color]::Green)
                         $movedLooseShowPosterCount++
                     }
                 } catch { Add-LogEntry "      ❌ Error moving loose show poster '$($looseFile.FullName)': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red) }
            } # End if loose file matches show pattern
        } # End foreach loose file
    } else {
         Add-LogEntry "   No loose image files found in '$SourceRoot' to check." -ColorInput ([System.Drawing.Color]::Gray)
    }
    # --- END Loose File Processing ---


    # --- Process Subfolders (For Season Posters and Folder Images) ---
    $sourceFolders = Get-ChildItem -Path $SourceRoot -Directory -ErrorAction SilentlyContinue
     if($null -eq $sourceFolders -or $sourceFolders.Count -eq 0) {
        Add-LogEntry "No subfolders found in the source directory '$SourceRoot' to process for renaming." -ColorInput ([System.Drawing.Color]::Gray)
     } else {
        # Process each source subfolder
        foreach ($folder in $sourceFolders) {
            # Process only source folders that match a target show name (case-insensitive)
            if ($targetShowFoldersMap.ContainsKey($folder.Name)) {
                $sourceFolderPath = $folder.FullName
                Add-LogEntry "🔍 Checking for images in source folder: '$sourceFolderPath'" -ColorInput ([System.Drawing.Color]::Gray)

                $imageFiles = Get-ChildItem -Path $sourceFolderPath -File -ErrorAction SilentlyContinue | Where-Object { $imageExtensions -contains $_.Extension.ToLower() }

                foreach ($file in $imageFiles) {
                    # A. Check for Season Poster pattern: 'Show Name (YYYY) - Season X'
                    if ($file.BaseName -match ' - Season (\d+)$') {
                        $seasonNum = [int]$matches[1]
                        $extension = $file.Extension # Keep original extension casing
                        $expectedPrefix = $folder.Name # e.g., "Show Name (2023)"

                        if ($file.BaseName -like "$expectedPrefix - Season $seasonNum") {
                            $newName = ""
                            if ($seasonNum -eq 0) {
                                $newName = "season-specials-poster$extension"
                            } else {
                                $formattedSeason = "{0:D2}" -f $seasonNum # Pad with leading zero if needed
                                $newName = "season$formattedSeason-poster$extension"
                            }
                            $newPath = Join-Path $sourceFolderPath $newName
                            try {
                                # REMOVED Test-Path check to allow overwrite
                                Rename-Item -Path $file.FullName -NewName $newName -Force -ErrorAction Stop
                                Add-LogEntry "   ✅ Renamed Season Poster: '$($file.Name)' -> '$newName' in '$($folder.Name)'" -ColorInput ([System.Drawing.Color]::Green)
                                $renamedSeasonCount++
                            } catch {
                                Add-LogEntry "   ❌ Failed to rename Season Poster '$($file.Name)': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                            }
                        } else {
                            # Add-LogEntry "   ❓ Skipping rename for '$($file.Name)', prefix mismatch ('$($file.BaseName)' vs '$expectedPrefix - Season $seasonNum')." -ColorInput ([System.Drawing.Color]::Gray)
                        }
                    }
                    # *** RE-ADDED LOGIC *** B. Check for Folder Image pattern: 'Show Name (YYYY).ext' inside subfolder
                    elseif ($file.BaseName -eq $folder.Name) {
                        $extension = $file.Extension # Keep original extension casing
                        $newName = "folder$extension"
                        $newPath = Join-Path $sourceFolderPath $newName # Rename in place
                        try {
                            # REMOVED Test-Path check to allow overwrite
                            Rename-Item -Path $file.FullName -NewName $newName -Force -ErrorAction Stop
                            Add-LogEntry "   ✅ Renamed Folder Image: '$($file.Name)' -> '$newName' in '$($folder.Name)'" -ColorInput ([System.Drawing.Color]::Green)
                            $renamedFolderCount++ # Use the correct counter
                        } catch {
                            Add-LogEntry "   ❌ Failed to rename Folder Image '$($file.Name)': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                        }
                    } # End if/elseif file matches pattern
                } # End foreach file
            } # End if folder name matches target
        } # End foreach folder
     } # End else (source folders exist)

    # Adjusted final log message
    $totalRenamedSubfolder = $renamedSeasonCount + $renamedFolderCount
    $totalProcessedLoose = $movedLooseSeasonPosterCount + $movedLooseShowPosterCount

    if ($totalRenamedSubfolder -gt 0) {
         Add-LogEntry "Successfully renamed $renamedSeasonCount season poster(s) and $renamedFolderCount folder image(s) within source subfolders." -ColorInput ([System.Drawing.Color]::Green)
    }
    if ($movedLooseSeasonPosterCount -gt 0) {
         Add-LogEntry "Successfully moved and renamed $movedLooseSeasonPosterCount loose season poster(s) from source root to target." -ColorInput ([System.Drawing.Color]::Green)
    }
    if ($movedLooseShowPosterCount -gt 0) {
        Add-LogEntry "Successfully moved and renamed $movedLooseShowPosterCount loose show poster(s) to folder.ext in target." -ColorInput ([System.Drawing.Color]::Green)
    }

    if ($totalRenamedSubfolder -eq 0 -and $totalProcessedLoose -eq 0) {
         Add-LogEntry "No Season Poster or Show Poster images (loose or in subfolders) were found that required processing." -ColorInput ([System.Drawing.Color]::Orange)
    }
    Add-LogEntry "--- Finished Media Image Rename ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
}


# 4. Rename Episode Images in Source Folders
function Rename-EpisodeImages {
     param(
        [string]$SourceRoot,
        [System.Collections.Generic.List[string]]$TargetRoots
    )
    Add-LogEntry "--- Starting Episode Image Rename ---" -ColorInput ([System.Drawing.Color]::Green)

    # Create a case-insensitive hashtable to map 'Show Name (YYYY)' to its full path in targets
    $targetShowFoldersMap = Get-TargetShowFoldersMap -TargetBasePaths $TargetRoots # Use helper function
    if ($targetShowFoldersMap.Count -eq 0) {
        Add-LogEntry "No valid 'Show Name (YYYY)' folders found in target directories. Cannot find corresponding media files." -ColorInput ([System.Drawing.Color]::Orange)
        Add-LogEntry "--- Finished Episode Image Rename (No Targets) ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
        return
    }

    $sourceFolders = Get-ChildItem -Path $SourceRoot -Directory -ErrorAction SilentlyContinue
    if($null -eq $sourceFolders -or $sourceFolders.Count -eq 0) {
        Add-LogEntry "No subfolders found in the source directory '$SourceRoot'." -ColorInput ([System.Drawing.Color]::Orange)
        Add-LogEntry "--- Finished Episode Image Rename (No Source Folders) ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
        return
    }

    # Extensions to scan (using patterns for -Filter)
    $imageExtensionFilters = @("*.jpg", "*.jpeg", "*.png")
    $videoExtensions = @("*.mkv", "*.mp4", "*.avi", "*.mov", "*.mpg", "*.ts") # Add more if needed
    # Regex to find SxxExx
    $regexPattern = '(?i)S(\d{1,2})\s*E(\d{1,2})'
    $renamedCount = 0

    foreach ($sourceFolder in $sourceFolders) {
        # Check if this source folder matches a show in the target locations (case-insensitive)
        if ($targetShowFoldersMap.ContainsKey($sourceFolder.Name)) {
            $targetShowPath = $targetShowFoldersMap[$sourceFolder.Name]
            Add-LogEntry "✅ Match found for show: '$($sourceFolder.Name)'. Comparing source '$($sourceFolder.FullName)' with target '$targetShowPath'" -ColorInput ([System.Drawing.Color]::Green)

            # Build hashtable of video episode keys -> Base video file names (without extension) from the target folder
            $videoFilesHash = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
            Add-LogEntry "   🔍 Searching for video files in '$targetShowPath' (recursive)..." -ColorInput ([System.Drawing.Color]::Gray)
            # No need to loop through extensions here, Get-ChildItem -Include works well with -Recurse
            $targetVideoFiles = Get-ChildItem -Path $targetShowPath -Include $videoExtensions -Recurse -File -ErrorAction SilentlyContinue

            if ($null -ne $targetVideoFiles) {
                foreach ($videoFile in $targetVideoFiles) {
                    if ($videoFile.Name -match $regexPattern) {
                        $season = $matches[1].PadLeft(2, '0')
                        $episode = $matches[2].PadLeft(2, '0')
                        $key = "S${season}E${episode}"
                        if (-not $videoFilesHash.ContainsKey($key)) {
                            $videoFilesHash.Add($key, $videoFile.BaseName)
                        }
                    }
                }
            }

             if ($videoFilesHash.Count -eq 0) {
                Add-LogEntry "   ⚠️ No video files matching SxxExx pattern found in target '$targetShowPath'. Cannot rename episode images for this show." -ColorInput ([System.Drawing.Color]::Orange)
                continue # Next source folder
            } else {
                 Add-LogEntry "   Found $($videoFilesHash.Count) unique SxxExx video keys in target." -ColorInput ([System.Drawing.Color]::Gray)
            }

            # Now rename matching images in the source folder using the user's provided logic structure
            Add-LogEntry "   🖼️ Searching for episode images to rename in '$($sourceFolder.FullName)'..." -ColorInput ([System.Drawing.Color]::Gray)
            $foundSourceImages = $false
            foreach ($filter in $imageExtensionFilters) {
                $imageFiles = Get-ChildItem -Path $sourceFolder.FullName -Filter $filter -File -ErrorAction SilentlyContinue

                if ($null -ne $imageFiles) {
                    $foundSourceImages = $true # Mark that we found images with this filter at least
                    foreach ($imageFile in $imageFiles) {
                        # *** DEBUG LOGGING ENABLED (Commented out) ***
                        # Add-LogEntry "      Checking image: '$($imageFile.Name)'" -ColorInput ([System.Drawing.Color]::DarkGray)
                        $regexMatch = $imageFile.Name -match $regexPattern
                        # Add-LogEntry "         Regex match result: $regexMatch" -ColorInput ([System.Drawing.Color]::DarkGray)

                        # Exclude files already potentially renamed (like 'folder.jpg' or '*-thumb.jpg') using case-insensitive match
                        # Also exclude the main show poster if named like the folder
                        if ($imageFile.BaseName -notmatch '(?i)^(folder|.*-thumb)$' -and $imageFile.BaseName -ne $sourceFolder.Name -and $regexMatch) {
                            $season = $matches[1].PadLeft(2, '0')
                            $episode = $matches[2].PadLeft(2, '0')
                            $key = "S${season}E${episode}"

                             # *** DEBUG LOGGING ENABLED (Commented out) ***
                             # Add-LogEntry "         Extracted key: $key. Checking if key exists in video hash..." -ColorInput ([System.Drawing.Color]::DarkGray)

                            # Check key using case-insensitive hashtable lookup
                            if ($videoFilesHash.ContainsKey($key)) {
                                # *** DEBUG LOGGING ENABLED (Commented out) ***
                                # Add-LogEntry "         Key '$key' found in video hash. Proceeding with rename." -ColorInput ([System.Drawing.Color]::DarkGray)

                                $videoBaseName = $videoFilesHash[$key]
                                $newFileName = "${videoBaseName}-thumb$($imageFile.Extension)" # Keep original extension
                                $newFilePath = Join-Path -Path $imageFile.DirectoryName -ChildPath $newFileName

                                try {
                                    # REMOVED Test-Path check to allow overwrite
                                    Rename-Item -Path $imageFile.FullName -NewName $newFileName -Force -ErrorAction Stop
                                    Add-LogEntry "      ✅ Renamed '$($imageFile.Name)' -> '$newFileName'" -ColorInput ([System.Drawing.Color]::Green)
                                    $renamedCount++ # Increment local counter
                                } catch {
                                    Add-LogEntry "      ❌ Failed to rename '$($imageFile.FullName)' to '$newFileName': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
                                }
                            } else {
                                 # Log skip due to missing video key as RED warning (per user request)
                                 Add-LogEntry "      ❌ Key '$key' for image '$($imageFile.Name)' NOT found in video hash. Skipping rename." -ColorInput ([System.Drawing.Color]::Red)
                            }
                        } else {
                             # *** DEBUG LOGGING ENABLED (Commented out) ***
                             # Add-LogEntry "         Skipping '$($imageFile.Name)' due to exclusion rules (folder/thumb/no regex match)." -ColorInput ([System.Drawing.Color]::DarkGray)
                        } # End if image matches pattern and isn't already renamed/folder poster
                    } # End foreach imageFile
                } # End if imageFiles not null
            } # End foreach filter

            if (-not $foundSourceImages) {
                 Add-LogEntry "   No image files (.jpg, .jpeg, .png) found in source folder '$($sourceFolder.FullName)'." -ColorInput ([System.Drawing.Color]::Gray)
            }

        } else {
             # Add-LogEntry "Debug: Source folder '$($sourceFolder.Name)' does not match any target show folder name." -ColorInput ([System.Drawing.Color]::DarkGray)
        } # End if source folder matches target show
    } # End foreach source folder

     # Adjusted final log message
     if ($renamedCount -gt 0) {
         Add-LogEntry "Successfully renamed $renamedCount episode image file(s)." -ColorInput ([System.Drawing.Color]::Green)
     } else {
         Add-LogEntry "No episode images were found that required renaming." -ColorInput ([System.Drawing.Color]::Orange)
     }
     Add-LogEntry "--- Finished Episode Image Rename ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
}


# 5. Move Processed Image Files from Source Subfolders to Target
function Move-ImageFilesToServer {
    param(
        [string]$SourceRoot,
        [System.Collections.Generic.List[string]]$TargetRoots
    )
    Add-LogEntry "--- Starting Image Move ---" -ColorInput ([System.Drawing.Color]::Green)

    # Create a case-insensitive hashtable to map 'Show Name (YYYY)' to its full path in targets
    $targetShowFoldersMap = Get-TargetShowFoldersMap -TargetBasePaths $TargetRoots # Use helper function
    if ($targetShowFoldersMap.Count -eq 0) {
        Add-LogEntry "No valid 'Show Name (YYYY)' folders found in target directories. Cannot determine destination for moving files." -ColorInput ([System.Drawing.Color]::Orange)
        Add-LogEntry "--- Finished Image Move (No Targets) ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
        return
    }

    # Define image extensions for filtering (lowercase)
    $imageExtensionsToMove = @(".jpg", ".jpeg", ".png", ".webp")

    # Regex Patterns for different image types (Case-insensitive)
    $regexEpisodeThumb = '^(.*)-thumb\.(jpg|jpeg|png|webp)$' # Matches base video name + -thumb.ext
    $regexSeasonPoster = '(?i)^season(\d{2})-poster\.(jpg|jpeg|png|webp)$'
    $regexSpecialsPoster = '(?i)^season-specials-poster\.(jpg|jpeg|png|webp)$'
    $regexBackdrop = '(?i)^backdrop\.(jpg|jpeg|png|webp)$'
    # Regex to find SxxExx within the episode thumb base name for routing
    $regexFindEpisodeKey = '(?i)S(\d{1,2})\s*E(\d{1,2})'

    $movedCount = 0
    $deletedFolderCount = 0 # Count for deleted subfolders

    # *** REMOVED SECTION: Processing loose files moved to Buttons 2 & 3 ***


    # --- Process Subfolders ---
    $sourceFolders = Get-ChildItem -Path $SourceRoot -Directory -ErrorAction SilentlyContinue
    if($null -eq $sourceFolders -or $sourceFolders.Count -eq 0) {
        Add-LogEntry "No subfolders found in the source directory '$SourceRoot' to process for moving." -ColorInput ([System.Drawing.Color]::Gray)
    } else {
        # Process each source subfolder
        foreach ($sourceFolder in $sourceFolders) {
            # Use case-insensitive check
            if ($targetShowFoldersMap.ContainsKey($sourceFolder.Name)) {
                $targetShowPath = $targetShowFoldersMap[$sourceFolder.Name]
                Add-LogEntry "🚚 Processing folder for moving: '$($sourceFolder.FullName)' -> '$targetShowPath'" -ColorInput ([System.Drawing.Color]::Green)

                # Get target season/specials folder paths for this show (case-insensitive map)
                $targetSeasonMap = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase) # Key: "01", "02" etc. Value: Full Path
                $targetSpecialsPath = $null
                Get-ChildItem -Path $targetShowPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Name -match '(?i)^Season (\d+)$') {
                        $seasonNumStr = $matches[1].PadLeft(2, '0')
                        if (-not $targetSeasonMap.ContainsKey($seasonNumStr)) {
                            $targetSeasonMap.Add($seasonNumStr, $_.FullName)
                        }
                    } elseif ($_.Name -eq "Specials") { # Specials folder name is usually exact case
                        $script:targetSpecialsPath = $_.FullName
                    }
                }
                Add-LogEntry "   Found $($targetSeasonMap.Count) target season folders and $(if($targetSpecialsPath){'a'}else{'no'}) Specials folder." -ColorInput ([System.Drawing.Color]::Gray)

                # Process each image file in the source show folder
                # Use Where-Object based on extension, add -Force
                $sourceImageFiles = Get-ChildItem -Path $sourceFolder.FullName -File -Force -ErrorAction SilentlyContinue | Where-Object { $imageExtensionsToMove -contains $_.Extension.ToLower() }

                if ($null -ne $sourceImageFiles) {
                    foreach ($file in $sourceImageFiles) {
                        $targetPath = $null
                        $moveDescription = ""

                        try {
                            # A. Handle Episode Thumbnails
                            if ($file.Name -match $regexEpisodeThumb) {
                                $videoBaseName = $matches[1]
                                if ($videoBaseName -match $regexFindEpisodeKey) {
                                    $seasonNum = $matches[1].PadLeft(2, '0')
                                    $episodeNum = $matches[2].PadLeft(2, '0')
                                    $targetSeasonDir = $null
                                    if ($seasonNum -eq "00" -and $targetSpecialsPath) {
                                        $targetSeasonDir = $targetSpecialsPath
                                        $moveDescription = "episode thumb (S${seasonNum}E${episodeNum} - Specials)"
                                    } elseif ($targetSeasonMap.ContainsKey($seasonNum)) {
                                        $targetSeasonDir = $targetSeasonMap[$seasonNum]
                                        $moveDescription = "episode thumb (S${seasonNum}E${episodeNum})"
                                    }
                                    if ($targetSeasonDir) { $targetPath = Join-Path $targetSeasonDir $file.Name }
                                    else { Add-LogEntry "      ❓ Cannot determine target season/specials folder for S${seasonNum}. Skipping move for '$($file.Name)'." -ColorInput ([System.Drawing.Color]::Orange) }
                                } else { Add-LogEntry "      ❓ Could not extract SxxExx from base name '$videoBaseName'. Skipping move for '$($file.Name)'." -ColorInput ([System.Drawing.Color]::Orange) }
                            }
                            # B. Handle seasonXX-poster.ext
                            elseif ($file.Name -match $regexSeasonPoster) {
                                $seasonNum = $matches[1]
                                $targetPath = Join-Path $targetShowPath $file.Name
                                $moveDescription = "season $seasonNum poster"
                                if (!$targetSeasonMap.ContainsKey($seasonNum)) { Add-LogEntry "      ❓ Target Season $seasonNum folder does not exist. Moving poster to main show folder anyway." -ColorInput ([System.Drawing.Color]::Orange) }
                            }
                            # C. Handle season-specials-poster.ext
                            elseif ($file.Name -match $regexSpecialsPoster) {
                                $targetPath = Join-Path $targetShowPath $file.Name
                                $moveDescription = "specials poster"
                                if (!$targetSpecialsPath) { Add-LogEntry "      ❓ Target Specials folder does not exist. Moving poster to main show folder anyway." -ColorInput ([System.Drawing.Color]::Orange) }
                            }
                            # D. Handle backdrop.ext
                            elseif ($file.Name -match $regexBackdrop) {
                                $targetPath = Join-Path $targetShowPath $file.Name
                                $moveDescription = "backdrop"
                            }
                            # E. Handle 'folder.jpg' (renamed by Button 3)
                            elseif ($file.Name -match '(?i)^folder\.(jpg|jpeg|png|webp)$') {
                                $targetPath = Join-Path $targetShowPath $file.Name
                                $moveDescription = "folder image"
                            }
                             # F. Removed check for BaseName matching folder name

                            # --- Perform the Move ---
                            if ($targetPath) {
                                # REMOVED Test-Path check to allow overwrite
                                $targetDir = Split-Path $targetPath -Parent
                                if (-not (Test-Path $targetDir -PathType Container)) {
                                    Add-LogEntry "      ❌ Target directory '$targetDir' does not exist! Cannot move '$($file.Name)'." -ColorInput ([System.Drawing.Color]::Red)
                                } else {
                                    Move-Item -Path $file.FullName -Destination $targetPath -Force -ErrorAction Stop
                                    Add-LogEntry "      ✅ Moved ${moveDescription}: '$($file.Name)' to '$targetPath'" -ColorInput ([System.Drawing.Color]::Green)
                                    $movedCount++
                                }
                            } elseif ($moveDescription -eq "") {
                                 Add-LogEntry "      ❓ Unrecognized image file pattern in subfolder: '$($file.Name)'. Not moved." -ColorInput ([System.Drawing.Color]::Orange)
                            }
                        } catch { Add-LogEntry "      ❌ Error moving file '$($file.FullName)': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red) }
                    } # End ForEach image file in subfolder
                } else { Add-LogEntry "   No image files found in source folder '$($sourceFolder.FullName)' to move." -ColorInput ([System.Drawing.Color]::Gray) }

                # Delete the source subfolder if it's now empty
                try {
                     if ((Get-ChildItem -Path $sourceFolder.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                        Add-LogEntry "🗑️ Deleting empty source folder: '$($sourceFolder.FullName)'" -ColorInput ([System.Drawing.Color]::DarkGreen)
                        Remove-Item -Path $sourceFolder.FullName -Recurse -Force -ErrorAction Stop
                        $deletedFolderCount++
                     } else {
                        Add-LogEntry "🟡 Source folder not empty, skipping deletion: '$($sourceFolder.FullName)'" -ColorInput ([System.Drawing.Color]::Orange)
                     }
                } catch { Add-LogEntry "❌ Error deleting source folder '$($sourceFolder.FullName)': $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red) }

            } else { # End if targetShowFoldersMap contains sourceFolder.Name
                 # Add-LogEntry "Debug: Source folder '$($sourceFolder.Name)' does not match any target show folder name. Skipping move." -ColorInput ([System.Drawing.Color]::DarkGray)
            }
        } # End foreach sourceFolder
    } # End else (if sourceFolders exist)

    # --- Final Summary ---
     if ($movedCount -eq 0) {
        Add-LogEntry "No image files were moved from subfolders." -ColorInput ([System.Drawing.Color]::Orange) # Clarified message
    } else {
         Add-LogEntry "Successfully moved $movedCount image file(s) from subfolders." -ColorInput ([System.Drawing.Color]::Green) # Clarified message
    }
     if ($deletedFolderCount -gt 0) {
        Add-LogEntry "Successfully deleted $deletedFolderCount empty source folder(s)." -ColorInput ([System.Drawing.Color]::DarkGreen)
     }
    Add-LogEntry "--- Finished Image Move ---" -ColorInput ([System.Drawing.Color]::DarkBlue)
}


# --- GUI Setup ---
$form = New-Object System.Windows.Forms.Form
# *** TEXT CHANGE *** Updated Window Title
$form.Text = "Jellyfin Image Organization Tool"
$form.Size = New-Object System.Drawing.Size(800, 650) # Increased height for log
$form.MinimumSize = New-Object System.Drawing.Size(600, 500)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.BackColor = [System.Drawing.Color]::WhiteSmoke

# --- Source Folder Section ---
$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = "Source Folder:"
$sourceLabel.Location = New-Object System.Drawing.Point(10, 15)
$sourceLabel.AutoSize = $true
$form.Controls.Add($sourceLabel)

$sourceTextBox = New-Object System.Windows.Forms.TextBox
$sourceTextBox.Location = New-Object System.Drawing.Point(10, 35)
$sourceTextBox.Width = 600
$sourceTextBox.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($sourceTextBox)

$browseSourceButton = New-Object System.Windows.Forms.Button
$browseSourceButton.Text = "Browse..."
$browseSourceButton.Location = New-Object System.Drawing.Point(620, 33)
$browseSourceButton.Size = New-Object System.Drawing.Size(75, 23)
$browseSourceButton.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$browseSourceButton.Add_Click({
    $selectedPath = Select-FolderDialog -Description "Select the Source Folder" -InitialDirectory $sourceTextBox.Text
    if ($selectedPath) {
        $sourceTextBox.Text = $selectedPath
        $script:sourcePath = $selectedPath # Update global variable
    }
})
$form.Controls.Add($browseSourceButton)

# --- Target Folders Section ---
$targetLabel = New-Object System.Windows.Forms.Label
$targetLabel.Text = "Target Folders (Media Library Roots):"
$targetLabel.Location = New-Object System.Drawing.Point(10, 70)
$targetLabel.AutoSize = $true
$form.Controls.Add($targetLabel)

$targetListBox = New-Object System.Windows.Forms.ListBox
$targetListBox.Location = New-Object System.Drawing.Point(10, 90)
$targetListBox.Size = New-Object System.Drawing.Size(600, 100)
$targetListBox.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$targetListBox.SelectionMode = [System.Windows.Forms.SelectionMode]::One # Allow selecting one to remove
$targetListBox.HorizontalScrollbar = $true # Allow scrolling for long paths
$form.Controls.Add($targetListBox)

$addTargetButton = New-Object System.Windows.Forms.Button
$addTargetButton.Text = "Add Target"
$addTargetButton.Location = New-Object System.Drawing.Point(620, 88)
$addTargetButton.Size = New-Object System.Drawing.Size(100, 23)
$addTargetButton.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$addTargetButton.Add_Click({
    $selectedPath = Select-FolderDialog -Description "Add a Target Media Folder"
    if ($selectedPath) {
        # Use case-insensitive comparison for checking existence
        $exists = $false
        foreach($item in $targetListBox.Items){
            if($item -eq $selectedPath){
                $exists = $true
                break
            }
        }
        if (-not $exists) {
            $targetListBox.Items.Add($selectedPath) | Out-Null
            $script:targetPaths.Add($selectedPath) # Update global variable
        } else {
            [System.Windows.Forms.MessageBox]::Show("This path is already in the target list.", "Duplicate Path", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    }
})
$form.Controls.Add($addTargetButton)

$removeTargetButton = New-Object System.Windows.Forms.Button
$removeTargetButton.Text = "Remove Target"
$removeTargetButton.Location = New-Object System.Drawing.Point(620, 118)
$removeTargetButton.Size = New-Object System.Drawing.Size(100, 23)
$removeTargetButton.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$removeTargetButton.Add_Click({
    $selectedIndex = $targetListBox.SelectedIndex
    if ($selectedIndex -ge 0) {
        $itemToRemove = $targetListBox.Items[$selectedIndex]
        $targetListBox.Items.RemoveAt($selectedIndex)
        # Remove from the global list (case-insensitive removal might be safer if duplicates snuck in)
        $itemFoundInList = $script:targetPaths | Where-Object { $_ -eq $itemToRemove } | Select-Object -First 1
        if ($itemFoundInList) {
             $script:targetPaths.Remove($itemFoundInList)
        }
    } else {
         [System.Windows.Forms.MessageBox]::Show("Please select a target path from the list to remove.", "No Selection", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})
$form.Controls.Add($removeTargetButton)

# --- Action Buttons ---
$buttonYStart = 210
$buttonXStart = 10
$buttonWidth = 170
$buttonHeight = 30
$buttonSpacing = 10

$extractButton = New-Object System.Windows.Forms.Button
$extractButton.Text = "1. Extract Archives"
$extractButton.Location = New-Object System.Drawing.Point($buttonXStart, $buttonYStart)
$extractButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
$extractButton.Add_Click({ Process-Action -Action { Extract-MatchingArchives -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths } })
$form.Controls.Add($extractButton)

$renameBackdropButton = New-Object System.Windows.Forms.Button
$renameBackdropButton.Text = "2. Rename Backdrops"
$renameBackdropButton.Location = New-Object System.Drawing.Point(($buttonXStart + $buttonWidth + $buttonSpacing), $buttonYStart)
$renameBackdropButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
$renameBackdropButton.Add_Click({ Process-Action -Action { Rename-ExistingBackdrops -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths } })
$form.Controls.Add($renameBackdropButton)

$renameSeasonButton = New-Object System.Windows.Forms.Button
# *** TEXT CHANGE *** Renamed button 3
$renameSeasonButton.Text = "3. Rename Media Images"
$renameSeasonButton.Location = New-Object System.Drawing.Point(($buttonXStart + 2*($buttonWidth + $buttonSpacing)), $buttonYStart)
$renameSeasonButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
$renameSeasonButton.Add_Click({ Process-Action -Action { Rename-SeasonPosters -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths } })
$form.Controls.Add($renameSeasonButton)

$renameEpisodeButton = New-Object System.Windows.Forms.Button
$renameEpisodeButton.Text = "4. Rename Episode Images"
$renameEpisodeButton.Location = New-Object System.Drawing.Point($buttonXStart, ($buttonYStart + $buttonHeight + $buttonSpacing))
$renameEpisodeButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
$renameEpisodeButton.Add_Click({ Process-Action -Action { Rename-EpisodeImages -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths } })
$form.Controls.Add($renameEpisodeButton)

$moveButton = New-Object System.Windows.Forms.Button
$moveButton.Text = "5. Move Images && Cleanup"
$moveButton.Location = New-Object System.Drawing.Point(($buttonXStart + $buttonWidth + $buttonSpacing), ($buttonYStart + $buttonHeight + $buttonSpacing))
$moveButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
$moveButton.Add_Click({ Process-Action -Action { Move-ImageFilesToServer -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths } })
$form.Controls.Add($moveButton)

$runAllButton = New-Object System.Windows.Forms.Button
$runAllButton.Text = "Run All Steps (1-5)"
$runAllButton.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8.25, [System.Drawing.FontStyle]::Bold)
$runAllButton.Location = New-Object System.Drawing.Point(($buttonXStart + 2*($buttonWidth + $buttonSpacing)), ($buttonYStart + $buttonHeight + $buttonSpacing))
$runAllButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
$runAllButton.BackColor = [System.Drawing.Color]::LightGreen
$runAllButton.Add_Click({
    Process-Action -Action {
        Add-LogEntry "--- Starting All Steps ---" -ColorInput ([System.Drawing.Color]::DarkMagenta)
        Extract-MatchingArchives -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths
        Rename-ExistingBackdrops -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths # Handles loose backdrops too
        Rename-SeasonPosters -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths # Handles loose season/show posters & subfolder season/folder images
        Rename-EpisodeImages -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths
        Move-ImageFilesToServer -SourceRoot $script:sourcePath -TargetRoots $script:targetPaths # Moves files from subfolders only now
        Add-LogEntry "--- All Steps Completed ---" -ColorInput ([System.Drawing.Color]::DarkMagenta)
    }
})
$form.Controls.Add($runAllButton)

# --- Log Output Section ---
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = "Log Output:"
$logLabel.Location = New-Object System.Drawing.Point(10, ($buttonYStart + 2*($buttonHeight + $buttonSpacing) + 10))
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$script:logTextBox = New-Object System.Windows.Forms.RichTextBox # Assign to global variable
$logTextBox.Location = New-Object System.Drawing.Point(10, ($buttonYStart + 2*($buttonHeight + $buttonSpacing) + 30))
$logTextBox.Size = New-Object System.Drawing.Size(760, 250) # Adjust size as needed
$logTextBox.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$logTextBox.ReadOnly = $true
$logTextBox.WordWrap = $false
$logTextBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$logTextBox.Font = New-Object System.Drawing.Font("Consolas", 9) # Monospaced font is good for logs
# Remove background/foreground settings for log box to use defaults
#$logTextBox.BackColor = [System.Drawing.Color]::Black
#$logTextBox.ForeColor = [System.Drawing.Color]::LightGray
$form.Controls.Add($logTextBox)


# --- Helper Function to Wrap Button Actions ---
function Process-Action {
    param(
        [scriptblock]$Action
    )
    # Update source/target paths from GUI just before running
    $script:sourcePath = $sourceTextBox.Text
    $script:targetPaths.Clear()
    $targetListBox.Items | ForEach-Object { $script:targetPaths.Add($_) }

    # --- Input Validation ---
    if ([string]::IsNullOrWhiteSpace($script:sourcePath) -or (-not (Test-Path $script:sourcePath -PathType Container))) {
        Add-LogEntry "Error: Source path is not set or does not exist/is not a folder." -ColorInput ([System.Drawing.Color]::Red)
        [System.Windows.Forms.MessageBox]::Show("Please select a valid, existing Source Folder first.", "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ($script:targetPaths.Count -eq 0) {
        Add-LogEntry "Error: No target paths are specified." -ColorInput ([System.Drawing.Color]::Red)
        [System.Windows.Forms.MessageBox]::Show("Please add at least one Target Folder first.", "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    # Validate all target paths exist
    $allTargetsValid = $true
    foreach ($tp in $script:targetPaths) {
        if (-not (Test-Path $tp -PathType Container)) {
             Add-LogEntry "Error: Target path does not exist or is not a folder: '$tp'" -ColorInput ([System.Drawing.Color]::Red)
             $allTargetsValid = $false
        }
    }
     if (-not $allTargetsValid) {
         [System.Windows.Forms.MessageBox]::Show("One or more Target Folders do not exist or are not accessible. Please check the paths in the list.", "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }


    # Check for 7-Zip before extraction attempt
    # Check if the action scriptblock contains the name of the extraction function
    if ($Action.ToString() -match 'Extract-MatchingArchives') {
         $script:sevenZipPath = Test-7ZipPath # Re-check just in case
         if (-not $script:sevenZipPath) {
             Add-LogEntry "Error: 7z.exe not found. Cannot perform extraction." -ColorInput ([System.Drawing.Color]::Red)
             [System.Windows.Forms.MessageBox]::Show("7-Zip executable (7z.exe) could not be found in your system PATH or common install locations. Please install 7-Zip and ensure it's in the PATH.", "Dependency Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
         } else {
             Add-LogEntry "Using 7-Zip at: $script:sevenZipPath" -ColorInput ([System.Drawing.Color]::DarkGray)
         }
    }

    # Disable buttons during processing
    $form.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] } | ForEach-Object { $_.Enabled = $false }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    # Force UI update to show disabled state
    [System.Windows.Forms.Application]::DoEvents()


    try {
        # Execute the provided script block
        Invoke-Command -ScriptBlock $Action -ErrorAction Stop
    } catch {
        Add-LogEntry "❌ An error occurred during the operation: $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
        # Add more detail if available
        if ($_.Exception.InnerException) {
             Add-LogEntry "   Inner Exception: $($_.Exception.InnerException.Message)" -ColorInput ([System.Drawing.Color]::Red)
        }
         Add-LogEntry "   ScriptStackTrace: $($_.ScriptStackTrace)" -ColorInput ([System.Drawing.Color]::DarkRed)
    } finally {
        # Re-enable buttons and reset cursor
        $form.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] } | ForEach-Object { $_.Enabled = $true }
         $form.Cursor = [System.Windows.Forms.Cursors]::Default
         # Use default color for separator (will use textbox default)
         Add-LogEntry "--------------------"
         # Force UI update
         [System.Windows.Forms.Application]::DoEvents()
    }
}

# --- Form Load and Closing Actions ---
$form.Add_Load({
    # Check for 7-Zip on load
    $script:sevenZipPath = Test-7ZipPath
     if (-not $script:sevenZipPath) {
         Add-LogEntry "Warning: 7z.exe not found in PATH or common locations. Archive extraction (.rar, .7z) will fail." -ColorInput ([System.Drawing.Color]::Orange)
     } else {
         Add-LogEntry "7-Zip found: $script:sevenZipPath" -ColorInput ([System.Drawing.Color]::Green)
     }

    # Load configuration and populate fields
    Load-Configuration
    $sourceTextBox.Text = $script:sourcePath
    $targetListBox.Items.Clear()
    # AddRange is cleaner if the list is guaranteed to be strings
    if ($script:targetPaths -ne $null -and $script:targetPaths.Count -gt 0) {
        $targetListBox.Items.AddRange($script:targetPaths.ToArray())
    }
    Add-LogEntry "Tool Ready. Select folders and choose an action." -ColorInput ([System.Drawing.Color]::DarkGreen)
})

$form.Add_FormClosing({
    # Save configuration on exit
    # Update variables from GUI elements one last time
    $script:sourcePath = $sourceTextBox.Text
    $script:targetPaths.Clear()
    $targetListBox.Items | ForEach-Object { $script:targetPaths.Add($_) }
    Save-Configuration
})

# --- Show the Form ---
# Set STA mode for WinForms compatibility if not already set
# Note: This STA check/relaunch might not work reliably in all hosting environments (like some versions of ISE or specific consoles).
# Running the .ps1 file directly from a standard PowerShell console is generally the most reliable way.
if ($Host.Runspace.ApartmentState -ne 'STA') {
    Write-Warning "Host is not in STA mode. WinForms may behave unexpectedly. If GUI fails, try running from a standard PowerShell console: powershell -Sta -File `"$($MyInvocation.MyCommand.Path)`""
    # Attempt to re-launch in STA mode (may not work in all environments like ISE)
    # Only try relaunching if we actually know the script path
    if (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        try {
            Start-Process powershell -ArgumentList "-Sta", "-File", "`"$($MyInvocation.MyCommand.Path)`"", "-ExecutionPolicy", "Bypass" -ErrorAction Stop
            exit # Exit the current non-STA process
        } catch {
             Write-Error "Failed to relaunch in STA mode: $($_.Exception.Message)"
             Write-Error "Please try running manually: powershell -Sta -File `"$($MyInvocation.MyCommand.Path)`""
        }
    } else {
         Write-Error "Cannot determine script path to relaunch in STA mode. Please save the script to a .ps1 file and run it from a standard PowerShell console using 'powershell -Sta -File path\to\script.ps1'"
    }
}

# Display the form
# Add try/catch around ShowDialog for final safety
try {
    $form.ShowDialog() | Out-Null
} catch {
     Write-Error "An error occurred displaying the form: $($_.Exception.Message)"
     Add-LogEntry "An error occurred displaying the form: $($_.Exception.Message)" -ColorInput ([System.Drawing.Color]::Red)
     # Display error in console if GUI failed completely
     [System.Windows.Forms.MessageBox]::Show("An error occurred displaying the form: $($_.Exception.Message)", "GUI Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
} finally {
    # Clean up the form object explicitly
    if ($form -ne $null) {
        $form.Dispose()
    }
}


# --- Script End ---
Write-Host "Script finished."
