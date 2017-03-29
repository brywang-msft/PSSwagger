# Ensures a package source exists for the location "http://nuget.org/api/v2/"
function Test-NugetPackageSource {
    $bestNugetLocation = "http://nuget.org/api/v2/"
    $nugetPackageSource = Get-PackageSource | Where-Object {($_.ProviderName -eq "NuGet") -and ($_.Location -eq $bestNugetLocation) } | Select-Object -First 1
    Write-Verbose "Attempted to find NuGet package source. Got: $nugetPackageSource"
    if ($nugetPackageSource -eq $null) {
        Write-Verbose "No NuGet package source found for location $bestNugetLocation. Registering source PSSwaggerNuget."
        $nugetPackageSource = Register-PackageSource "PSSwaggerNuget" -Location $bestNugetLocation -ProviderName "NuGet" -Trusted -Force
    }

    return $nugetPackageSource
}

# Ensures a given package exists. Caller should validate if returned module is null or not (null indicates the package failed to install)
function Test-Package {
    param(
        [string]$packageName,
        [string]$packageSourceName,
        [string]$providerName = "NuGet"
    )

    $package = Get-Package $packageName -ProviderName $providerName -ErrorAction Ignore | Select-Object -First 1
    if ($package -eq $null) {
        Write-Verbose "Trying to install missing package $packageName from source $packageSourceName"
        $null = Install-Package $packageName -ProviderName $providerName -Source $packageSourceName -Force
        $package = Get-Package $packageName -ProviderName $providerName
    }

    $package
}

function Compile-TestAssembly {
    [CmdletBinding()]
    param(
        [string]$TestAssemblyName,
        [string]$TestAssemblyPath,
        [string]$TestCSharpFilePath,
        [string]$CompilationUtilsPath,
        [bool]$UseAzureCSharpGenerator
    )

    $fullPath = Join-Path -Path $TestAssemblyPath -ChildPath $TestAssemblyName
    Write-Verbose "Checking for test assembly '$fullPath'"
    if (-not (Test-Path $fullPath)) {
        Write-Verbose "Generating test assembly from file '$TestCSharpFilePath' using script '$CompilationUtilsPath'"
        . "$CompilationUtilsPath"
        Invoke-AssemblyCompilation -CSharpFiles @($TestCSharpFilePath) -OutputAssemblyName $TestAssemblyName -CodeCreatedByAzureGenerator:$UseAzureCSharpGenerator -ClrPath $TestAssemblyPath -Verbose
    }
}

function Initialize-Test {
    [CmdletBinding()]
    param(
        [string]$GeneratedModuleName,
        [string]$TestApiName,
        [string]$TestSpecFileName,
        [string]$TestDataFileName,
        [string]$PsSwaggerPath,
        [string]$TestRootPath,
        [string]$GeneratedModuleVersion
    )

    Compile-TestAssembly -TestAssemblyName "$global:testRunGuid.dll" `
                         -TestAssemblyPath (Join-Path "$TestRootPath" "PSSwagger.TestUtilities") `
                         -TestCSharpFilePath (Join-Path "$TestRootPath" "PSSwagger.TestUtilities" | Join-Path -ChildPath "TestCredentials.cs") `
                         -CompilationUtilsPath (Join-Path $PsSwaggerPath "Utils.ps1") -UseAzureCSharpGenerator $false -Verbose

    

    # TODO: Pass all these locations dynamically - See issues/17
    $generatedModulesPath = Join-Path -Path "$TestRootPath" -ChildPath "Generated"
    $testCaseDataLocation = Join-Path -Path "$TestRootPath" -ChildPath "Data" | Join-Path -ChildPath "$TestApiName"

    # Note: This only works if these tests are never run in parallel, but our current usage of json-server is the same way, so...
    $global:testDataSpec = ConvertFrom-Json ((Get-Content (Join-Path -Path $testCaseDataLocation -ChildPath $TestSpecFileName)) -join [Environment]::NewLine) -ErrorAction Stop
        
    # Generate module
    Write-Verbose "Removing old module, if any"
    if (Test-Path (Join-Path $generatedModulesPath $GeneratedModuleName)) {
        Remove-Item (Join-Path $generatedModulesPath $GeneratedModuleName) -Recurse -Force
    }

    # Module generation part needs to happen in full powershell
    Write-Verbose "Generating module"
    if((Get-Variable -Name PSEdition -ErrorAction Ignore) -and ($script:CorePsEditionConstant -eq $PSEdition)) {
        & "powershell.exe" -command "& {`$env:PSModulePath=`$env:PSModulePath_Backup;
            Import-Module (Join-Path `"$PsSwaggerPath`" `"PSSwagger.psd1`") -Force;
            New-PSSwaggerModule -SwaggerSpecPath (Join-Path -Path `"$testCaseDataLocation`" -ChildPath $TestSpecFileName) -Path "$generatedModulesPath" -Name $GeneratedModuleName -Verbose -NoAssembly;
        }"
    } else {
        Import-Module (Join-Path "$PsSwaggerPath" "PSSwagger.psd1") -Force
        New-PSSwaggerModule -SwaggerSpecPath (Join-Path -Path "$testCaseDataLocation" -ChildPath $TestSpecFileName) -Path "$generatedModulesPath" -Name $GeneratedModuleName -Verbose -NoAssembly
    }

    # Copy json-server data since it's updated live
    Copy-Item "$testCaseDataLocation\$TestDataFileName" "$TestRootPath\NodeModules\db.json" -Force
}

function Start-JsonServer {
    [CmdletBinding()]
    param(
        [string]$TestRootPath,
        [string]$TestApiName,
        [string]$TestRoutesFileName,
        [string[]]$TestMiddlewareFileNames
    )

    $testCaseDataLocation = Join-Path -Path "$TestRootPath" -ChildPath "Data" | Join-Path -ChildPath "$TestApiName"

    $nodeProcesses = Get-Process -Name "node" -ErrorAction SilentlyContinue
    if ($nodeProcesses -eq $null) {
        $nodeProcesses = @()
    } elseif ($nodeProcesses.Count -eq 1) {
        $nodeProcesses = @($nodeProcesses)
    }

    $argList = "--watch `"$PSScriptRoot\NodeModules\db.json`""
    if ($TestRoutesFileName) {
        $argList += " --routes `"$testCaseDataLocation\$TestRoutesFileName`""
    }

    if ($TestMiddlewareFileNames) {
        $middlewares = $TestMiddlewareFileNames | ForEach-Object { "`"$testCaseDataLocation\$_`"" }
        $argList += " --middlewares $($middlewares -join ' ')"
    }

    Write-Verbose "Starting json-server: $PSScriptRoot\NodeModules\json-server.cmd $argList"
    if ('Core' -eq $PSEdition) {
        $jsonServerProcess = Start-Process -FilePath "$PSScriptRoot\NodeModules\json-server.cmd" -ArgumentList $argList -PassThru
    } else {
        $jsonServerProcess = Start-Process -FilePath "$PSScriptRoot\NodeModules\json-server.cmd" -ArgumentList $argList -PassThru -WindowStyle Hidden
    }

    # Wait for local json-server to start on full CLR
    if ('Core' -ne $PSEdition) {
        while (-not (Test-NetConnection -ComputerName localhost -Port 3000)) {
            Write-Verbose -Message "Waiting for server to start..." -Verbose
            Start-Sleep -s 1
        }
    }

    $nodeProcessToStop = Get-Process -Name "node" -ErrorAction SilentlyContinue | Where-Object {-not $nodeProcesses.Contains($_)}
    while ($nodeProcessToStop -eq $null) {
        $nodeProcessToStop = Get-Process -Name "node" -ErrorAction SilentlyContinue | Where-Object {-not $nodeProcesses.Contains($_)}
    }

    $props = @{
        ServerProcess = $jsonServerProcess;
        NodeProcess = $nodeProcessToStop
    }

    return New-Object -TypeName PSObject -Property $props
}

function Stop-JsonServer {
    [CmdletBinding()]
    param(
        [System.Diagnostics.Process]$JsonServerProcess,
        [System.Diagnostics.Process]$NodeProcess
    )

    Write-Verbose "Stopping process: $($JsonServerProcess.ID)"
    $JsonServerProcess | Stop-Process
    Write-Verbose "Stopping process: $($NodeProcess.ID)"
    $NodeProcess | Stop-Process
}