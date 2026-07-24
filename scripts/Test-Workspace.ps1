[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$gitMetadataRoot = (Join-Path $workspaceRoot '.git') + [System.IO.Path]::DirectorySeparatorChar
$excludedDirectoryNames = @(
    '.git',
    '.azureiq',
    '.pytest_cache',
    '__pycache__',
    'bin',
    'coverage',
    'node_modules',
    'obj',
    'TestResults'
)
$requiredPaths = @(
    '.azure/deployment-plan.md',
    '.github/copilot-instructions.md',
    'artifacts/README.md',
    'artifacts/catalog.json',
    'capabilities/README.md',
    'capabilities/registry.json',
    'case-study/WaypointFreight/README.md',
    'case-study/WaypointFreight/WaypointFreight.sln',
    'case-study/WaypointFreight/backend/WaypointFreight.Api/WaypointFreight.Api.csproj',
    'case-study/WaypointFreight/backend/WaypointFreight.Api/Program.cs',
    'case-study/WaypointFreight/backend/WaypointFreight.Api.Tests/ShipmentApiTests.cs',
    'case-study/WaypointFreight/client/WaypointFreight.Client/WaypointFreight.Client.csproj',
    'case-study/WaypointFreight/client/WaypointFreight.Client/wwwroot/index.html',
    'config/azureiq.yaml',
    'docs/architecture.md',
    'docs/capabilities.md',
    'docs/coding-engine.md',
    'docs/current-architecture.md',
    'docs/execution-tools.md',
    'docs/memory-model.md',
    'docs/roadmap.md',
    'schemas/action-manifest.schema.json',
    'schemas/artifact-catalog.schema.json',
    'schemas/capability-registry.schema.json',
    'schemas/execution-record.schema.json',
    'src/AzureIQ.Execution/AzureIQ.Execution.csproj',
    'src/AzureIQ.Execution/operations.json',
    'src/AzureIQ.Execution/Program.cs',
    'src/AzureIQ.Execution/README.md',
    'service-packs/api-management/manifest.yaml'
)

foreach ($requiredPath in $requiredPaths) {
    $fullPath = Join-Path $workspaceRoot $requiredPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required file is missing: $requiredPath"
    }
}

function Test-IsGeneratedWorkspacePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $relativePath = [System.IO.Path]::GetRelativePath($workspaceRoot, $Path)
    $segments = $relativePath -split '[\\/]'
    return @($segments | Where-Object { $_ -in $excludedDirectoryNames }).Count -gt 0
}

function Get-FrontMatter {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    $lines = Get-Content -LiteralPath $File.FullName
    if ($lines.Count -lt 3 -or $lines[0] -ne '---') {
        throw "Missing opening frontmatter marker: $($File.FullName)"
    }

    $closingIndex = -1
    for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lines[$lineIndex] -eq '---') {
            $closingIndex = $lineIndex
            break
        }
    }

    if ($closingIndex -lt 2) {
        throw "Missing or empty frontmatter: $($File.FullName)"
    }

    return $lines[1..($closingIndex - 1)] -join "`n"
}

function Get-FrontMatterValue {
    param(
        [Parameter(Mandatory)]
        [string]$FrontMatter,

        [Parameter(Mandatory)]
        [string]$Property
    )

    $propertyPattern = [regex]::Escape($Property)
    $propertyMatch = [regex]::Match($FrontMatter, "(?m)^${propertyPattern}:\s*(.*?)\s*$")
    if (-not $propertyMatch.Success) {
        return $null
    }

    return $propertyMatch.Groups[1].Value.Trim().Trim('"').Trim("'")
}

function Get-FrontMatterBoolean {
    param(
        [Parameter(Mandatory)]
        [string]$FrontMatter,

        [Parameter(Mandatory)]
        [string]$Property,

        [Parameter(Mandatory)]
        [bool]$Default
    )

    $propertyValue = Get-FrontMatterValue -FrontMatter $FrontMatter -Property $Property
    if ($null -eq $propertyValue) {
        return $Default
    }

    switch ($propertyValue.ToLowerInvariant()) {
        'true' { return $true }
        'false' { return $false }
        default { throw "Frontmatter property '$Property' must be true or false; found '$propertyValue'." }
    }
}

$agentFiles = @(Get-ChildItem -Path (Join-Path $workspaceRoot '.github/agents') -Filter '*.agent.md' -File)
if ($agentFiles.Count -lt 5) {
    throw "Expected at least five AzureIQ agents; found $($agentFiles.Count)."
}

$agentMetadata = [System.Collections.Generic.List[object]]::new()
foreach ($agentFile in $agentFiles) {
    $frontMatter = Get-FrontMatter -File $agentFile
    $agentName = Get-FrontMatterValue -FrontMatter $frontMatter -Property 'name'
    if ([string]::IsNullOrWhiteSpace($agentName)) {
        throw "Agent name is missing: $($agentFile.FullName)"
    }
    if ($frontMatter -notmatch '(?m)^description:\s*["'']?[^\r\n]+$') {
        throw "Agent description is missing: $($agentFile.FullName)"
    }

    $agentMetadata.Add([pscustomobject]@{
        Name = $agentName
        File = $agentFile
        UserInvocable = Get-FrontMatterBoolean -FrontMatter $frontMatter -Property 'user-invocable' -Default $true
        DisableModelInvocation = Get-FrontMatterBoolean -FrontMatter $frontMatter -Property 'disable-model-invocation' -Default $false
    })
}

$requiredAgentNames = @(
    'AzureIQ Orchestrator',
    'AzureIQ Inventory',
    'AzureIQ Incident Diagnostician',
    'AzureIQ Change Planner',
    'AzureIQ Verifier'
)
foreach ($requiredAgentName in $requiredAgentNames) {
    if ($requiredAgentName -notin $agentMetadata.Name) {
        throw "Required AzureIQ agent is missing: $requiredAgentName"
    }
}

$visibleAgents = @($agentMetadata | Where-Object UserInvocable)
if ($visibleAgents.Count -ne 1 -or $visibleAgents[0].Name -ne 'AzureIQ Orchestrator') {
    $visibleAgentNames = $visibleAgents.Name -join ', '
    throw "AzureIQ must expose only 'AzureIQ Orchestrator'; visible agents: $visibleAgentNames"
}

$orchestrator = $visibleAgents[0]
if (-not $orchestrator.DisableModelInvocation) {
    throw 'AzureIQ Orchestrator must not be model-invoked as an extra routing layer.'
}

$orchestratorContent = Get-Content -Raw -LiteralPath $orchestrator.File.FullName
$hiddenSpecialists = @($agentMetadata | Where-Object Name -ne 'AzureIQ Orchestrator')
foreach ($hiddenSpecialist in $hiddenSpecialists) {
    if ($hiddenSpecialist.UserInvocable) {
        throw "AzureIQ specialist must be hidden from users: $($hiddenSpecialist.Name)"
    }
    if ($hiddenSpecialist.DisableModelInvocation) {
        throw "AzureIQ specialist must remain available for model routing: $($hiddenSpecialist.Name)"
    }
    if ($orchestratorContent -notmatch [regex]::Escape($hiddenSpecialist.Name)) {
        throw "AzureIQ Orchestrator does not route to specialist: $($hiddenSpecialist.Name)"
    }
}

$skillFiles = @(Get-ChildItem -Path (Join-Path $workspaceRoot '.github/skills') -Filter 'SKILL.md' -File -Recurse)
if ($skillFiles.Count -lt 3) {
    throw "Expected at least three AzureIQ skills; found $($skillFiles.Count)."
}

foreach ($skillFile in $skillFiles) {
    $frontMatter = Get-FrontMatter -File $skillFile
    $declaredName = Get-FrontMatterValue -FrontMatter $frontMatter -Property 'name'
    if ([string]::IsNullOrWhiteSpace($declaredName)) {
        throw "Skill name is missing: $($skillFile.FullName)"
    }

    if ($declaredName -ne $skillFile.Directory.Name) {
        throw "Skill name '$declaredName' does not match folder '$($skillFile.Directory.Name)'."
    }

    if ($frontMatter -notmatch '(?m)^description:\s*["'']?[^\r\n]+$') {
        throw "Skill description is missing: $($skillFile.FullName)"
    }

    if (Get-FrontMatterBoolean -FrontMatter $frontMatter -Property 'user-invocable' -Default $true) {
        throw "AzureIQ skills must load automatically without requiring slash-command knowledge: $declaredName"
    }
    if (Get-FrontMatterBoolean -FrontMatter $frontMatter -Property 'disable-model-invocation' -Default $false) {
        throw "AzureIQ skill is unavailable for automatic model loading: $declaredName"
    }
}

$servicePackManifests = @(Get-ChildItem -Path (Join-Path $workspaceRoot 'service-packs') -Filter 'manifest.yaml' -File -Recurse)
foreach ($servicePackManifest in $servicePackManifests) {
    $manifestContent = Get-Content -Raw -LiteralPath $servicePackManifest.FullName
    $requiredValuePatterns = @(
        '(?m)^value:\s*$',
        '(?m)^\s+proofStatus:\s+(unproven|baseline-recorded|value-demonstrated|no-value)\s*$',
        '(?m)^\s+baselineProvider:\s+\S.*$',
        '(?m)^\s+baselineStatus:\s+(not-run|completed)\s*$',
        '(?m)^\s+retentionDecision:\s+(pending|keep|revise|retire)\s*$'
    )

    foreach ($requiredValuePattern in $requiredValuePatterns) {
        if ($manifestContent -notmatch $requiredValuePattern) {
            throw "Service-pack value proof metadata is incomplete: $($servicePackManifest.FullName)"
        }
    }
}

$jsonFiles = @(Get-ChildItem -Path $workspaceRoot -Filter '*.json' -File -Recurse -Force | Where-Object {
    -not (Test-IsGeneratedWorkspacePath -Path $_.FullName)
})
foreach ($jsonFile in $jsonFiles) {
    Get-Content -Raw -LiteralPath $jsonFile.FullName | ConvertFrom-Json -Depth 100 | Out-Null
}

$artifactCatalogPath = Join-Path $workspaceRoot 'artifacts/catalog.json'
$artifactSchemaPath = Join-Path $workspaceRoot 'schemas/artifact-catalog.schema.json'
$artifactCatalogContent = Get-Content -Raw -LiteralPath $artifactCatalogPath
if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
    if (-not ($artifactCatalogContent | Test-Json -SchemaFile $artifactSchemaPath -ErrorAction Stop)) {
        throw 'Artifact catalog does not conform to its JSON schema.'
    }
}

$artifactCatalog = $artifactCatalogContent | ConvertFrom-Json -Depth 100
$artifacts = @($artifactCatalog.artifacts)
$artifactKeys = @($artifacts | ForEach-Object { "$($_.id)@$($_.version)" })
if (@($artifactKeys | Sort-Object -Unique).Count -ne $artifactKeys.Count) {
    throw 'Artifact catalog id/version combinations must be unique.'
}

$artifactCatalogDirectory = Split-Path -Parent $artifactCatalogPath
foreach ($artifact in $artifacts) {
    $artifactSourcePath = Join-Path $artifactCatalogDirectory $artifact.source.path
    if (-not (Test-Path -LiteralPath $artifactSourcePath -PathType Leaf)) {
        throw "Artifact '$($artifact.id)@$($artifact.version)' source is missing: $($artifact.source.path)"
    }

    $normalizedSource = (Get-Content -Raw -LiteralPath $artifactSourcePath).Replace("`r`n", "`n").Replace("`r", "`n")
    $sourceBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedSource)
    $actualDigest = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($sourceBytes)
    ).ToLowerInvariant()
    if ($actualDigest -ne $artifact.source.sha256) {
        throw "Artifact '$($artifact.id)@$($artifact.version)' source digest does not match the catalog."
    }
}

$registryPath = Join-Path $workspaceRoot 'capabilities/registry.json'
$registrySchemaPath = Join-Path $workspaceRoot 'schemas/capability-registry.schema.json'
$registryContent = Get-Content -Raw -LiteralPath $registryPath
if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
    if (-not ($registryContent | Test-Json -SchemaFile $registrySchemaPath -ErrorAction Stop)) {
        throw 'Capability registry does not conform to its JSON schema.'
    }
}

$capabilityRegistry = $registryContent | ConvertFrom-Json -Depth 100
$capabilities = @($capabilityRegistry.capabilities)
$capabilityIds = @($capabilities.id)
$uniqueCapabilityIds = @($capabilityIds | Sort-Object -Unique)
if ($uniqueCapabilityIds.Count -ne $capabilityIds.Count) {
    throw 'Capability registry IDs must be unique.'
}

$operationCatalog = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot 'src/AzureIQ.Execution/operations.json') |
    ConvertFrom-Json -Depth 100
$registeredOperations = @($operationCatalog.operations.operation)
$registryDirectory = Split-Path -Parent $registryPath

foreach ($capability in $capabilities) {
    if (@($capability.intents).Count -eq 0) {
        throw "Capability '$($capability.id)' must declare at least one intent."
    }
    if (@($capability.verification).Count -eq 0) {
        throw "Capability '$($capability.id)' must declare independent verification."
    }

    foreach ($reference in @($capability.references)) {
        $referencePath = Join-Path $registryDirectory $reference
        if (-not (Test-Path -LiteralPath $referencePath)) {
            throw "Capability '$($capability.id)' has a broken reference: $reference"
        }
    }

    $routes = @($capability.primary)
    if ($null -ne $capability.fallback) {
        $routes += $capability.fallback
    }
    foreach ($route in $routes) {
        if ($route.kind -eq 'azureiq-cli' -and $route.operation -notin $registeredOperations) {
            throw "Capability '$($capability.id)' references unregistered AzureIQ CLI operation '$($route.operation)'."
        }
    }
}

$workspaceInstructions = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot '.github/copilot-instructions.md')
if ($workspaceInstructions -notmatch [regex]::Escape('capabilities/registry.json')) {
    throw 'Always-on workspace instructions must route through capabilities/registry.json.'
}
if ($workspaceInstructions -notmatch [regex]::Escape('artifacts/catalog.json')) {
    throw 'Always-on workspace instructions must retrieve from artifacts/catalog.json before generation.'
}
if ($orchestratorContent -notmatch [regex]::Escape('capabilities/registry.json')) {
    throw 'AzureIQ Orchestrator must route through capabilities/registry.json.'
}
if ($orchestratorContent -notmatch [regex]::Escape('artifacts/catalog.json')) {
    throw 'AzureIQ Orchestrator must retrieve from artifacts/catalog.json before generation.'
}

$brokenLinks = [System.Collections.Generic.List[string]]::new()
$markdownFiles = @(Get-ChildItem -Path $workspaceRoot -Filter '*.md' -File -Recurse -Force | Where-Object {
    -not (Test-IsGeneratedWorkspacePath -Path $_.FullName)
})
foreach ($markdownFile in $markdownFiles) {
    $content = Get-Content -Raw -LiteralPath $markdownFile.FullName
    $linkMatches = [regex]::Matches($content, '\[[^\]]*\]\((?!https?://|mailto:|command:|#)([^)#]+)(?:#[^)]+)?\)')
    foreach ($linkMatch in $linkMatches) {
        $relativeTarget = [uri]::UnescapeDataString($linkMatch.Groups[1].Value)
        $fullTarget = Join-Path $markdownFile.DirectoryName $relativeTarget
        if (-not (Test-Path -LiteralPath $fullTarget)) {
            $brokenLinks.Add("$($markdownFile.FullName) -> $relativeTarget")
        }
    }
}

if ($brokenLinks.Count -gt 0) {
    throw "Broken local Markdown links:`n$($brokenLinks -join "`n")"
}

$sensitiveExtensions = @('.pfx', '.p12', '.pem', '.key', '.jks', '.publishsettings', '.har', '.trace')
$sensitiveFiles = @(Get-ChildItem -Path $workspaceRoot -File -Recurse -Force | Where-Object {
    -not (Test-IsGeneratedWorkspacePath -Path $_.FullName) -and
    $sensitiveExtensions -contains $_.Extension.ToLowerInvariant()
})
if ($sensitiveFiles.Count -gt 0) {
    throw "Sensitive or raw evidence file type found: $($sensitiveFiles.FullName -join ', ')"
}

$trackedConfigurationPath = Join-Path $workspaceRoot 'config/azureiq.yaml'
$localConfigurationPath = Join-Path $workspaceRoot 'config/local.azureiq.json'
$trackedConfiguration = Get-Content -Raw -LiteralPath $trackedConfigurationPath
$effectiveConfiguration = $trackedConfiguration
$scopeSource = 'tracked-bootstrap'

if (Test-Path -LiteralPath $localConfigurationPath -PathType Leaf) {
    & git -C $workspaceRoot check-ignore --quiet -- 'config/local.azureiq.json'
    if ($LASTEXITCODE -ne 0) {
        throw 'Private config/local.azureiq.json must be ignored by Git.'
    }

    $localConfiguration = Get-Content -Raw -LiteralPath $localConfigurationPath | ConvertFrom-Json -Depth 20
    $effectiveConfiguration = Get-Content -Raw -LiteralPath $localConfigurationPath
    $scopeSource = 'private-local'

    $privateScopeIdentifiers = @([regex]::Matches(
        $effectiveConfiguration,
        '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    ) | ForEach-Object Value | Sort-Object -Unique)

    if ($privateScopeIdentifiers.Count -gt 0) {
        $scopeLeakFiles = [System.Collections.Generic.List[string]]::new()
        $workspaceFiles = @(Get-ChildItem -Path $workspaceRoot -File -Recurse -Force | Where-Object {
            -not (Test-IsGeneratedWorkspacePath -Path $_.FullName) -and
            $_.FullName -ne $localConfigurationPath
        })

        foreach ($workspaceFile in $workspaceFiles) {
            $workspaceContent = Get-Content -Raw -LiteralPath $workspaceFile.FullName -ErrorAction SilentlyContinue
            if ($null -eq $workspaceContent) {
                continue
            }
            foreach ($privateScopeIdentifier in $privateScopeIdentifiers) {
                if ($workspaceContent.Contains($privateScopeIdentifier, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $scopeLeakFiles.Add($workspaceFile.FullName)
                    break
                }
            }
        }

        if ($scopeLeakFiles.Count -gt 0) {
            throw "Private Azure scope identifier found outside ignored local configuration:`n$($scopeLeakFiles -join "`n")"
        }
    }
}

$modeMatch = if ($scopeSource -eq 'private-local') {
    [pscustomobject]@{ Success = $true; Groups = @($null, [pscustomobject]@{ Value = [string]$localConfiguration.mode }) }
} else {
    [regex]::Match($effectiveConfiguration, '(?m)^mode:\s*(\S+)\s*$')
}
$targetModeMatch = [regex]::Match($trackedConfiguration, '(?m)^targetMode:\s*(\S+)\s*$')
$azureWritesMatch = if ($scopeSource -eq 'private-local') {
    [pscustomobject]@{ Success = $true; Groups = @($null, [pscustomobject]@{ Value = [string]$localConfiguration.safety.azureWrites }) }
} else {
    [regex]::Match($effectiveConfiguration, '(?m)^\s*azureWrites:\s*(\S+)\s*$')
}
if (-not $modeMatch.Success -or -not $targetModeMatch.Success -or -not $azureWritesMatch.Success) {
    throw 'AzureIQ mode, targetMode, and safety.azureWrites must be configured.'
}

$mode = $modeMatch.Groups[1].Value
$targetMode = $targetModeMatch.Groups[1].Value
$azureWrites = $azureWritesMatch.Groups[1].Value
if ($targetMode -ne 'supervised-management') {
    throw "AzureIQ targetMode must remain supervised-management; found '$targetMode'."
}

switch ($mode) {
    'bootstrap-read-only' {
        if ($azureWrites -ne 'deny') {
            throw 'bootstrap-read-only requires safety.azureWrites: deny.'
        }
    }
    'supervised-management' {
        if ($azureWrites -ne 'supervised') {
            throw 'supervised-management requires safety.azureWrites: supervised.'
        }
        if ($scopeSource -eq 'private-local' -and @($localConfiguration.scope.subscriptionIds).Count -eq 0) {
            throw 'supervised-management requires at least one configured subscription ID.'
        }
        if ($scopeSource -ne 'private-local' -and $effectiveConfiguration -match '(?m)^\s*subscriptionIds:\s*\[\s*\]\s*$') {
            throw 'supervised-management requires at least one configured subscription ID.'
        }
        if ($scopeSource -eq 'private-local' -and [string]::IsNullOrWhiteSpace($localConfiguration.identity.interactivePrincipal)) {
            throw 'supervised-management requires a configured interactive principal.'
        }
        if ($scopeSource -ne 'private-local' -and $effectiveConfiguration -match '(?m)^\s*interactivePrincipal:\s*null\s*$') {
            throw 'supervised-management requires a configured interactive principal.'
        }
        if ($scopeSource -eq 'private-local' -and $localConfiguration.observability.topology -eq 'undecided') {
            throw 'supervised-management requires an observability topology decision.'
        }
        if ($scopeSource -ne 'private-local' -and $effectiveConfiguration -match '(?m)^\s*topology:\s*undecided\s*$') {
            throw 'supervised-management requires an observability topology decision.'
        }
        if ($scopeSource -eq 'private-local' -and $localConfiguration.operations.primaryIac -eq 'undecided') {
            throw 'supervised-management requires a primary IaC choice.'
        }
        if ($scopeSource -ne 'private-local' -and $effectiveConfiguration -match '(?m)^\s*primaryIac:\s*undecided\s*$') {
            throw 'supervised-management requires a primary IaC choice.'
        }
        if ($scopeSource -eq 'private-local' -and $localConfiguration.operations.approvalSystem -eq 'undecided') {
            throw 'supervised-management requires an approval mechanism.'
        }
        if ($scopeSource -ne 'private-local' -and $effectiveConfiguration -match '(?m)^\s*approvalSystem:\s*undecided\s*$') {
            throw 'supervised-management requires an approval mechanism.'
        }
        if ($scopeSource -eq 'private-local' -and @($localConfiguration.safety.automaticRiskTiers).Count -ne 0) {
            throw 'Initial supervised-management requires automaticRiskTiers to remain empty.'
        }
        if ($scopeSource -ne 'private-local' -and $effectiveConfiguration -notmatch '(?m)^\s*automaticRiskTiers:\s*\[\s*\]\s*$') {
            throw 'Initial supervised-management requires automaticRiskTiers to remain empty.'
        }
    }
    default {
        throw "Unsupported AzureIQ operating mode: $mode"
    }
}

$deploymentPlan = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot '.azure/deployment-plan.md')
if ($deploymentPlan -notmatch 'Local Waypoint Freight API, test, and client implementation is complete and validated') {
    throw 'The case-study deployment plan must record the validated local milestone.'
}
if ($deploymentPlan -notmatch 'Azure rollout preparation approved - deployment pending validated what-if and exact action approval' -and
    $deploymentPlan -notmatch 'The supervised deployment is complete') {
    throw 'The case-study deployment plan must record either the exact deployment gate or its supervised completion.'
}
if ($deploymentPlan -notmatch 'No Azure resource or application write is authorized until the resulting action manifest and what-if are approved immediately before execution') {
    throw 'The case-study deployment plan must keep Azure writes gated by an approved manifest and what-if.'
}
if ($deploymentPlan -notmatch '## Disposable Teardown Contract') {
    throw 'The case-study deployment plan must define supervised teardown and absence verification.'
}
if ($deploymentPlan -notmatch '## Coding Engine Requirement For This Case Study') {
    throw 'The case-study deployment plan must route tool gaps into the coding engine.'
}

[pscustomobject]@{
    Status = 'PASS'
    Mode = $mode
    ScopeSource = $scopeSource
    Agents = $agentFiles.Count
    VisibleAgent = $visibleAgents[0].Name
    Skills = $skillFiles.Count
    ServicePacks = $servicePackManifests.Count
    CapabilityOverlays = $capabilities.Count
    ReusableArtifacts = $artifacts.Count
    CliOperations = $registeredOperations.Count
    MarkdownFiles = $markdownFiles.Count
    JsonFiles = $jsonFiles.Count
    AzureWrites = $azureWrites
}