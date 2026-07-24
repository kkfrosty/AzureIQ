# Waypoint Freight Case Study

Waypoint Freight is AzureIQ's local proving application: a .NET shipment API plus a dependency-free browser client. The client calls the API directly during local development and will later use the same contract through API Management.

## Projects

| Path | Purpose |
| --- | --- |
| `backend/WaypointFreight.Api` | Shipment API, health endpoints, correlation, and development-only fault simulation |
| `backend/WaypointFreight.Api.Tests` | API integration tests |
| `client/WaypointFreight.Client` | Static shipment operations client hosted by ASP.NET Core |

## Run Locally

Start the API:

```powershell
dotnet run --project ./backend/WaypointFreight.Api
```

Start the client in a second terminal:

```powershell
dotnet run --project ./client/WaypointFreight.Client
```

Open `http://localhost:5265`. The API defaults to `http://localhost:5083`.

The checked-in browser client currently targets the deployed APIM gateway at `https://apim-wf-nter65xq.azure-api.net/waypoint`. Enter the APIM subscription key at runtime; it is never stored in source.

## Validate

```powershell
dotnet build ./backend/WaypointFreight.Api.Tests/WaypointFreight.Api.Tests.csproj --configuration Release --no-restore
dotnet build ./client/WaypointFreight.Client/WaypointFreight.Client.csproj --configuration Release --no-restore
dotnet test ./backend/WaypointFreight.Api.Tests/WaypointFreight.Api.Tests.csproj --configuration Release --no-build --no-restore
dotnet list ./backend/WaypointFreight.Api/WaypointFreight.Api.csproj package --vulnerable --include-transitive --no-restore
```

Focused project commands are preferred on the current Windows machine because `.sln` evaluation is substantially slower despite the individual projects completing quickly.

Fault simulation is active only when the API runs in the `Development` environment. The Azure deployment will disable backend fault headers by default and introduce approved APIM scenarios separately.