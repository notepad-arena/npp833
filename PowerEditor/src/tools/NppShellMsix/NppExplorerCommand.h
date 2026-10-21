// This file is part of Notepad++ project
// Copyright (C)2021 Don HO <don.h@free.fr>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// at your option any later version.
//
// MSIX context menu handler for Windows 10 (classic menu) and Windows 11 (top level menu).
//
// This DLL is NOT a classic in-process shell extension: MSIX does not allow those. It is
// declared in Package.appxmanifest as a packaged COM *surrogate* server
//   <com:SurrogateServer AppId="..."><com:Class Id="..." Path="NppShellMsix.dll" ... />
// so the shell loads it into dllhost.exe (out of process) and talks to it through
// IExplorerCommand. Windows 10 1903+ and Windows 11 both understand that; the manifest
// extension that points at this class is <desktop4:FileExplorerContextMenus>.

#pragma once

#include <windows.h>
#include <shobjidl.h>

// {8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11}
// Keep this in sync with:
//   * Package.appxmanifest  (com:Class Id and desktop4:Verb Clsid)
//   * the AppId of the com:SurrogateServer entry
class __declspec(uuid("8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11")) CNppExplorerCommand;

// Keeps the module alive while a command object exists (see dllmain.cpp).
void NppServerAddRef();
void NppServerRelease();

class CNppExplorerCommand : public IExplorerCommand
{
public:
    CNppExplorerCommand();

    // IUnknown
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    IFACEMETHODIMP_(ULONG) AddRef() override;
    IFACEMETHODIMP_(ULONG) Release() override;

    // IExplorerCommand
    IFACEMETHODIMP GetTitle(IShellItemArray* psiItemArray, LPWSTR* ppszName) override;
    IFACEMETHODIMP GetIcon(IShellItemArray* psiItemArray, LPWSTR* ppszIcon) override;
    IFACEMETHODIMP GetToolTip(IShellItemArray* psiItemArray, LPWSTR* ppszInfotip) override;
    IFACEMETHODIMP GetCanonicalName(GUID* pguidCommandName) override;
    IFACEMETHODIMP GetState(IShellItemArray* psiItemArray, BOOL fOkToBeSlow, EXPCMDSTATE* pCmdState) override;
    IFACEMETHODIMP Invoke(IShellItemArray* psiItemArray, IBindCtx* pbc) override;
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* pFlags) override;
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** ppEnum) override;

private:
    ~CNppExplorerCommand();

    LONG _refCount;
};
