@echo off
SET RELEASE=
for /f %%i in (..\RELEASE.txt) do set RELEASE=%%i
if "%RELEASE%"=="" goto _err_no_release

del *.msi
del *.wixobj

candle -out ts_block.wixobj ts_block.wxs
if errorlevel 1 goto _err_candle

light -out ..\ts_block_%RELEASE%.msi ts_block.wixobj
if errorlevel 1 goto _err_light

del ts_block.wixobj
goto :EOF

:_err_candle
echo Fatal Error - CANDLE returned error.
echo.
goto :EOF

:_err_light
echo Fatal Error - LIGHT returned error.
echo.
goto :EOF

:_err_no_release
echo Fatal Error - No ..\RELEASE.txt found.
echo.
