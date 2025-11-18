# GitHub Actions Workflows

This document describes all GitHub Actions workflows configured for the Dayflow Windows project.

## Workflows Overview

### 1. Build and Test (`build.yml`)

**Triggers:**
- Push to `main`, `develop`, or `claude/**` branches
- Pull requests to `main` or `develop`

**Purpose:**
- Builds the application for all platforms (x64, ARM64)
- Runs unit tests
- Collects code coverage
- Creates build artifacts

**Matrix:**
- Configuration: Debug, Release
- Platform: x64, ARM64

**Artifacts:**
- Build outputs for each platform (retention: 7 days)
- Code coverage reports (uploaded to Codecov)

---

### 2. Release (`release.yml`)

**Triggers:**
- Git tags matching `v*.*.*` (e.g., `v1.0.0`)
- Manual workflow dispatch with version input

**Purpose:**
- Creates official releases
- Builds installers for x64 and ARM64
- Generates Squirrel.Windows update packages
- Creates GitHub releases with installers and checksums

**Outputs:**
- `DayflowSetup-{version}-x64.exe` - x64 installer
- `DayflowSetup-{version}-arm64.exe` - ARM64 installer
- `checksums.txt` - SHA256 checksums
- Squirrel.Windows RELEASES and .nupkg files
- Automated release notes

**To create a release:**
```bash
# Via git tag
git tag v1.0.0
git push origin v1.0.0

# Via GitHub UI
# Go to Actions → Release → Run workflow
# Enter version (e.g., 1.0.0)
```

---

### 3. PR Validation (`pr-validation.yml`)

**Triggers:**
- Pull request opened, synchronized, or reopened

**Purpose:**
- Validates code formatting
- Runs full test suite
- Performs code analysis
- Checks for security vulnerabilities
- Validates project configuration
- Comments on PR with build status

**Checks:**
- ✅ Code formatting (dotnet format)
- ✅ Build success
- ✅ Unit tests with coverage
- ✅ Security vulnerability scan
- ✅ Installer configuration
- ✅ Project version validation
- ✅ PR size warning (>5000 lines)
- ✅ Dependency review

---

### 4. Code Quality (`code-quality.yml`)

**Triggers:**
- Push to `main` or `develop`
- Pull requests to `main` or `develop`
- Weekly schedule (Mondays at 9 AM UTC)

**Purpose:**
- CodeQL security analysis
- SonarCloud code quality scanning
- Security vulnerability detection
- SARIF report generation

**Analysis:**
- CodeQL security and quality queries
- SonarCloud comprehensive analysis (if token configured)
- Package vulnerability scanning

---

### 5. Nightly Build (`nightly.yml`)

**Triggers:**
- Daily at 2 AM UTC
- Manual workflow dispatch

**Purpose:**
- Creates unstable nightly builds from `develop` branch
- Provides early access to latest features
- Helps identify issues before releases

**Outputs:**
- `Dayflow-nightly-x64.zip`
- `Dayflow-nightly-arm64.zip`
- Pre-release GitHub release
- Artifacts retained for 30 days

**Version format:** `0.0.0-nightly.YYYYMMDD.{commit}`

---

## Workflow Configuration

### Required Secrets

| Secret | Required For | Description |
|--------|-------------|-------------|
| `GITHUB_TOKEN` | All workflows | Auto-provided by GitHub Actions |
| `SONAR_TOKEN` | Code Quality | SonarCloud authentication (optional) |
| `CODECOV_TOKEN` | Build | Codecov upload (optional) |

### Optional Variables

| Variable | Used In | Description |
|----------|---------|-------------|
| `RELEASE_SERVER_URL` | Release | Custom release server URL |

---

## Build Artifacts

### Release Artifacts
- **Installers**: Full NSIS installers with .NET runtime
- **Squirrel Packages**: Delta update packages for auto-updater
- **Checksums**: SHA256 verification files

### Nightly Artifacts
- **Portable zips**: No installer, extract and run
- **Pre-release**: Marked as unstable

### Build Artifacts (PR/Push)
- **Published binaries**: Self-contained executables
- **Coverage reports**: For analysis tools

---

## Workflow Status Badges

Add these to your README.md:

```markdown
[![Build](https://github.com/YOUR_ORG/Dayflow/actions/workflows/build.yml/badge.svg)](https://github.com/YOUR_ORG/Dayflow/actions/workflows/build.yml)
[![Release](https://github.com/YOUR_ORG/Dayflow/actions/workflows/release.yml/badge.svg)](https://github.com/YOUR_ORG/Dayflow/actions/workflows/release.yml)
[![Code Quality](https://github.com/YOUR_ORG/Dayflow/actions/workflows/code-quality.yml/badge.svg)](https://github.com/YOUR_ORG/Dayflow/actions/workflows/code-quality.yml)
```

---

## Deployment Strategy

### Development Flow
1. Work on feature branches
2. Create PR → triggers **PR Validation**
3. Merge to `develop` → triggers **Build**, **Code Quality**
4. Nightly builds created automatically

### Release Flow
1. Merge `develop` to `main`
2. Create git tag `vX.Y.Z` → triggers **Release**
3. GitHub release created automatically
4. Squirrel packages enable auto-updates

---

## Troubleshooting

### Build failures
- Check .NET SDK version (requires 8.0.x)
- Verify all NuGet packages restore correctly
- Review build logs for specific errors

### Release failures
- Ensure NSIS is installed in workflow
- Check installer script syntax
- Verify version format (semantic versioning)

### Code quality failures
- Review CodeQL alerts
- Check SonarCloud dashboard
- Update dependencies to fix vulnerabilities

### Nightly build issues
- Ensure `develop` branch is not broken
- Check artifact upload limits
- Verify retention policy settings

---

## Local Testing

### Test build workflow locally
```powershell
# Build for x64
dotnet publish DayflowWindows/Dayflow.csproj -c Release -r win-x64 --self-contained

# Build for ARM64
dotnet publish DayflowWindows/Dayflow.csproj -c Release -r win-arm64 --self-contained
```

### Test installer creation
```powershell
# Install NSIS
choco install nsis -y

# Copy files to expected location
Copy-Item publish/win-x64 publish/current -Recurse

# Create installer
makensis /DVERSION=1.0.0 installer.nsi
```

### Run tests with coverage
```powershell
dotnet test Dayflow.sln --collect:"XPlat Code Coverage"
```

---

## Best Practices

1. **Always create PRs** - Don't push directly to `main` or `develop`
2. **Wait for CI** - Ensure all checks pass before merging
3. **Fix warnings** - Treat warnings as errors in CI
4. **Update changelog** - Document changes for releases
5. **Test locally** - Run builds and tests before pushing
6. **Security first** - Fix vulnerabilities immediately
7. **Semantic versioning** - Follow `MAJOR.MINOR.PATCH` format

---

## Maintenance

### Update .NET version
1. Update `dotnet-version` in all workflow files
2. Update `TargetFramework` in .csproj
3. Test locally before committing

### Add new checks
1. Create new workflow file in `.github/workflows/`
2. Test with workflow dispatch first
3. Add status badge to README
4. Document in this file

### Modify release process
1. Update `release.yml`
2. Test with workflow dispatch
3. Create pre-release to verify
4. Update documentation
