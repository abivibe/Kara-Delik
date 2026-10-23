; Inno Setup Script for KaraDelik Downloader
; Created for KaraDelik 1.0.2

#define MyAppName "KaraDelik"
#define MyAppVersion "1.0.2"
#define MyAppPublisher "KaraDelik"
#define MyAppExeName "karadelik.exe"

[Setup]
AppId={{5A8D2F82-D5E7-45A9-B587-B2A64585B1F1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://github.com/karadelik
AppSupportURL=https://github.com/karadelik
AppUpdatesURL=https://github.com/karadelik
DefaultDirName={autopf}\{#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=KaraDelik_Setup
SetupIconFile=windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DisableProgramGroupPage=yes
ChangesAssociations=yes
CloseApplications=force
CloseApplicationsFilter=*.exe
RestartApplications=no

; Meşru yayıncı ve sürüm künyesi (Antivirüs sezgisel motorlarının güvenini sağlar)
VersionInfoVersion=1.0.2.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Video ve Medya İndirici Kurulumu
VersionInfoTextVersion={#MyAppVersion}
VersionInfoCopyright=Copyright © 2026 {#MyAppPublisher}. Tüm hakları saklıdır.
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion=1.0.2.0

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; Microsoft Visual C++ 2015-2022 Redistributable Resmi Yükleyicisi
Source: "windows\redist\VC_redist.x64.exe"; DestDir: "{tmp}"; Flags: ignoreversion deleteafterinstall

; Tüm Uygulama Dosyaları
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; IconFilename: "{app}\{#MyAppExeName}"

[Run]
; Visual C++ Redistributable bağımlılığı gerekliyse sessizce kur
Filename: "{tmp}\VC_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Microsoft Visual C++ Redistributable bileşenleri yükleniyor..."; Check: VCRedistNeedsInstall; Flags: waituntilterminated

; Kurulum tamamlanınca uygulamayı başlat
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  FilesListBox: TNewListBox;

procedure KillRunningProcesses();
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/F /T /IM karadelik.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /T /IM KaraDelikNotifier.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /T /IM yt-dlp.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /T /IM ffmpeg.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(300);
end;

// Kuruluma başlarken çalışan eski exe'leri zorla kapat
function InitializeSetup(): Boolean;
begin
  KillRunningProcesses();
  Result := True;
end;

// Kaldırma işlemi başlatıldığında çalışan tüm KaraDelik exe'lerini zorla kapat
function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  KillRunningProcesses();
  Exec('taskkill.exe', '/F /T /IM Updater.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(200);
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    KillRunningProcesses();
  end;
end;

// Visual C++ 2015-2022 x64 kurulu mu kontrol et
function VCRedistNeedsInstall(): Boolean;
var
  Installed: Cardinal;
begin
  if RegQueryDWordValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) then
  begin
    Result := (Installed <> 1);
  end
  else
  begin
    Result := True;
  end;
end;

// Kurulacak dosyaların listesini Setup arayüzünde göster
procedure InitializeWizard();
begin
  WizardForm.FilenameLabel.Visible := True;

  FilesListBox := TNewListBox.Create(WizardForm);
  FilesListBox.Parent := WizardForm.InstallingPage;
  FilesListBox.Left := WizardForm.ProgressGauge.Left;
  FilesListBox.Top := WizardForm.ProgressGauge.Top + WizardForm.ProgressGauge.Height + ScaleY(12);
  FilesListBox.Width := WizardForm.ProgressGauge.Width;
  FilesListBox.Height := WizardForm.InstallingPage.Height - FilesListBox.Top - ScaleY(8);
  FilesListBox.Font.Name := 'Segoe UI';
  FilesListBox.Font.Size := 9;

  FilesListBox.Items.Add('Kurulum paketi içeriği:');
  FilesListBox.Items.Add('✔ karadelik.exe (Ana Uygulama Yürütülebilir Dosyası)');
  FilesListBox.Items.Add('✔ KaraDelikNotifier.exe (Özel Bildirim ve Pano Yöneticisi)');
  FilesListBox.Items.Add('✔ Updater.exe (Bağımsız Otomatik Güncelleme Yöneticisi)');
  FilesListBox.Items.Add('✔ ffmpeg.exe (Stüdyo Kalitesinde MP3/MP4 Medya Motoru)');
  FilesListBox.Items.Add('✔ yt-dlp.exe (Yedek Çok Katmanlı İndirme Motoru)');
  FilesListBox.Items.Add('✔ flutter_windows.dll (Flutter Windows 64-bit Motoru)');
  FilesListBox.Items.Add('✔ vcruntime140.dll & msvcp140.dll (C++ Runtime Kütüphaneleri)');
  FilesListBox.Items.Add('✔ VC_redist.x64.exe (Microsoft C++ 2015-2022 Dağıtılabilir Paketi)');
  FilesListBox.Items.Add('✔ data\app.so & data\icudtl.dat (Derlenmiş Kod ve Dil Tabloları)');
  FilesListBox.Items.Add('✔ data\flutter_assets (İkonlar, Varlıklar, Ses Dosyaları)');
  FilesListBox.Items.Add('✔ bildirimtetik.mp3 & completed.mp3 (Optimize Bildirim Sesleri)');
  FilesListBox.Items.Add('✔ Sistem Eklentileri (Window Manager, Tray, Launcher, vb.)');
end;

// Hazır (Ready) sayfasında kurulacak dosyaların özet listesini dök
function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S: String;
begin
  S := '';
  if MemoDirInfo <> '' then
    S := S + MemoDirInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then
    S := S + MemoTasksInfo + NewLine + NewLine;

  S := S + 'Kurulacak Temel Dosyalar ve Bileşenler:' + NewLine;
  S := S + Space + '• karadelik.exe (Ana Uygulama)' + NewLine;
  S := S + Space + '• KaraDelikNotifier.exe (Pano & Bildirim Servisi)' + NewLine;
  S := S + Space + '• Updater.exe (Otomatik Güncelleme Motoru)' + NewLine;
  S := S + Space + '• ffmpeg.exe (FFmpeg Yüksek Kalite Dönüştürücü)' + NewLine;
  S := S + Space + '• yt-dlp.exe (Yedek İndirme Motoru)' + NewLine;
  S := S + Space + '• flutter_windows.dll (Flutter Windows Çekirdeği)' + NewLine;
  S := S + Space + '• Microsoft Visual C++ 2015-2022 x64 Redistributable' + NewLine;
  S := S + Space + '• vcruntime140.dll, msvcp140.dll (C++ Çalışma Zamanı Kütüphaneleri)' + NewLine;
  S := S + Space + '• data/app.so & data/icudtl.dat (Uygulama Motoru ve Tablolar)' + NewLine;
  S := S + Space + '• assets/sounds (Optimize Bildirim Sesleri)' + NewLine;
  S := S + Space + '• Tüm sistem bağımlılıkları ve entegre eklentiler' + NewLine;

  Result := S;
end;
