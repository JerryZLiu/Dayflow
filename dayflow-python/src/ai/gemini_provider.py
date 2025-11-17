"""
Google Gemini API provider for video analysis
"""

import google.generativeai as genai
from pathlib import Path
from typing import List, Dict, Optional
import time


class GeminiProvider:
    """Gemini AI provider for analyzing video chunks"""

    def __init__(self, api_key: str):
        self.api_key = api_key
        genai.configure(api_key=api_key)
        self.model = genai.GenerativeModel('gemini-1.5-flash')

    def analyze_video(self, video_path: Path) -> Optional[Dict]:
        """
        Analyze a video file and generate timeline information

        Returns:
            Dict with 'title', 'summary', 'category', 'activities'
        """
        try:
            # Upload video file
            print(f"📤 Uploading video to Gemini: {video_path.name}")
            video_file = genai.upload_file(path=str(video_path))

            # Wait for processing
            while video_file.state.name == "PROCESSING":
                time.sleep(1)
                video_file = genai.get_file(video_file.name)

            if video_file.state.name == "FAILED":
                print(f"❌ Video processing failed")
                return None

            # Generate analysis
            prompt = """Analyze this screen recording video and provide:
1. A concise title (max 5 words) describing the main activity
2. A brief summary (1-2 sentences) of what the person was doing
3. A category (choose one: Work, Communication, Development, Design, Entertainment,
   Productivity, Research, Social Media, Video, Music, Gaming, Other)
4. List of specific applications or activities visible

Format your response as JSON:
{
  "title": "Brief activity title",
  "summary": "Detailed summary of activities",
  "category": "Category name",
  "activities": ["activity1", "activity2"]
}
"""

            response = self.model.generate_content([video_file, prompt])

            # Clean up uploaded file
            genai.delete_file(video_file.name)

            # Parse response (try to extract JSON)
            response_text = response.text
            # Remove markdown code blocks if present
            if "```json" in response_text:
                response_text = response_text.split("```json")[1].split("```")[0]
            elif "```" in response_text:
                response_text = response_text.split("```")[1].split("```")[0]

            import json
            result = json.loads(response_text.strip())

            print(f"✅ Analysis complete: {result.get('title', 'Unknown')}")
            return result

        except Exception as e:
            print(f"❌ Gemini analysis error: {e}")
            return None

    def analyze_batch(self, video_paths: List[Path]) -> List[Dict]:
        """Analyze multiple videos (as individual chunks)"""
        results = []
        for video_path in video_paths:
            result = self.analyze_video(video_path)
            if result:
                results.append(result)
        return results
