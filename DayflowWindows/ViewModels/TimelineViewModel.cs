using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Dayflow.Core.Storage;

namespace Dayflow.ViewModels
{
    public class TimelineViewModel : INotifyPropertyChanged
    {
        private readonly StorageManager _storage;

        public ObservableCollection<TimelineCard> Cards { get; set; } = new();

        public event PropertyChangedEventHandler? PropertyChanged;

        public TimelineViewModel(StorageManager storage)
        {
            _storage = storage;
            LoadCards();
        }

        private async void LoadCards()
        {
            var today = DateTime.Today;
            var cards = await _storage.GetChunksForDateRange(today, today.AddDays(1));
            // Convert chunks to timeline cards and populate ObservableCollection
        }

        protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
