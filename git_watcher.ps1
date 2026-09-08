$folder = "C:\Users\kumar\Documents\trae_projects\AK_project"
$filter = "*.*"

Write-Output "Watching for changes in $folder..."

$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $folder
$fsw.Filter = $filter
$fsw.IncludeSubdirectories = $true
$fsw.EnableRaisingEvents = $true

$action = {
    $path = $Event.SourceEventArgs.FullPath
    $changeType = $Event.SourceEventArgs.ChangeType
    
    # Ignore git internal metadata folder changes
    if ($path -like "*\.git\*") { return }
    
    Write-Output "Change detected: $path ($changeType)"
    
    cd $folder
    git add .
    git commit -m "Auto-update: Saved changes on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    git push origin main
}

Register-ObjectEvent $fsw "Changed" -Action $action
Register-ObjectEvent $fsw "Created" -Action $action
Register-ObjectEvent $fsw "Deleted" -Action $action

while ($true) { Start-Sleep 5 }
