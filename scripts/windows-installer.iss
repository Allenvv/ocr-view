#ifndef BundleDir
  #error Specify /DBundleDir=<Flutter Windows x64 Release directory>
#endif
#ifndef AppVersion
  #error Specify /DAppVersion=<application version>
#endif
#ifndef VcRedist
  #error Specify /DVcRedist=<offline Microsoft x64 VC++ redistributable executable>
#endif
#if !FileExists(BundleDir + "\pm25_capture.exe") || !FileExists(BundleDir + "\onnxruntime.dll") || !FileExists(BundleDir + "\rec.onnx") || !FileExists(BundleDir + "\rec.conf") || !FileExists(BundleDir + "\rec.dict") || !FileExists(BundleDir + "\uvc.conf")
  #error Build the Windows bundle with the real offline assets and x64 ONNX Runtime first.
#endif

[Setup]
AppId=PM25Capture.Laboratory
AppName=PM2.5 Capture
AppVersion={#AppVersion}
DefaultDirName={autopf}\PM25 Capture
DefaultGroupName=PM2.5 Capture
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
OutputBaseFilename=PM25-Capture-{#AppVersion}-x64-setup
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
CloseApplications=yes

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#VcRedist}"; DestDir: "{tmp}"; DestName: "vc_redist.x64.exe"; Flags: deleteafterinstall

[Icons]
Name: "{group}\PM2.5 Capture"; Filename: "{app}\pm25_capture.exe"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    if not Exec(ExpandConstant('{tmp}\vc_redist.x64.exe'), '/install /quiet /norestart', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Could not launch the bundled x64 VC++ runtime installer.');
    if (ResultCode <> 0) and (ResultCode <> 1638) and (ResultCode <> 3010) then
      RaiseException(Format('The bundled x64 VC++ runtime installer failed (%d).', [ResultCode]));
  end;
end;
