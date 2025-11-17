"""
Ollama local LLM provider for video analysis
Uses frame extraction + vision model
"""

import requests
import base64
import cv2
from pathlib import Path
from typing import List, Dict, Optional
import json


class OllamaProvider:
    """Ollama provider for local video analysis"""

    def __init__(self, base_url: str = "http://localhost:11434", model: str = "llava"):
        self.base_url = base_url.rstrip('/')
        self.model = model

    def _extract_frames(self, video_path: Path, num_frames: int = 10) -> List[bytes]:
        """Extract evenly-spaced frames from video"""
        cap = cv2.VideoCapture(str(video_path))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

        if total_frames == 0:
            cap.release()
            return []

        # Calculate frame indices to extract
        frame_indices = [int(i * total_frames / num_frames) for i in range(num_frames)]

        frames = []
        for idx in frame_indices:
            cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
            ret, frame = cap.read()
            if ret:
                # Convert to JPEG bytes
                _, buffer = cv2.imencode('.jpg', frame)
                frames.append(buffer.tobytes())

        cap.release()
        return frames

    def _analyze_frame(self, frame_bytes: bytes) -> Optional[str]:
        """Analyze a single frame using Ollama vision model"""
        try:
            # Encode frame as base64
            frame_b64 = base64.b64encode(frame_bytes).decode('utf-8')

            # Send to Ollama
            response = requests.post(
                f"{self.base_url}/api/generate",
                json={
                    "model": self.model,
                    "prompt": "Describe what application or activity is shown in this screenshot. "
                              "Be concise and specific. Just describe what you see.",
                    "images": [frame_b64],
                    "stream": False
                },
                timeout=30
            )

            if response.status_code == 200:
                result = response.json()
                return result.get('response', '').strip()
            else:
                print(f"❌ Ollama API error: {response.status_code}")
                return None

        except Exception as e:
            print(f"❌ Frame analysis error: {e}")
            return None

    def _synthesize_descriptions(self, descriptions: List[str]) -> Optional[Dict]:
        """Synthesize frame descriptions into timeline card"""
        try:
            # Combine descriptions
            combined = "\n".join([f"- {desc}" for desc in descriptions if desc])

            prompt = f"""Based on these screen activity descriptions, create a summary:

{combined}

Provide a JSON response with:
1. title: A concise title (max 5 words)
2. summary: Brief summary of activities (1-2 sentences)
3. category: Choose from (Work, Communication, Development, Design, Entertainment,
   Productivity, Research, Social Media, Video, Music, Gaming, Other)

Format as JSON only:
{{"title": "...", "summary": "...", "category": "..."}}
"""

            response = requests.post(
                f"{self.base_url}/api/generate",
                json={
                    "model": self.model,
                    "prompt": prompt,
                    "stream": False
                },
                timeout=30
            )

            if response.status_code == 200:
                result = response.json()
                response_text = result.get('response', '').strip()

                # Try to extract JSON
                if '{' in response_text and '}' in response_text:
                    json_start = response_text.index('{')
                    json_end = response_text.rindex('}') + 1
                    json_str = response_text[json_start:json_end]
                    return json.loads(json_str)

            return None

        except Exception as e:
            print(f"❌ Synthesis error: {e}")
            return None

    def analyze_video(self, video_path: Path) -> Optional[Dict]:
        """
        Analyze a video file using frame extraction + description

        Returns:
            Dict with 'title', 'summary', 'category'
        """
        try:
            print(f"🎬 Extracting frames from: {video_path.name}")
            frames = self._extract_frames(video_path, num_frames=5)

            if not frames:
                print(f"❌ No frames extracted")
                return None

            print(f"🔍 Analyzing {len(frames)} frames...")
            descriptions = []
            for i, frame_bytes in enumerate(frames):
                desc = self._analyze_frame(frame_bytes)
                if desc:
                    descriptions.append(desc)
                    print(f"  Frame {i+1}/{len(frames)}: {desc[:60]}...")

            if not descriptions:
                print(f"❌ No descriptions generated")
                return None

            print(f"📝 Synthesizing results...")
            result = self._synthesize_descriptions(descriptions)

            if result:
                print(f"✅ Analysis complete: {result.get('title', 'Unknown')}")
                return result
            else:
                # Fallback: create basic result from descriptions
                return {
                    "title": "Screen Activity",
                    "summary": ". ".join(descriptions[:2]),
                    "category": "Other"
                }

        except Exception as e:
            print(f"❌ Ollama analysis error: {e}")
            return None

    def analyze_batch(self, video_paths: List[Path]) -> List[Dict]:
        """Analyze multiple videos"""
        results = []
        for video_path in video_paths:
            result = self.analyze_video(video_path)
            if result:
                results.append(result)
        return results
