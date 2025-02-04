@echo off
setlocal EnableExtensions DisableDelayedExpansion
call app.bat
set SCRIPTDIR=%~dp0

set CERT_SHA1=%1

rem ==================================================
rem DEFINE path to NSIS binary here
SET MAKENSIS="C:\Program Files (x86)\NSIS\makensis.exe"
rem ==================================================
SET INSTALLER_OUT_DIR=%SCRIPTDIR%bin
set INSTALLER_TMP_DIR=%INSTALLER_OUT_DIR%\temp
SET FILE_LIST=%SCRIPTDIR%Installer\release-files.txt

set APPVER=???
set SERVICE_REPO=%SCRIPTDIR%..\..\..\daemon

rem Checking if msbuild available
WHERE msbuild >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
	echo [!] 'msbuild' is not recognized as an internal or external command
	echo [!] Ensure you are running this script from Developer Cammand Prompt for Visual Studio
	goto :error
)

rem Checking if NSIS  available
if not exist %MAKENSIS% (
    echo [!] NSIS binary not found [%MAKENSIS%]
	echo [!] Install NSIS [https://nsis.sourceforge.io/] or\and modify MAKENSIS variable of this script
	goto :error
)

call :read_app_version 				|| goto :error
echo     APPVER         : '%APPVER%'
echo     SOURCES Service: %SERVICE_REPO%

call :build_service						|| goto :error
call :build_ui								|| goto :error

call :copy_files 							|| goto :error
call :build_installer					|| goto :error

rem THE END
goto :success

:read_app_version
	echo [*] Reading App version ...

	set VERSTR=???
	set PackageJsonFile=%SCRIPTDIR%..\..\package.json
	set VerRegExp=^ *\"version\": *\".*\", *$

	set cmd=findstr /R /C:"%VerRegExp%" "%PackageJsonFile%"
	rem Find string in file
	FOR /F "tokens=* USEBACKQ" %%F IN (`%cmd%`) DO SET VERSTR=%%F
	if	"%VERSTR%" == "???" (
		echo "[!] ERROR: The file shall contain '"version": "X.X.X"' string"
		exit /b 1
 	)
	rem Get substring in quotes
	for /f tokens^=3^ delims^=^" %%a in ("%VERSTR%") do (
			set APPVER=%%a
	)
 
	goto :eof

:build_service
	echo [*] Building VPN service and dependencies...
	call %SERVICE_REPO%\References\Windows\scripts\build-all.bat %APPVER% %CERT_SHA1% || exit /b 1
	goto :eof

:build_ui
	echo ==================================================
	echo ============ BUILDING VPN UI ====================
	echo ==================================================

	jq ".productName = $APP_NAME"  "%PackageJsonFile%" --arg APP_NAME "%APP_NAME%" > temp.json && mv temp.json "%PackageJsonFile%"
	jq ".description = $DESC"  "%PackageJsonFile%" --arg DESC "%APP_NAME% Client For VPN Connection" > temp.json && mv temp.json "%PackageJsonFile%"
	jq ".name = $APP_ID"  "%PackageJsonFile%" --arg APP_ID "%APP_ID%" > temp.json && mv temp.json "%PackageJsonFile%"
	jq ".author = $AUTHOR"  "%PackageJsonFile%" --arg AUTHOR "%AUTHOR%" > temp.json && mv temp.json "%PackageJsonFile%"


  	cd %SCRIPTDIR%\..\..  || exit /b 1

	echo [*] Installing NPM dependencies...
	call npm install  || exit /b 1

	echo [*] Building UI...
	cd %SCRIPTDIR%  || exit /b 1
	call npm run electron:build || exit /b 1

	goto :eof

:copy_files
	set UI_BINARIES_FOLDER=%SCRIPTDIR%..\..\dist_electron\win-unpacked

	set TIMESTAMP_SERVER=http://timestamp.digicert.com
	if NOT "%CERT_SHA1%" == "" (
		echo.
		echo Signing binary by certificate:  %CERT_SHA1% timestamp: %TIMESTAMP_SERVER%
		echo.
		signtool.exe sign /tr %TIMESTAMP_SERVER% /td sha256 /fd sha256 /sha1 %CERT_SHA1% /v "%UI_BINARIES_FOLDER%\%APP_NAME%.exe" || exit /b 1
		echo.
		echo Signing SUCCES
		echo.
	)

	echo [*] Copying files...
	IF exist "%INSTALLER_TMP_DIR%" (
		rmdir /s /q "%INSTALLER_TMP_DIR%"
	)
	mkdir "%INSTALLER_TMP_DIR%"

	echo     Copying UI '%UI_BINARIES_FOLDER%' ...
	xcopy /E /I  "%UI_BINARIES_FOLDER%" "%INSTALLER_TMP_DIR%\ui" || goto :error
	echo     Renaming UI binary to 'VPN Client.exe' ...
	rename  "%INSTALLER_TMP_DIR%\ui\%APP_NAME%.exe" "%APP% Client.exe" || goto :error

	echo     Copying other files ...
	set BIN_FOLDER_SERVICE=%SERVICE_REPO%\bin\x86_64\
	set BIN_FOLDER_SERVICE_REFS=%SERVICE_REPO%\References\Windows\

	setlocal EnableDelayedExpansion
	for /f "tokens=*" %%i in (%FILE_LIST%) DO (
		set SRCPATH=???
		if exist "%BIN_FOLDER_SERVICE%%%i" set SRCPATH=%BIN_FOLDER_SERVICE%%%i
		if exist "%BIN_FOLDER_CLI%%%i" set SRCPATH=%BIN_FOLDER_CLI%%%i
		if exist "%BIN_FOLDER_SERVICE_REFS%%%i" set SRCPATH=%BIN_FOLDER_SERVICE_REFS%%%i
		if exist "%BIN_FOLDER_APP%%%i"  set SRCPATH=%BIN_FOLDER_APP%%%i
		if exist "%SCRIPTDIR%Installer\%%i" set SRCPATH=%SCRIPTDIR%Installer\%%i
		if !SRCPATH! == ??? (
			echo FILE '%%i' NOT FOUND!
			@REM exit /b 1
		)
		echo     !SRCPATH!

		IF NOT EXIST "%INSTALLER_TMP_DIR%\%%i\.." (
			MKDIR "%INSTALLER_TMP_DIR%\%%i\.."
		)

		copy /y "!SRCPATH!" "%INSTALLER_TMP_DIR%\%%i" > NUL
		IF !errorlevel! NEQ 0 (
			ECHO     Error: failed to copy "!SRCPATH!" to "%INSTALLER_TMP_DIR%"
			@REM EXIT /B 1
		)
	)
	mv "%INSTALLER_TMP_DIR%\VPN Service.exe" "%INSTALLER_TMP_DIR%\%APP% Service.exe" 
	goto :eof

:build_installer
	echo [*] Building installer...
	if NOT "%CERT_SHA1%" == "" (
		call "%PATH_UI_REPO%\References\Windows\verify-bin-signs.bat" || exit /b 1
	)

	cd %SCRIPTDIR%\Installer

	SET OUT_FILE="%INSTALLER_OUT_DIR%\%APP%-Client-v%APPVER%.exe"
	%MAKENSIS% /DPRODUCT_VERSION="%APPVER%"  /DPRODUCT_NAME="%APP_NAME%" /DPRODUCT_SLUG="%APP%" /DOUT_FILE=%OUT_FILE% /DSOURCE_DIR=%INSTALLER_TMP_DIR% "VPN Client.nsi"
	IF not ERRORLEVEL 0 (
		ECHO [!] Error: failed to create installer
		EXIT /B 1
	)
	goto :eof

:success
	goto :remove_tmp_vars_before_exit
	echo [*] SUCCESS
	exit /b 0

:error
	goto :remove_tmp_vars_before_exit
	echo [!] VPN Client installer build FAILED with error #%errorlevel%.
	exit /b %errorlevel%

:remove_tmp_vars_before_exit
	endlocal
	goto :eof
