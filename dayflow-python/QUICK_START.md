# Dayflow Python - Quick Start Guide

## 🚀 5-Minute Setup

### Windows Users

1. **Install Python** (if not installed)
   - Download from: https://www.python.org/downloads/
   - ✅ Check "Add Python to PATH"

2. **Run Dayflow**
   - Double-click `run.bat`
   - Wait for dependencies to install

3. **Configure AI**
   - Click ⚙️ Settings
   - Select Gemini or Ollama
   - Enter API key (Gemini) or keep default URL (Ollama)

4. **Start Recording**
   - Click 🎥 Start Recording
   - Your timeline builds automatically!

---

### macOS/Linux Users

```bash
# Make executable
chmod +x run.sh

# Run
./run.sh
```

---

## 📋 What You'll See

### Main Window
- **Top bar**: Recording status and controls
- **Timeline**: Automatically generated activity cards
- **Settings**: Configure AI provider

### System Tray
- Shows recording status (red = recording)
- Quick access to start/stop
- Right-click for menu

---

## 🎯 First Steps

1. **Start recording** - Click the button, that's it!
2. **Wait 15 minutes** - First analysis happens automatically
3. **View timeline** - Cards appear showing your activities
4. **Review categories** - Work, Development, Communication, etc.

---

## ⚡ Pro Tips

### Get Better Results
- Use descriptive window titles
- Keep activities focused in 15-min blocks
- Gemini gives better results than Ollama

### Performance
- CPU usage: 1-5% while recording
- Storage: ~1-2 MB per hour of recording
- Auto-cleanup after 3 days

### Privacy
- All data stored locally (except Gemini uses cloud)
- No telemetry or tracking
- Use Ollama for 100% local processing

---

## ❓ Common Questions

**Q: Why no timeline cards?**
A: Wait 15 minutes, or click "Analyze Now"

**Q: How do I use Gemini?**
A: Get free API key from https://ai.google.dev/

**Q: How do I use Ollama?**
A: Install from https://ollama.com/, run `ollama pull llava`

**Q: Where are recordings stored?**
A: Windows: `C:\Users\{You}\AppData\Local\Dayflow\`
   macOS: `~/Library/Application Support/Dayflow/`

**Q: Can I run this 24/7?**
A: Yes! Low CPU/memory usage, auto-cleanup

---

## 🐛 Issues?

See `INSTALL.md` for detailed troubleshooting.

---

**That's it! You're ready to automatically track your day. 🎉**
