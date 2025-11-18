using System;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Collections.Generic;

namespace Dayflow.Core.AI
{
    /// <summary>
    /// Gemini AI provider for timeline analysis
    /// Uses Google Gemini API with video understanding
    /// </summary>
    public class GeminiProvider
    {
        private readonly HttpClient _httpClient;
        private readonly string? _apiKey;
        private const string API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta";

        public GeminiProvider(CredentialManager credentialManager)
        {
            _httpClient = new HttpClient();
            _apiKey = credentialManager.GetApiKey("Gemini");
        }

        public async Task<TimelineAnalysisResult> AnalyzeVideo(string videoPath, DateTime startTime, DateTime endTime)
        {
            if (string.IsNullOrEmpty(_apiKey))
            {
                throw new InvalidOperationException("Gemini API key not configured");
            }

            try
            {
                // Step 1: Upload video
                var videoUri = await UploadVideo(videoPath);

                // Step 2: Transcribe and analyze
                var analysis = await TranscribeAndAnalyze(videoUri, startTime, endTime);

                return analysis;
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
                throw;
            }
        }

        private async Task<string> UploadVideo(string videoPath)
        {
            // Upload video to Gemini Files API
            var fileBytes = await System.IO.File.ReadAllBytesAsync(videoPath);

            var content = new MultipartFormDataContent
            {
                { new ByteArrayContent(fileBytes), "file", System.IO.Path.GetFileName(videoPath) }
            };

            var response = await _httpClient.PostAsync(
                $"{API_BASE_URL}/files?key={_apiKey}",
                content);

            response.EnsureSuccessStatusCode();

            var result = await response.Content.ReadAsStringAsync();
            var json = JsonDocument.Parse(result);
            return json.RootElement.GetProperty("file").GetProperty("uri").GetString()!;
        }

        private async Task<TimelineAnalysisResult> TranscribeAndAnalyze(string videoUri, DateTime startTime, DateTime endTime)
        {
            var prompt = @"Analyze this screen recording video and create a concise timeline entry.

Provide:
1. A brief, descriptive title (5-10 words)
2. A concise summary of the main activity (1-2 sentences)
3. Category (e.g., Coding, Meeting, Email, Research, Social Media, etc.)
4. Whether this appears to be a distraction (true/false)

Format your response as JSON:
{
  ""title"": ""...\",
  ""summary"": ""...\",
  ""category"": ""...\",
  ""isDistraction"": true/false
}";

            var requestBody = new
            {
                contents = new[]
                {
                    new
                    {
                        role = "user",
                        parts = new object[]
                        {
                            new { text = prompt },
                            new { fileData = new { fileUri = videoUri, mimeType = "video/mp4" } }
                        }
                    }
                }
            };

            var json = JsonSerializer.Serialize(requestBody);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync(
                $"{API_BASE_URL}/models/gemini-1.5-flash:generateContent?key={_apiKey}",
                content);

            response.EnsureSuccessStatusCode();

            var resultJson = await response.Content.ReadAsStringAsync();
            var doc = JsonDocument.Parse(resultJson);

            var text = doc.RootElement
                .GetProperty("candidates")[0]
                .GetProperty("content")
                .GetProperty("parts")[0]
                .GetProperty("text")
                .GetString()!;

            // Parse the JSON response from the model
            var analysisJson = text.Trim('`').Replace("json\n", "").Trim();
            var analysis = JsonSerializer.Deserialize<TimelineAnalysisResult>(analysisJson);

            if (analysis != null)
            {
                analysis.StartTime = startTime;
                analysis.EndTime = endTime;
            }

            return analysis ?? new TimelineAnalysisResult();
        }
    }

    public class TimelineAnalysisResult
    {
        public string Title { get; set; } = "";
        public string Summary { get; set; } = "";
        public string Category { get; set; } = "";
        public bool IsDistraction { get; set; }
        public DateTime StartTime { get; set; }
        public DateTime EndTime { get; set; }
    }
}
