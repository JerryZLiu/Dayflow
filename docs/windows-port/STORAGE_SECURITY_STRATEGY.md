# Storage & Security Migration Strategy

**Component**: Data persistence, credential storage, configuration
**Priority**: P1 - HIGH (Required before screen recording)
**Complexity**: MEDIUM

---

## Current macOS Implementation

### 1. File Storage Locations

#### Application Support Directory
```swift
// StorageManager.swift
let fileManager = FileManager.default
let appSupportDir = fileManager.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
).first!

// Path: ~/Library/Application Support/com.teleportlabs.dayflow/
```

**Stored Files**:
- `chunks.sqlite` - Main database
- `chunks.sqlite-wal` - Write-ahead log
- `chunks.sqlite-shm` - Shared memory file
- `recordings/` - Video chunk files (*.mp4)

#### Database Schema (SQLite)
```swift
// Tables managed by GRDB
- chunks         // Individual 15-second recordings
- batches        // Groups of chunks for analysis
- timeline_cards // Generated timeline entries
- llm_metadata   // LLM request/response tracking
- categories     // User-defined categories
```

#### UserDefaults (Preferences)
```swift
// Stored in: ~/Library/Preferences/com.teleportlabs.dayflow.plist
UserDefaults.standard.set(value, forKey: "isRecording")
UserDefaults.standard.bool(forKey: "didOnboard")

// Keys used:
- isRecording
- didOnboard
- onboardingStep
- selectedLLMProvider
- llmLocalBaseURL
- idleResetMinutes
- analyticsOptIn
```

### 2. Keychain (Secure Storage)

```swift
// KeychainManager.swift
final class KeychainManager {
    func store(_ apiKey: String, for provider: String) -> Bool
    func retrieve(for provider: String) -> String?
    func delete(for provider: String) -> Bool
}

// Usage:
KeychainManager.shared.store(apiKey, for: "gemini")
let key = KeychainManager.shared.retrieve(for: "gemini")
```

**Stored Credentials**:
- `com.teleportlabs.dayflow.apikeys.gemini` → Gemini API key
- `com.teleportlabs.dayflow.apikeys.dayflow` → Dayflow backend key
- `analyticsDistinctId` → PostHog distinct ID

---

## Windows Implementation

### 1. File Storage Locations

#### Application Data Directory

**Windows Equivalent**:
```csharp
using Windows.Storage;

// Local app data (not roaming)
var localFolder = ApplicationData.Current.LocalFolder;
// Path: C:\Users\{Username}\AppData\Local\Packages\{PackageId}\LocalState\

// Or for non-packaged apps (traditional desktop):
var appDataPath = Environment.GetFolderPath(
    Environment.SpecialFolder.LocalApplicationData);
// Path: C:\Users\{Username}\AppData\Local\Dayflow\
```

**Recommended Path Structure**:
```
C:\Users\{Username}\AppData\Local\Dayflow\
├── Database\
│   ├── chunks.db
│   ├── chunks.db-wal
│   └── chunks.db-shm
├── Recordings\
│   ├── 2025-11-17\
│   │   ├── chunk_001.mp4
│   │   ├── chunk_002.mp4
│   │   └── ...
│   └── 2025-11-18\
└── Logs\
    └── dayflow.log
```

#### Implementation

```csharp
// StoragePathManager.cs
public static class StoragePathManager
{
    private static readonly string AppName = "Dayflow";

    public static string LocalAppDataPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppName);

    public static string DatabasePath =>
        Path.Combine(LocalAppDataPath, "Database", "chunks.db");

    public static string RecordingsPath =>
        Path.Combine(LocalAppDataPath, "Recordings");

    public static void EnsureDirectoriesExist()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);
        Directory.CreateDirectory(RecordingsPath);
    }

    public static string GetRecordingPath(DateTime date)
    {
        var dateFolder = Path.Combine(RecordingsPath, date.ToString("yyyy-MM-dd"));
        Directory.CreateDirectory(dateFolder);
        return dateFolder;
    }
}
```

---

### 2. SQLite Database Migration

#### From GRDB (Swift) to Microsoft.Data.Sqlite (C#)

**macOS (GRDB)**:
```swift
import GRDB

let dbQueue = try DatabaseQueue(path: dbPath)

try dbQueue.write { db in
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY,
            start_time REAL NOT NULL,
            end_time REAL NOT NULL,
            file_path TEXT NOT NULL,
            status TEXT NOT NULL
        )
    """)
}
```

**Windows (Microsoft.Data.Sqlite)**:
```csharp
using Microsoft.Data.Sqlite;

public class DatabaseManager
{
    private readonly string _connectionString;

    public DatabaseManager(string dbPath)
    {
        _connectionString = $"Data Source={dbPath}";
        InitializeDatabase();
    }

    private void InitializeDatabase()
    {
        using var connection = new SqliteConnection(_connectionString);
        connection.Open();

        var command = connection.CreateCommand();
        command.CommandText = @"
            CREATE TABLE IF NOT EXISTS chunks (
                id TEXT PRIMARY KEY,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                file_path TEXT NOT NULL,
                status TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_chunks_start_time
            ON chunks(start_time);
        ";
        command.ExecuteNonQuery();
    }

    public async Task<string> InsertChunkAsync(Chunk chunk)
    {
        using var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync();

        var command = connection.CreateCommand();
        command.CommandText = @"
            INSERT INTO chunks (id, start_time, end_time, file_path, status)
            VALUES ($id, $start, $end, $path, $status)
        ";
        command.Parameters.AddWithValue("$id", chunk.Id);
        command.Parameters.AddWithValue("$start", chunk.StartTime.ToUnixTimeSeconds());
        command.Parameters.AddWithValue("$end", chunk.EndTime.ToUnixTimeSeconds());
        command.Parameters.AddWithValue("$path", chunk.FilePath);
        command.Parameters.AddWithValue("$status", chunk.Status);

        await command.ExecuteNonQueryAsync();
        return chunk.Id;
    }
}
```

#### Alternative: Entity Framework Core

**Advantages**:
- Higher-level ORM (less boilerplate)
- LINQ queries instead of raw SQL
- Automatic migrations

**Disadvantages**:
- Larger dependency
- Slightly slower than raw SQLite

**Example**:
```csharp
using Microsoft.EntityFrameworkCore;

public class DayflowDbContext : DbContext
{
    public DbSet<Chunk> Chunks { get; set; }
    public DbSet<Batch> Batches { get; set; }
    public DbSet<TimelineCard> TimelineCards { get; set; }

    protected override void OnConfiguring(DbContextOptionsBuilder options)
    {
        options.UseSqlite($"Data Source={StoragePathManager.DatabasePath}");
    }
}

// Usage:
using var db = new DayflowDbContext();
db.Chunks.Add(new Chunk { ... });
await db.SaveChangesAsync();

var recentCards = await db.TimelineCards
    .Where(c => c.StartTime > DateTime.Today)
    .OrderByDescending(c => c.StartTime)
    .ToListAsync();
```

**Recommendation**: Use **Microsoft.Data.Sqlite** initially for simplicity, migrate to EF Core later if needed.

---

### 3. Configuration Storage (UserDefaults → Windows)

#### macOS (UserDefaults)
```swift
UserDefaults.standard.set(true, forKey: "isRecording")
let value = UserDefaults.standard.bool(forKey: "didOnboard")
```

#### Windows (ApplicationDataContainer)

**For Packaged Apps (MSIX)**:
```csharp
using Windows.Storage;

public class SettingsManager
{
    private readonly ApplicationDataContainer _settings =
        ApplicationData.Current.LocalSettings;

    public bool IsRecording
    {
        get => _settings.Values["IsRecording"] as bool? ?? false;
        set => _settings.Values["IsRecording"] = value;
    }

    public bool DidOnboard
    {
        get => _settings.Values["DidOnboard"] as bool? ?? false;
        set => _settings.Values["DidOnboard"] = value;
    }

    public string SelectedLLMProvider
    {
        get => _settings.Values["SelectedLLMProvider"] as string ?? "gemini";
        set => _settings.Values["SelectedLLMProvider"] = value;
    }
}
```

**For Non-Packaged Apps (Traditional)**:
```csharp
using System.Configuration;
using System.Text.Json;

public class SettingsManager
{
    private readonly string _settingsPath;
    private Dictionary<string, object> _settings;

    public SettingsManager()
    {
        _settingsPath = Path.Combine(
            StoragePathManager.LocalAppDataPath,
            "settings.json");
        LoadSettings();
    }

    private void LoadSettings()
    {
        if (File.Exists(_settingsPath))
        {
            var json = File.ReadAllText(_settingsPath);
            _settings = JsonSerializer.Deserialize<Dictionary<string, object>>(json)
                ?? new Dictionary<string, object>();
        }
        else
        {
            _settings = new Dictionary<string, object>();
        }
    }

    private void SaveSettings()
    {
        var json = JsonSerializer.Serialize(_settings, new JsonSerializerOptions
        {
            WriteIndented = true
        });
        File.WriteAllText(_settingsPath, json);
    }

    public T Get<T>(string key, T defaultValue = default)
    {
        if (_settings.TryGetValue(key, out var value))
        {
            return (T)Convert.ChangeType(value, typeof(T));
        }
        return defaultValue;
    }

    public void Set<T>(string key, T value)
    {
        _settings[key] = value;
        SaveSettings();
    }
}
```

**Recommendation**: Use `ApplicationDataContainer` if using MSIX packaging, otherwise use JSON file approach.

---

### 4. Keychain → Windows Credential Manager

#### macOS (Keychain)
```swift
KeychainManager.shared.store(apiKey, for: "gemini")
let key = KeychainManager.shared.retrieve(for: "gemini")
```

#### Windows (Credential Manager via P/Invoke)

```csharp
using System.Runtime.InteropServices;
using System.Text;

public class CredentialManager
{
    private const string TargetPrefix = "Dayflow_";

    public static bool Store(string key, string secret)
    {
        var credential = new NativeMethods.CREDENTIAL
        {
            Type = NativeMethods.CRED_TYPE_GENERIC,
            TargetName = TargetPrefix + key,
            CredentialBlob = Encoding.UTF8.GetBytes(secret),
            CredentialBlobSize = (uint)Encoding.UTF8.GetByteCount(secret),
            Persist = NativeMethods.CRED_PERSIST_LOCAL_MACHINE,
            UserName = Environment.UserName
        };

        return NativeMethods.CredWrite(ref credential, 0);
    }

    public static string Retrieve(string key)
    {
        if (NativeMethods.CredRead(TargetPrefix + key,
                                   NativeMethods.CRED_TYPE_GENERIC,
                                   0,
                                   out var credPtr))
        {
            var credential = Marshal.PtrToStructure<NativeMethods.CREDENTIAL>(credPtr);
            var secret = Encoding.UTF8.GetString(
                credential.CredentialBlob,
                (int)credential.CredentialBlobSize);

            NativeMethods.CredFree(credPtr);
            return secret;
        }

        return null;
    }

    public static bool Delete(string key)
    {
        return NativeMethods.CredDelete(TargetPrefix + key,
                                        NativeMethods.CRED_TYPE_GENERIC,
                                        0);
    }

    private static class NativeMethods
    {
        public const int CRED_TYPE_GENERIC = 1;
        public const int CRED_PERSIST_LOCAL_MACHINE = 2;

        [StructLayout(LayoutKind.Sequential)]
        public struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            [MarshalAs(UnmanagedType.LPWStr)]
            public string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)]
            public string Comment;
            public long LastWritten;
            public uint CredentialBlobSize;
            public byte[] CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)]
            public string TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)]
            public string UserName;
        }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CredRead(string target, int type, int flags,
                                           out IntPtr credential);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern void CredFree(IntPtr credential);
    }
}
```

**Usage**:
```csharp
// Store
CredentialManager.Store("gemini_api_key", "your-api-key-here");

// Retrieve
var apiKey = CredentialManager.Retrieve("gemini_api_key");

// Delete
CredentialManager.Delete("gemini_api_key");
```

**Alternative**: Use `Windows.Security.Credentials.PasswordVault` (WinRT API)

```csharp
using Windows.Security.Credentials;

public class SecureStorage
{
    private const string ResourcePrefix = "Dayflow_";
    private readonly PasswordVault _vault = new PasswordVault();

    public void Store(string key, string secret)
    {
        var credential = new PasswordCredential(
            ResourcePrefix + key,
            Environment.UserName,
            secret);

        _vault.Add(credential);
    }

    public string Retrieve(string key)
    {
        try
        {
            var credential = _vault.Retrieve(ResourcePrefix + key, Environment.UserName);
            credential.RetrievePassword();
            return credential.Password;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public void Delete(string key)
    {
        try
        {
            var credential = _vault.Retrieve(ResourcePrefix + key, Environment.UserName);
            _vault.Remove(credential);
        }
        catch { }
    }
}
```

**Recommendation**: Use **PasswordVault** (WinRT) if targeting Windows 10+, otherwise use Win32 Credential Manager.

---

## Data Migration & Compatibility

### Challenge: Moving User Data from macOS to Windows

**Scenario**: User wants to transfer timeline data from Mac to Windows.

**Solution**: Export/Import Functionality

```csharp
public class DataExporter
{
    public async Task<string> ExportToJsonAsync(DateTime startDate, DateTime endDate)
    {
        using var db = new DayflowDbContext();

        var cards = await db.TimelineCards
            .Where(c => c.StartTime >= startDate && c.StartTime <= endDate)
            .ToListAsync();

        var export = new
        {
            Version = "1.0",
            ExportDate = DateTime.UtcNow,
            TimelineCards = cards
        };

        return JsonSerializer.Serialize(export, new JsonSerializerOptions
        {
            WriteIndented = true
        });
    }

    public async Task ImportFromJsonAsync(string json)
    {
        var data = JsonSerializer.Deserialize<ExportData>(json);

        using var db = new DayflowDbContext();
        db.TimelineCards.AddRange(data.TimelineCards);
        await db.SaveChangesAsync();
    }
}
```

---

## Storage Cleanup (Auto-delete Old Recordings)

### macOS Implementation
```swift
// StorageManager.swift
func cleanupOldRecordings() {
    let cutoffDate = Date().addingTimeInterval(-3 * 24 * 60 * 60) // 3 days ago

    try dbQueue.write { db in
        let oldChunks = try Chunk
            .filter(Column("start_time") < cutoffDate.timeIntervalSince1970)
            .fetchAll(db)

        for chunk in oldChunks {
            try? FileManager.default.removeItem(atPath: chunk.filePath)
            try chunk.delete(db)
        }
    }
}
```

### Windows Implementation
```csharp
public class StorageCleanupService
{
    private readonly DatabaseManager _db;
    private readonly int _retentionDays = 3;

    public async Task CleanupOldRecordingsAsync()
    {
        var cutoffDate = DateTime.UtcNow.AddDays(-_retentionDays);

        using var connection = new SqliteConnection(_db.ConnectionString);
        await connection.OpenAsync();

        // Get old chunks
        var command = connection.CreateCommand();
        command.CommandText = @"
            SELECT id, file_path
            FROM chunks
            WHERE start_time < $cutoff
        ";
        command.Parameters.AddWithValue("$cutoff", cutoffDate.ToUnixTimeSeconds());

        var oldChunks = new List<(string id, string path)>();
        using (var reader = await command.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                oldChunks.Add((reader.GetString(0), reader.GetString(1)));
            }
        }

        // Delete files and database records
        foreach (var (id, path) in oldChunks)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch (Exception ex)
            {
                // Log error but continue
                Console.WriteLine($"Failed to delete {path}: {ex.Message}");
            }
        }

        // Delete from database
        var deleteCommand = connection.CreateCommand();
        deleteCommand.CommandText = "DELETE FROM chunks WHERE start_time < $cutoff";
        deleteCommand.Parameters.AddWithValue("$cutoff", cutoffDate.ToUnixTimeSeconds());
        await deleteCommand.ExecuteNonQueryAsync();
    }

    public async Task<long> GetStorageUsedAsync()
    {
        var recordingsPath = StoragePathManager.RecordingsPath;
        if (!Directory.Exists(recordingsPath))
            return 0;

        var files = Directory.GetFiles(recordingsPath, "*.mp4", SearchOption.AllDirectories);
        return files.Sum(f => new FileInfo(f).Length);
    }
}
```

**Scheduled Cleanup**:
```csharp
// Run cleanup daily at 3 AM
using var timer = new PeriodicTimer(TimeSpan.FromHours(24));
while (await timer.WaitForNextTickAsync())
{
    if (DateTime.Now.Hour == 3)
    {
        await cleanupService.CleanupOldRecordingsAsync();
    }
}
```

---

## Migration Checklist

### File Storage
- [ ] Create application data directory structure
- [ ] Implement StoragePathManager utility
- [ ] Handle directory creation on first launch
- [ ] Implement file path generation for video chunks
- [ ] Add logging for file operations

### Database
- [ ] Port SQLite schema from macOS
- [ ] Implement DatabaseManager with connection pooling
- [ ] Create data models (Chunk, Batch, TimelineCard, etc.)
- [ ] Implement CRUD operations
- [ ] Add database migration support (future schema changes)
- [ ] Enable WAL mode for concurrent access

### Configuration
- [ ] Implement SettingsManager (ApplicationDataContainer or JSON)
- [ ] Migrate all UserDefaults keys
- [ ] Add default values for first launch
- [ ] Implement settings export/import

### Secure Storage
- [ ] Implement CredentialManager wrapper
- [ ] Migrate Keychain keys to Windows Credential Manager
- [ ] Test API key storage/retrieval
- [ ] Add encryption for sensitive data in database (optional)

### Storage Cleanup
- [ ] Implement StorageCleanupService
- [ ] Schedule daily cleanup task
- [ ] Add user-configurable retention period
- [ ] Display storage usage in settings

### Testing
- [ ] Test database operations under load
- [ ] Test concurrent access (recording + analysis)
- [ ] Test storage cleanup edge cases
- [ ] Test credential storage/retrieval
- [ ] Test migration from empty state (first launch)

---

## Performance Considerations

### Database Optimization

1. **Enable WAL Mode** (Write-Ahead Logging)
   ```csharp
   using var connection = new SqliteConnection(_connectionString);
   connection.Open();
   var command = connection.CreateCommand();
   command.CommandText = "PRAGMA journal_mode=WAL;";
   command.ExecuteNonQuery();
   ```

2. **Use Indexes**
   ```sql
   CREATE INDEX idx_chunks_start_time ON chunks(start_time);
   CREATE INDEX idx_timeline_cards_date ON timeline_cards(start_time);
   ```

3. **Batch Writes**
   ```csharp
   using var transaction = connection.BeginTransaction();
   foreach (var chunk in chunks)
   {
       // Insert chunk
   }
   transaction.Commit();
   ```

### File I/O Optimization

1. **Async Operations**
   ```csharp
   await File.WriteAllBytesAsync(path, data);
   ```

2. **Buffered Streams**
   ```csharp
   using var fileStream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
   await fileStream.WriteAsync(data);
   ```

---

## Security Best Practices

1. **API Key Storage**
   - ✅ Store in Credential Manager (encrypted by OS)
   - ❌ Never store in plaintext files
   - ❌ Never store in database

2. **Database Encryption** (Optional)
   - Use SQLCipher for encrypted database
   - NuGet: `SQLitePCLRaw.bundle_sqlcipher`

3. **File Permissions**
   - Ensure recordings are only readable by current user
   - Set ACLs on sensitive directories

---

## Timeline Estimate

| Task | Estimated Duration |
|------|-------------------|
| File storage setup | 1 day |
| Database migration | 2-3 days |
| Configuration management | 1 day |
| Credential Manager integration | 2 days |
| Storage cleanup service | 1 day |
| Testing & optimization | 2 days |
| **TOTAL** | **1-2 weeks** |

---

## References

- [SQLite Documentation](https://www.sqlite.org/docs.html)
- [Microsoft.Data.Sqlite Docs](https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/)
- [Windows Credential Manager API](https://learn.microsoft.com/en-us/windows/win32/api/wincred/)
- [ApplicationData Class (UWP)](https://learn.microsoft.com/en-us/uwp/api/windows.storage.applicationdata)
- [PasswordVault Class](https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.passwordvault)

---

**Created**: 2025-11-17
**Last Updated**: 2025-11-17
