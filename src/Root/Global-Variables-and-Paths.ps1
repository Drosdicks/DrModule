# Global-Variables-and-Paths.ps1 (example)

#region Global Variables and Constants

# Module Version (injected at build time)
$Global:DrModuleVersion = '__DRMODULE_VERSION__'

# Primary Root (Persistent Data)
$Global:DrRoot = 'C:\ProgramData\Syncro\DrOsdicks'
$Global:DrBin = Join-Path $Global:DrRoot 'Bin'

# Module identity (stable)
$Global:DrModulePath = Join-Path $Global:DrBin 'DrModule.psm1'

# Assets
$Global:DrLogo = Join-Path $Global:DrBin 'Logo.jpg'
$Global:DrVarStorePath = Join-Path $Global:DrBin 'variables.xml'
$Global:DrFilePusherPath = 'C:\ProgramData\Syncro\bin\FilePusher.exe'

# External API
$Global:DrRepairTechKabutoApiUrl = 'https://rmm.syncromsp.com'

# Hidden operational root
$Global:DrHiddenRoot = 'C:\DrOsdicks'
$Global:DrLogs = Join-Path $Global:DrHiddenRoot 'DrLogs'
$Global:DrTemp = Join-Path $Global:DrHiddenRoot 'DrTemp'
$Global:DrToolbox = Join-Path $Global:DrHiddenRoot 'Toolbox'
$Global:DrHiddenBin = Join-Path $Global:DrHiddenRoot 'bin'
$Global:DrJobsPath = Join-Path $Global:DrHiddenRoot 'Jobs'

# Runtime-initialized
$Global:DrJobRoot = $Global:DrJobsPath
$Global:DrLogFile = $null
$Global:DrTimers = $null

#endregion

