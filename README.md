Jellyfin Image Organization Tool
================================

Purpose
-------
This PowerShell-based GUI tool streamlines the process of organizing and integrating custom artwork for Jellyfin media servers. 
It is particularly useful when sourcing images from platforms like Mediux, which may follow naming conventions for other platforms like Plex.

Problem Solved
--------------
Manually downloading, extracting, renaming, and placing custom media artwork (posters, backdrops, episode thumbs) into 
the correct Jellyfin directory structure can be a time-consuming and error-prone task. This tool automates those steps, 
saving time and ensuring consistency.

Core Functionality
------------------
The tool provides a user-friendly graphical interface with distinct steps to process your media artwork:

1. Source & Target Matching:
   - Compares user-specified Source (e.g., D:\Downloads) and Target directories (e.g., Z:\Media\TV Shows).
   - Identifies matches using the "Show Name (YYYY)" format.
   - Only processes shows that exist in both source and target folders.

2. Automated Archive Extraction:
   - Automatically extracts .zip, .rar, or .7z archives using 7-Zip (must be installed and in system PATH).
   - Extracted contents are placed in a new subfolder within the source.
   - Original archive is deleted with retry logic for file locks.

3. Intelligent Renaming (within Source Subfolders):
   - Backdrops → renamed to `backdrop.jpg`
   - Season Posters → renamed to `seasonXX-poster.jpg` or `season-specials-poster.jpg` (for Season 0)
   - Folder Posters → renamed to `folder.jpg`
   - Episode Thumbs:
     - Matched using SXXEXX format and compared against target video files.
     - Renamed to match the video’s base name with `-thumb` suffix (e.g., `S01E07 - Pinkeye-thumb.jpg`)

   *Note: Episode thumbs are only renamed if matching video files are found.*

4. Loose File Handling (Direct Move/Rename):
   - Loose backdrop, season, and folder images in the main source folder are moved directly and renamed accordingly.

5. Organized File Placement:
   - Moves renamed files to the correct locations in the Jellyfin media structure (show root or season subfolders).

6. Overwrite Behavior:
   - All operations are configured to overwrite existing files of the same name. Backup your media if needed.

7. Configuration Persistence:
   - Saves source and target folder paths to a `MediaToolConfig.json` for future use.

Workflow Example
----------------
1. Download custom artwork sets (e.g., from Mediux.pro) to your downloads folder (e.g., D:\Downloads).
   - Examples: `South Park (1997).zip`, `Loki (2021) - Season 1.jpg`

2. Launch the "Jellyfin Image Organization Tool".

3. Set your Source Folder (e.g., D:\Downloads).

4. Add one or more Target Folders (e.g., Z:\Media\TV Shows, X:\Movies).

5. Use step-by-step buttons or the "Run All Steps" button.

6. The tool will:
   - Extract `South Park (1997).zip`
   - Rename images in the extracted folder
   - Match and rename episode thumbs based on Jellyfin’s existing files
   - Move images to the correct folders
   - Process any loose images like `Loki (2021) - Season 1.jpg` into the right show folder

7. Result: Jellyfin-compatible images ready for library scanning.

Requirements
------------
- Windows OS
- PowerShell 5.1 or newer
- .NET Framework 4.5 or newer
- 7-Zip installed and `7z.exe` added to your system PATH

Installation & Usage
--------------------
1. Download the script
   
3. Ensure 7-Zip is installed and `7z.exe` is in your system PATH.

4. To create a shortcut for easy use:
   - Right-click your Desktop or any folder → New → Shortcut
   - For the location, enter:
     powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Path\To\Jellyfin_Image_Organizer_Tool.ps1"
   - Replace with the actual full path to the script
   - Name the shortcut (e.g., Jellyfin Image Tool), then click Finish

5. To run manually from PowerShell (recommended for GUI scripts):
   powershell -Sta -File "C:\Path\To\Jellyfin_Image_Organizer_Tool.ps1"

Adding 7-Zip to your System PATH
--------------------
To ensure 7z.exe is in your system path, you need to add the directory containing it to your PATH environment variable. This allows your operating system to find and execute the 7z command from the command line or other applications. 
Here's how to do it:

  1. Install 7-Zip:
    If you don't have it already, download and install 7-Zip from the official 7-Zip website. 

  2. Locate the 7-Zip directory:
  Find the directory where 7-Zip is installed. By default, it's usually C:\Program Files\7-Zip.
 
  4. Edit environment variables:
  Windows 10/11: Search for "environment variables" in the Start Menu and click "Edit the system environment variables". 

  Older Windows versions: Right-click on "My Computer" (or "This PC") and select "Properties." Then, click on "Advanced system settings" and then the "Environment Variables" button. 

  5. Find the PATH variable:
  In the "System variables" section (or "User variables" if you're only modifying it for your user), find the "Path" variable.

  6. Edit the PATH:
  Click "Edit" and then click "New" to add a new path. 
  
  7. Add the 7-Zip directory:
  Enter the full path to the 7-Zip directory (e.g., C:\Program Files\7-Zip). 

  8. Confirm and restart:
  Click "OK" on all the windows to save the changes. You may need to restart your command prompt or the application where you're using 7-Zip for the changes to take effect. 
  
  9. Verify:
  Open a new command prompt and type 7z. If the folder was added correctly, you should see the 7-Zip usage information.

Supported File Types
--------------------
.jpg, .jpeg, .png are the supported image types
.mkv, .mp4, .avi, .mov, .mpg are the supported video types

If your image files are not one of the above supported types, the tool will NOT see them.
If your video type is not listed above, then the corresponding image will NOT match the video file, resulting in it being skipped.

Disclaimer
----------
This tool performs file operations including deletion and overwriting. While tested extensively, you should **back up**
your source and target media directories before using the tool, especially on first use.

The author is not responsible for any data loss or misfiled content.
