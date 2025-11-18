using System;
using System.Windows;
using System.Windows.Input;

namespace Dayflow
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();

            // Save window position
            SourceInitialized += (s, e) =>
            {
                RestoreWindowPosition();
            };

            Closing += (s, e) =>
            {
                SaveWindowPosition();
            };
        }

        private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ClickCount == 2)
            {
                MaximizeButton_Click(sender, e);
            }
            else
            {
                DragMove();
            }
        }

        private void MinimizeButton_Click(object sender, RoutedEventArgs e)
        {
            WindowState = WindowState.Minimized;
        }

        private void MaximizeButton_Click(object sender, RoutedEventArgs e)
        {
            WindowState = WindowState == WindowState.Maximized
                ? WindowState.Normal
                : WindowState.Maximized;
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e)
        {
            // Hide to system tray instead of closing
            Hide();
        }

        private void SaveWindowPosition()
        {
            Properties.Settings.Default.WindowTop = Top;
            Properties.Settings.Default.WindowLeft = Left;
            Properties.Settings.Default.WindowHeight = Height;
            Properties.Settings.Default.WindowWidth = Width;
            Properties.Settings.Default.WindowState = WindowState;
            Properties.Settings.Default.Save();
        }

        private void RestoreWindowPosition()
        {
            if (Properties.Settings.Default.WindowTop >= 0)
            {
                Top = Properties.Settings.Default.WindowTop;
                Left = Properties.Settings.Default.WindowLeft;
                Height = Properties.Settings.Default.WindowHeight;
                Width = Properties.Settings.Default.WindowWidth;
                WindowState = Properties.Settings.Default.WindowState;
            }
        }
    }
}
