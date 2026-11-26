ARG NODE_IMAGE=node:26.13.0-bookworm-slim
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0.403
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:10.0.14-noble-chiseled

FROM ${NODE_IMAGE} AS browser
WORKDIR /source/src/harbor-support-web
COPY src/harbor-support-web/package.json src/harbor-support-web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY src/harbor-support-web/ ./
RUN npm run build

FROM ${SDK_IMAGE} AS api
WORKDIR /source
COPY NuGet.config Directory.Build.props global.json ./
COPY src/Harbor.Support.Api/Harbor.Support.Api.csproj src/Harbor.Support.Api/packages.lock.json src/Harbor.Support.Api/
RUN dotnet restore src/Harbor.Support.Api/Harbor.Support.Api.csproj --configfile NuGet.config --locked-mode
COPY data/ data/
COPY src/Harbor.Support.Api/ src/Harbor.Support.Api/
RUN dotnet publish src/Harbor.Support.Api/Harbor.Support.Api.csproj --no-restore --configuration Release --output /app --no-self-contained -p:UseAppHost=false
COPY --from=browser /source/src/harbor-support-web/dist/ /app/wwwroot/

FROM ${RUNTIME_IMAGE} AS runtime
WORKDIR /app
COPY --from=api --chown=app:app /app/ ./
ENV ASPNETCORE_URLS=http://+:8080
USER app
EXPOSE 8080
ENTRYPOINT ["dotnet", "Harbor.Support.Api.dll"]
