param($name)

$ChocoApp = Get-Content ".\ChocoApps.Cache\$name" | ConvertFrom-Json
$intuneBody = $ChocoApp.IntuneBody
$tenant = $chocoapp.Tenant
[xml]$Intunexml = Get-Content "AddChocoApp\choco.app.xml"
$assignTo = $ChocoApp.AssignTo
$intunewinFilesize = (Get-Item "AddChocoApp\IntunePackage.intunewin")
$Baseuri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"
$ContentBody = ConvertTo-Json @{
    name          = $intunexml.ApplicationInfo.FileName
    size          = [int64]$intunexml.ApplicationInfo.UnencryptedContentSize
    sizeEncrypted = [int64]($intunewinFilesize).length
} 
$RemoveCacheFile = Remove-Item ".\ChocoApps.Cache\$name" -Force
$EncBody = @{
    fileEncryptionInfo = @{
        encryptionKey        = $intunexml.ApplicationInfo.EncryptionInfo.EncryptionKey
        macKey               = $intunexml.ApplicationInfo.EncryptionInfo.MacKey
        initializationVector = $intunexml.ApplicationInfo.EncryptionInfo.InitializationVector
        mac                  = $intunexml.ApplicationInfo.EncryptionInfo.Mac
        profileIdentifier    = $intunexml.ApplicationInfo.EncryptionInfo.ProfileIdentifier
        fileDigest           = $intunexml.ApplicationInfo.EncryptionInfo.FileDigest
        fileDigestAlgorithm  = $intunexml.ApplicationInfo.EncryptionInfo.FileDigestAlgorithm
    }
} | ConvertTo-Json


Try {
    $ApplicationList = (New-graphGetRequest -Uri $baseuri -tenantid $Tenant) | Where-Object { $_.DisplayName -eq $ChocoApp.ApplicationName }
    if ($ApplicationList.displayname.count -ge 1) { 
        Log-Request -message "$($Tenant): $($ChocoApp.ApplicationName) exists. Skipping this application" -Sev "Warning"
        continue
    }
    $NewApp = New-GraphPostRequest -Uri $baseuri -Body ($intuneBody | ConvertTo-Json) -Type POST -tenantid $tenant
    $ContentReq = New-GraphPostRequest -Uri "$($BaseURI)/$($NewApp.id)/microsoft.graph.win32lobapp/contentVersions/1/files/" -Body $ContentBody -Type POST -tenantid $tenant
    do {
        $AzFileUri = New-graphGetRequest -Uri  "$($BaseURI)/$($NewApp.id)/microsoft.graph.win32lobapp/contentVersions/1/files/$($ContentReq.id)" -tenantid $tenant
        if ($AZfileuri.uploadState -like "*fail*") { break }
        Start-Sleep -Milliseconds 300
    } while ($AzFileUri.AzureStorageUri -eq $null) 
        
    $chunkSizeInBytes = 4mb
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($($intunewinFilesize.fullname))
    $chunks = [Math]::Ceiling($bytes.Length / $chunkSizeInBytes);
    $id = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($chunks.ToString("0000")))
    #For anyone that reads this, The maximum chunk size is 100MB for blob storage, so we can upload it as one part and just give it the single ID. Easy :)
    $Upload = Invoke-RestMethod -Uri "$($AzFileUri.azureStorageUri)&comp=block&blockid=$id" -Method Put -Headers @{'x-ms-blob-type' = 'BlockBlob' } -InFile "AddChocoApp\$($intunexml.ApplicationInfo.FileName)" -ContentType "application/octet-stream"
    $ConfirmUpload = Invoke-RestMethod -Uri "$($AzFileUri.azureStorageUri)&comp=blocklist" -Method Put -Body "<?xml version=`"1.0`" encoding=`"utf-8`"?><BlockList><Latest>$id</Latest></BlockList>"
    $CommitReq = New-graphPostRequest -Uri  "$($BaseURI)/$($NewApp.id)/microsoft.graph.win32lobapp/contentVersions/1/files/$($ContentReq.id)/commit" -Body $EncBody -Type POST -tenantid $tenant
         
    do {
        $CommitStateReq = New-graphGetRequest -Uri "$($BaseURI)/$($NewApp.id)/microsoft.graph.win32lobapp/contentVersions/1/files/$($ContentReq.id)" -tenantid $tenant
        if ($CommitStateReq.uploadState -like "*fail*") {
            Log-Request -message "$($Tenant): $($ChocoApp.ApplicationName) Commit failed. Please check if app uploaded succesful" -Sev "Warning"
            break 
        }
        Start-Sleep -Milliseconds 300
    } while ($CommitStateReq.uploadState -eq "commitFilePending")        
    $CommitFinalizeReq = New-graphPostRequest -Uri "$($BaseURI)/$($NewApp.id)" -tenantid $tenant -Body '{"@odata.type":"#microsoft.graph.win32lobapp","committedContentVersion":"1"}' -type PATCH
    Log-Request -user $user -message "$($Tenant): Added Choco app $($chocoApp.ApplicationName)" -Sev "Info"
    if ($AssignTo -ne "On") {
        $AssignBody = if ($AssignTo -ne "AllDevicesAndUsers") { '{"mobileAppAssignments":[{"@odata.type":"#microsoft.graph.mobileAppAssignment","target":{"@odata.type":"#microsoft.graph.' + $($AssignTo) + 'AssignmentTarget"},"intent":"Required","settings":{"@odata.type":"#microsoft.graph.win32LobAppAssignmentSettings","notifications":"hideAll","installTimeSettings":null,"restartSettings":null,"deliveryOptimizationPriority":"notConfigured"}}]}' } else { '{"mobileAppAssignments":[{"@odata.type":"#microsoft.graph.mobileAppAssignment","target":{"@odata.type":"#microsoft.graph.allDevicesAssignmentTarget"},"intent":"Required","settings":{"@odata.type":"#microsoft.graph.win32LobAppAssignmentSettings","notifications":"showAll","installTimeSettings":null,"restartSettings":null,"deliveryOptimizationPriority":"notConfigured"}},{"@odata.type":"#microsoft.graph.mobileAppAssignment","target":{"@odata.type":"#microsoft.graph.allLicensedUsersAssignmentTarget"},"intent":"Required","settings":{"@odata.type":"#microsoft.graph.win32LobAppAssignmentSettings","notifications":"showAll","installTimeSettings":null,"restartSettings":null,"deliveryOptimizationPriority":"notConfigured"}}]}' }
        $assign = New-GraphPOSTRequest -uri  "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($NewApp.id)/assign" -tenantid $tenant -type POST -body $AssignBody
        Log-Request -user $user -message "$($Tenant): Assigned application $($chocoApp.ApplicationName) to $AssignTo" -Sev "Info"
    }
    Log-Request -message "$($Tenant): Succesfully added Choco App for $($Tenant)<br>"
}
catch {
    "Failed to add Choco App for $($Tenant): $($_.Exception.Message) <br>"
    Log-Request -user $user -message "$($Tenant): Failed adding choco App $($ChocoApp.ApplicationName). Error: $($_.Exception.Message)" -Sev "Error"
    continue
}