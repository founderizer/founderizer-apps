@echo off
rem Proof A's probe (azure-pc-make.sh probe): explorer starts this file with builder's limited token, as a person's
rem double-click, and it asks Windows for one elevated start of whoami.exe. A task of vm.sh desktop cannot ask it on
rem the Azure PC: it has the full token there, and a RunAs from a full token starts the program with that token at once,
rem with no rise, so the list would hold a whoami.exe that proves nothing.
powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath $env:WINDIR\System32\whoami.exe -Verb RunAs -WindowStyle Hidden -Wait"
