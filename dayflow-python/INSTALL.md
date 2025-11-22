# Dayflow Python - Installation Guide

## For Windows Users (Simplest Method)

### Step 1: Install Python

1. Go to https://www.python.org/downloads/
2. Download **Python 3.10 or 3.11** (recommended)
3. **IMPORTANT**: During installation, check ☑️ **"Add Python to PATH"**
4. Click "Install Now"

### Step 2: Verify Python Installation

1. Open **Command Prompt** (search "cmd" in Start menu)
2. Type: `python --version`
3. Should show: `Python 3.10.x` or similar

### Step 3: Run Dayflow

1. Navigate to the `dayflow-python` folder
2. **Double-click `run.bat`**
3. First time will install dependencies (takes 1-2 minutes)
4. Dayflow window will open!

### Step 4: Configure (First Launch)

1. Click **⚙️ Settings**
2. Choose AI provider:
   - **Gemini**: Get free API key from https://ai.google.dev/
   - **Ollama**: Install from https://ollama.com/, then run `ollama pull llava`
3. Click **💾 Save Settings**
4. Click **🎥 Start Recording**

Done! Your timeline will build automatically every 15 minutes.

---

## For macOS Users

### Step 1: Install Python (if not already installed)

```bash
# Check if Python 3 is installed
python3 --version

# If not installed, install via Homebrew:
brew install python@3.10
```

### Step 2: Run Dayflow

```bash
# Navigate to dayflow-python folder
cd dayflow-python

# Make launcher executable
chmod +x run.sh

# Run
./run.sh
```

### Step 3: Grant Permissions

macOS will ask for **Screen Recording** permission:
1. Go to **System Settings** → **Privacy & Security**
2. Enable **Screen Recording** for Terminal (or your terminal app)
3. Restart Dayflow

---

## For Linux Users

### Step 1: Install Dependencies

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install python3 python3-pip python3-tk

# Fedora
sudo dnf install python3 python3-pip python3-tkinter

# Arch
sudo pacman -S python python-pip tk
```

### Step 2: Install Dayflow Dependencies

```bash
cd dayflow-python
pip3 install -r requirements.txt
```

### Step 3: Run

```bash
python3 run.py
```

---

## Troubleshooting

### "Python is not recognized as an internal or external command"

**Windows:**
- Python not added to PATH during installation
- Solution: Reinstall Python, check "Add Python to PATH"
- Or add manually: System → Advanced → Environment Variables → Path → Add Python folder

### "ModuleNotFoundError"

Dependencies not installed. Run:

```bash
pip install -r requirements.txt
```

### "Permission denied" (macOS/Linux)

Script not executable:

```bash
chmod +x run.sh
```

### Gemini API Errors

1. Check API key is correct
2. Enable Gemini API at https://console.cloud.google.com/
3. Check internet connection

### Ollama Not Working

1. Install Ollama: https://ollama.com/
2. Start server: `ollama serve`
3. Pull model: `ollama pull llava`
4. Verify URL in settings: `http://localhost:11434`

---

## Manual Installation (Advanced)

If automatic installation doesn't work:

```bash
# Create virtual environment (optional but recommended)
python -m venv venv

# Activate virtual environment
# Windows:
venv\Scripts\activate
# macOS/Linux:
source venv/bin/activate

# Install dependencies manually
pip install mss>=9.0.1
pip install opencv-python>=4.8.0
pip install Pillow>=10.0.0
pip install numpy>=1.24.0
pip install customtkinter>=5.2.0
pip install pystray>=0.19.0
pip install google-generativeai>=0.3.0
pip install requests>=2.31.0
pip install python-dotenv>=1.0.0
pip install python-dateutil>=2.8.2
pip install pynput>=1.7.6
pip install coloredlogs>=15.0.1

# Windows only:
pip install pywin32>=306

# Run
python run.py
```

---

## System Requirements

### Minimum
- **CPU**: Dual-core 2.0 GHz
- **RAM**: 4GB
- **Storage**: 500MB (for app) + recordings
- **OS**: Windows 10+, macOS 10.14+, Linux (Ubuntu 20.04+)
- **Python**: 3.8 or higher

### Recommended
- **CPU**: Quad-core 2.5 GHz+
- **RAM**: 8GB+
- **Storage**: 2GB+ free space
- **OS**: Windows 11, macOS 13+, Ubuntu 22.04+
- **Python**: 3.10 or 3.11

---

## First Time Setup Checklist

- [ ] Python installed and in PATH
- [ ] Dependencies installed (`pip install -r requirements.txt`)
- [ ] Dayflow runs without errors
- [ ] AI provider configured (Gemini or Ollama)
- [ ] Recording permission granted (macOS)
- [ ] First recording started
- [ ] Timeline cards appearing after 15 minutes

---

## Getting Help

If you encounter issues:

1. Check error messages carefully
2. Review troubleshooting section above
3. Check README.md for detailed documentation
4. Report issues on GitHub

---

**Ready to track your day? Run `run.bat` (Windows) or `./run.sh` (macOS/Linux) to get started!**
