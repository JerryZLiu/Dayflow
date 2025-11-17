#!/bin/bash
# Dayflow macOS/Linux Launcher

echo "===================================="
echo "  Dayflow - Starting..."
echo "===================================="
echo

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo "ERROR: Python 3 is not installed"
    echo "Please install Python 3.8+ from https://www.python.org/"
    exit 1
fi

# Check if dependencies are installed
python3 -c "import mss" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Installing dependencies..."
    python3 -m pip install -r requirements.txt
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to install dependencies"
        exit 1
    fi
fi

# Run Dayflow
echo "Starting Dayflow..."
python3 run.py
