using System;
using System.IO;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Linq;
using Microsoft.EntityFrameworkCore;

namespace Dayflow.Core.Storage
{
    /// <summary>
    /// Manages local storage for recordings and timeline data
    /// Equivalent to macOS StorageManager using GRDB
    /// </summary>
    public class StorageManager
    {
        private readonly string _appDataPath;
        private readonly string _timelapsesPath;
        private readonly string _recordingsPath;
        private readonly string _databasePath;
        private DayflowDbContext? _dbContext;

        public StorageManager()
        {
            // Windows equivalent of ~/Library/Application Support/Dayflow/
            _appDataPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Dayflow");

            _timelapsesPath = Path.Combine(_appDataPath, "timelapses");
            _recordingsPath = Path.Combine(_appDataPath, "recordings");
            _databasePath = Path.Combine(_appDataPath, "chunks.db");
        }

        public async Task InitializeAsync()
        {
            // Create directories
            Directory.CreateDirectory(_appDataPath);
            Directory.CreateDirectory(_timelapsesPath);
            Directory.CreateDirectory(_recordingsPath);

            // Initialize database
            var options = new DbContextOptionsBuilder<DayflowDbContext>()
                .UseSqlite($"Data Source={_databasePath}")
                .Options;

            _dbContext = new DayflowDbContext(options);
            await _dbContext.Database.MigrateAsync();
        }

        public string GetChunkPath(DateTime timestamp)
        {
            var dateFolder = timestamp.ToString("yyyy-MM-dd");
            var chunkFolder = Path.Combine(_recordingsPath, dateFolder);
            Directory.CreateDirectory(chunkFolder);

            var fileName = $"chunk_{timestamp:HHmmss}.mp4";
            return Path.Combine(chunkFolder, fileName);
        }

        public async Task SaveChunkMetadata(string filePath, DateTime startTime, int frameCount)
        {
            if (_dbContext == null)
                throw new InvalidOperationException("Storage not initialized");

            var chunk = new VideoChunk
            {
                Id = Guid.NewGuid(),
                FilePath = filePath,
                StartTime = startTime,
                EndTime = startTime.AddSeconds(15),
                FrameCount = frameCount,
                FileSize = new FileInfo(filePath).Length,
                CreatedAt = DateTime.UtcNow
            };

            _dbContext.VideoChunks.Add(chunk);
            await _dbContext.SaveChangesAsync();
        }

        public async Task<List<VideoChunk>> GetChunksForDateRange(DateTime start, DateTime end)
        {
            if (_dbContext == null)
                throw new InvalidOperationException("Storage not initialized");

            return await _dbContext.VideoChunks
                .Where(c => c.StartTime >= start && c.StartTime <= end)
                .OrderBy(c => c.StartTime)
                .ToListAsync();
        }

        public async Task CleanupOldRecordings(int retentionDays = 3)
        {
            if (_dbContext == null)
                throw new InvalidOperationException("Storage not initialized");

            var cutoffDate = DateTime.UtcNow.AddDays(-retentionDays);

            var oldChunks = await _dbContext.VideoChunks
                .Where(c => c.CreatedAt < cutoffDate)
                .ToListAsync();

            foreach (var chunk in oldChunks)
            {
                try
                {
                    if (File.Exists(chunk.FilePath))
                    {
                        File.Delete(chunk.FilePath);
                    }
                }
                catch (Exception ex)
                {
                    Sentry.SentrySdk.CaptureException(ex);
                }
            }

            _dbContext.VideoChunks.RemoveRange(oldChunks);
            await _dbContext.SaveChangesAsync();

            // Clean up empty date folders
            CleanupEmptyFolders(_recordingsPath);
        }

        public string GetTimelapseOutputPath(DateTime date)
        {
            var dateFolder = date.ToString("yyyy-MM-dd");
            var folder = Path.Combine(_timelapsesPath, dateFolder);
            Directory.CreateDirectory(folder);
            return Path.Combine(folder, "timelapse.mp4");
        }

        private void CleanupEmptyFolders(string path)
        {
            foreach (var directory in Directory.GetDirectories(path))
            {
                CleanupEmptyFolders(directory);
                if (!Directory.EnumerateFileSystemEntries(directory).Any())
                {
                    try
                    {
                        Directory.Delete(directory);
                    }
                    catch { }
                }
            }
        }

        public string RecordingsPath => _recordingsPath;
        public string TimelapsesPath => _timelapsesPath;
    }

    /// <summary>
    /// Entity Framework DbContext for Dayflow database
    /// </summary>
    public class DayflowDbContext : DbContext
    {
        public DbSet<VideoChunk> VideoChunks { get; set; } = null!;
        public DbSet<TimelineCard> TimelineCards { get; set; } = null!;
        public DbSet<AnalysisJob> AnalysisJobs { get; set; } = null!;

        public DayflowDbContext(DbContextOptions<DayflowDbContext> options) : base(options)
        {
        }

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            base.OnModelCreating(modelBuilder);

            modelBuilder.Entity<VideoChunk>(entity =>
            {
                entity.HasKey(e => e.Id);
                entity.HasIndex(e => e.StartTime);
                entity.HasIndex(e => e.CreatedAt);
            });

            modelBuilder.Entity<TimelineCard>(entity =>
            {
                entity.HasKey(e => e.Id);
                entity.HasIndex(e => e.StartTime);
                entity.HasIndex(e => e.Date);
            });

            modelBuilder.Entity<AnalysisJob>(entity =>
            {
                entity.HasKey(e => e.Id);
                entity.HasIndex(e => e.Status);
                entity.HasIndex(e => e.CreatedAt);
            });
        }
    }

    // Database models
    public class VideoChunk
    {
        public Guid Id { get; set; }
        public string FilePath { get; set; } = "";
        public DateTime StartTime { get; set; }
        public DateTime EndTime { get; set; }
        public int FrameCount { get; set; }
        public long FileSize { get; set; }
        public DateTime CreatedAt { get; set; }
    }

    public class TimelineCard
    {
        public Guid Id { get; set; }
        public DateTime Date { get; set; }
        public DateTime StartTime { get; set; }
        public DateTime EndTime { get; set; }
        public string Title { get; set; } = "";
        public string Summary { get; set; } = "";
        public string Category { get; set; } = "";
        public bool IsDistraction { get; set; }
        public string? ThumbnailPath { get; set; }
        public DateTime CreatedAt { get; set; }
    }

    public class AnalysisJob
    {
        public Guid Id { get; set; }
        public DateTime StartTime { get; set; }
        public DateTime EndTime { get; set; }
        public string Status { get; set; } = "pending"; // pending, processing, completed, failed
        public string? ErrorMessage { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime? CompletedAt { get; set; }
    }
}
