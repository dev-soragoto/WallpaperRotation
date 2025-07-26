# Event-driven landscape/portrait wallpaper switching script

param(
    [Parameter(Mandatory = $true)]
    [string]$LandscapeWallpaper,
    
    [Parameter(Mandatory = $true)]
    [string]$PortraitWallpaper
)

# Wallpaper setting API
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public class WallpaperAPI {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
    
    public static bool SetWallpaper(string path) {
        return SystemParametersInfo(20, 0, path, 3) != 0;
    }
}
"@

# Display change detection
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class DisplayMonitor : NativeWindow {
    [DllImport("user32.dll")]
    public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
    
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr CreateWindowEx(
        int dwExStyle, string lpClassName, string lpWindowName, int dwStyle,
        int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);
    
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
    
    public const int WM_DISPLAYCHANGE = 0x007E;
    public const int WS_OVERLAPPEDWINDOW = 0x00CF0000;
    
    private static DisplayMonitor instance;
    public static Action OnDisplayChange;
    
    public static void StartMonitoring() {
        if (instance == null) {
            instance = new DisplayMonitor();
            instance.CreateHandle(new CreateParams {
                Caption = "DisplayChangeMonitor",
                ClassName = "STATIC",
                Style = 0,
                ExStyle = 0,
                X = 0, Y = 0, Width = 1, Height = 1,
                Parent = IntPtr.Zero
            });
            Console.WriteLine("Display monitor window created successfully");
        }
    }
    
    public static void StopMonitoring() {
        if (instance != null) {
            instance.DestroyHandle();
            instance = null;
            Console.WriteLine("Display monitor stopped");
        }
    }
    
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_DISPLAYCHANGE) {
            Console.WriteLine("WM_DISPLAYCHANGE received!");
            if (OnDisplayChange != null) {
                OnDisplayChange.Invoke();
            }
        }
        base.WndProc(ref m);
    }
}
"@ -ReferencedAssemblies System.Windows.Forms

# Get screen orientation
function Get-ScreenOrientation {
    # Get display orientation
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DisplayOrientation {
    [DllImport("user32.dll")]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    
    [StructLayout(LayoutKind.Sequential)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
    }
    
    public const int ENUM_CURRENT_SETTINGS = -1;
    
    public static int GetDisplayOrientation() {
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(dm);
        EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm);
        return dm.dmDisplayOrientation;
    }
}
"@
    
    $orientation = [DisplayOrientation]::GetDisplayOrientation()
    Write-Host "Display orientation code: $orientation"
    
    # Display orientation: 0=0 degrees(landscape), 1=90 degrees(portrait), 2=180 degrees(inverted landscape), 3=270 degrees(inverted portrait)
    switch ($orientation) {
        0 { return "Landscape" }      # 0 degrees - normal landscape
        1 { return "Portrait" }       # 90 degrees - portrait
        2 { return "Landscape" }      # 180 degrees - inverted landscape
        3 { return "Portrait" }       # 270 degrees - inverted portrait
        default { 
            Write-Host "Unknown display orientation: $orientation"
            return "Landscape"  # Default to landscape
        }
    }
}


function SetLockScreen {
    param (
        [string]$imagePath
    )
    # Load Windows Runtime support
    [System.Reflection.Assembly]::LoadWithPartialName("System.Runtime.WindowsRuntime") | Out-Null
        
    # Manually load Windows Runtime assemblies
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]  
    $null = [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
        
        
    # Define async operation helper functions
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
        
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { 
            $_.Name -eq 'AsTask' -and 
            $_.GetParameters().Count -eq 1 -and 
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' 
        })[0]
        
    $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { 
            $_.Name -eq 'AsTask' -and 
            $_.GetParameters().Count -eq 1 -and 
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' 
        })[0]
        
    function Await($WinRtTask, $ResultType) {
        $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
        $netTask = $asTask.Invoke($null, @($WinRtTask))
        $netTask.Wait(-1) | Out-Null
        $netTask.Result
    }
        
    function AwaitAction($WinRtAction) {
        $netTask = $asTaskAction.Invoke($null, @($WinRtAction))
        $netTask.Wait(-1) | Out-Null
    }
        
    # Create StorageFile object
    $storageFile = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imagePath)) ([Windows.Storage.StorageFile])
        
    # Set lock screen background
    AwaitAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($storageFile))
}
    
# Display change handler function
$global:lastOrientation = ""

function Invoke-DisplayChange {
    $newOrientation = Get-ScreenOrientation
    Write-Host "Current orientation: $newOrientation, Last orientation: $global:lastOrientation"
    
    if ($newOrientation -ne $global:lastOrientation -and $global:lastOrientation -ne "") {
        Write-Host "Screen orientation change detected: $global:lastOrientation -> $newOrientation"


        $wallpaperPath = switch ($newOrientation) {
            "Landscape" { $LandscapeWallpaper }
            "Portrait" { $PortraitWallpaper }
        }

        [WallpaperAPI]::SetWallpaper($wallpaperPath)
        SetLockScreen $wallpaperPath
    }
    
    else {
        Write-Host "Screen orientation unchanged, keeping: $newOrientation"
    }
    $global:lastOrientation = $newOrientation
}

# Main program
Write-Host "Landscape/Portrait wallpaper monitor starting..."
Write-Host "Landscape desktop wallpaper: $LandscapeWallpaper"
Write-Host "Portrait desktop wallpaper: $PortraitWallpaper"

# Initialize
$global:lastOrientation = Get-ScreenOrientation
Write-Host "Initial screen orientation: $global:lastOrientation"

# Set initial wallpaper and lock screen
$initialWallpaperPath = switch ($global:lastOrientation) {
    "Landscape" { $LandscapeWallpaper }
    "Portrait" { $PortraitWallpaper }
}

Write-Host "Setting initial wallpaper: $initialWallpaperPath"
[WallpaperAPI]::SetWallpaper($initialWallpaperPath)
SetLockScreen $initialWallpaperPath

# Set event callback
[DisplayMonitor]::OnDisplayChange = { Invoke-DisplayChange }

# Start monitoring
[DisplayMonitor]::StartMonitoring()

try {
    while (1) {
        Start-Sleep -Seconds 1000
    }
}
finally {
    # Cleanup
    [DisplayMonitor]::StopMonitoring()
    Write-Host "Monitoring stopped"
}