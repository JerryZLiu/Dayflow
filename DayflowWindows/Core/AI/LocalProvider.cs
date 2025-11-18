using System;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Linq;

namespace Dayflow.Core.AI
{
    /// <summary>
    /// Local AI provider (Ollama/LM Studio) for timeline analysis
    /// Processes frames individually for models without native video understanding
    /// </summary>
    public class LocalProvider
    {
        private readonly HttpClient _httpClient;
        private readonly string _endpoint;
        private readonly string _model;

        public LocalProvider(string endpoint = "http://localhost:11434", string model = "llava")
        {
            _httpClient = new HttpClient();
            _endpoint = endpoint;
            _model = model;
        }

        public async Task<TimelineAnalysisResult> AnalyzeVideo(string videoPath, DateTime startTime, DateTime endTime)
        {
            try
            {
                // Step 1: Extract 30 frames from video
                var frames = await ExtractFrames(videoPath, 30);

                // Step 2: Describe each frame (30 LLM calls)
                var descriptions = new List<string>();
                foreach (var frame in frames)
                {
                    var description = await DescribeFrame(frame);
                    descriptions.Add(description);
                }

                // Step 3: Merge descriptions (1 LLM call)
                var mergedDescription = await MergeDescriptions(descriptions);

                // Step 4: Generate title (1 LLM call)
                var title = await GenerateTitle(mergedDescription);

                // Step 5: Check if merge needed (1 LLM call)
                // This would be for merging with previous cards

                // Step 6: Categorize and detect distractions
                var category = await CategorizeActivity(mergedDescription);
                var isDistraction = await DetectDistraction(mergedDescription, category);

                return new TimelineAnalysisResult
                {
                    Title = title,
                    Summary = mergedDescription,
                    Category = category,
                    IsDistraction = isDistraction,
                    StartTime = startTime,
                    EndTime = endTime
                };
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
                throw;
            }
        }

        private async Task<List<string>> ExtractFrames(string videoPath, int frameCount)
        {
            // Use FFmpeg or similar to extract frames
            // For now, return placeholder
            return Enumerable.Range(0, frameCount)
                .Select(i => $"frame_{i}.jpg")
                .ToList();
        }

        private async Task<string> DescribeFrame(string framePath)
        {
            var prompt = "Describe what's happening in this screenshot in one concise sentence.";

            var requestBody = new
            {
                model = _model,
                prompt = prompt,
                images = new[] { Convert.ToBase64String(await System.IO.File.ReadAllBytesAsync(framePath)) }
            };

            var response = await CallOllama(requestBody);
            return response;
        }

        private async Task<string> MergeDescriptions(List<string> descriptions)
        {
            var prompt = $@"Merge these frame descriptions into a cohesive 1-2 sentence summary of the activity:

{string.Join("\n", descriptions.Select((d, i) => $"{i + 1}. {d}"))}

Provide just the summary, no preamble.";

            var requestBody = new
            {
                model = _model,
                prompt = prompt
            };

            return await CallOllama(requestBody);
        }

        private async Task<string> GenerateTitle(string description)
        {
            var prompt = $@"Create a brief, descriptive title (5-10 words) for this activity:

{description}

Provide just the title, no quotes or preamble.";

            var requestBody = new
            {
                model = _model,
                prompt = prompt
            };

            return await CallOllama(requestBody);
        }

        private async Task<string> CategorizeActivity(string description)
        {
            var prompt = $@"Categorize this activity with ONE of these categories:
Coding, Meeting, Email, Research, Documentation, Social Media, Entertainment, Productivity, Communication, Design, Other

Activity: {description}

Provide just the category name, nothing else.";

            var requestBody = new
            {
                model = _model,
                prompt = prompt
            };

            return await CallOllama(requestBody);
        }

        private async Task<bool> DetectDistraction(string description, string category)
        {
            var distractionCategories = new[] { "Social Media", "Entertainment" };
            if (distractionCategories.Contains(category))
                return true;

            var prompt = $@"Is this activity likely a distraction from focused work? Answer only 'yes' or 'no'.

Activity: {description}
Category: {category}";

            var requestBody = new
            {
                model = _model,
                prompt = prompt
            };

            var response = await CallOllama(requestBody);
            return response.ToLower().Contains("yes");
        }

        private async Task<string> CallOllama(object requestBody)
        {
            var json = JsonSerializer.Serialize(requestBody);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync(
                $"{_endpoint}/api/generate",
                content);

            response.EnsureSuccessStatusCode();

            var result = await response.Content.ReadAsStringAsync();
            var doc = JsonDocument.Parse(result);
            return doc.RootElement.GetProperty("response").GetString() ?? "";
        }
    }
}
