using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Dayflow.Core.Recording;
using Dayflow.Core.Storage;

namespace Dayflow.ViewModels
{
    public class MainViewModel : INotifyPropertyChanged
    {
        private readonly ScreenRecorder _recorder;
        private readonly StorageManager _storage;
        private bool _isRecording;

        public event PropertyChangedEventHandler? PropertyChanged;

        public bool IsRecording
        {
            get => _isRecording;
            set
            {
                if (_isRecording != value)
                {
                    _isRecording = value;
                    OnPropertyChanged();
                    OnPropertyChanged(nameof(RecordingButtonText));
                }
            }
        }

        public string RecordingButtonText => IsRecording ? "Stop Recording" : "Start Recording";

        public MainViewModel(ScreenRecorder recorder, StorageManager storage)
        {
            _recorder = recorder;
            _storage = storage;

            _recorder.StateChanged += (s, e) => IsRecording = e.IsRecording;
        }

        protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
