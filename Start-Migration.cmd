@echo off
rem Offline launcher (no GitHub needed): elevates and runs the tool next to this file with the
rem execution policy bypassed for that window only. The tool then asks whether this is the old or the new PC.
rem Online alternative: see the bootstrap one-liner in README.md.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0Migrate-Windows.ps1\"'"
