#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'ApimInsights.psm1') -Force
Import-Module (Join-Path $root 'ApimInsights.Report.psm1') -Force
$script:assertions = 0
function Check {
    param([bool]$Value, [string]$Description)
    if (-not $Value) { throw "FAILED: $Description" }
    $script:assertions++
}
function Fixture {
    Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'example.snapshot.json') | ConvertFrom-Json -AsHashtable
}
function Finding {
    param($Report, [string]$Id)
    @($Report.findings | Where-Object ruleId -eq $Id)[0]
}
$fixture = Fixture
$report = Invoke-ApimInsightsAssessment $fixture
Check ($report.delivery.state -eq 'Observed') 'Exact historical rows are observed'
Check ($report.rootCauseAnalysis.confidence -eq 'undetermined') 'Historical ingestion is not a transport root cause'
Check ((Finding $report 'identity-selector').status -eq 'Unknown') 'Protected selector is unknown, not invalid'
Check ((Finding $report 'publisher-role').status -eq 'Pass') 'Explicit scoped role candidate is recognized'
Check ((Finding $report 'effective-diagnostic').status -eq 'Pass' -and $report.diagnosticSource -eq 'API override') 'API override wins'
$withoutInjection = Fixture
$withoutInjection.networkSnapshot = @{
    schemaVersion = 1; capturedAt = [datetimeoffset]::UtcNow.ToString('o')
    service = @{ sku = @{ name = 'Developer'; capacity = 1 }; location = 'eastus'; properties = @{ virtualNetworkType = 'None' } }
    regions = @()
}
$networkReport = Invoke-ApimInsightsAssessment $withoutInjection
Check (@($networkReport.findings | Where-Object status -eq 'NotApplicable').Count -gt 0) 'Existing VNet not-applicable results are preserved'
Check ($networkReport.summary.notApplicable -eq @($networkReport.findings | Where-Object status -eq 'NotApplicable').Count) 'Skipped network counts reconcile with detailed results'
Check ((ConvertTo-ApimInsightsHtml $networkReport).Contains('data-status="NotApplicable"')) 'Skipped network checks render without a false pass'
$nativeFixture = Fixture
$now = [datetimeoffset]::UtcNow.ToString('o')
$nativeFixture.networkSnapshot = @{
    schemaVersion = 1; capturedAt = $now
    service = @{ sku = @{ name = 'Developer'; capacity = 1 }; location = 'eastus'; properties = @{ virtualNetworkType = 'Internal' } }
    regions = @(@{ location = 'eastus' })
    nativeNetworkStatus = @{ available = $true; locations = @(@{ location = 'eastus'; networkStatus = @{ connectivityStatus = @(
        @{ resourceType = 'ApplicationInsightsIngestionEndpoint'; status = 'failure'; isOptional = $true
            lastUpdated = $now; name = 'PRIVATE_DEPENDENCY_HOST'; error = 'PRIVATE_NATIVE_ERROR' }
    ) } }) }
}
$nativeReport = Invoke-ApimInsightsAssessment $nativeFixture
$nativeFinding = Finding $nativeReport 'vnet:native-dependency-1'
Check ($nativeFinding.title -eq 'Network / Application Insights ingestion' -and $nativeFinding.status -eq 'Unknown') 'Logging dependency is named without relabeling an optional feature failure as a core outage'
$nativeHtml = ConvertTo-ApimInsightsHtml $nativeReport
Check ($nativeHtml.Contains('ApplicationInsightsIngestionEndpoint') -and $nativeHtml.Contains('Last checked') -and $nativeHtml.Contains('reported failure')) 'Platform dependency status and freshness reach the HTML report'
Check (-not $nativeHtml.Contains('PRIVATE_NATIVE_ERROR') -and -not $nativeHtml.Contains('PRIVATE_DEPENDENCY_HOST')) 'Native hostnames and raw transport errors remain private'
$fixture.apiDiagnostic = $null
$fixture.serviceDiagnostic = (Fixture).apiDiagnostic
$fixture.collectionErrors.apiDiagnostic = 'NOT_FOUND'
$report = Invoke-ApimInsightsAssessment $fixture
Check ($report.diagnosticSource -eq 'Service inherited') 'Missing API diagnostic inherits'
$fixture.collectionErrors.apiDiagnostic = 'ACCESS_DENIED'
$report = Invoke-ApimInsightsAssessment $fixture
Check ((Finding $report 'effective-diagnostic').status -eq 'Unknown') 'Denied API diagnostic does not certify inheritance'
$fixture = Fixture
$fixture.apiDiagnostic = $null
$fixture.serviceDiagnostic = $null
$report = Invoke-ApimInsightsAssessment $fixture
Check ((Finding $report 'effective-diagnostic').status -eq 'Fail') 'Absent effective diagnostic is a constraint failure'
$fixture = Fixture
$fixture.apiAvailable = $false
$fixture.collectionErrors.api = 'NOT_FOUND'
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'effective-diagnostic').status -eq 'Unknown') 'Missing API is not missing diagnostic proof'
$fixture = Fixture
$fixture.apiDiagnostic.properties.sampling.percentage = 0
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'sampling').status -eq 'Fail') 'Zero sampling explains intended missing successful requests'
$fixture.apiDiagnostic.properties.sampling.percentage = 50
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'sampling').status -eq 'Unknown') 'Reduced sampling is not a universal fault'
$fixture = Fixture
$fixture.logger.properties.resourceId += '-other'
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'logger-destination').status -eq 'Fail') 'Explicit expected destination mismatch is distinguished'
$fixture.expectedComponentId = $null
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'logger-destination').status -eq 'Unknown') 'No expected target means no invented wrong-target finding'
$fixture = Fixture
$fixture.roles.value[0].properties.condition = 'conditional'
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'publisher-role').status -eq 'Unknown') 'Conditional role remains qualified'
$fixture.roles.value[0].properties.Remove('condition')
$fixture.roles.value[0].properties.scope += '/unrelated-child'
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'publisher-role').status -eq 'Unknown') 'Noncovering scope cannot certify publishing rights'
$fixture = Fixture
$fixture.component.properties.publicNetworkAccessForIngestion = 'Disabled'
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'ingestion-access-component').status -eq 'Unknown') 'Private ingestion is not automatically broken'
$fixture = Fixture
$fixture.requestEvidence.counts.Rows = 0
Check ((Invoke-ApimInsightsAssessment $fixture).delivery.state -eq 'EvidenceAbsent') 'Zero rows do not diagnose a network fault'
$fixture = Fixture
$fixture.requestEvidence.counts.KnownTraceRows = 0
Check ((Invoke-ApimInsightsAssessment $fixture).delivery.state -eq 'CountMismatch') 'Known trace mismatch is explicit'
$fixture = Fixture
$fixture.requestEvidence.counts.Rows = '20'
$thrown = $false
try { $null = Invoke-ApimInsightsAssessment $fixture } catch { $thrown = $_.Exception.Message -eq 'INVALID_QUERY_RESULT' }
Check $thrown 'Malformed aggregate types are rejected'
$fixture = Fixture
$fixture.requestEvidence = @{ state = 'Unavailable' }
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'request-evidence').status -eq 'Unknown') 'Query access failure is not sender failure'
$fixture.requestEvidence = @{ state = 'NotTested' }
Check ((Invoke-ApimInsightsAssessment $fixture).delivery.state -eq 'NotTested') 'No implicit query or traffic'
$fixture = Fixture
$fixture.service.sku.name = 'PremiumV2'
Check ((Finding (Invoke-ApimInsightsAssessment $fixture) 'gateway-model').status -eq 'Unknown') 'Uncertified gateway models are marked'

$fixture = Fixture
$sentinel = 'PRIVATE_SENTINEL_NEVER_PERSIST'
$fixture.logger.properties.credentials.connectionString = $sentinel
$fixture.component.properties.ConnectionString = $sentinel
$fixture.logger.properties.credentials.identityClientId = "{{${sentinel}}}"
$fixture.requestEvidence.counts.untrustedExtra = $sentinel
$report = Invoke-ApimInsightsAssessment $fixture
$json = $report | ConvertTo-Json -Depth 40
$html = ConvertTo-ApimInsightsHtml $report
Check (-not $json.Contains($sentinel) -and -not $html.Contains($sentinel)) 'Credentials/protected values never leave evaluation'
Check (-not $json.Contains('00000000-0000-0000-0000-000000000001') -and -not $html.Contains('/subscriptions/')) 'Private scope identifiers are omitted'
Check ($html.Contains('1. Problem definition') -and $html.Contains('2. Diagnosis') -and $html.Contains('3. Root cause analysis')) 'Three-section HTML contract'
Check ($html.Contains('OFFLINE') -and $html.Contains('status-dot') -and $html.Contains('data-status="Unknown"')) 'Offline provenance and per-row indicators'
Check ($html.Contains('--cp-bg: #f7f4ef') -and $html.Contains('scoutTheme')) 'Required shared light/dark theme'
$scriptText = [regex]::Match($html, '<script>(.*?)</script>', [Text.RegularExpressions.RegexOptions]::Singleline).Groups[1].Value
$browserText = $scriptText.Replace("`r`n", "`n").Replace("`r", "`n")
$scriptHash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($browserText)))
Check ($html.Contains("script-src 'sha256-$scriptHash'")) 'CSP hash matches browser-normalized script text'
$fixture.capturedAt = $sentinel
$thrown = $false
try { $null = Invoke-ApimInsightsAssessment $fixture } catch { $thrown = $_.Exception.Message -eq 'INVALID_SNAPSHOT' }
Check $thrown 'Timestamp fields cannot smuggle private/raw text into reports'
$report.findings[0].detail = '<script>alert("untrusted")</script>'
$report.findings[0].source = 'javascript:alert(1)'
$html = ConvertTo-ApimInsightsHtml $report
Check (-not $html.Contains('<script>alert') -and -not $html.Contains('href="javascript:')) 'Untrusted text is encoded and unsafe links rejected'

$subscription = '00000000-0000-0000-0000-000000000001'
$service = "/subscriptions/$subscription/resourceGroups/example/providers/Microsoft.ApiManagement/service/example"
$component = (Fixture).component.id
Check ((Get-InsightsReadUri "$service/apis/mock;rev=2/diagnostics/applicationinsights" $subscription @('example') $service).EndsWith('api-version=2024-05-01')) 'Exact revision ARM path supported'
foreach ($id in @("$service/namedValues/secret/listValue", "$service/loggers/secret/listKeys", $component.Replace($subscription, '00000000-0000-0000-0000-000000000002'))) {
    $thrown = $false
    try { $null = Get-InsightsReadUri $id $subscription @('example') $service } catch { $thrown = $true }
    Check $thrown 'Secret operations and cross-subscription paths are rejected'
}
$thrown = $false
try { $null = Get-InsightsReadUri ($component.Replace('/example/', '/different/')) $subscription @('example') $service } catch { $thrown = $true }
Check $thrown 'Related resource groups need explicit coverage'
$query = Get-InsightsRequestQuery $component ([datetimeoffset]'2026-01-01T00:00:00Z') ([datetimeoffset]'2026-01-01T01:00:00Z') '00000000-0000-0000-0000-000000000004' ('5' * 32)
Check ($query.Contains('_ResourceId =~') -and $query.Contains('KnownTraceRows') -and -not $query.Contains("`n")) 'Scoped aggregate uses CLI-safe query text'
$thrown = $false
try { $null = Get-InsightsRequestQuery $component ([datetimeoffset]'2026-01-01T00:00:00Z') ([datetimeoffset]'2026-01-03T00:00:00Z') '' '' } catch { $thrown = $true }
Check $thrown 'Query windows are bounded'

[pscustomobject]@{ status = 'Passed'; assertions = $script:assertions; azureCalls = 0 } | ConvertTo-Json
