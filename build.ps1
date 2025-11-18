# Dayflow Windows Build Script
param(
    [Parameter(Mandatory=$false)]
    [string]$Configuration = "Release"
)

Write-Host "Building Dayflow for Windows..." -ForegroundColor Cyan

# Restore NuGet packages
Write-Host "Restoring NuGet packages..." -ForegroundColor Yellow
dotnet restore Dayflow.sln

# Build the solution
Write-Host "Building solution..." -ForegroundColor Yellow
dotnet build Dayflow.sln -c $Configuration

# Publish for Windows x64
Write-Host "Publishing for Windows x64..." -ForegroundColor Yellow
dotnet publish DayflowWindows/Dayflow.csproj -c $Configuration -r win-x64 --self-contained true -o publish/win-x64

# Publish for Windows ARM64
Write-Host "Publishing for Windows ARM64..." -ForegroundColor Yellow
dotnet publish DayflowWindows/Dayflow.csproj -c $Configuration -r win-arm64 --self-contained true -o publish/win-arm64

Write-Host "Build completed successfully!" -ForegroundColor Green
Write-Host "Output directories:" -ForegroundColor Cyan
Write-Host "  - publish/win-x64" -ForegroundColor White
Write-Host "  - publish/win-arm64" -ForegroundColor White
