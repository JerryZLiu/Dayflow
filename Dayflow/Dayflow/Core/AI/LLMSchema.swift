import Foundation

enum LLMSchema {
    static let screenRecordingTranscriptionSchema: String = """
    {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "startTimestamp": {
            "type": "string",
            "description": "The start timestamp of the segment in 'MM:SS' format."
          },
          "endTimestamp": {
            "type": "string",
            "description": "The end timestamp of the segment in 'MM:SS' format."
          },
          "description": {
            "type": "string",
            "description": "A 1-3 sentence description of the activity in the segment."
          }
        },
        "required": ["startTimestamp", "endTimestamp", "description"]
      }
    }
    """

    static let activityCardsSchema: String = """
    {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "startTime": {
            "type": "string",
            "description": "The start time of the activity card in 'h:mm a' format (e.g., '1:12 AM')."
          },
          "endTime": {
            "type": "string",
            "description": "The end time of the activity card in 'h:mm a' format (e.g., '1:30 AM')."
          },
          "category": {
            "type": "string",
            "description": "The category of the activity."
          },
          "subcategory": {
            "type": "string",
            "description": "The subcategory of the activity."
          },
          "title": {
            "type": "string",
            "description": "A concise title for the activity card."
          },
          "summary": {
            "type": "string",
            "description": "A 2-3 sentence summary of the activity."
          },
          "detailedSummary": {
            "type": "string",
            "description": "A detailed, granular log of the activity."
          },
          "distractions": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "startTime": {
                  "type": "string",
                  "description": "The start time of the distraction in 'h:mm a' format."
                },
                "endTime": {
                  "type": "string",
                  "description": "The end time of the distraction in 'h:mm a' format."
                },
                "title": {
                  "type": "string",
                  "description": "A title for the distraction."
                },
                "summary": {
                  "type": "string",
                  "description": "A summary of the distraction."
                }
              },
              "required": ["startTime", "endTime", "title", "summary"]
            }
          },
          "appSites": {
            "type": "object",
            "properties": {
              "primary": {
                "type": "string",
                "description": "The primary app or website used."
              },
              "secondary": {
                "type": "string",
                "description": "The secondary app or website used."
              }
            },
            "required": ["primary"]
          }
        },
        "required": ["startTime", "endTime", "category", "title", "summary", "detailedSummary", "appSites"]
      }
    }
    """
}
