using System;
using System.Windows;

namespace KaraDelik.Updater
{
    public partial class App : Application
    {
        private void App_Startup(object sender, StartupEventArgs e)
        {
            var mainWindow = new MainWindow(e.Args);
            mainWindow.Show();
        }
    }
}
