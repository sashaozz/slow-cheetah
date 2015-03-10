param($rootPath, $toolsPath, $package, $project)

"Installing AltLanDS.VSProjectPackage to project [{0}]" -f $project.FullName | Write-Host

$scLabel = "AltLanDS_VSProjectPackage"

# When this package is installed we need to add a property
# to the current project, SlowCheetahTargets, which points to the
# .targets file in the packages folder

function RemoveExistingSlowCheetahPropertyGroups($projectRootElement){
    # if there are any PropertyGroups with a label of "SlowCheetah" they will be removed here
    $pgsToRemove = @()
    foreach($pg in $projectRootElement.PropertyGroups){
        if($pg.Label -and [string]::Compare($scLabel,$pg.Label,$true) -eq 0) {
            # remove this property group
            $pgsToRemove += $pg
        }
    }

    foreach($pg in $pgsToRemove){
        $pg.Parent.RemoveChild($pg)
    }
}

# TODO: Revisit this later, it was causing some exceptions
function CheckoutProjFileIfUnderScc(){
    # http://daltskin.blogspot.com/2012/05/nuget-powershell-and-tfs.html
    $sourceControl = Get-Interface $project.DTE.SourceControl ([EnvDTE80.SourceControl2])
    if($sourceControl.IsItemUnderSCC($project.FullName) -and $sourceControl.IsItemCheckedOut($project.FullName)){
        $sourceControl.CheckOutItem($project.FullName)
    }
}

function EnsureProjectFileIsWriteable(){
    $projItem = Get-ChildItem $project.FullName
    if($projItem.IsReadOnly) {
        "The project file is read-only. Please checkout the project file and re-install this package" | Write-Host -ForegroundColor Red
        throw;
    }
}

function ComputeRelativePathToTargetsFile(){
    param($startPath,$targetPath)
    
    # we need to compute the relative path
    $startLocation = Get-Location

    Set-Location $startPath.Directory | Out-Null
    $relativePath = Resolve-Path -Relative $targetPath.FullName

    # reset the location
    Set-Location $startLocation | Out-Null

    return $relativePath
}

function GetSolutionDirFromProj{
    param($msbuildProject)

    if(!$msbuildProject){
        throw "msbuildProject is null"
    }

    $result = $null
    $solutionElement = $null
    foreach($pg in $msbuildProject.PropertyGroups){
        foreach($prop in $pg.Properties){
            if([string]::Compare("SolutionDir",$prop.Name,$true) -eq 0){
                $solutionElement = $prop
                break
            }
        }
    }

    if($solutionElement){
        $result = $solutionElement.Value
    }

    return $result
}

# we need to update the packageRestore.proj file to have the correct value for SolutionDir
function UpdatePackageRestoreSolutionDir (){
    param($pkgRestorePath, $solDirValue)
    if(!(Test-Path $pkgRestorePath)){
        throw ("pkgRestore file not found at {0}" -f $pkgRestorePath)
    }

    $solDirElement = $null
    $root = [Microsoft.Build.Construction.ProjectRootElement]::Open($pkgRestorePath)
    foreach($pg in $root.PropertyGroups){
        foreach($prop in $pg.Properties){
            if([string]::Compare("AltLanDS_VSProjectPackageSolutionDir",$prop.Label,$true) -eq 0){
                $solDirElement = $prop
                break
            }
        }
    }
    
    if($solDirElement){
        $solDirElement.Value = $solDirValue

        $root.Save()

    }
}

function AddImportElementIfNotExists(){
    param($projectRootElement)

    $foundImport = $false
    $importsToRemove = @()
    foreach($import in $projectRootElement.Imports){
        $importStr = $import.Project
        if(!$importStr){
            $importStr = ""
        }

        if([string]::Compare('$(AltLanDS_VSProjectPackage)',$importStr.Trim(),$true) -eq 0){
            if(!$foundImport){
               # if it doesn't have a label then add one
                if([string]::IsNullOrWhiteSpace($import.Label)){
                    $import.Label = $scLabel
                }
                $import.Condition="Exists('`$(AltLanDS_VSProjectPackage)')"

                $foundImport = $true
            }
            else{
                # if we already found an import, this must be a duplicate remove it
                $importsToRemove+=$import
            }
        }
    }
    
    foreach($import in $importsToRemove){        
        # $projectRootElement.Imports.Remove($import)
        # you have to use Microsoft.Build.Evaluation.ProjectCollection to remove, so disabling should be good enough
        $import.Condition='false'
    }

    if(!$foundImport){
        # the import is not in the project, add it
        # <Import Project="$(SlowCheetahTargets)" Condition="Exists('$(SlowCheetahTargets)')" Label="SlowCheetah" />
        $importToAdd = $projectRootElement.AddImport('$(AltLanDS_VSProjectPackage)');
        $importToAdd.Condition = "Exists('`$(AltLanDS_VSProjectPackage)')"
        $importToAdd.Label = $scLabel 
    }        
}



#########################
# Start of script here
#########################

$projFile = $project.FullName

# Make sure that the project file exists
if(!(Test-Path $projFile)){
    throw ("Project file not found at [{0}]" -f $projFile)
}

# use MSBuild to load the project and add the property

# This is what we want to add to the project
#  <PropertyGroup Label="SlowCheetah">
#      <SlowCheetah_EnableImportFromNuGet Condition=" '$(SC_EnableImportFromNuGet)'=='' ">true</SlowCheetah_EnableImportFromNuGet>
#      <SlowCheetah_NuGetImportPath Condition=" '$(SlowCheetah_NuGetImportPath)'=='' ">$([System.IO.Path]::GetFullPath( $(Filepath) ))</SlowCheetah_NuGetImportPath>
#      <SlowCheetahTargets Condition=" '$(SlowCheetah_EnableImportFromNuGet)'=='true' and Exists('$(SlowCheetah_NuGetImportPath)') ">$(SlowCheetah_NuGetImportPath)</SlowCheetahTargets>
#  </PropertyGroup>


# EnsureProjectFileIsWriteable
# Before modifying the project save everything so that nothing is lost
$DTE.ExecuteCommand("File.SaveAll")
CheckoutProjFileIfUnderScc
EnsureProjectFileIsWriteable

# Update the Project file to import the .targets file
$relPathToTargets = ComputeRelativePathToTargetsFile -startPath ($projItem = Get-Item $project.FullName) -targetPath (Get-Item ("{0}\tools\AltLanDS.VSProjectPackage.targets" -f $rootPath))

$projectMSBuild = [Microsoft.Build.Construction.ProjectRootElement]::Open($projFile)

RemoveExistingSlowCheetahPropertyGroups -projectRootElement $projectMSBuild
$propertyGroup = $projectMSBuild.AddPropertyGroup()
$propertyGroup.Label = $scLabel

$relPathToToolsFolder = ComputeRelativePathToTargetsFile -startPath ($projItem = Get-Item $project.FullName) -targetPath (Get-Item ("{0}\tools\" -f $rootPath))
$propertyGroup.AddProperty('AltLanDS_VSProjectPackage_ToolsPath', ('$([System.IO.Path]::GetFullPath( $(MSBuildProjectDirectory)\{0}\))') -f $relPathToToolsFolder);

$propEnableNuGetImport = $propertyGroup.AddProperty('AltLanDS_VSProjectPackage_EnableImportFromNuGet', 'true');
$propEnableNuGetImport.Condition = ' ''$(AltLanDS_VSProjectPackage_EnableImportFromNuGet)''=='''' ';

$importStmt = ('$([System.IO.Path]::GetFullPath( $(MSBuildProjectDirectory)\Properties\AltLanDS.VSProjectPackage\AltLanDS.VSProjectPackage.targets ))' -f $relPathToTargets)
$propNuGetImportPath = $propertyGroup.AddProperty('AltLanDS_VSProjectPackage_NuGetImportPath', "$importStmt");
$propNuGetImportPath.Condition = ' ''$(AltLanDS_VSProjectPackage_NuGetImportPath)''=='''' ';

$propImport = $propertyGroup.AddProperty('AltLanDS_VSProjectPackageTargets', '$(AltLanDS_VSProjectPackage_NuGetImportPath)');
$propImport.Condition = ' ''$(AltLanDS_VSProjectPackage_EnableImportFromNuGet)''==''true'' and Exists(''$(AltLanDS_VSProjectPackage_NuGetImportPath)'') ';

AddImportElementIfNotExists -projectRootElement $projectMSBuild

$projectMSBuild.Save()